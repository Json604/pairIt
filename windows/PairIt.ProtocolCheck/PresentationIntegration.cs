using System.Net;
using System.Security.Cryptography.X509Certificates;
using PairIt.Core;
using static Integration;

internal static class PresentationIntegration
{
    public static async Task RunAsync(X509Certificate2 certificate, string token)
    {
        var audio = new SyntheticEndpoints();
        var sessions = new DesktopSessions(audio);
        await using var server = new RelayServer(certificate, token, sessions);
        server.Start(IPAddress.Loopback, 0);
        var connector = new Connector(server.Port, certificate, token);
        await sessions.ConfigureAsync(new(SourceEndpointId: "synthetic", SharingEnabled: true));
        await using var first = await connector.ReceiverAsync();
        await first.SendAsync("STATS ALIGN1 320 20\n");
        await Probe(first, 0, 1, 1);
        var second = await connector.ReceiverAsync();
        try {
        await Probe(first, 0, 2, 1); // Legacy peer never receives an unknown frame.
        Require(second.AlignmentReplies == 0 && !second.Closed, "Legacy receiver received alignment extension.");
        await second.SendAsync("STATS ALIGN1 320 -1\n");
        await Probe(first, 0, 2, 2); // Wait for its routed output clock to settle.
        await second.SendAsync("STATS ALIGN1 320 183\n");
        await second.ProbeAsync(); // Ensure its report has been processed before probing the other socket.
        await Probe(first, 510, 2, 2);
        await Probe(second, 510, 2, 2);
        var at = MonotonicClock.Nanoseconds;
        audio.Emit(480, at);
        await UntilAsync(() => first.Frames.Any(f => f.CapturedAt == at) && second.Frames.Any(f => f.CapturedAt == at), "aligned source packets");
        Require(sessions.Status.Receivers == 2 && audio.SourceStarts == 1, "Timing reports restarted capture or connection.");
        await second.SendAsync("ACTIVE 0\n");
        await second.ProbeAsync();
        await Probe(first, 0, 1, 1);
        await second.SendAsync("ACTIVE 1\n");
        await second.ProbeAsync();
        await Probe(first, 510, 2, 2);
        await second.SendAsync("STATS ALIGN1 320 -1\n"); // Route change invalidates old calibration.
        await second.ProbeAsync();
        await Probe(first, 0, 2, 2);
        } finally { await second.DisposeAsync(); }
        await UntilAsync(() => sessions.Status.Receivers == 1, "late listener leaves");
        await Probe(first, 0, 1, 1);
        Console.WriteLine("PASS: negotiated shared presentation, mixed versions, route relearning, late join, pause and solo fallback preserve sockets.");
    }
    private static async Task Probe(Receiver receiver, uint target, uint listeners, uint capable) {
        var before = receiver.AlignmentReplies;
        await receiver.ProbeAsync();
        await UntilAsync(() => receiver.AlignmentReplies > before, "presentation response");
        Require(receiver.PresentationTarget == target && receiver.PresentationListeners == listeners && receiver.PresentationCapable == capable,
            $"Wrong presentation group: {receiver.PresentationTarget}/{receiver.PresentationListeners}/{receiver.PresentationCapable}; expected {target}/{listeners}/{capable}.");
    }
}
