namespace PairIt.Core;

public enum ParkReason { Phone, Pause, Output }
internal enum ReceiverIntent { None, Park, Resume, Release }
public enum MediaCommand { Play, Next, Previous }

// The Windows adapter observes a single actual media session. No PCM, route,
// system volume or default-device operations belong in this interface.
public interface IMediaPauseLease : IDisposable
{
    bool IsValid { get; }
    bool IsPaused { get; }
    bool HasResumed { get; }
    event Action? Changed;
}

public interface IMediaHandoffController : IAsyncDisposable
{
    bool IsAvailable { get; }
    Task<IMediaPauseLease?> TryPauseCurrentAsync(CancellationToken cancellation);
    // Explicit listener commands (STATS MEDIA1, and Play when a paused phone resumes).
    // Play must not toggle: an adapter does nothing when its session is already playing.
    Task<bool> TryPlayCurrentAsync(CancellationToken cancellation) => Task.FromResult(false);
    Task<bool> TrySkipAsync(bool forward, CancellationToken cancellation) => Task.FromResult(false);
}

internal sealed class UnavailableMediaController : IMediaHandoffController
{
    public bool IsAvailable => false;
    public Task<IMediaPauseLease?> TryPauseCurrentAsync(CancellationToken cancellation) => Task.FromResult<IMediaPauseLease?>(null);
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}

// One coalescing worker, at most four parked tickets, and one retained media
// lease. Windows media commands never run inside the desktop audio lifecycle lock.
internal sealed class MediaHandoffCoordinator(IMediaHandoffController controller) : IAsyncDisposable
{
    private sealed class Ticket(Guid peer, uint token, ParkReason reason)
    {
        public Guid Peer { get; } = peer;
        public uint Token { get; } = token;
        public ParkReason Reason { get; } = reason;
        public CancellationTokenSource Cancellation { get; } = new();
        public IMediaPauseLease? Lease;
        public bool PausedConfirmed, ResumeOffered;
    }

    private readonly object state = new();
    private readonly Dictionary<Guid, Ticket> tickets = [];
    private readonly CancellationTokenSource lifetime = new();
    private Ticket? pending;
    private Task worker = Task.CompletedTask;
    private Task? unsettledCommand;
    // Play/skip run one at a time, in arrival order, each bounded like a pause.
    private Task commands = Task.CompletedTask;
    private int queuedCommands;
    private bool workerRunning, disposed;
    public bool IsAvailable => controller.IsAvailable;
    public bool HasUnsettledCommand { get { lock (state) return unsettledCommand is { IsCompleted: false }; } }

    // Call after CancelAll while owning the desktop lifecycle gate. A timeout
    // only releases the caller: the actual command remains represented until
    // its native operation ends, including across later activation attempts.
    public async Task<bool> WaitUntilSettledAsync(CancellationToken cancellation)
    {
        cancellation.ThrowIfCancellationRequested();
        Task? previous;
        lock (state) previous = unsettledCommand;
        if (previous == null) return true;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        deadline.CancelAfter(TimeSpan.FromSeconds(2));
        try { await previous.WaitAsync(deadline.Token).ConfigureAwait(false); return true; }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested) { return false; }
    }

    public void Park(Guid peer, uint token, ParkReason reason, bool lastListener)
    {
        Cancel(peer);
        if (!lastListener || reason == ParkReason.Output || !controller.IsAvailable) return;
        CancelAll();
        lock (state)
        {
            if (disposed) return;
            var ticket = new Ticket(peer, token, reason);
            tickets[peer] = ticket;
            pending = ticket;
            if (workerRunning) return;
            workerRunning = true;
            worker = Task.Run(WorkAsync);
        }
    }

    // True while this peer's own park demonstrably paused the computer player.
    public bool PausedFor(Guid peer, uint token)
    {
        lock (state) return tickets.TryGetValue(peer, out var ticket) && ticket.Token == token && ticket.PausedConfirmed;
    }

    public bool Send(MediaCommand command)
    {
        lock (state)
        {
            // A phone cannot queue an unbounded series of native commands.
            if (disposed || !controller.IsAvailable || queuedCommands >= 4) return false;
            queuedCommands++;
            commands = RunCommandAsync(commands, command);
            return true;
        }
    }

    private async Task RunCommandAsync(Task previous, MediaCommand command)
    {
        await previous.ConfigureAwait(false);
        try
        {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            deadline.CancelAfter(TimeSpan.FromSeconds(2));
            var token = deadline.Token;
            token.ThrowIfCancellationRequested();
            await Task.Run(() => command == MediaCommand.Play ? controller.TryPlayCurrentAsync(token)
                : controller.TrySkipAsync(command == MediaCommand.Next, token)).WaitAsync(token).ConfigureAwait(false);
        }
        catch (Exception)
        {
            // An unsupported, rejected or stalled player never affects the relay.
        }
        finally { lock (state) queuedCommands--; }
    }

    public uint Flags(Guid peer, uint token)
    {
        lock (state)
        {
            if (!tickets.TryGetValue(peer, out var ticket) || ticket.Token != token) return 0;
            return (ticket.PausedConfirmed ? Protocol.PlayerPaused : 0) | (ticket.ResumeOffered ? Protocol.ResumeOffer : 0);
        }
    }

    public void Cancel(Guid peer)
    {
        Ticket? previous;
        lock (state)
        {
            tickets.Remove(peer, out previous);
            if (previous == pending) pending = null;
        }
        End(previous);
    }

    public void CancelAll()
    {
        Ticket[] previous;
        lock (state)
        {
            previous = tickets.Values.ToArray();
            tickets.Clear();
            pending = null;
        }
        foreach (var ticket in previous) End(ticket);
    }

    private static void End(Ticket? ticket)
    {
        if (ticket == null) return;
        ticket.Cancellation.Cancel();
        ticket.Lease?.Dispose();
        // The worker may still be observing cancellation. The bounded ticket
        // becomes collectible after it or a late adapter completion finishes.
    }

    private async Task WorkAsync()
    {
        while (true)
        {
            Ticket? ticket;
            lock (state)
            {
                ticket = pending;
                pending = null;
                if (ticket == null || disposed) { workerRunning = false; return; }
            }
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token, ticket.Cancellation.Token);
            deadline.CancelAfter(TimeSpan.FromSeconds(2));
            Task<IMediaPauseLease?>? attempt = null;
            try
            {
                // An earlier Play/skip must finish first, or it could undo this newer pause.
                Task earlier;
                lock (state) earlier = commands;
                await earlier.WaitAsync(deadline.Token).ConfigureAwait(false);
                attempt = BeginAttempt(ticket, deadline.Token);
                if (attempt == null) continue;
                var lease = await attempt.WaitAsync(deadline.Token).ConfigureAwait(false);
                if (lease == null) continue;
                var retain = false;
                lock (state)
                {
                    if (!disposed && !deadline.IsCancellationRequested && tickets.TryGetValue(ticket.Peer, out var current) && current == ticket && lease.IsValid)
                    {
                        ticket.Lease = lease;
                        lease.Changed += () => LeaseChanged(ticket, lease);
                        // PAUSE also observes current status, but never offers
                        // automatic return. Validity alone is not paused state.
                        ticket.PausedConfirmed = lease.IsValid && lease.IsPaused;
                        ticket.ResumeOffered = ticket.Reason == ParkReason.Phone && lease.IsValid && lease.HasResumed;
                        retain = true;
                    }
                }
                if (!retain) lease.Dispose();
            }
            catch (Exception)
            {
                // An unsupported/rejected/late media command must not break
                // relay or claim that Windows was paused. Late results cannot
                // acquire a newer ticket and are disposed when they arrive.
                if (attempt != null) _ = DisposeLateAsync(attempt);
            }
        }
    }

    private Task<IMediaPauseLease?>? BeginAttempt(Ticket ticket, CancellationToken cancellation)
    {
        lock (state)
        {
            if (disposed || cancellation.IsCancellationRequested || !tickets.TryGetValue(ticket.Peer, out var current) || current != ticket ||
                unsettledCommand is { IsCompleted: false }) return null;
            // Registration and ticket validation are atomic with cancellation.
            // A newer ticket cannot replace a hung command's settlement marker.
            var settled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            unsettledCommand = settled.Task;
            return Task.Run(async () =>
            {
                try
                {
                    cancellation.ThrowIfCancellationRequested();
                    return await controller.TryPauseCurrentAsync(cancellation).ConfigureAwait(false);
                }
                finally
                {
                    settled.TrySetResult();
                    lock (state) { if (unsettledCommand == settled.Task) unsettledCommand = null; }
                }
            });
        }
    }

    private void LeaseChanged(Ticket ticket, IMediaPauseLease lease)
    {
        lock (state)
        {
            if (disposed || !tickets.TryGetValue(ticket.Peer, out var current) || current != ticket || ticket.Lease != lease) return;
            ticket.PausedConfirmed = lease.IsValid && lease.IsPaused;
            ticket.ResumeOffered = ticket.Reason == ParkReason.Phone && lease.IsValid && lease.HasResumed;
        }
    }

    private static async Task DisposeLateAsync(Task<IMediaPauseLease?> attempt)
    {
        try { (await attempt.ConfigureAwait(false))?.Dispose(); }
        catch { }
    }

    public async ValueTask DisposeAsync()
    {
        lock (state) disposed = true;
        CancelAll();
        lifetime.Cancel();
        await worker.ConfigureAwait(false);
        // Each queued command observes the canceled lifetime and ends promptly.
        Task queued;
        lock (state) queued = commands;
        await queued.ConfigureAwait(false);
        await controller.DisposeAsync().ConfigureAwait(false);
        lifetime.Dispose();
    }
}
