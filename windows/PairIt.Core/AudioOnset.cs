using System.Buffers.Binary;
namespace PairIt.Core;

// A new, sustained sound after silence. Never treats continuous playback as a request.
internal sealed class AudioOnset
{
    private long lastAudible = MonotonicClock.Nanoseconds;
    private long? onset;
    private bool armed;
    public bool Observe(ReadOnlySpan<byte> pcm, long now)
    {
        var audible = false;
        for (var i = 0; i + 1 < pcm.Length; i += 2)
            if (Math.Abs((int)BinaryPrimitives.ReadInt16LittleEndian(pcm[i..])) > 160) { audible = true; break; }
        if (now - lastAudible >= 750_000_000) armed = true;
        if (!audible) { onset = null; return false; }
        lastAudible = now;
        if (!armed) return false;
        onset ??= now;
        if (now - onset < 80_000_000) return false;
        armed = false; onset = null; return true;
    }
}
