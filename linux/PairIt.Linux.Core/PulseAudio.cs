using System.Diagnostics;
using System.Text.Json;
using System.Text.RegularExpressions;
using PairIt.Core;

namespace PairIt.Linux;

public sealed record AudioOutput(string Name, string Description, string Monitor, uint? Volume = null, bool Virtual = false)
{
    public override string ToString() => Description;
}

public static partial class PulseAudio
{
    [GeneratedRegex(@"^[A-Za-z0-9_][A-Za-z0-9_.:-]{0,255}$")]
    private static partial Regex EndpointName();
    public static bool ValidEndpoint(string value) => EndpointName().IsMatch(value);
    public static IReadOnlyList<AudioOutput> ParseSinks(string json)
    {
        using var document = JsonDocument.Parse(json);
        var outputs = new List<AudioOutput>();
        foreach (var sink in document.RootElement.EnumerateArray())
        {
            if (!sink.TryGetProperty("name", out var name) || !sink.TryGetProperty("monitor_source", out var monitor) ||
                name.ValueKind != JsonValueKind.String || monitor.ValueKind != JsonValueKind.String) continue;
            var id = name.GetString()!; var source = monitor.GetString()!;
            if (!ValidEndpoint(id) || !ValidEndpoint(source)) continue;
            var label = sink.TryGetProperty("description", out var description) && description.ValueKind == JsonValueKind.String ? description.GetString() : id;
            uint? volume = null;
            if (sink.TryGetProperty("volume", out var channels) && channels.ValueKind == JsonValueKind.Object) {
                var levels = channels.EnumerateObject().Select(channel => channel.Value.TryGetProperty("value", out var scalar) && scalar.TryGetDouble(out var number) ? number / 65536.0 : double.NaN).Where(double.IsFinite).ToArray();
                if (levels.Length > 0) volume = (uint)Math.Round(Math.Clamp(levels.Average(), 0, 1) * 1000) | (sink.TryGetProperty("mute", out var mute) && mute.ValueKind == JsonValueKind.True ? 0x10000u : 0u);
            }
            bool virtualOutput = sink.TryGetProperty("driver", out var driver) && driver.GetString() == "module-null-sink.c";
            if (sink.TryGetProperty("properties", out var properties) && properties.TryGetProperty("device.class", out var deviceClass))
                virtualOutput |= deviceClass.GetString() == "abstract";
            outputs.Add(new(id, string.IsNullOrWhiteSpace(label) ? id : label, source, volume, virtualOutput));
        }
        return outputs;
    }
    public static async Task<IReadOnlyList<AudioOutput>> ListAsync()
    {
        using var process = Start("/usr/bin/pactl", "--format=json", "list", "sinks");
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        try
        {
            var stdout = ReadBoundedAsync(process.StandardOutput, deadline.Token);
            var stderr = ReadBoundedAsync(process.StandardError, deadline.Token);
            await process.WaitForExitAsync(deadline.Token);
            var json = await stdout; await stderr;
            if (process.ExitCode != 0) throw new IOException("Start your PipeWire/PulseAudio user session, then refresh outputs.");
            return ParseSinks(json);
        }
        finally { Stop(process); }
    }
    private static async Task<string> ReadBoundedAsync(StreamReader reader, CancellationToken cancellation)
    {
        var text = new System.Text.StringBuilder(); var buffer = new char[4096];
        int count;
        while ((count = await reader.ReadAsync(buffer, cancellation)) != 0)
        {
            if (text.Length + count > 1024 * 1024) throw new IOException("Audio server response is too large.");
            text.Append(buffer, 0, count);
        }
        return text.ToString();
    }
    internal static Process Start(string executable, params string[] arguments)
    {
        var info = new ProcessStartInfo(executable) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var value in arguments) info.ArgumentList.Add(value);
        return Process.Start(info) ?? throw new IOException("Could not start the PulseAudio client.");
    }
    internal static void Stop(Process process)
    {
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
        catch (InvalidOperationException) { }
    }
}

public sealed class LinuxAudioEndpoints : IAudioEndpoints
{
    public ISystemAudioSource CreateSource(string endpointId) => new PulseSource(endpointId);
    public async Task<IMicrophoneSink> OpenMicrophoneSinkAsync(string endpointId, CancellationToken cancellation)
    {
        cancellation.ThrowIfCancellationRequested();
        if (!(await PulseAudio.ListAsync()).Any(output => output.Name == endpointId && output.Virtual))
            throw new IOException("Choose an available virtual sink for phone microphone audio.");
        return new PulseMicrophoneSink(endpointId);
    }
}

public sealed class PulseSource(string monitor) : ISystemAudioSource
{
    private readonly CancellationTokenSource lifetime = new();
    private Process? process;
    private Task? reader, errors, volumeObserver;
    private int computerVolume = -1;
    public uint? ComputerVolume => Volatile.Read(ref computerVolume) is var value && value >= 0 ? (uint)value : null;
    private int disposed;
    public async Task StartAsync(Action<SourcePacket> received, Action<string> failed, CancellationToken cancellation)
    {
        ObjectDisposedException.ThrowIf(disposed != 0, this);
        cancellation.ThrowIfCancellationRequested();
        if (process != null) throw new InvalidOperationException("Capture already started.");
        var outputs = await PulseAudio.ListAsync();
        if (!outputs.Any(output => output.Monitor == monitor)) throw new IOException("Selected output is no longer available.");
        // Explicit sink monitors only: never fall back to the default microphone.
        process = PulseAudio.Start("/usr/bin/parec", "--raw", "--format=s16le", "--rate=48000", "--channels=2",
            "--channel-map=front-left,front-right", "--latency-msec=20", "--client-name=PairIt", "--device=" + monitor);
        volumeObserver = ObserveVolumeAsync();
        errors = process.StandardError.BaseStream.CopyToAsync(Stream.Null, lifetime.Token);
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        reader = PumpAsync(process.StandardOutput.BaseStream, received, failed, ready);
        try { await ready.Task.WaitAsync(TimeSpan.FromSeconds(6), cancellation); }
        catch { await DisposeAsync(); throw; }
    }
    private async Task ObserveVolumeAsync()
    {
        while (!lifetime.IsCancellationRequested) {
            try {
                var output = (await PulseAudio.ListAsync()).FirstOrDefault(value => value.Monitor == monitor);
                Volatile.Write(ref computerVolume, output?.Volume is uint value ? (int)value : -1);
            } catch (Exception error) when (error is IOException or JsonException or OperationCanceledException) { Volatile.Write(ref computerVolume, -1); }
            try { await Task.Delay(1000, lifetime.Token); } catch (OperationCanceledException) { return; }
        }
    }
    private async Task PumpAsync(Stream stream, Action<SourcePacket> received, Action<string> failed, TaskCompletionSource ready)
    {
        try
        {
            while (!lifetime.IsCancellationRequested)
            {
                var bytes = new byte[1920];
                await stream.ReadExactlyAsync(bytes, lifetime.Token);
                // Pipe delivery timestamps are approximate, not driver/video compensation.
                var timestamp = MonotonicClock.Nanoseconds - 10_000_000;
                ready.TrySetResult();
                received(new SourcePacket(48000, 480, timestamp, bytes));
            }
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or ObjectDisposedException)
        {
            ready.TrySetException(new IOException("Selected audio output stopped responding."));
            if (!lifetime.IsCancellationRequested) failed("Audio capture stopped. Check the selected output and start sharing again.");
        }
    }
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        lifetime.Cancel();
        if (process != null) PulseAudio.Stop(process);
        if (volumeObserver != null) await volumeObserver;
        try { if (reader != null) await reader; } catch (OperationCanceledException) { }
        try { if (errors != null) await errors; } catch (Exception e) when (e is IOException or OperationCanceledException or ObjectDisposedException) { }
        process?.Dispose(); process = null;
        lifetime.Dispose();
    }
}
