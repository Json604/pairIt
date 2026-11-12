package dev.bluetoothswitch.relay;

import android.media.AudioDeviceInfo;
import android.media.AudioTrack;
import android.os.Build;
import android.util.Log;

/** Apply the live-stream buffer policy after Android has selected the real output. */
final class PlaybackBuffer {
    // App scheduling headroom, separate from network jitter and Bluetooth delay.
    static final int TARGET_MS = 120;
    private int deviceId = -1, acceptedSize = -1, acceptedThreshold = -1;
    private long nextCheck;
    int adjustments;

    boolean configure(AudioTrack track, AudioDeviceInfo route, int rate) {
        long now = System.nanoTime();
        if (route.getId() == deviceId && now < nextCheck) return false;
        nextCheck = now + 250_000_000L;
        int size = track.getBufferSizeInFrames();
        int threshold = startThreshold(track);
        if (route.getId() == deviceId && size == acceptedSize && threshold == acceptedThreshold) return false;

        int requested = Math.max(1, rate * TARGET_MS / 1000);
        int result = track.setBufferSizeInFrames(requested);
        acceptedSize = track.getBufferSizeInFrames();
        if (Build.VERSION.SDK_INT >= 31)
            track.setStartThresholdInFrames(Math.min(requested, acceptedSize));
        acceptedThreshold = startThreshold(track);
        deviceId = route.getId();
        adjustments++;
        Log.i("AudioRelayLab", "BUFFER_POLICY route=" + deviceId + " old=" + size
                + " requested=" + requested + " result=" + result + " effective=" + acceptedSize
                + " startThreshold=" + acceptedThreshold + " capacity=" + track.getBufferCapacityInFrames());
        // Discard audio queued under the old route/size once, then refill consistently.
        return true;
    }

    static int startThreshold(AudioTrack track) {
        return Build.VERSION.SDK_INT >= 31 ? track.getStartThresholdInFrames() : -1;
    }
}
