package dev.bluetoothswitch.relay;

import java.util.function.BooleanSupplier;
import java.util.function.LongSupplier;
import java.util.concurrent.locks.LockSupport;

/** One clock anchor per playback epoch. Network jitter never moves its deadlines. */
final class PlayoutTiming {
    static final int CUSHION_MS = 320;
    static final int CANCELLED = 0, READY = 1, TOO_LATE = 2;
    private long clockOffset = Long.MIN_VALUE;
    private long lastCorrection;
    private double filteredError;
    private double submissionTarget = Double.NaN;
    private final int cushionMs;
    private final LongSupplier clock;
    int recoveries;
    long latePackets;
    PlayoutTiming() { this(CUSHION_MS); }
    PlayoutTiming(int cushionMs) { this(cushionMs, System::nanoTime); }
    PlayoutTiming(int cushionMs, LongSupplier clock) { this.cushionMs = cushionMs; this.clock = clock; }

    void reset() { clockOffset = Long.MIN_VALUE; lastCorrection = 0; filteredError = 0; submissionTarget = Double.NaN; }

    int start(PcmInbox inbox, PcmInbox.Packet packet, boolean shared, BooleanSupplier active) {
        clockOffset = inbox.clockOffset();
        long deadline = packet.capturedAt + clockOffset + cushionMs * 1_000_000L;
        // Only startup waits on a timer. Once primed, AudioTrack drives the clock.
        while (active.getAsBoolean()) {
            long remaining = deadline - clock.getAsLong();
            if (remaining < -(shared ? 10_000_000L : 100_000_000L)) { latePackets++; reset(); return TOO_LATE; }
            if (remaining <= 0) return READY;
            LockSupport.parkNanos(Math.min(remaining, 5_000_000L));
            if (Thread.currentThread().isInterrupted()) return CANCELLED;
        }
        return CANCELLED;
    }

    double submissionErrorMillis(PcmInbox.Packet packet) {
        return (clock.getAsLong() - packet.capturedAt - clockOffset) / 1e6 - cushionMs;
    }

    boolean correctionDue() { return clock.getAsLong() - lastCorrection >= 2_000_000_000L; }

    int correctedPresentationRate(double measuredMs, int targetMs, int rate) {
        long now = clock.getAsLong();
        if (!Double.isFinite(measuredMs) || now - lastCorrection < 2_000_000_000L) return 0;
        lastCorrection = now;
        filteredError = filteredError * 0.8 + (measuredMs - targetMs) * 0.2;
        return (int)Math.round(rate * (1 + PresentationTiming.rateCorrection(filteredError)));
    }

    // Bounded, slow correction for independent source/output crystal clocks.
    // Never speed through a network stall or repeatedly flush small jitter.
    int correctedRate(PcmInbox.Packet packet) {
        long now = clock.getAsLong();
        if (now - lastCorrection < 2_000_000_000L) return 0;
        lastCorrection = now;
        double age = submissionErrorMillis(packet);
        if (Double.isNaN(submissionTarget)) submissionTarget = age;
        double error = age - submissionTarget;
        filteredError = filteredError * 0.8 + error * 0.2;
        double correction = Math.abs(filteredError) < 4 ? 0 : Math.max(-0.001, Math.min(0.001, filteredError / 20000));
        return (int)Math.round(packet.rate * (1 + correction));
    }
}
