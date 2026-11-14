using PairIt.Core;

namespace PairIt.Linux;

// Routing is deliberately separate from PulseSource: microphone monitor tests
// and explicit raw capture must never move desktop application streams.
public sealed class RoutedPulseSource(string selectedMonitor) : ISystemAudioSource
{
    private readonly CancellationTokenSource lifetime = new();
    private readonly PulseRoute route = new(new PulseCommands());
    private PulseSource? capture;
    private Task? observer;
    private PulseRouteEvents? events;
    private int disposed;
    public uint? ComputerVolume => capture?.ComputerVolume;

    public async Task StartAsync(Action<SourcePacket> received, Action<string> failed, CancellationToken cancellation)
    {
        ObjectDisposedException.ThrowIf(disposed != 0, this);
        if (capture != null) throw new InvalidOperationException("Capture already started.");
        try {
            events = new PulseRouteEvents();
            await route.StartAsync(selectedMonitor, cancellation);
            capture = new PulseSource(route.Monitor);
            await capture.StartAsync(received, failed, cancellation);
            observer = ObserveRoutesAsync(failed);
        } catch { await DisposeAsync(); throw; }
    }

    private async Task ObserveRoutesAsync(Action<string> failed)
    {
        try {
            while (!lifetime.IsCancellationRequested) {
                await events!.WaitAsync(lifetime.Token);
                await route.RefreshAsync(lifetime.Token);
            }
        } catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception error) when (error is IOException or System.Text.Json.JsonException or OperationCanceledException or System.ComponentModel.Win32Exception) {
            if (!lifetime.IsCancellationRequested) failed("Audio routing stopped. Check the selected output and start sharing again.");
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        lifetime.Cancel();
        try {
            try { if (observer != null) await observer; }
            finally {
                try { if (capture != null) await capture.DisposeAsync(); }
                finally { if (events != null) await events.DisposeAsync(); }
            }
        } finally {
            try { await route.DisposeAsync(); }
            finally { lifetime.Dispose(); }
        }
    }
}
