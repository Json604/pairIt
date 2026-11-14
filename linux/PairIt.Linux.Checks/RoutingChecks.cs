using PairIt.Linux;
using System.Text.Json;

internal static class RoutingChecks
{
    private static void Require(bool value, string message) { if (!value) throw new Exception(message); }
    public static async Task RunAsync()
    {
        var server = new FakePulse();
        await using (var route = new PulseRoute(server))
        {
            await route.StartAsync("speakers.monitor", CancellationToken.None);
            Require(server.Default == route.SinkName && server.Streams[1] == 99, "Phone mode must divert selected-output audio.");
            Require(server.Streams[2] == 2, "Must leave unrelated output streams alone.");
            server.Streams[3] = 1;
            await route.RefreshAsync(CancellationToken.None);
            Require(server.Streams[3] == 99, "New selected-output streams must also move.");
            server.Streams[1] = 1;
            await route.RefreshAsync(CancellationToken.None);
            Require(server.Streams[1] == 1, "A manually moved stream must not be stolen back.");
            server.Streams[1] = 2; server.Default = "headphones";
        }
        Require(server.Default == "headphones", "Cleanup must preserve a manual default-output change.");
        Require(server.Streams[1] == 2 && server.Streams[3] == 1, "Restore only streams still on the owned relay output.");
        Require(!server.Loaded && !server.Commands.Any(c => c[0].Contains("mute")), "Owned sink must unload without muting speakers.");
        var ordinary = new FakePulse();
        await using (var route = new PulseRoute(ordinary)) { await route.StartAsync("speakers.monitor", CancellationToken.None); }
        Require(ordinary.Default == "speakers" && ordinary.Streams[1] == 1, "Computer/disconnect must restore the original output.");
        var rollback = new FakePulse { FailMove = true };
        try { await using var route = new PulseRoute(rollback); await route.StartAsync("speakers.monitor", CancellationToken.None); throw new Exception("Expected route failure"); }
        catch (IOException) { }
        Require(rollback.Default == "speakers" && !rollback.Loaded, "A partial route failure must roll back default and module.");
        var nonDefault = new FakePulse { Default = "headphones" };
        await using (var route = new PulseRoute(nonDefault)) {
            await route.StartAsync("speakers.monitor", CancellationToken.None);
            Require(nonDefault.Default == "headphones", "Explicit nondefault capture must not change system default.");
        }
        var disappearing = new FakePulse { VanishOnMove = true };
        await using (var route = new PulseRoute(disappearing)) { await route.StartAsync("speakers.monitor", CancellationToken.None); }
        Require(!disappearing.Loaded, "A naturally closing player must not fail routing or leak its sink.");
        using var canceled = new CancellationTokenSource();
        var cancelServer = new FakePulse { CancelAfterLoad = canceled };
        try { await using var route = new PulseRoute(cancelServer); await route.StartAsync("speakers.monitor", canceled.Token); throw new Exception("Expected cancellation"); }
        catch (OperationCanceledException) { }
        Require(!cancelServer.Loaded && cancelServer.Default=="speakers", "Canceled startup must remove temporary routing.");
        Console.WriteLine("PASS: Linux routing, new streams, restoration, manual changes and rollback.");
    }
}

internal sealed class FakePulse : IPulseCommands
{
    public string Default = "speakers", Relay = "";
    public bool Loaded, FailMove, VanishOnMove;
    public CancellationTokenSource? CancelAfterLoad;
    public Dictionary<uint,uint> Streams = new() { [1]=1, [2]=2 };
    public List<string[]> Commands = [];
    public Task<string> RunAsync(CancellationToken token, params string[] args)
    {
        token.ThrowIfCancellationRequested(); Commands.Add(args);
        if (args[0] == "get-default-sink") return Task.FromResult(Default);
        if (args[0] == "load-module") { Loaded=true; Relay=args.First(x=>x.StartsWith("sink_name=")).Split('=')[1]; CancelAfterLoad?.Cancel(); return Task.FromResult("51"); }
        if (args[0] == "set-default-sink") { Default=args[1]; return Task.FromResult(""); }
        if (args[0] == "move-sink-input") {
            if (VanishOnMove && args[2]==Relay) { Streams.Remove(uint.Parse(args[1])); throw new IOException("Stream ended"); }
            if (FailMove && args[2]==Relay) throw new IOException("Move failed");
            Streams[uint.Parse(args[1])]=args[2]==Relay ? 99u : args[2]=="speakers" ? 1u : 2u; return Task.FromResult("");
        }
        if (args[0] == "unload-module") { Loaded=false; return Task.FromResult(""); }
        if (args.SequenceEqual(new[]{"--format=json","list","sinks"})) {
            var sinks = new List<object> { new {index=1,name="speakers",monitor_source="speakers.monitor"},new {index=2,name="headphones",monitor_source="headphones.monitor"} };
            if (Loaded) sinks.Add(new {index=99,name=Relay,monitor_source=Relay+".monitor",owner_module=51});
            return Task.FromResult(JsonSerializer.Serialize(sinks));
        }
        if (args.SequenceEqual(new[]{"--format=json","list","sink-inputs"})) return Task.FromResult(JsonSerializer.Serialize(Streams.Select(s=>new {index=s.Key,sink=s.Value})));
        throw new Exception(string.Join(' ',args));
    }
}
