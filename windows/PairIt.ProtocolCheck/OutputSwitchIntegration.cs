using System.Net;
using System.Security.Cryptography.X509Certificates;
using PairIt.Core;
using static Integration;

internal static class OutputSwitchIntegration
{
    public static async Task RunAsync(X509Certificate2 certificate, string token)
    {
        var audio = new SyntheticEndpoints();
        var media = new SyntheticMediaController();
        var sessions = new DesktopSessions(audio, media);
        var pairings = 0;
        sessions.PairingAcknowledged += () => Interlocked.Increment(ref pairings);
        await using var server = new RelayServer(certificate, token, sessions);
        server.Start(IPAddress.Loopback, 0);
        var connector = new Connector(server.Port, certificate, token);
        using (var pairing = await connector.ConnectAsync())
        {
            await pairing.WriteLineAsync(token + " PAIR1");
            Require(await pairing.ReadLineAsync() == "OK PAIR1", "Pairing confirmation was not acknowledged.");
        }
        await UntilAsync(() => pairings == 1, "desktop receives pairing confirmation immediately");
        Require(sessions.Status.Receivers == 0 && !sessions.Status.Capturing && audio.SourceAttempts == 0,
            "Pairing confirmation opened a receiver or captured audio.");
        using (var invalid = await connector.ConnectAsync())
        {
            await invalid.WriteLineAsync(new string('0', 64) + " PAIR1");
            try { await invalid.ReadLineAsync(); throw new InvalidOperationException("Wrong pairing token was accepted."); }
            catch (IOException) { }
        }
        Require(pairings == 1, "Unauthenticated confirmation raised a desktop pairing event.");
        await sessions.ConfigureAsync(new(SourceEndpointId: "synthetic", SharingEnabled: true));
        await using var phone = await connector.ReceiverAsync();
        Require((await phone.ProbeAsync() & 128) != 0, "Output switching capability was not advertised.");
        for (var cycle = 0; cycle < 3; cycle++)
        {
            await phone.SendAsync("OUTPUT COMPUTER\n");
            Require((await phone.ProbeAsync() & 64) != 0, "Computer output was not acknowledged.");
            Require(!sessions.Status.Capturing && sessions.Status.Receivers == 1 && sessions.Status.ActiveReceivers == 1,
                "Computer output closed the receiver or changed its playback intent.");
            var heartbeats = phone.Heartbeats;
            await UntilAsync(() => phone.Heartbeats > heartbeats, "heartbeat continues in computer mode");
            await phone.SendAsync("OUTPUT PHONE\n");
            Require((await phone.ProbeAsync() & 64) == 0 && sessions.Status.Capturing, "Phone output did not resume capture.");
            var at = MonotonicClock.Nanoseconds;
            audio.Emit(480, at);
            await UntilAsync(() => phone.Frames.Any(frame => frame.CapturedAt == at), "same socket receives resumed audio");
            Require(sessions.Status.Receivers == 1 && !phone.Closed, "Switching replaced the phone connection.");
        }
        await phone.SendAsync("PARK 1 OUTPUT\n");
        Require((await phone.ProbeAsync() & Protocol.ParkAccepted) != 0, "Phone did not park.");
        var attempts = media.Attempts;
        await phone.SendAsync("OUTPUT COMPUTER\nOUTPUT PHONE\n");
        var parked = await phone.ProbeAsync();
        Require((parked & Protocol.ParkAccepted) != 0 && (parked >> 8) == 1 && (parked & 64) == 0
            && !sessions.Status.Capturing && sessions.Status.Receivers == 1 && media.Attempts == attempts,
            "Output switching cleared the phone's park or issued a media command.");
        await phone.SendAsync("RESUME 2\n");
        Require((await phone.ProbeAsync() & Protocol.ParkAccepted) == 0 && sessions.Status.Capturing,
            "Explicit phone resume did not recover after output switching.");
        await sessions.SetComputerOutputAsync(true);
        Require((await phone.ProbeAsync() & Protocol.ComputerOutput) != 0 && !sessions.Status.Capturing,
            "Desktop computer choice did not reach the phone.");
        audio.FailSourceStartup = true;
        await sessions.SetComputerOutputAsync(false);
        Require((await phone.ProbeAsync() & Protocol.ComputerOutput) != 0 && sessions.Status.Receivers == 1 && !phone.Closed,
            "Failed source restart dropped the phone connection or advertised a false output switch.");
        audio.FailSourceStartup = false;
        await sessions.SetComputerOutputAsync(false);
        Require((await phone.ProbeAsync() & Protocol.ComputerOutput) == 0 && sessions.Status.Capturing,
            "Desktop explicit retry did not resume the existing phone connection.");
        Console.WriteLine("PASS: pairing confirms without capture; output switches preserve sockets/heartbeats and parked phone intent.");
    }
}
