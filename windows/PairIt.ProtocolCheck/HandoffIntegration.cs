using System.Net;
using System.Security.Cryptography.X509Certificates;
using PairIt.Core;
using static Integration;

// Actual TLS/control/queue/lifecycle integration with synthetic PCM and a
// controllable media adapter. No Windows APIs or physical audio are invoked.
internal static class HandoffIntegration
{
    public static async Task RunAsync(X509Certificate2 certificate, string token)
    {
        var audio = new SyntheticEndpoints();
        var media = new SyntheticMediaController();
        var sessions = new DesktopSessions(audio, media);
        await using var server = new RelayServer(certificate, token, sessions);
        server.Start(IPAddress.Loopback, 0);
        var connector = new Connector(server.Port, certificate, token);
        await sessions.ConfigureAsync(new(SourceEndpointId: "synthetic", SharingEnabled: true));
        await using (var unnegotiated = await connector.ReceiverAsync())
        {
            await unnegotiated.SendAsync("PARK 1 PHONE\n");
            await UntilAsync(() => unnegotiated.Closed, "unadvertised handoff command rejected");
        }
        await UntilAsync(() => sessions.Status.Receivers == 0, "unnegotiated peer cleanup");
        await using var phone = await connector.ReceiverAsync();
        Require(await phone.ProbeAsync() == ((Protocol.ParkSupported | Protocol.OutputControlSupported) | Protocol.PlayerControl), "Initial capabilities/token wrong.");
        await phone.SendAsync("PARK 1 PHONE\n");
        await ExpectAsync(phone, 1, Protocol.ParkAccepted | Protocol.PlayerPaused);
        Require(!sessions.Status.Capturing && sessions.Status.ActiveReceivers == 0 && sessions.Status.Receivers == 1, "PARK must preserve only the control connection.");
        var firstLease = media.LastLease!;
        firstLease.Resume();
        await ExpectAsync(phone, 1, Protocol.ParkAccepted | Protocol.ResumeOffer);
        firstLease.Pause();
        await ExpectAsync(phone, 1, Protocol.ParkAccepted | Protocol.PlayerPaused);
        firstLease.Resume();
        await phone.SendAsync("PARK 1 PHONE\nACTIVE 1\nACTIVE 0\n");
        await ExpectAsync(phone, 1, Protocol.ParkAccepted | Protocol.ResumeOffer);
        Require(media.Attempts == 1 && !sessions.Status.Capturing, "Duplicate PARK or legacy ACTIVE changed negotiated state.");
        await phone.SendAsync("RESUME 2\n");
        await ExpectAsync(phone, 2, 0);
        Require(sessions.Status.ActiveReceivers == 1 && sessions.Status.Capturing && firstLease.Disposed, "Explicit RESUME did not activate/release ownership.");
        await phone.SendAsync("PARK 1 PHONE\nRELEASE 1\nRESUME 1\n");
        await ExpectAsync(phone, 2, 0);
        Require(sessions.Status.ActiveReceivers == 1, "Stale intent changed active state.");

        // One listener parking must not pause the shared source/player.
        await using (var other = await connector.ReceiverAsync())
        {
            await other.ProbeAsync();
            await phone.SendAsync("PARK 3 PHONE\n");
            await ExpectAsync(phone, 3, Protocol.ParkAccepted);
            Require(media.Attempts == 1 && sessions.Status.ActiveReceivers == 1, "PARK disturbed another active listener.");
            var at = MonotonicClock.Nanoseconds;
            audio.Emit(480, at);
            await UntilAsync(() => other.Frames.Any(frame => frame.CapturedAt == at), "other listener continues during PARK");
            Require(!phone.Frames.Any(frame => frame.CapturedAt == at), "Parked receiver received new PCM.");
            await other.SendAsync("PARK 1 OUTPUT\n");
            await ExpectAsync(other, 1, Protocol.ParkAccepted);
            Require(media.Attempts == 1 && !sessions.Status.Capturing, "OUTPUT attempted player control.");
            await phone.SendAsync("RELEASE 4\n");
            await ExpectAsync(phone, 4, Protocol.ReleaseAccepted);
            await ExpectAsync(other, 1, Protocol.ParkAccepted);
        }
        await UntilAsync(() => sessions.Status.Receivers == 1, "shared peer cleanup");

        // Replace a pending PHONE handoff and complete its command too late.
        media.DelayNext = true;
        await phone.SendAsync("PARK 5 PHONE\n");
        await UntilAsync(() => media.Pending != null, "pending media pause");
        await phone.SendAsync("PARK 6 OUTPUT\n");
        await ExpectAsync(phone, 6, Protocol.ParkAccepted);
        var lateLease = new SyntheticPauseLease();
        media.CompleteDelayed(lateLease);
        await UntilAsync(() => lateLease.Disposed, "stale media completion released");
        lateLease.Resume();
        await ExpectAsync(phone, 6, Protocol.ParkAccepted);
        await phone.SendAsync("PARK 7 PAUSE\n");
        await ExpectAsync(phone, 7, Protocol.ParkAccepted | Protocol.PlayerPaused);
        media.LastLease!.Resume();
        await ExpectAsync(phone, 7, Protocol.ParkAccepted);
        await phone.SendAsync("PARK 8 PHONE\n");
        await ExpectAsync(phone, 8, Protocol.ParkAccepted | Protocol.PlayerPaused);
        var canceledByAdmission = media.LastLease!;
        await using (var newListener = await connector.ReceiverAsync())
        {
            await newListener.ProbeAsync();
            Require(canceledByAdmission.Disposed, "New active listener retained stale global player ownership.");
            canceledByAdmission.Resume();
            await ExpectAsync(phone, 8, Protocol.ParkAccepted);
        }
        await UntilAsync(() => sessions.Status.Receivers == 1, "new peer cleanup");
        await phone.SendAsync("RELEASE 9\n");
        await ExpectAsync(phone, 9, Protocol.ReleaseAccepted);
        await ExpectAsync(phone, 9, Protocol.ReleaseAccepted);
        await phone.SendAsync("RESUME 10\n");
        await ExpectAsync(phone, 10, 0);
        await sessions.SetMediaHandoffSuppressedAsync(true);
        Require(sessions.Status.ActiveReceivers == 1 && sessions.Status.Capturing, "Session lock hook stopped ordinary audio.");
        await sessions.SetMediaHandoffSuppressedAsync(false);
        media.RejectNext = true;
        await phone.SendAsync("PARK 11 PHONE\n");
        await UntilAsync(() => !media.RejectNext, "media adapter rejects unsupported app");
        await ExpectAsync(phone, 11, Protocol.ParkAccepted);
        await phone.SendAsync("RESUME 12\n");
        await ExpectAsync(phone, 12, 0);

        // Parked connections still consume their original four-listener quota.
        var parked = new List<Receiver>();
        try
        {
            for (var index = 0; index < 3; index++)
            {
                var next = await connector.ReceiverAsync();
                parked.Add(next);
                await next.ProbeAsync();
                await next.SendAsync("PARK 1 OUTPUT\n");
                await ExpectAsync(next, 1, Protocol.ParkAccepted);
            }
            await phone.SendAsync("PARK 13 PHONE\n");
            await ExpectAsync(phone, 13, Protocol.ParkAccepted | Protocol.PlayerPaused);
            await using var fifth = await connector.ReceiverAsync();
            await UntilAsync(() => fifth.Closed, "parked peers retain four-slot admission bound");
            Require(sessions.Status.Receivers == 4, "Parked receiver quota changed.");
            await sessions.SetMediaHandoffSuppressedAsync(true);
            await ExpectAsync(phone, 13, Protocol.ParkAccepted);
            Require(!sessions.Status.Capturing && sessions.CurrentSettings.SharingEnabled, "Lock changed sharing or unparked control.");
            var attemptsAtLock = media.Attempts;
            await phone.SendAsync("PARK 14 PHONE\n");
            await ExpectAsync(phone, 14, Protocol.ParkAccepted);
            Require(media.Attempts == attemptsAtLock, "PHONE rearmed player control while locked.");
            await sessions.SetMediaHandoffSuppressedAsync(false);
            await ExpectAsync(phone, 14, Protocol.ParkAccepted);
            Require(media.Attempts == attemptsAtLock, "Unlock automatically rearmed an old intent.");
            await phone.SendAsync("PARK 15 PHONE\n");
            await ExpectAsync(phone, 15, Protocol.ParkAccepted | Protocol.PlayerPaused);
            var revokedLease = media.LastLease!;
            await sessions.ConfigureAsync(new());
            await UntilAsync(() => phone.Closed && parked.All(peer => peer.Closed), "desktop Stop closes parked controls");
            Require(revokedLease.Disposed && !sessions.Status.Capturing, "Desktop Stop retained media ownership.");
        }
        finally { foreach (var peer in parked) await peer.DisposeAsync(); }
        Require(audio.MaximumSources == 1 && audio.SourceStarts == audio.SourceStops, "Handoff changed capture lifetime bounds.");
        await CheckUnsupportedAsync(certificate, token);
        await CheckUnsettledAdmissionAsync(certificate, token);
        Console.WriteLine("PASS: capability/token ACKs and bounds, parked TLS reuse, explicit RESUME, stale/duplicate intents, late/rejected media completion, reason changes, shared-listener isolation, parked quota, lock and Stop revoke.");
    }

    private static async Task CheckUnsettledAdmissionAsync(X509Certificate2 certificate, string token)
    {
        var audio = new SyntheticEndpoints();
        var media = new SyntheticMediaController();
        var sessions = new DesktopSessions(audio, media);
        await using var server = new RelayServer(certificate, token, sessions);
        server.Start(IPAddress.Loopback, 0);
        var connector = new Connector(server.Port, certificate, token);
        await sessions.ConfigureAsync(new(SourceEndpointId: "synthetic", SharingEnabled: true));
        await using var phone = await connector.ReceiverAsync();
        await phone.ProbeAsync();
        media.DelayNext = true;
        await phone.SendAsync("PARK 1 PHONE\n");
        await UntilAsync(() => media.Pending != null, "native pause is unresolved");
        var starts = audio.SourceStarts;
        await using (var joining = await connector.ReceiverAsync())
        {
            await UntilAsync(() => sessions.Status.Message.StartsWith("Waiting for a computer", StringComparison.Ordinal), "new listener waits for native pause completion");
            Require(sessions.Status.Receivers == 1 && sessions.Status.ActiveReceivers == 0 && audio.SourceStarts == starts,
                "New listener became active while a prior native pause was unresolved.");
            var late = new SyntheticPauseLease();
            media.CompleteDelayed(late);
            await joining.ProbeAsync();
            await UntilAsync(() => late.Disposed && sessions.Status.ActiveReceivers == 1 && audio.SourceStarts == starts + 1,
                "native settlement precedes new listener capture");
        }
        await UntilAsync(() => sessions.Status.Receivers == 1 && !sessions.Status.Capturing, "joined receiver cleanup");
        media.DelayNext = true;
        await phone.SendAsync("PARK 2 PHONE\n");
        await UntilAsync(() => media.Pending != null, "second native pause pending");
        starts = audio.SourceStarts;
        await phone.SendAsync("RESUME 3\nPING 444\n");
        await UntilAsync(() => phone.Closed, "RESUME times out without native settlement", 4000);
        Require(!phone.Clocks.Contains(444) && !sessions.Status.Capturing && audio.SourceStarts == starts,
            "Unsettled RESUME was acknowledged or started capture.");
        await UntilAsync(() => sessions.Status.Receivers == 0, "timed-out resuming peer removed");
        await using (var retry = await connector.ReceiverAsync())
            await UntilAsync(() => retry.Closed, "later admission still sees original unresolved command", 4000);
        Require(media.Pending != null && sessions.Status.ActiveReceivers == 0 && audio.SourceStarts == starts && sessions.CurrentSettings.SharingEnabled,
            "Timeout forgot the native command, started capture, or revoked unrelated sharing.");
        var finallySettled = new SyntheticPauseLease();
        media.CompleteDelayed(finallySettled);
        await UntilAsync(() => finallySettled.Disposed, "late timed-out native lease cleanup");
        await using var recovered = await connector.ReceiverAsync();
        await recovered.ProbeAsync();
        Require(sessions.Status.ActiveReceivers == 1 && audio.SourceStarts == starts + 1,
            "Explicit retry did not recover after genuine native settlement.");
        Console.WriteLine("PASS: unresolved native pause fences new admission/RESUME, survives cancellation and repeated deadlines, emits no false RESUME ACK, and permits retry only after actual completion.");
    }

    private static async Task CheckUnsupportedAsync(X509Certificate2 certificate, string token)
    {
        var audio = new SyntheticEndpoints();
        var sessions = new DesktopSessions(audio);
        await using var server = new RelayServer(certificate, token, sessions);
        server.Start(IPAddress.Loopback, 0);
        var connector = new Connector(server.Port, certificate, token);
        await sessions.ConfigureAsync(new(SourceEndpointId: "synthetic", SharingEnabled: true));
        await using (var interrupted = await connector.ReceiverAsync())
        await using (var paused = await connector.ReceiverAsync())
        {
            await interrupted.ProbeAsync(); await paused.ProbeAsync();
            await interrupted.SendAsync("PARK 1 PHONE\n"); await paused.SendAsync("PARK 1 PAUSE\n");
            await UntilAsync(() => sessions.Status.ActiveReceivers == 0, "fallback phones parked");
            Require(sessions.Status.Capturing, "Fallback must observe the selected computer source while phone audio has priority.");
            await Task.Delay(800); audio.Emit(480, MonotonicClock.Nanoseconds, silent: true);
            Require((await interrupted.ProbeAsync() & Protocol.ResumeOffer) == 0, "Silence offered resume.");
            audio.Emit(480, MonotonicClock.Nanoseconds); await Task.Delay(100); audio.Emit(480, MonotonicClock.Nanoseconds);
            Require((await interrupted.ProbeAsync() & Protocol.ResumeOffer) != 0, "New computer audio did not offer fallback resume.");
            Require((await paused.ProbeAsync() & Protocol.ResumeOffer) == 0, "Fallback overrode manual pause.");
            await interrupted.SendAsync("RESUME 2\n"); await interrupted.ProbeAsync();
            await interrupted.SendAsync("PARK 3 PHONE\n"); await interrupted.ProbeAsync();
            audio.Emit(480, MonotonicClock.Nanoseconds); await Task.Delay(100); audio.Emit(480, MonotonicClock.Nanoseconds);
            Require((await interrupted.ProbeAsync() & Protocol.ResumeOffer) == 0, "Continuous playback stole focus back.");
            await interrupted.SendAsync("PARK 4 OUTPUT\n"); await interrupted.ProbeAsync();
            await UntilAsync(() => !sessions.Status.Capturing, "output hold releases fallback capture");
        }
        await UntilAsync(() => sessions.Status.Receivers == 0, "fallback test cleanup");
        Console.WriteLine("PASS: Linux/unavailable-media fallback detects fresh audio, protects pause/output and ignores continuous audio.");
        await using(var controlled=await connector.ReceiverAsync()){
            await controlled.SendAsync("STATS CONTROLS1\n");await controlled.ProbeAsync();
            await controlled.SendAsync("RESUME 1\n");await controlled.ProbeAsync();
            var pause=sessions.RequestPlaybackAsync(false);await controlled.ProbeAsync();
            await UntilAsync(()=>controlled.DesktopRequest==(1u<<8|2u),"Separate desktop pause request");
            Require(!pause.IsCompleted,"Pause must wait for phone acknowledgment");
            await controlled.SendAsync("PARK 2 PAUSE\n");await pause;
            var resume=sessions.RequestPlaybackAsync(true);await controlled.ProbeAsync();
            await UntilAsync(()=>controlled.DesktopRequest==(2u<<8|18u),"Separate desktop resume request");
            Require(!resume.IsCompleted,"Resume must wait for phone acknowledgment");
            await controlled.SendAsync("RESUME 3\n");await resume;
        }
        await UntilAsync(()=>sessions.Status.Receivers==0,"Desktop playback check cleanup");
        Console.WriteLine("PASS: desktop pause/resume use negotiated command frames and wait for receiver acknowledgment.");
        foreach (var command in new[] { "PARK 0 PHONE", "PARK 16777216 PHONE", "RESUME -1", "PARK 1 UNKNOWN" })
        {
            await using var malformed = await connector.ReceiverAsync();
            Require(await malformed.ProbeAsync() == (Protocol.ParkSupported | Protocol.OutputControlSupported), "Unavailable media API advertised player control.");
            await malformed.SendAsync(command + "\n");
            await UntilAsync(() => malformed.Closed, "invalid handoff framing/token rejected");
        }
        await using (var phone = await connector.ReceiverAsync())
        {
            await phone.ProbeAsync();
            await phone.SendAsync("PARK 16777215 PHONE\n");
            Require(await phone.ProbeAsync() == (Protocol.MaximumIntentToken << 8 | (Protocol.ParkSupported | Protocol.OutputControlSupported) | Protocol.ParkAccepted), "24-bit maximum or unavailable-app fallback wrong.");
            await phone.SendAsync("RELEASE 16777215\n");
            Require(await phone.ProbeAsync() == (Protocol.MaximumIntentToken << 8 | (Protocol.ParkSupported | Protocol.OutputControlSupported) | Protocol.ParkAccepted), "Same token changed intent identity.");
        }
        await UntilAsync(() => sessions.Status.Receivers == 0, "exhausted token connection cleanup");
        await using var restarted = await connector.ReceiverAsync();
        await restarted.ProbeAsync();
        await restarted.SendAsync("PARK 1 OUTPUT\n");
        Require(await restarted.ProbeAsync() == (1u << 8 | (Protocol.ParkSupported | Protocol.OutputControlSupported) | Protocol.ParkAccepted), "Fresh connection did not reset token space.");
        audio.FailSourceStartup = true;
        await restarted.SendAsync("RESUME 2\n");
        await UntilAsync(() => restarted.Closed, "resume source failure closes held peer");
        Require(!sessions.CurrentSettings.SharingEnabled, "Failed resume left sharing enabled.");
    }

    private static async Task ExpectAsync(Receiver peer, uint token, uint stateFlags)
    {
        using var deadline = new CancellationTokenSource(3000);
        uint last;
        do
        {
            last = await peer.ProbeAsync();
            if (last == (token << 8 | (Protocol.ParkSupported | Protocol.OutputControlSupported) | Protocol.PlayerControl | stateFlags)) return;
            await Task.Delay(10, deadline.Token);
        } while (!deadline.IsCancellationRequested);
        throw new InvalidOperationException($"Unexpected handoff flags {last:x8} for token {token}.");
    }
}

internal sealed class SyntheticMediaController : IMediaHandoffController
{
    public bool IsAvailable => true;
    public volatile int Attempts;
    public volatile bool DelayNext;
    public volatile bool RejectNext;
    public TaskCompletionSource<IMediaPauseLease?>? Pending;
    public SyntheticPauseLease? LastLease;
    public Task<IMediaPauseLease?> TryPauseCurrentAsync(CancellationToken cancellation)
    {
        Interlocked.Increment(ref Attempts);
        if (RejectNext) { RejectNext = false; return Task.FromResult<IMediaPauseLease?>(null); }
        if (DelayNext)
        {
            DelayNext = false;
            Pending = new(TaskCreationOptions.RunContinuationsAsynchronously);
            return Pending.Task; // Deliberately ignores cancellation to exercise late completion.
        }
        LastLease = new();
        return Task.FromResult<IMediaPauseLease?>(LastLease);
    }
    public void CompleteDelayed(SyntheticPauseLease lease)
    {
        var previous = Pending!;
        Pending = null;
        previous.SetResult(lease);
    }
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}

internal sealed class SyntheticPauseLease : IMediaPauseLease
{
    public volatile bool Disposed;
    public bool IsValid => !Disposed;
    public bool IsPaused => !Disposed && !HasResumed;
    public bool HasResumed { get; private set; }
    public event Action? Changed;
    public void Resume() { HasResumed = true; Changed?.Invoke(); }
    public void Pause() { HasResumed = false; Changed?.Invoke(); }
    public void Dispose() { Disposed = true; }
}
