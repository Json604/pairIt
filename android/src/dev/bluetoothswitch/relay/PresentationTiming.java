package dev.bluetoothswitch.relay;

/** Common presentation deadline, with each phone's measured output path removed.
 * A zero target means solo/legacy/unmeasured group: preserve existing timing. */
final class PresentationTiming {
    private static boolean desktop(String platform) {
        return "linux".equals(platform) || "windows".equals(platform) || "macos".equals(platform);
    }
    /** Low latency learns network jitter instead of holding a fixed 320 ms cushion.
     * Windows/Linux local outputs always learned; Low latency extends it to Mac and
     * Bluetooth. Unknown/legacy computers keep Reliable. Unstable sessions fall back. */
    static boolean adaptive(String platform, boolean bluetooth, boolean lowLatency) {
        if (!bluetooth && ("linux".equals(platform) || "windows".equals(platform))) return true;
        return lowLatency && desktop(platform);
    }
    static boolean adaptive(String platform, boolean bluetooth) { return adaptive(platform, bluetooth, false); }
    /** The original local Windows/Linux path keeps its 40 ms floor. Paths added by Low
     * latency keep 60 ms, because a short learning window can miss Wi-Fi power-save gaps. */
    static int floorMs(String platform, boolean bluetooth) {
        return !bluetooth && ("linux".equals(platform) || "windows".equals(platform)) ? 40 : 60;
    }
    static int adaptiveCushion(double jitterMs, double packetMs, double leadMs) { return adaptiveCushion(jitterMs, packetMs, leadMs, 40); }
    static int adaptiveCushion(double jitterMs, double packetMs, double leadMs, int floorMs) {
        return (int)Math.min(320, Math.max(Math.max(40, Math.min(320, floorMs)), Math.ceil(jitterMs + 2 * packetMs + leadMs)));
    }
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
