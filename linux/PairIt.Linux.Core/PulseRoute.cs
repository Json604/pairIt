using System.Diagnostics;
using System.Globalization;
using System.Text.Json;

namespace PairIt.Linux;

public interface IPulseCommands
{
    Task<string> RunAsync(CancellationToken cancellation, params string[] arguments);
}

public sealed class PulseCommands : IPulseCommands
{
    public async Task<string> RunAsync(CancellationToken cancellation, params string[] arguments)
    {
        using var process = PulseAudio.Start("pactl", arguments);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        deadline.CancelAfter(TimeSpan.FromSeconds(5));
        try {
            var output = PulseAudio.ReadBoundedAsync(process.StandardOutput, deadline.Token);
            var error = PulseAudio.ReadBoundedAsync(process.StandardError, deadline.Token);
            await process.WaitForExitAsync(deadline.Token);
            var result = await output; await error;
            if (process.ExitCode != 0) throw new IOException("The audio server could not change the selected output. Check your PipeWire/PulseAudio session.");
            return result.Trim();
        } finally { PulseAudio.Stop(process); }
    }
}

// One active capture owns one uniquely named sink. Never mute a physical sink:
// its monitor can become silent too, and another application may own its mute.
public sealed class PulseRoute(IPulseCommands commands) : IAsyncDisposable
{
    public string SinkName { get; } = "pairit_relay_" + Guid.NewGuid().ToString("N");
    public string Monitor => SinkName + ".monitor";
    private string? selected, previousDefault;
    private uint? module;
    private readonly HashSet<uint> seen = [];
    private readonly Dictionary<uint, string> originalRoutes = [];
    private Process? guardian;
    private bool disposed;

    public async Task StartAsync(string monitor, CancellationToken cancellation)
    {
        if (module != null || disposed) throw new InvalidOperationException("Route already used.");
        var sinks = await SinksAsync(cancellation);
        selected = sinks.SingleOrDefault(s => s.Monitor == monitor && !s.Name.StartsWith("pairit_relay_", StringComparison.Ordinal))?.Name
            ?? throw new IOException("Selected output is no longer available.");
        previousDefault = (await commands.RunAsync(cancellation, "get-default-sink")).Trim();
        foreach (var input in await InputsAsync(cancellation)) {
            var original = sinks.FirstOrDefault(s => s.Index == input.Sink)?.Name;
            if (original != null) originalRoutes[input.Index] = original;
        }
        try {
            var id = await commands.RunAsync(cancellation, "load-module", "module-null-sink", "sink_name=" + SinkName,
                "rate=48000", "channels=2", "channel_map=front-left,front-right", "sink_properties=device.description=PairIt_Phone_Audio");
            if (!uint.TryParse(id, NumberStyles.None, CultureInfo.InvariantCulture, out var value))
                throw new IOException("The audio server did not identify the temporary output.");
            module = value;
            if (commands is PulseCommands) guardian = StartGuardian();
            var selectedOutput = sinks.Single(s => s.Name == selected);
            if (selectedOutput.Volume is uint volume)
                await commands.RunAsync(cancellation, "set-sink-volume", SinkName, volume.ToString(CultureInfo.InvariantCulture));
            if (selectedOutput.Muted)
                await commands.RunAsync(cancellation, "set-sink-mute", SinkName, "1");
            if (previousDefault == selected) await commands.RunAsync(cancellation, "set-default-sink", SinkName);
            await RefreshAsync(cancellation);
        } catch {
            await DisposeAsync();
            throw;
        }
    }

    public async Task RefreshAsync(CancellationToken cancellation)
    {
        var sinks = await SinksAsync(cancellation);
        var relay = sinks.SingleOrDefault(s => s.Name == SinkName && s.Module == module)
            ?? throw new IOException("PairIt's temporary audio output disappeared.");
        var origin = sinks.SingleOrDefault(s => s.Name == selected)
            ?? throw new IOException("The selected computer output disconnected.");
        foreach (var input in await InputsAsync(cancellation)) {
            // A user's explicit move after we first observed a stream wins.
            if (!seen.Add(input.Index)) continue;
            if (input.Sink == origin.Index) {
                originalRoutes[input.Index] = origin.Name;
                await MoveAsync(input.Index, SinkName, cancellation);
            } else if (input.Sink == relay.Index && originalRoutes.TryGetValue(input.Index, out var original) && original != selected) {
                // Some servers move default-following streams when the default changes.
                // Do not take streams that were on a different selected output.
                await MoveAsync(input.Index, original, cancellation);
            }
        }
    }

    private async Task MoveAsync(uint input, string sink, CancellationToken cancellation)
    {
        try { await commands.RunAsync(cancellation, "move-sink-input", input.ToString(CultureInfo.InvariantCulture), sink); }
        catch (IOException) {
            // Players can close between enumeration and movement. A vanished
            // stream is already cleaned up, not an audio-server routing failure.
            if ((await InputsAsync(cancellation)).Any(value => value.Index == input)) throw;
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (disposed) return;
        disposed = true;
        try {
            if (module == null) return;
            var sinks = await SinksAsync(CancellationToken.None);
            var relay = sinks.SingleOrDefault(s => s.Name == SinkName && s.Module == module);
            if (relay == null) return; // A restarted server may reuse module IDs.
            var currentDefault = await commands.RunAsync(CancellationToken.None, "get-default-sink");
            var fallback = sinks.FirstOrDefault(s => s.Name == selected)?.Name
                ?? sinks.FirstOrDefault(s => s.Name == currentDefault && !s.Name.StartsWith("pairit_relay_", StringComparison.Ordinal))?.Name
                ?? sinks.FirstOrDefault(s => s.Name == previousDefault)?.Name;
            // If every prior output disappeared, let server policy choose on
            // unload; never choose an arbitrary sink such as a microphone cable.
            if (currentDefault == SinkName && fallback != null)
                await commands.RunAsync(CancellationToken.None, "set-default-sink", fallback);
            foreach (var input in await InputsAsync(CancellationToken.None)) {
                if (input.Sink != relay.Index) continue;
                var target = originalRoutes.TryGetValue(input.Index, out var original) && sinks.Any(s => s.Name == original) ? original : fallback;
                if (target != null) await MoveAsync(input.Index, target, CancellationToken.None);
            }
            await commands.RunAsync(CancellationToken.None, "unload-module", module.Value.ToString(CultureInfo.InvariantCulture));
        } finally {
            // EOF is also delivered when the parent crashes; helper attempts cleanup.
            if (guardian != null) {
                guardian.StandardInput.Close();
                try { await guardian.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(8)); }
                catch (TimeoutException) { /* Keep the independent recovery helper alive. */ }
                guardian.Dispose(); guardian = null;
            }
        }
    }

    private Process StartGuardian()
    {
        var info = new ProcessStartInfo("/bin/sh") { UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        info.ArgumentList.Add("-c"); info.ArgumentList.Add(GuardianScript);
        info.ArgumentList.Add("pairit-route-cleanup"); info.ArgumentList.Add(SinkName);
        info.ArgumentList.Add(module!.Value.ToString(CultureInfo.InvariantCulture)); info.ArgumentList.Add(selected!);
        info.ArgumentList.Add(previousDefault!);
        return Process.Start(info) ?? throw new IOException("Could not start audio route recovery.");
    }

    // All identifiers are argv, never executable shell interpolation. Only unload
    // the exact uniquely named module we created, never modules owned by others.
    private const string GuardianScript = """
        read -r ignored
        relay=$1; module=$2; original=$3; previous=$4
        owned=$(pactl list short modules 2>/dev/null | awk -v id="$module" -v name="$relay" '$1 == id && $2 == "module-null-sink" && index($0, "sink_name=" name) { print $1 }')
        [ "$owned" = "$module" ] || exit 0
        sink_id=$(pactl list short sinks 2>/dev/null | awk -v name="$relay" '$2 == name { print $1 }')
        [ -n "$sink_id" ] || exit 0
        target=$(pactl list short sinks 2>/dev/null | awk -v name="$original" '$2 == name { print $2 }')
        if [ -z "$target" ]; then target=$(pactl list short sinks 2>/dev/null | awk -v name="$previous" '$2 == name { print $2 }'); fi
        if [ -n "$target" ]; then
            if [ "$(pactl get-default-sink 2>/dev/null)" = "$relay" ]; then pactl set-default-sink "$target" >/dev/null 2>&1; fi
            pactl list short sink-inputs 2>/dev/null | while read -r id sink rest; do
                if [ "$sink" = "$sink_id" ]; then pactl move-sink-input "$id" "$target" >/dev/null 2>&1; fi
            done
        fi
        pactl unload-module "$module" >/dev/null 2>&1
        """;

    private sealed record Sink(uint Index, string Name, string Monitor, uint? Module, uint? Volume, bool Muted);
    private sealed record Input(uint Index, uint Sink);
    private async Task<List<Sink>> SinksAsync(CancellationToken cancellation)
    {
        using var json = JsonDocument.Parse(await commands.RunAsync(cancellation, "--format=json", "list", "sinks"));
        var result = new List<Sink>();
        foreach (var item in json.RootElement.EnumerateArray()) {
            var name = item.GetProperty("name").GetString(); var monitor = item.GetProperty("monitor_source").GetString();
            if (name == null || monitor == null || !PulseAudio.ValidEndpoint(name) || !PulseAudio.ValidEndpoint(monitor)) continue;
            uint? owner = item.TryGetProperty("owner_module", out var m) && m.TryGetUInt32(out var id) ? id : null;
            uint? volume = null;
            if (item.TryGetProperty("volume", out var channels) && channels.ValueKind == JsonValueKind.Object) {
                var levels = channels.EnumerateObject().Select(c => c.Value.GetProperty("value").GetUInt32()).ToArray();
                if (levels.Length > 0) volume = (uint)Math.Round(levels.Average(v => (double)v));
            }
            var muted = item.TryGetProperty("mute", out var mute) && mute.ValueKind == JsonValueKind.True;
            result.Add(new(item.GetProperty("index").GetUInt32(), name, monitor, owner, volume, muted));
        }
        return result;
    }
    private async Task<List<Input>> InputsAsync(CancellationToken cancellation)
    {
        using var json = JsonDocument.Parse(await commands.RunAsync(cancellation, "--format=json", "list", "sink-inputs"));
        return json.RootElement.EnumerateArray().Select(i => new Input(i.GetProperty("index").GetUInt32(), i.GetProperty("sink").GetUInt32())).ToList();
    }
}
