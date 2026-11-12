namespace PairIt.Core;

internal sealed class MicrophoneLease(IMicrophoneSink sink)
{
    public IMicrophoneSink Sink { get; } = sink;
    public CancellationTokenSource Lifetime { get; } = new();
}

// All mode transitions go through lifecycle. Capture callbacks only take the
// short state lock and enqueue immutable packets; they never await socket I/O.
public sealed class DesktopSessions(IAudioEndpoints endpoints, IMediaHandoffController? mediaController = null) : IAsyncDisposable
{
    private readonly SemaphoreSlim lifecycle = new(1);
    private readonly object state = new();
    private readonly Dictionary<Guid, ReceiverSession> receivers = [];
    private readonly MediaHandoffCoordinator handoff = new(mediaController ?? new UnavailableMediaController());
    private DesktopSettings settings = new();
    private ISystemAudioSource? source;
    private MicrophoneLease? microphone;
    private uint sequence;
    private string message = "Select a computer audio source to begin.";
    private bool disposed, mediaHandoffSuppressed, computerOutput;
    public event Action<DesktopStatus>? StatusChanged;
    public event Action? PairingAcknowledged;
    public DesktopSettings CurrentSettings => Volatile.Read(ref settings);

    public DesktopStatus Status
    {
        get { lock (state) return new(receivers.Count, receivers.Values.Count(peer => peer.Active), source != null, microphone != null, message, computerOutput); }
    }

    internal void AcknowledgePairing()
    {
        SetMessage(CurrentSettings.SharingEnabled
            ? "Phone paired. Choose Start audio on your phone when ready."
            : "Phone paired. Choose Start sharing here, then Start audio on your phone.");
        PairingAcknowledged?.Invoke();
    }

    public async Task SetComputerOutputAsync(bool value)
    {
        await lifecycle.WaitAsync().ConfigureAwait(false);
        try
        {
            if (disposed || computerOutput == value) return;
            handoff.CancelAll();
            if (!value && !await handoff.WaitUntilSettledAsync(CancellationToken.None).ConfigureAwait(false))
            {
                SetMessage("Windows player pause is still finishing. Choose Phone headphones again after it responds.");
                return;
            }
            lock (state)
            {
                computerOutput = value;
                foreach (var peer in receivers.Values) peer.DiscardQueuedAudio();
            }
            try { await UpdateCaptureAsync(CancellationToken.None).ConfigureAwait(false); }
            catch (Exception)
            {
                // Keep paired connections available for an explicit retry after
                // the selected source becomes available again.
                lock (state) computerOutput = true;
                SetMessage("Could not restart the selected source. Check it, then choose Phone headphones again.");
                return;
            }
            PublishOutputStatus();
        }
        finally { lifecycle.Release(); }
    }

    private void PublishOutputStatus() => SetMessage(computerOutput
        ? "Computer output selected. Phone connections stay ready; Windows local output is unchanged."
        : Status.ActiveReceivers == 0 ? "Phone headphones selected. Start or resume audio on your phone."
        : "Sharing computer audio. Windows local output stays unchanged.");

    public async Task ConfigureAsync(DesktopSettings value)
    {
        await lifecycle.WaitAsync().ConfigureAwait(false);
        try
        {
            if (disposed) return;
            if (value.SharingEnabled && value.MicrophoneEnabled)
                throw new InvalidOperationException("Choose computer sharing or phone microphone, one at a time.");
            await EndSessionsAsync().ConfigureAwait(false);
            settings = value;
            SetMessage(value.MicrophoneEnabled ? "Ready for an explicit microphone start on your phone." :
                value.SharingEnabled ? "Ready for up to four paired receivers." : "Sharing stopped. Pairing remains available.");
        }
        finally { lifecycle.Release(); }
    }

    public async Task SetMediaHandoffSuppressedAsync(bool suppressed)
    {
        await lifecycle.WaitAsync().ConfigureAwait(false);
        try
        {
            mediaHandoffSuppressed = suppressed;
            if (suppressed) handoff.CancelAll();
        }
        finally { lifecycle.Release(); }
    }

    internal async Task<bool> AddReceiverAsync(ReceiverSession peer, CancellationToken cancellation)
    {
        await lifecycle.WaitAsync(cancellation).ConfigureAwait(false);
        try
        {
            if (disposed || microphone != null || !settings.SharingEnabled || string.IsNullOrEmpty(settings.SourceEndpointId)) return false;
            lock (state)
            {
                if (receivers.Count >= Protocol.MaximumReceivers) return false;
            }
            if (!await PrepareActivationAsync(peer, cancellation).ConfigureAwait(false)) return false;
            lock (state) receivers.Add(peer.Id, peer);
            try { await UpdateCaptureAsync(cancellation).ConfigureAwait(false); }
            catch (Exception error)
            {
                await EndSessionsAsync().ConfigureAwait(false);
                settings = settings with { SharingEnabled = false };
                SetMessage(error is NotSupportedException ? error.Message : "Could not start the selected audio source. Check its format and availability.");
                return false;
            }
            PublishOutputStatus();
            return true;
        }
        finally { lifecycle.Release(); }
    }

    internal async Task RemoveReceiverAsync(ReceiverSession peer)
    {
        await lifecycle.WaitAsync().ConfigureAwait(false);
        try
        {
            handoff.Cancel(peer.Id);
            lock (state) receivers.Remove(peer.Id);
            await UpdateCaptureAsync(CancellationToken.None).ConfigureAwait(false);
            if (Status.Receivers == 0 && microphone == null) SetMessage("No receivers connected.");
            Publish();
        }
        finally { lifecycle.Release(); }
    }

    internal async Task SetActiveAsync(ReceiverSession peer, bool active)
    {
        await lifecycle.WaitAsync().ConfigureAwait(false);
        try
        {
            lock (state)
            {
                if (!receivers.ContainsKey(peer.Id) || peer.HandoffNegotiated) return;
                if (active && (microphone != null || !settings.SharingEnabled)) { peer.Close(); return; }
            }
            if (active && !await PrepareActivationAsync(peer, peer.Cancellation).ConfigureAwait(false)) return;
            lock (state) peer.Active = active;
            try { await UpdateCaptureAsync(peer.Cancellation).ConfigureAwait(false); }
            catch (Exception error)
            {
                await EndSessionsAsync().ConfigureAwait(false);
                settings = settings with { SharingEnabled = false };
                SetMessage(error is NotSupportedException ? error.Message : "Could not restart the selected audio source. Check its format and availability.");
                return;
            }
            PublishOutputStatus();
        }
        finally { lifecycle.Release(); }
    }

    internal uint ClockStatus(ReceiverSession peer)
    {
        lock (state)
        {
            peer.HandoffAdvertised = true;
            return Protocol.ParkSupported | Protocol.OutputControlSupported | (computerOutput ? Protocol.ComputerOutput : 0) |
                (handoff.IsAvailable ? Protocol.PlayerControl : 0) |
                (peer.IntentToken << 8) | (peer.Parked ? Protocol.ParkAccepted : 0) |
                (peer.LastIntent == ReceiverIntent.Release ? Protocol.ReleaseAccepted : 0) |
                handoff.Flags(peer.Id, peer.IntentToken);
        }
    }

    internal async Task ApplyIntentAsync(ReceiverSession peer, ReceiverIntent intent, uint token, ParkReason reason = ParkReason.Output)
    {
        await lifecycle.WaitAsync(peer.Cancellation).ConfigureAwait(false);
        try
        {
            lock (state)
            {
                if (!receivers.ContainsKey(peer.Id)) return;
                if (!peer.HandoffAdvertised || token is 0 or > Protocol.MaximumIntentToken)
                    throw new InvalidDataException("Handoff capability/token required.");
                // Token identity includes its original intent/reason. Replays
                // cannot reissue media commands or undo a later user choice.
                if (token <= peer.IntentToken) return;
                if (microphone != null || !settings.SharingEnabled) { peer.Close(); return; }
            }
            if (intent == ReceiverIntent.Resume && !await PrepareActivationAsync(peer, peer.Cancellation).ConfigureAwait(false)) return;
            bool lastListener;
            lock (state)
            {
                peer.HandoffNegotiated = true;
                peer.IntentToken = token;
                peer.LastIntent = intent;
                peer.ParkReason = reason;
                peer.Parked = intent == ReceiverIntent.Park;
                peer.Active = intent == ReceiverIntent.Resume;
                if (!peer.Active) peer.DiscardQueuedAudio();
                lastListener = receivers.Values.All(value => !value.Active);
            }
            handoff.Cancel(peer.Id);
            try { await UpdateCaptureAsync(peer.Cancellation).ConfigureAwait(false); }
            catch (Exception error)
            {
                await EndSessionsAsync().ConfigureAwait(false);
                settings = settings with { SharingEnabled = false };
                SetMessage(error is NotSupportedException ? error.Message : "Could not restart the selected audio source. Check its format and availability.");
                return;
            }
            if (intent == ReceiverIntent.Park) handoff.Park(peer.Id, token, reason, lastListener && !mediaHandoffSuppressed && !computerOutput);
            if (computerOutput) { PublishOutputStatus(); return; }
            SetMessage(Status.ActiveReceivers == 0
                ? "Relay held. Windows player pause is best effort; unsupported apps can keep playing locally."
                : "Sharing computer audio. Windows local output stays unchanged.");
        }
        finally { lifecycle.Release(); }
    }

    private async Task<bool> PrepareActivationAsync(ReceiverSession peer, CancellationToken cancellation)
    {
        if (computerOutput) return true;
        handoff.CancelAll();
        if (handoff.HasUnsettledCommand) SetMessage("Waiting for a Windows player command before starting audio.");
        if (await handoff.WaitUntilSettledAsync(cancellation).ConfigureAwait(false))
        {
            cancellation.ThrowIfCancellationRequested();
            return true;
        }
        // Never acknowledge RESUME or admit an active listener while an older
        // native Pause can still finish and silence that listener's source.
        peer.Close();
        SetMessage("Windows player pause is still finishing. Try Start audio again.");
        return false;
    }

    internal void SetHello(ReceiverSession peer, string installation)
    {
        lock (state)
        {
            var other = receivers.Values.FirstOrDefault(value => value != peer && value.InstallationId == installation);
            if (other != null)
            {
                // An installation ID is not authority to evict a healthy session.
                if (MonotonicClock.Nanoseconds - other.LastControlAt < 4_000_000_000) { peer.Close(); return; }
                other.Close();
            }
            peer.InstallationId = installation;
        }
    }

    internal async Task<(MicrophoneLease? Lease, string Response)> AcquireMicrophoneAsync(CancellationToken cancellation)
    {
        await lifecycle.WaitAsync(cancellation).ConfigureAwait(false);
        try
        {
            if (disposed) return (null, "ERR DISABLED\n");
            if (microphone != null || source != null || Status.ActiveReceivers != 0) return (null, "ERR BUSY\n");
            if (!settings.MicrophoneEnabled) return (null, "ERR DISABLED\n");
            if (!settings.VirtualEndpointConfirmed || string.IsNullOrEmpty(settings.MicrophoneEndpointId)) return (null, "ERR OUTPUT\n");
            try
            {
                var sink = await endpoints.OpenMicrophoneSinkAsync(settings.MicrophoneEndpointId, cancellation).ConfigureAwait(false);
                lock (state) microphone = new(sink);
                SetMessage("Phone microphone active. Stop here or on your phone.");
                return (microphone, "OK MIC1 48000\n");
            }
            catch (Exception error) when (error is not OperationCanceledException)
            {
                SetMessage("Virtual microphone endpoint unavailable. Select an installed virtual cable.");
                return (null, "ERR OUTPUT\n");
            }
        }
        finally { lifecycle.Release(); }
    }

    internal async Task ReleaseMicrophoneAsync(MicrophoneLease lease)
    {
        await lifecycle.WaitAsync().ConfigureAwait(false);
        try
        {
            if (microphone != lease) return;
            await EndMicrophoneAsync().ConfigureAwait(false);
            SetMessage("Phone microphone stopped. Start again explicitly on your phone.");
        }
        finally { lifecycle.Release(); }
    }

    private async Task UpdateCaptureAsync(CancellationToken cancellation)
    {
        var hasActive = Status.ActiveReceivers != 0 && !computerOutput;
        if (!hasActive && source != null)
        {
            var previous = source;
            lock (state) source = null;
            await previous.DisposeAsync().ConfigureAwait(false);
        }
        if (!hasActive || source != null || disposed) return;
        var next = endpoints.CreateSource(settings.SourceEndpointId!);
        lock (state) { source = next; sequence += 2; }
        try
        {
            await next.StartAsync(packet => Broadcast(next, packet), reason => _ = SourceFailedAsync(next, reason), cancellation).ConfigureAwait(false);
        }
        catch
        {
            lock (state) source = null;
            await next.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    private void Broadcast(ISystemAudioSource expected, SourcePacket packet)
    {
        lock (state)
        {
            if (source != expected || computerOutput) return;
            if (packet.Discontinuity) sequence += 2;
            var frame = Protocol.Pcm(sequence++, packet);
            foreach (var peer in receivers.Values)
                if (peer.Active && !peer.TryEnqueue(frame)) peer.RequestCloseOnce();
        }
    }

    public void SendHeartbeat()
    {
        lock (state)
        {
            var frame = Protocol.Heartbeat(sequence);
            foreach (var peer in receivers.Values)
                if (!peer.TryEnqueue(frame)) peer.Close();
        }
    }

    private async Task SourceFailedAsync(ISystemAudioSource expected, string reason)
    {
        await lifecycle.WaitAsync().ConfigureAwait(false);
        try
        {
            if (source != expected) return;
            // A source fault is not an invitation to capture another endpoint.
            await EndSessionsAsync().ConfigureAwait(false);
            settings = settings with { SharingEnabled = false };
            SetMessage(reason);
        }
        finally { lifecycle.Release(); }
    }

    private async Task EndSessionsAsync()
    {
        handoff.CancelAll();
        lock (state)
        {
            foreach (var peer in receivers.Values) peer.Close();
            receivers.Clear();
        }
        var previous = source;
        lock (state) source = null;
        if (previous != null) await previous.DisposeAsync().ConfigureAwait(false);
        await EndMicrophoneAsync().ConfigureAwait(false);
    }

    private async Task EndMicrophoneAsync()
    {
        var lease = microphone;
        if (lease == null) return;
        lease.Lifetime.Cancel();
        await lease.Sink.DisposeAsync().ConfigureAwait(false);
        lock (state) microphone = null;
        // The session owns token disposal after it has stopped observing it.
    }

    private void SetMessage(string value) { lock (state) message = value; Publish(); }
    private void Publish() => StatusChanged?.Invoke(Status);

    public async ValueTask DisposeAsync()
    {
        await lifecycle.WaitAsync().ConfigureAwait(false);
        try { disposed = true; await EndSessionsAsync().ConfigureAwait(false); }
        finally { lifecycle.Release(); }
        await handoff.DisposeAsync().ConfigureAwait(false);
    }
}
