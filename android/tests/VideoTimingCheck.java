package dev.bluetoothswitch.relay;

import android.media.AudioTrack;
import android.os.SystemClock;

public final class VideoTimingCheck {
    private static Integer sample(VideoTiming timing, PcmInbox inbox, AudioTrack track) {
        SystemClock.now += 501;
        long capture = System.nanoTime() - 700_000_000L;
        PcmInbox.Packet packet = new PcmInbox.Packet(48000, 480, capture, 1, new byte[1920]);
        return timing.observe(track, inbox, packet, track.frame + 481, 0);
    }

    public static void main(String[] args) {
        VideoTiming timing = new VideoTiming();
        PcmInbox inbox = new PcmInbox();
        inbox.clockSamples = 3;
        AudioTrack track = new AudioTrack();
        SystemClock.now = 3000;
        for (int i = 0; i < 3; i++) sample(timing, inbox, track);
        timing.restartSampling(true);
        for (int i = 0; i < 6; i++)
            if (sample(timing, inbox, track) != null) throw new AssertionError("Mixed epochs");
        if (sample(timing, inbox, track) == null) throw new AssertionError("Missing calibration");
        for (int recovery = 0; recovery < 4; recovery++) {
            timing.restartSampling(true);
            for (int i = 0; i < 8; i++)
                if (sample(timing, inbox, track) != null) throw new AssertionError("Repeated calibration");
        }
        timing.restartSampling(false);
        for (int i = 0; i < 6; i++) sample(timing, inbox, track);
        if (sample(timing, inbox, track) == null) throw new AssertionError("New route must calibrate");
    }
}
