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
        var audible = Audible(pcm);
        if (now - lastAudible >= 750_000_000) armed = true;
        if (!audible) { onset = null; return false; }
        lastAudible = now;
        if (!armed) return false;
        onset ??= now;
        if (now - onset < 80_000_000) return false;
        armed = false; onset = null; return true;
    }

    internal static bool Audible(ReadOnlySpan<byte> pcm)
    {
        for (var i = 0; i + 1 < pcm.Length; i += 2)
            if (Math.Abs((int)BinaryPrimitives.ReadInt16LittleEndian(pcm[i..])) > 160) return true;
        return false;
    }
}

internal readonly record struct PlaybackChange(bool PlayingChanged, bool PauseOffer);

// Whether the computer is producing sound (STATS PLAYER1), from captured PCM only.
// Loopback capture may deliver nothing while idle, so silence is also observed on a timer.
internal sealed class ComputerPlayback
{
    public const long PlayingWindow = 1_500_000_000, OfferSilence = 2_000_000_000, OfferSound = 500_000_000;
    private long? lastAudible, runStart;
    private long observedSince;
    private bool armed;
    public bool Playing { get; private set; }

    // Silence is only evidence while a source is actually being observed.
    public void SourceStarted(long now) { observedSince = now; runStart = null; }

    public bool SilentFor(long duration, long now) => lastAudible is not long at || now - at >= duration;

    public PlaybackChange Sound(ReadOnlySpan<byte> pcm, long now) => AudioOnset.Audible(pcm) ? Audible(now) : Silence(now, true);

    public PlaybackChange Silence(long now, bool observing)
    {
        // A real stop (not a gap between songs) arms one offer for the next sustained sound.
        if (observing && now - Math.Max(lastAudible ?? long.MinValue, observedSince) >= OfferSilence) armed = true;
        if (SilentFor(300_000_000, now)) runStart = null;
        if (!Playing || !SilentFor(PlayingWindow, now)) return default;
        Playing = false;
        return new(true, false);
    }

    private PlaybackChange Audible(long now)
    {
        runStart ??= now;
        lastAudible = now;
        var changed = !Playing;
        Playing = true;
        // Short sounds such as notification chimes never reclaim a paused phone.
        var offer = armed && now - runStart.Value >= OfferSound;
        if (offer) armed = false;
        return new(changed, offer);
    }
}
