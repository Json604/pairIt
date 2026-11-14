using PairIt.Core;
using PairIt.Linux;

internal static class LiveCaptureTimingChecks
{
    public static async Task RunAsync()
    {
        var commands = new PulseCommands();
        var name = "pairit_timing_" + Guid.NewGuid().ToString("N");
        var module = await commands.RunAsync(CancellationToken.None, "load-module", "module-null-sink", "sink_name=" + name, "rate=48000", "channels=2");
        try {
            await using var source = new RoutedPulseSource(name + ".monitor");
            var complete = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var intervals = new List<double>();
            long? previousSample = null, previousArrival = null;
            int count = 0, resets = 0;
            bool stalled = false;
            await source.StartAsync(packet => {
                var now = MonotonicClock.Nanoseconds;
                if (count >= 250) return;
                if (previousSample.HasValue && !packet.Discontinuity && packet.FirstFrameNanoseconds - previousSample != 10_000_000)
                    complete.TrySetException(new Exception("Pipe delivery jitter leaked into PCM timestamps."));
                if (packet.Discontinuity) resets++;
                if (stalled && now - packet.FirstFrameNanoseconds > 100_000_000)
                    complete.TrySetException(new Exception("Stale queued audio replayed after a consumer stall."));
                if (previousArrival.HasValue) intervals.Add((now - previousArrival.Value) / 1_000_000.0);
                previousSample = packet.FirstFrameNanoseconds; previousArrival = now;
                if (++count == 80) { stalled = true; Thread.Sleep(350); }
                if (count == 250) complete.TrySetResult();
            }, message => complete.TrySetException(new IOException(message)), CancellationToken.None);
            var routeBefore = (await PulseAudio.ListAsync()).Single(s => s.IsRelay).Name;
            await complete.Task.WaitAsync(TimeSpan.FromSeconds(10));
            if (!(await PulseAudio.ListAsync()).Any(s => s.Name == routeBefore))
                throw new Exception("Capture recovery replaced the private audio route.");
            if (resets < 1 || resets > 5) throw new Exception("Capture must recover once from the deliberate consumer stall without repeated resets.");
            intervals.Sort();
            Console.WriteLine($"PASS: 250 live capture packets retain 10ms sample spacing; resets={resets}; arrival median={intervals[intervals.Count / 2]:F2}ms p95={intervals[(int)(intervals.Count * .95)]:F2}ms.");
        } finally { await commands.RunAsync(CancellationToken.None, "unload-module", module); }
    }
}
