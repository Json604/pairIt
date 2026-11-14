namespace PairIt.Linux;

/// <summary>Keep sample time independent of the scheduler that drains the capture pipe.</summary>
public sealed class CaptureTimeline(bool recovering = false)
{
    public const int Rate = 48_000;
    public const int Frames = 480;
    public const int PacketBytes = Frames * 4;
    private const long PacketNanoseconds = 10_000_000;
    private const long InterruptionNanoseconds = 100_000_000;
    private const int MaximumQueuedBytes = PacketBytes * 6;
    private long? next;

    public (long FirstFrameNanoseconds, bool Discontinuity, bool Restart) Next(long deliveredAtNanoseconds, int pendingBytes = 0)
    {
        if (pendingBytes < 0) throw new ArgumentOutOfRangeException(nameof(pendingBytes));
        var bufferedNanoseconds = (long)pendingBytes * 1_000_000_000 / (Rate * 4);
        var estimated = deliveredAtNanoseconds - PacketNanoseconds - bufferedNanoseconds;
        // Opaque upstream buffers can contain more than FIONREAD reports. Never
        // re-anchor old PCM to now: restart the capture client to discard all of it.
        if (pendingBytes > MaximumQueuedBytes || next.HasValue && Math.Abs(estimated - next.Value) > InterruptionNanoseconds)
            return (0, false, true);
        var first = next ?? estimated;
        var discontinuity = !next.HasValue && recovering;
        next = first + PacketNanoseconds;
        return (first, discontinuity, false);
    }
}
