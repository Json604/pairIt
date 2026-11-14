using PairIt.Linux;
using System.Diagnostics;
using System.Text.Json;

internal static class LiveRoutingChecks
{
    private static void Require(bool value, string message) { if (!value) throw new Exception(message); }
    public static async Task RunAsync()
    {
        var commands = new PulseCommands();
        var original = await commands.RunAsync(CancellationToken.None, "get-default-sink");
        var a = await commands.RunAsync(CancellationToken.None, "load-module", "module-null-sink", "sink_name=pairit_route_test");
        var b = await commands.RunAsync(CancellationToken.None, "load-module", "module-null-sink", "sink_name=pairit_unrelated_test");
        var players = new List<Process>();
        try {
            await commands.RunAsync(CancellationToken.None, "set-default-sink", "pairit_route_test");
            players.Add(Player("pairit_route_test", "PairItTestFirst"));
            players.Add(Player("pairit_unrelated_test", "PairItTestOther"));
            await Task.Delay(300);
            string expectedFirst, expectedNew;
            await using (var route = new PulseRoute(commands)) {
                await route.StartAsync("pairit_route_test.monitor", CancellationToken.None);
                Require(await SinkFor("PairItTestFirst", commands) == route.SinkName, "Existing selected stream did not move.");
                Require(await SinkFor("PairItTestOther", commands) == "pairit_unrelated_test", "Unrelated stream moved.");
                players.Add(Player("pairit_route_test", "PairItTestNew"));
                await Task.Delay(300);
                await route.RefreshAsync(CancellationToken.None);
                Require(await SinkFor("PairItTestNew", commands) == route.SinkName, "New selected stream did not move.");
                await commands.RunAsync(CancellationToken.None, "set-default-sink", "pairit_unrelated_test");
                expectedFirst = await SinkFor("PairItTestFirst",commands);
                expectedNew = await SinkFor("PairItTestNew",commands);
                if(expectedFirst==route.SinkName) expectedFirst="pairit_route_test";
                if(expectedNew==route.SinkName) expectedNew="pairit_route_test";
            }
            Require(await commands.RunAsync(CancellationToken.None, "get-default-sink") == "pairit_unrelated_test", "Manual default was overwritten.");
            Require(await SinkFor("PairItTestFirst", commands) == expectedFirst, "Original stream restored over manual routing choice.");
            Require(await SinkFor("PairItTestNew", commands) == expectedNew, "New stream restored over manual routing choice.");
            Require(!(await PulseAudio.ListAsync()).Any(s => s.IsRelay), "Temporary relay sink leaked.");
            await commands.RunAsync(CancellationToken.None,"set-default-sink","pairit_route_test");
            await commands.RunAsync(CancellationToken.None,"set-sink-volume","pairit_route_test","32768");
            await using (var source = new LinuxAudioEndpoints().CreateSource("pairit_route_test.monitor")) {
                var heard = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                await source.StartAsync(p => { if (p.StereoPcm16.Any(x=>x!=0)) heard.TrySetResult(); }, message=>heard.TrySetException(new IOException(message)), CancellationToken.None);
                await heard.Task.WaitAsync(TimeSpan.FromSeconds(8));
                Require((await SinkFor("PairItTestFirst",commands)).StartsWith("pairit_relay_"),"Routed source did not divert speakers.");
                var relay=(await PulseAudio.ListAsync()).Single(s=>s.IsRelay);
                Require(relay.Volume==500,"Phone routing changed the selected output volume.");
                await using var physical=new PulseSource("pairit_route_test.monitor");
                var silent=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); int packets=0;
                await physical.StartAsync(p=>{
                    if(p.StereoPcm16.Any(x=>x!=0)) silent.TrySetException(new Exception("Laptop output still carries audio while Phone is selected."));
                    if(Interlocked.Increment(ref packets)>=20) silent.TrySetResult();
                },message=>silent.TrySetException(new IOException(message)),CancellationToken.None);
                await silent.Task.WaitAsync(TimeSpan.FromSeconds(8));
            }
            Require(await SinkFor("PairItTestFirst", commands) == "pairit_route_test", "Source disposal did not restore speakers.");
            var crashInfo = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute=false,RedirectStandardOutput=true,RedirectStandardError=true };
            if (Path.GetFileNameWithoutExtension(Environment.ProcessPath)=="dotnet") crashInfo.ArgumentList.Add(typeof(LiveRoutingChecks).Assembly.Location);
            crashInfo.ArgumentList.Add("--route-crash-helper");
            using(var child=Process.Start(crashInfo)!) {
                var owned=await child.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(10));
                Require(owned?.StartsWith("pairit_relay_")==true,"Crash helper did not create route.");
                child.Kill(); await child.WaitForExitAsync();
                for(int i=0;i<30 && (await PulseAudio.ListAsync()).Any(s=>s.Name==owned);i++) await Task.Delay(100);
                Require(!(await PulseAudio.ListAsync()).Any(s=>s.Name==owned),"Crash recovery leaked its sink.");
                Require(await commands.RunAsync(CancellationToken.None,"get-default-sink")=="pairit_route_test","Crash recovery did not restore default.");
            }
            Console.WriteLine("PASS: live server routes old/new streams, isolates other outputs, captures audible PCM, restores on stop/crash and honors manual default.");
        } finally {
            foreach(var p in players) { if (!p.HasExited) p.Kill(); await p.WaitForExitAsync(); p.Dispose(); }
            if ((await PulseAudio.ListAsync()).Any(s=>s.Name==original)) await commands.RunAsync(CancellationToken.None,"set-default-sink",original);
            await commands.RunAsync(CancellationToken.None,"unload-module",a);
            await commands.RunAsync(CancellationToken.None,"unload-module",b);
        }
    }
    private static Process Player(string sink, string name)
    {
        var info = new ProcessStartInfo("pacat") { UseShellExecute=false,RedirectStandardInput=true,RedirectStandardError=true };
        foreach(var a in new[]{"--playback","--raw","--format=s16le","--rate=48000","--channels=2","--device="+sink,"--client-name="+name}) info.ArgumentList.Add(a);
        var p=Process.Start(info)!;
        _ = Task.Run(async () => {
            var data = new byte[1920];
            for(int i=0;i<960;i++) System.Buffers.Binary.BinaryPrimitives.WriteInt16LittleEndian(data.AsSpan(i*2),(short)(8000*Math.Sin(i*Math.Tau*440/48000)));
            try { while(!p.HasExited) { await p.StandardInput.BaseStream.WriteAsync(data); await Task.Delay(10); } }
            catch(Exception e) when(e is IOException or ObjectDisposedException or InvalidOperationException) { }
        });
        return p;
    }
    private static async Task<string> SinkFor(string name, IPulseCommands commands)
    {
        using var inputs=JsonDocument.Parse(await commands.RunAsync(CancellationToken.None,"--format=json","list","sink-inputs"));
        var input=inputs.RootElement.EnumerateArray().Single(i=>i.GetProperty("properties").GetProperty("application.name").GetString()==name);
        var id=input.GetProperty("sink").GetUInt32();
        using var sinks=JsonDocument.Parse(await commands.RunAsync(CancellationToken.None,"--format=json","list","sinks"));
        return sinks.RootElement.EnumerateArray().Single(s=>s.GetProperty("index").GetUInt32()==id).GetProperty("name").GetString()!;
    }
}
