using PairIt.Core;
using global::Windows.Media.Control;

namespace PairIt.Windows;

// Public GSMTC only: no injected media keys, app-specific automation, output
// routing or system-volume changes. Play/skip are sent only for a listener's
// explicit phone command or its resume after a pause, never as a toggle.
internal sealed class WindowsMediaHandoff : IMediaHandoffController
{
    private readonly object state = new();
    private readonly SemaphoreSlim command = new(1, 1);
    // Separate from the pause slot, which a retained pause lease holds until released.
    private readonly SemaphoreSlim transport = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private GlobalSystemMediaTransportControlsSessionManager? manager;
    private SessionPauseLease? inFlight;
    private bool disposed;
    private volatile bool available;
    public bool IsAvailable => available;

    public WindowsMediaHandoff() => _ = Task.Run(InitializeAsync);

    private async Task InitializeAsync()
    {
        try
        {
            var result = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync().AsTask().ConfigureAwait(false);
            lock (state)
            {
                if (disposed) return;
                manager = result;
                available = true; // API available, not a claim that any app accepted Pause.
            }
        }
        catch { available = false; } // Unsupported/denied control never prevents relay.
    }

    public async Task<IMediaPauseLease?> TryPauseCurrentAsync(CancellationToken cancellation)
    {
        if (!IsAvailable) return null;
        // This managed wait is cancellable. The single slot also covers event
        // cleanup, so a blocked native call cannot accumulate later requests.
        await command.WaitAsync(cancellation).ConfigureAwait(false);
        return await Task.Run(() => PauseCurrentAsync(cancellation)).ConfigureAwait(false);
    }

    private async Task<IMediaPauseLease?> PauseCurrentAsync(CancellationToken cancellation)
    {
        SessionPauseLease? lease = null;
        var retained = false;
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellation, lifetime.Token);
        try
        {
            GlobalSystemMediaTransportControlsSessionManager? currentManager;
            lock (state) currentManager = disposed ? null : manager;
            if (currentManager == null) return null;
            linked.Token.ThrowIfCancellationRequested();
            var current = currentManager.GetCurrentSession();
            if (current == null) return null;
            var playback = current.GetPlaybackInfo();
            if (playback.PlaybackStatus != GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing || !playback.Controls.IsPauseEnabled) return null;
            lease = new SessionPauseLease(currentManager, current, () => command.Release());
            lease.Attach();
            lock (state) inFlight = lease;
            using var canceled = linked.Token.Register(lease.Dispose);
            linked.Token.ThrowIfCancellationRequested();
            if (!lease.IsValid || !Equals(currentManager.GetCurrentSession(), current)) return null;
            // Hold this slot until the actual WinRT operation ends. The core's
            // deadline releases its own worker, but a stalled app cannot cause
            // an accumulating series of native pause requests.
            var accepted = await current.TryPauseAsync().AsTask().ConfigureAwait(false);
            linked.Token.ThrowIfCancellationRequested();
            if (!accepted) return null;
            lease.Refresh();
            await lease.WaitForPauseAsync(linked.Token).ConfigureAwait(false);
            linked.Token.ThrowIfCancellationRequested();
            if (!lease.IsValid) return null;
            retained = true;
            return lease;
        }
        catch { return null; }
        finally
        {
            lock (state) { if (inFlight == lease) inFlight = null; }
            if (lease == null) command.Release();
            if (lease != null)
            {
                if (!retained) lease.Dispose();
                lease.CommandCompleted();
            }
        }
    }

    public Task<bool> TryPlayCurrentAsync(CancellationToken cancellation) =>
        TransportAsync(playback => playback.PlaybackStatus != GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing && playback.Controls.IsPlayEnabled,
            session => session.TryPlayAsync(), cancellation);

    public Task<bool> TrySkipAsync(bool forward, CancellationToken cancellation) =>
        TransportAsync(playback => forward ? playback.Controls.IsNextEnabled : playback.Controls.IsPreviousEnabled,
            session => forward ? session.TrySkipNextAsync() : session.TrySkipPreviousAsync(), cancellation);

    private async Task<bool> TransportAsync(Func<GlobalSystemMediaTransportControlsSessionPlaybackInfo, bool> allowed,
        Func<GlobalSystemMediaTransportControlsSession, global::Windows.Foundation.IAsyncOperation<bool>> send, CancellationToken cancellation)
    {
        if (!IsAvailable) return false;
        await transport.WaitAsync(cancellation).ConfigureAwait(false);
        Task<bool>? operation = null;
        try
        {
            GlobalSystemMediaTransportControlsSessionManager? currentManager;
            lock (state) currentManager = disposed ? null : manager;
            if (currentManager == null) return false;
            cancellation.ThrowIfCancellationRequested();
            // Only the current session; another app or browser is never retargeted.
            var current = currentManager.GetCurrentSession();
            if (current == null || !allowed(current.GetPlaybackInfo())) return false;
            operation = send(current).AsTask();
        }
        catch { return false; }
        finally
        {
            // Hold the slot until the actual WinRT operation ends, so a stalled app
            // cannot accumulate native commands; the caller's wait stays bounded.
            if (operation == null) transport.Release();
            else _ = operation.ContinueWith(_ => transport.Release(), CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        }
        try { return await operation!.WaitAsync(cancellation).ConfigureAwait(false); }
        catch { return false; }
    }

    public ValueTask DisposeAsync()
    {
        SessionPauseLease? pending;
        lock (state)
        {
            disposed = true;
            available = false;
            manager = null;
            pending = inFlight;
        }
        lifetime.Cancel();
        pending?.Dispose();
        // A hung native command is abandoned, never awaited on tray shutdown.
        // Its finally block releases the one command slot if it completes.
        return ValueTask.CompletedTask;
    }

    private sealed class SessionPauseLease(GlobalSystemMediaTransportControlsSessionManager manager,
        GlobalSystemMediaTransportControlsSession session, Action releaseCommand) : IMediaPauseLease
    {
        private readonly object state = new();
        private readonly TaskCompletionSource paused = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private long observationRevision;
        private bool disposed, sawPause, isPaused, resumed;
        private bool commandCompleted, detached, released;
        private bool playbackSubscribed, mediaSubscribed, currentSubscribed, sessionsSubscribed;
        public bool IsValid { get { lock (state) return !disposed; } }
        public bool IsPaused { get { lock (state) return !disposed && isPaused; } }
        public bool HasResumed { get { lock (state) return !disposed && resumed; } }
        public event Action? Changed;

        public void Attach()
        {
            lock (state)
            {
                session.PlaybackInfoChanged += PlaybackChanged;
                playbackSubscribed = true;
                session.MediaPropertiesChanged += MediaChanged;
                mediaSubscribed = true;
                manager.CurrentSessionChanged += CurrentChanged;
                currentSubscribed = true;
                manager.SessionsChanged += SessionsChanged;
                sessionsSubscribed = true;
            }
        }

        public Task WaitForPauseAsync(CancellationToken cancellation) => paused.Task.WaitAsync(cancellation);
        private void PlaybackChanged(GlobalSystemMediaTransportControlsSession sender, PlaybackInfoChangedEventArgs args) => Refresh();
        private void MediaChanged(GlobalSystemMediaTransportControlsSession sender, MediaPropertiesChangedEventArgs args) => Dispose();
        private void CurrentChanged(GlobalSystemMediaTransportControlsSessionManager sender, CurrentSessionChangedEventArgs args) => Dispose();
        private void SessionsChanged(GlobalSystemMediaTransportControlsSessionManager sender, SessionsChangedEventArgs args) => Dispose();

        public void Refresh()
        {
            long revision;
            lock (state)
            {
                if (disposed) return;
                revision = ++observationRevision;
            }
            try
            {
                // Never retarget another app or browser session. Conservatively
                // cancel on media/session-list changes instead of identifying a
                // different session by app ID, title or artwork.
                if (!Equals(manager.GetCurrentSession(), session)) { Dispose(revision); return; }
                var status = session.GetPlaybackInfo().PlaybackStatus;
                if (status is GlobalSystemMediaTransportControlsSessionPlaybackStatus.Closed or GlobalSystemMediaTransportControlsSessionPlaybackStatus.Stopped)
                { Dispose(revision); return; }
                lock (state)
                {
                    // The post-command read and native event callbacks may
                    // overlap. A slow older read cannot overwrite newer state.
                    if (disposed || revision != observationRevision) return;
                    isPaused = status == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Paused;
                    if (isPaused)
                    {
                        sawPause = true;
                        paused.TrySetResult();
                    }
                    resumed = sawPause && status == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;
                }
                Changed?.Invoke(); // Never call the core while holding this lock.
            }
            catch { Dispose(revision); }
        }

        public void Dispose() => Dispose(null);

        private void Dispose(long? expectedRevision)
        {
            lock (state)
            {
                // Stale failed/closed observations are fenced exactly like
                // successful reads. Explicit cancellation is unconditional.
                if (disposed || (expectedRevision.HasValue && expectedRevision.Value != observationRevision)) return;
                disposed = true;
            }
            paused.TrySetCanceled();
            Changed?.Invoke();
            // Invalidation is immediate and managed. Removing WinRT handlers
            // can never block the desktop Stop/lock/lifecycle caller.
            _ = Task.Run(Detach);
        }

        private void Detach()
        {
            try { if (playbackSubscribed) session.PlaybackInfoChanged -= PlaybackChanged; } catch { }
            try { if (mediaSubscribed) session.MediaPropertiesChanged -= MediaChanged; } catch { }
            try { if (currentSubscribed) manager.CurrentSessionChanged -= CurrentChanged; } catch { }
            try { if (sessionsSubscribed) manager.SessionsChanged -= SessionsChanged; } catch { }
            bool release;
            lock (state) { detached = true; release = CanReleaseCommand(); }
            if (release) releaseCommand();
        }

        public void CommandCompleted()
        {
            bool release;
            lock (state) { commandCompleted = true; release = CanReleaseCommand(); }
            if (release) releaseCommand();
        }

        private bool CanReleaseCommand()
        {
            if (!disposed || !detached || !commandCompleted || released) return false;
            released = true;
            return true;
        }
    }
}
