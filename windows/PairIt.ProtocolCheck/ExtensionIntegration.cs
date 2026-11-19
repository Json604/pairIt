using System.Net;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using PairIt.Core;
using static Integration;

// STATS-negotiated phone/computer extensions over real loopback TLS with synthetic PCM,
// volume and media adapters: PLAYER1, MEDIA1, paused-phone offers and player resume,
// VOLUME2/PVOL1 and CONTROLS2 disconnect. No Windows media, audio or UI APIs run.
internal static class ExtensionIntegration
{
    public static async Task RunAsync(X509Certificate2 certificate, string token)
    {
        await CheckPlayerAsync(certificate, token);
        await CheckPausedPhoneAsync(certificate, token);
        await CheckVolumeAsync(certificate, token);
        await CheckDisconnectAsync(certificate, token);
    }

    private static async Task CheckPlayerAsync(X509Certificate2 certificate, string token)
    {
        var audio = new SyntheticEndpoints();
        var media = new SyntheticMediaController();
        var sessions = new DesktopSessions(audio, media);
        await using var server = new RelayServer(certificate, token, sessions);
        server.Start(IPAddress.Loopback, 0);
        var connector = new Connector(server.Port, certificate, token);
        await sessions.ConfigureAsync(new(SourceEndpointId: "synthetic", SharingEnabled: true));
        await using var legacy = await connector.ReceiverAsync();
        await using var phone = await connector.ReceiverAsync();
        await legacy.ProbeAsync();
        await phone.SendAsync("STATS PLAYER1\n");
        await UntilAsync(() => phone.PlayerStates.Count == 1, "player state sent on PLAYER1");
        Require(phone.PlayerStates.Last() == 0, "A silent computer was reported as playing.");
        await phone.ProbeAsync();
        await UntilAsync(() => phone.PlayerStates.Count == 2, "player state repeated with each PING reply");
        await phone.SendAsync("RESUME 1\n");
        await phone.ProbeAsync();
        audio.Emit(480, MonotonicClock.Nanoseconds);
        await UntilAsync(() => phone.PlayerStates.Last() == 1, "player state sent as soon as the computer sounds");

        await phone.SendAsync("STATS MEDIA1 PLAY\nSTATS MEDIA1 STOP\n");
        await phone.ProbeAsync(); await Task.Delay(150);
        Require(media.Plays == 0 && !phone.Closed, "MEDIA1 PLAY pressed Play while the computer was sounding, or an unknown key closed the phone.");
        await phone.SendAsync("STATS MEDIA1 NEXT\nSTATS MEDIA1 PREVIOUS\n");
        await UntilAsync(() => media.Nexts == 1 && media.Previouses == 1, "earphone next/previous reach the computer player");
        await UntilAsync(() => phone.PlayerStates.Last() == 0, "player state turns off after 1.5 s of silence");
        await phone.SendAsync("STATS MEDIA1 PLAY\n");
        await UntilAsync(() => media.Plays == 1, "MEDIA1 PLAY starts a computer player that is silent");

        await sessions.SetComputerOutputAsync(true);
        await phone.SendAsync("STATS MEDIA1 NEXT\nSTATS MEDIA1 PLAY\n");
        await phone.ProbeAsync(); await Task.Delay(150);
        Require(media.Nexts == 1 && media.Plays == 1, "Earphone media commands were sent while computer speakers were selected.");
        await sessions.SetComputerOutputAsync(false);
        await legacy.ProbeAsync();
        Require(legacy.PlayerStates.IsEmpty && !legacy.Closed, "A receiver without PLAYER1 received a player-state frame.");
        Console.WriteLine("PASS: PLAYER1 state on negotiation, PING and change; MEDIA1 skip/play only while sharing, Play only after 1.5 s silence; legacy peers see no new frames.");
    }

    private static async Task CheckPausedPhoneAsync(X509Certificate2 certificate, string token)
    {
        var audio = new SyntheticEndpoints();
        var media = new SyntheticMediaController();
        var sessions = new DesktopSessions(audio, media);
        await using var server = new RelayServer(certificate, token, sessions);
        server.Start(IPAddress.Loopback, 0);
        var connector = new Connector(server.Port, certificate, token);
        await sessions.ConfigureAsync(new(SourceEndpointId: "synthetic", SharingEnabled: true));
        await using var phone = await connector.ReceiverAsync();
        await phone.SendAsync("STATS PLAYER1\n");
        await phone.ProbeAsync();
        await phone.SendAsync("RESUME 1\n");
        await phone.ProbeAsync();
        await SoundAsync(audio, 600);
        await Task.Delay(150);
        Require(media.Plays == 0, "A first connection pressed Play.");

        await phone.SendAsync("PARK 2 PAUSE\n");
        Require((await phone.ProbeAsync() & Protocol.ParkAccepted) != 0, "Listener pause was not acknowledged.");
        Require(sessions.Status.Capturing, "A PLAYER1 phone paused by its listener must keep the computer observed.");
        await SoundAsync(audio, 600);
        Require((await phone.ProbeAsync() & Protocol.ResumeOffer) == 0, "Sound continuing through the pause offered resume.");
        await Task.Delay(2200);
        audio.Emit(480, MonotonicClock.Nanoseconds);
        await Task.Delay(400);
        Require((await phone.ProbeAsync() & Protocol.ResumeOffer) == 0, "A short chime after silence offered resume.");
        await SoundAsync(audio, 600);
        await ProbeUntilAsync(phone, flags => (flags & Protocol.ResumeOffer) != 0, "sustained new computer sound after a stop offers resume");

        await Task.Delay(2100);
        await phone.SendAsync("RESUME 3\n");
        Require((await phone.ProbeAsync() & Protocol.ParkAccepted) == 0, "Resume was not acknowledged.");
        await UntilAsync(() => media.Plays == 1, "resume from a listener pause starts the quiet computer player");

        await phone.SendAsync("PARK 4 PAUSE\n");
        await phone.ProbeAsync();
        await SoundAsync(audio, 300);
        await phone.SendAsync("RESUME 5\n");
        await phone.ProbeAsync(); await Task.Delay(150);
        Require(media.Plays == 1, "Resume pressed Play while the computer was sounding.");

        await phone.SendAsync("PARK 6 OUTPUT\n");
        await phone.ProbeAsync(); await Task.Delay(2100);
        await phone.SendAsync("RESUME 7\n");
        await phone.ProbeAsync(); await Task.Delay(150);
        Require(media.Plays == 1, "Resume after an output park pressed Play.");

        await phone.SendAsync("PARK 8 PAUSE\n");
        await phone.ProbeAsync(); await Task.Delay(2100);
        await phone.SendAsync("STATS MEDIA1 NEXT\nRESUME 9\n");
        await phone.ProbeAsync(); await Task.Delay(150);
        Require(media.Plays == 1 && media.Nexts == 1, "Resume right after an earphone skip also pressed Play.");

        await phone.SendAsync("PARK 10 PHONE\n");
        await ProbeUntilAsync(phone, flags => (flags & Protocol.PlayerPaused) != 0, "a call pauses the computer player");
        await Task.Delay(2100);
        await sessions.SetMediaHandoffSuppressedAsync(true);
        await phone.SendAsync("RESUME 11\n");
        await phone.ProbeAsync(); await Task.Delay(150);
        Require(media.Plays == 1, "Resume pressed Play while the computer was locked.");
        await sessions.SetMediaHandoffSuppressedAsync(false);
        await phone.SendAsync("PARK 12 PHONE\n");
        await ProbeUntilAsync(phone, flags => (flags & Protocol.PlayerPaused) != 0, "second call pauses the computer player");
        await Task.Delay(600);
        await phone.SendAsync("RESUME 13\n");
        await phone.ProbeAsync();
        await UntilAsync(() => media.Plays == 2, "resume after a call starts the player PairIt paused");
        Console.WriteLine("PASS: PLAYER1 pause offers need a 2 s stop then 0.5 s of sound; resume presses Play only after a pause/call, when quiet, unlocked and not right after a skip.");
    }

    private static async Task CheckVolumeAsync(X509Certificate2 certificate, string token)
    {
        var audio = new SyntheticEndpoints { VolumeWire = 500, VolumeIndependent = true };
        var sessions = new DesktopSessions(audio);
        await using var server = new RelayServer(certificate, token, sessions);
        server.Start(IPAddress.Loopback, 0);
        var connector = new Connector(server.Port, certificate, token);
        await sessions.ConfigureAsync(new(SourceEndpointId: "synthetic", SharingEnabled: true));
        await using var legacy = await connector.ReceiverAsync();
        await using var phone = await connector.ReceiverAsync();
        await legacy.SendAsync("STATS VOLUME1\n");
        await phone.SendAsync("STATS VOLUME1\nSTATS VOLUME2\nSTATS PVOL1 300\n");
        await legacy.ProbeAsync(); await phone.ProbeAsync();
        await UntilAsync(() => legacy.ComputerVolumeFrames > 0 && phone.ComputerVolumeFrames > 0, "computer volume frames");
        Require(legacy.ComputerVolume == 500 && phone.ComputerVolume == (500 | Protocol.PhoneOwnedVolume),
            "Only a VOLUME2 phone may be told it owns its volume.");
        await Task.Delay(400); // The first observation is a baseline, never a key press.
        Require(phone.VolumeRequests.IsEmpty, "Connecting moved the phone's volume.");
        await ExpectVolumeAsync(audio, phone, 600, 400);
        await ExpectVolumeAsync(audio, phone, 0, 0);
        audio.VolumeWire = 0x10000; // Muted at the same level.
        await Task.Delay(400);
        Require(phone.VolumeRequests.Count == 2, "Mute alone moved the phone's volume.");
        await ExpectVolumeAsync(audio, phone, 250, 250);
        await phone.SendAsync("STATS PVOL1 900\n");
        await phone.ProbeAsync();
        await ExpectVolumeAsync(audio, phone, 300, 950);
        await phone.SendAsync("STATS PVOL1 1001\nSTATS PVOL1 -5\nSTATS PVOL1 x\n");
        await phone.ProbeAsync();
        Require(!phone.Closed, "A malformed phone level closed the receiver.");
        await ExpectVolumeAsync(audio, phone, 310, 960);
        var at = MonotonicClock.Nanoseconds;
        audio.Emit(480, at);
        await UntilAsync(() => phone.Frames.Any(frame => frame.CapturedAt == at) && legacy.Frames.Any(frame => frame.CapturedAt == at), "PCM for both volume modes");
        Require(phone.Frames.Single(frame => frame.CapturedAt == at) == legacy.Frames.Single(frame => frame.CapturedAt == at),
            "A VOLUME2 phone's PCM differs from the unattenuated stream.");
        Require(legacy.VolumeRequests.IsEmpty, "A receiver without VOLUME2 received a volume request.");

        // A capture already attenuated by the computer volume never links the phone's volume.
        audio.VolumeIndependent = false;
        var before = phone.ComputerVolumeFrames;
        await phone.ProbeAsync();
        await UntilAsync(() => phone.ComputerVolumeFrames > before, "volume frame after capture change");
        Require((phone.ComputerVolume & Protocol.PhoneOwnedVolume) == 0, "Attenuated capture claimed the phone owns its volume.");
        audio.VolumeWire = 400;
        await Task.Delay(400);
        Require(phone.VolumeRequests.Count == 5, "Attenuated capture also moved the phone's volume.");
        Console.WriteLine("PASS: VOLUME2 flag and PVOL1 levels; computer volume changes move only VOLUME2 phones by the same delta, clamped; mute and attenuated capture do not.");
    }

    private static async Task ExpectVolumeAsync(SyntheticEndpoints audio, Receiver phone, int computer, uint target)
    {
        var count = phone.VolumeRequests.Count;
        audio.VolumeWire = computer;
        await UntilAsync(() => phone.VolumeRequests.Count == count + 1, "phone volume request");
        Require(phone.VolumeRequests.Last() == target, $"Phone volume request {phone.VolumeRequests.Last()}; expected {target}.");
    }

    private static async Task CheckDisconnectAsync(X509Certificate2 certificate, string token)
    {
        var audio = new SyntheticEndpoints();
        var sessions = new DesktopSessions(audio);
        await using var server = new RelayServer(certificate, token, sessions);
        server.Start(IPAddress.Loopback, 0);
        var connector = new Connector(server.Port, certificate, token);
        await sessions.ConfigureAsync(new(SourceEndpointId: "synthetic", SharingEnabled: true));
        await using var updated = await NamedAsync(connector, "Updated", "STATS CONTROLS1\nSTATS CONTROLS2\nRESUME 1\n");
        await using var older = await NamedAsync(connector, "Older", "STATS CONTROLS1\n");
        await using var silent = await NamedAsync(connector, "Silent", "STATS CONTROLS1\nSTATS CONTROLS2\nRESUME 1\n");
        await UntilAsync(() => sessions.Phones.Count == 3 && sessions.Phones.All(phone => phone.Name != "Phone"), "listed phones");
        DesktopPhone Find(string name) => sessions.Phones.Single(phone => phone.Name == name);
        Require(Find("Updated").StopsOnDisconnect && !Find("Older").StopsOnDisconnect && Find("Updated").State == DesktopPhoneState.Listening,
            "Phone list does not reflect negotiated disconnect support or state.");

        sessions.DisconnectPhone(Find("Updated").Id);
        await updated.ProbeAsync();
        await UntilAsync(() => updated.DesktopRequest == (1u << 8 | 2u | Protocol.DesktopRelease), "disconnect request to a CONTROLS2 phone");
        await updated.SendAsync("RELEASE 2\n");
        Require((await updated.ProbeAsync() & Protocol.ReleaseAccepted) != 0, "Phone release was not acknowledged.");
        await UntilAsync(() => sessions.Phones.All(phone => phone.Name != "Updated"), "released phone leaves the list");

        sessions.DisconnectPhone(Find("Older").Id);
        await UntilAsync(() => older.Closed, "older phone closed directly");
        Require(older.DesktopRequest == 0, "A phone without CONTROLS2 received the disconnect bit.");

        sessions.DisconnectPhone(Find("Silent").Id);
        await silent.ProbeAsync();
        await UntilAsync(() => (silent.DesktopRequest & Protocol.DesktopRelease) != 0, "disconnect request to an unresponsive phone");
        await Task.Delay(1000);
        await updated.ProbeAsync(); // Keeps the released phone's control channel alive.
        Require(!silent.Closed, "An updated phone was closed before it could stop itself.");
        await UntilAsync(() => silent.Closed, "unresponsive phone closed after 5 s", 6000);
        Require(!updated.Closed, "A phone that released was closed anyway.");
        Console.WriteLine("PASS: phone list; CONTROLS2 disconnect asks the phone to stop and closes it after 5 s only if it never releases; older phones close directly.");
    }

    private static async Task<Receiver> NamedAsync(Connector connector, string name, string lines)
    {
        var receiver = await connector.ReceiverAsync();
        await receiver.SendAsync("NAME1 " + Convert.ToBase64String(Encoding.UTF8.GetBytes(name)) + "\n");
        await receiver.ProbeAsync(); // Advertises handoff before any intent.
        await receiver.SendAsync(lines);
        await receiver.ProbeAsync();
        return receiver;
    }

    private static async Task ProbeUntilAsync(Receiver receiver, Func<uint, bool> condition, string description)
    {
        using var deadline = new CancellationTokenSource(3000);
        while (!condition(await receiver.ProbeAsync()))
        {
            if (deadline.IsCancellationRequested) throw new TimeoutException(description);
            await Task.Delay(10);
        }
    }

    // Sustained synthetic sound: one 10 ms packet every 100 ms for the given duration.
    private static async Task SoundAsync(SyntheticEndpoints audio, int milliseconds)
    {
        for (var elapsed = 0; elapsed <= milliseconds; elapsed += 100)
        {
            audio.Emit(480, MonotonicClock.Nanoseconds);
            await Task.Delay(100);
        }
    }
}
