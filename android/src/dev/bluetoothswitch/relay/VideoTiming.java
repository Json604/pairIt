package dev.bluetoothswitch.relay;

import android.media.AudioTimestamp;
import android.media.AudioTrack;
import java.util.Arrays;

/** Estimate source-to-presentation delay once the routed audio clock is stable.
 * This is an OS timestamp estimate, not an acoustic measurement. Never chase
 * packet jitter by changing video compensation during steady playback. */
final class VideoTiming {
    private final double[] samples = new double[7];
    private final AudioTimestamp timestamp = new AudioTimestamp();
    private int count;
    private long nextSample, previousFrame = -1;
    private boolean locked;

    void restartSampling(boolean keepCalibration) {
        count = 0;
        nextSample = 0;
        previousFrame = -1;
        if (!keepCalibration) locked = false;
    }
    Integer observe(AudioTrack track, PcmInbox inbox, PcmInbox.Packet packet, long writtenFrames, long startedMs) {
        long now = android.os.SystemClock.elapsedRealtime();
        if (locked || inbox.clockSamples < 3 || now - startedMs < 2500 || now < nextSample) return null;
        nextSample = now + 500;
        double delay = presentationDelay(track, inbox, packet, writtenFrames);
        if (!Double.isFinite(delay) || timestamp.framePosition <= previousFrame) return null;
        previousFrame = timestamp.framePosition;
        samples[count++] = delay;
        if (count < samples.length) return null;
        double[] sorted = samples.clone(); Arrays.sort(sorted);
        // Wait for the route's latency to settle instead of committing a warmup value.
        if (sorted[5] - sorted[1] > 30) { count = 0; return null; }
        locked = true;
        return (int)Math.round(sorted[3]);
    }
    double presentationDelay(AudioTrack track, PcmInbox inbox, PcmInbox.Packet packet, long writtenFrames) {
        if (!track.getTimestamp(timestamp) || timestamp.framePosition < 0 ||
                Math.abs(System.nanoTime() - timestamp.nanoTime) > 2_000_000_000L) return Double.NaN;
        double sourceEnd = packet.capturedAt + inbox.clockOffset() + packet.frames * 1e9 / packet.rate;
        double outputEnd = timestamp.nanoTime + (writtenFrames - timestamp.framePosition) * 1e9 / track.getPlaybackRate();
        double delay = (outputEnd - sourceEnd) / 1e6;
        return Double.isFinite(delay) && delay >= 0 && delay <= 2000 ? delay : Double.NaN;
    }

}
