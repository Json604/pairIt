using System.Diagnostics;

namespace PairIt.Linux;

// Coalesce audio-server notifications instead of spawning pactl dozens of times
// per second when nothing changes. The periodic wake also detects dead servers.
internal sealed class PulseRouteEvents : IAsyncDisposable
{
    private readonly CancellationTokenSource lifetime = new();
    private readonly SemaphoreSlim changed = new(0, 1);
    private readonly Process process = PulseAudio.Start("pactl", "subscribe");
    private readonly Task pump;
    private readonly Task errors;
    public PulseRouteEvents()
    {
        pump = ReadAsync();
        errors = process.StandardError.BaseStream.CopyToAsync(Stream.Null, lifetime.Token);
    }
    private async Task ReadAsync()
    {
        try {
            while (await process.StandardOutput.ReadLineAsync(lifetime.Token) is { } line) {
                if (!line.Contains("sink", StringComparison.Ordinal)) continue;
                if (changed.CurrentCount == 0) changed.Release();
            }
        } catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (IOException) { }
        finally { if (changed.CurrentCount == 0) changed.Release(); }
    }
    public async Task WaitAsync(CancellationToken cancellation)
    {
        await changed.WaitAsync(TimeSpan.FromSeconds(2), cancellation);
        if (pump.IsCompleted) throw new IOException("Audio server notifications stopped.");
    }
    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel(); PulseAudio.Stop(process);
        await pump;
        try { await errors; } catch (Exception e) when (e is IOException or OperationCanceledException or ObjectDisposedException) { }
        process.Dispose(); lifetime.Dispose(); changed.Dispose();
    }
}
