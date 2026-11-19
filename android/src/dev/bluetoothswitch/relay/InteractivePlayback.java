package dev.bluetoothswitch.relay;

import android.media.AudioTrack;
import android.os.Build;
import java.util.ArrayDeque;
import java.util.Arrays;

/** Fixed-epoch jitter estimate used by Low latency playback. Reliable playback never uses it. */
final class InteractivePlayback {
    private final int floorMs;
    InteractivePlayback() { this(40); }
    InteractivePlayback(int floorMs) { this.floorMs = floorMs; }
    private final long[] arrival = new long[64];
    private final ArrayDeque<Long> recoveries = new ArrayDeque<>();
    private int count;
    private long started, maximumPacketNs;
    private boolean ready, fallback;
    private int cushionMs = PlayoutTiming.CUSHION_MS;
    int cushionMs() { return cushionMs; }
    boolean fallback() { return fallback; }
    void resetLearning() { count = 0; started = 0; maximumPacketNs = 0; ready = false; }
    void useReliable() { fallback = true; ready = true; cushionMs = PlayoutTiming.CUSHION_MS; }
    boolean timedOut() {
        if (!ready && started != 0 && System.nanoTime() - started > 1_000_000_000L) useReliable();
        return fallback;
    }
    boolean observe(PcmInbox.Packet packet, int leadFrames) {
        if (ready) return true;
        if (started == 0) started = packet.receivedAt;
        if (packet.receivedAt - started > 1_000_000_000L) { useReliable(); return true; }
        arrival[count++] = packet.receivedAt - packet.capturedAt;
        maximumPacketNs = Math.max(maximumPacketNs, (long)Math.ceil(packet.frames * 1e9 / packet.rate));
        if (count < arrival.length) return false;
        double leadMs = leadFrames * 1000.0 / packet.rate;
        if (leadMs > PlayoutTiming.CUSHION_MS) { useReliable(); return true; }
        long[] sorted = arrival.clone(); Arrays.sort(sorted);
        long residual95 = sorted[(int)Math.ceil(.95 * sorted.length) - 1] - sorted[0];
        cushionMs = PresentationTiming.adaptiveCushion(residual95 / 1e6, maximumPacketNs / 1e6, leadMs, floorMs);
        ready = true; return true;
    }
    void recovery() {
        long now = System.nanoTime(); recoveries.addLast(now);
        while (!recoveries.isEmpty() && now - recoveries.peekFirst() > 15_000_000_000L) recoveries.removeFirst();
        if (recoveries.size() >= 3) useReliable();
    }
    static void configure(AudioTrack track, int minimumBytes) {
        int minimumFrames = Math.max(1, (minimumBytes + 3) / 4);
        track.setBufferSizeInFrames(minimumFrames);
        if (Build.VERSION.SDK_INT >= 31) track.setStartThresholdInFrames(Math.max(1, track.getBufferSizeInFrames()));
    }
}
