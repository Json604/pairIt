package dev.bluetoothswitch.relay;

/** Common presentation deadline, with each phone's measured output path removed.
 * A zero target means solo/legacy/unmeasured group: preserve existing timing. */
final class PresentationTiming {
    static int correctedDelay(int delay, int correction) {
        return Math.max(Math.min(delay,40), Math.min(2500,delay-Math.max(-500,Math.min(500,correction))));
    }
    static double rateCorrection(double errorMs) {
        if (!Double.isFinite(errorMs)) return 0;
        return Math.abs(errorMs) < 1 ? 0 : Math.max(-0.001, Math.min(0.001, errorMs / 20000));
    }
    static int outputDelay(int measuredTotalMs, int renderDelayMs) {
        int output = measuredTotalMs - renderDelayMs;
        return output >= 0 && output <= 1000 ? output : -1;
    }
    static int renderDelay(int minimumMs, int outputMs, int groupTargetMs) {
        if (outputMs < 0 || outputMs > 1000 || groupTargetMs <= 0 || groupTargetMs > 2000) return minimumMs;
        return Math.max(minimumMs, groupTargetMs - outputMs);
    }
}
