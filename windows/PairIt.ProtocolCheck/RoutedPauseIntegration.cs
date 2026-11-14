using System.Net;
using System.Security.Cryptography.X509Certificates;
using PairIt.Core;
using static Integration;

internal static class RoutedPauseIntegration
{
    internal static async Task RunAsync(X509Certificate2 certificate, string token)
    {
        var audio = new SyntheticEndpoints { KeepCaptureWhilePaused = true };
        var sessions = new DesktopSessions(audio, new SyntheticMediaController());
        await using var server = new RelayServer(certificate, token, sessions);
        server.Start(IPAddress.Loopback, 0);
        await sessions.ConfigureAsync(new(SourceEndpointId: "synthetic", SharingEnabled: true));
        var connector = new Connector(server.Port, certificate, token);
        await using (var phone = await connector.ReceiverAsync())
        {
            await phone.ProbeAsync();
            await phone.SendAsync("PARK 1 OUTPUT\n");
            Require((await phone.ProbeAsync() & Protocol.ParkAccepted) != 0, "Routed phone must acknowledge pause.");
            Require(sessions.Status.Capturing && audio.SourceStops == 0,
                "Pausing the phone must retain its existing silent computer route.");
            var frameCount = phone.Frames.Count;
            audio.Emit(480, MonotonicClock.Nanoseconds);
            await phone.ProbeAsync();
            Require(phone.Frames.Count == frameCount, "Paused phone received PCM from retained route.");
            await sessions.SetComputerOutputAsync(true);
            Require(!sessions.Status.Capturing && audio.SourceStops == 1, "Computer choice must release the route.");
            await sessions.SetComputerOutputAsync(false);
            Require(!sessions.Status.Capturing, "Paused phone must not initiate new capture on output switch.");
            await phone.SendAsync("RESUME 2\n");
            await phone.ProbeAsync();
            Require(sessions.Status.Capturing && audio.SourceStarts == 2, "Resume must reacquire the route.");
        }
        await UntilAsync(() => sessions.Status.Receivers == 0 && audio.SourceStops == 2, "disconnect restores routed output");
        Console.WriteLine("PASS: routed playback pause stays silent, explicit Computer and disconnect release routing.");
    }
}
