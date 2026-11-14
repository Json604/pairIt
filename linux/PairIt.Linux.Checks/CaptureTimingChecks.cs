using PairIt.Linux;

internal static class CaptureTimingChecks
{
    private static void Require(bool value, string message) { if (!value) throw new Exception(message); }
    public static void Run()
    {
        var clock = new CaptureTimeline();
        var first = clock.Next(1_000_000_000);
        Require(first.FirstFrameNanoseconds == 990_000_000 && !first.Discontinuity, "First packet must describe its first sample, not its delivery end.");
        var second = clock.Next(1_000_100_000);
        Require(second.FirstFrameNanoseconds - first.FirstFrameNanoseconds == 10_000_000, "A pipe-delivery burst must retain sample spacing.");
        var third = clock.Next(1_020_800_000);
        Require(third.FirstFrameNanoseconds - second.FirstFrameNanoseconds == 10_000_000 && !third.Discontinuity, "Scheduler jitter must not become source-clock jitter.");
        Require(clock.Next(1_500_000_000, 4096).Restart, "A long stall must discard opaque upstream backlog, even when only a short buffer fits the pipe.");
        Require(new CaptureTimeline().Next(1_500_000_000, CaptureTimeline.PacketBytes * 50).Restart, "Initial queued stale PCM must not be labelled fresh.");
        var recovered = new CaptureTimeline(recovering: true);
        var fresh = recovered.Next(1_600_000_000);
        Require(fresh.Discontinuity && !fresh.Restart && fresh.FirstFrameNanoseconds == 1_590_000_000, "Fresh capture must reset playback queues without disconnecting peers.");
        Require(!recovered.Next(1_610_000_000).Discontinuity, "Only the first fresh packet should reset playback queues.");
        // The private null sink uses server time, but tolerate plausible capture
        // clock drift: 50ppm over ten minutes is 30ms, below recovery threshold.
        var drift = new CaptureTimeline();
        for (int i = 0; i < 60_000; i++)
            Require(!drift.Next(1_000_000_000L + i * 10_000_500L).Restart, "Slow clock drift must not repeatedly restart capture.");
        Console.WriteLine("PASS: Linux sample clock preserves burst cadence, rejects stale backlog and marks fresh recovery.");
    }
}
