package dev.bluetoothswitch.relay;

import java.util.Arrays;

public final class PcmGapCheck {
    private static PcmInbox.Packet packet(long sequence, long nanos) {
        byte[] pcm = new byte[480 * 4];
        Arrays.fill(pcm, (byte)0x20);
        return new PcmInbox.Packet(48000, 480, nanos, sequence, pcm);
    }

    public static void main(String[] args) {
        PcmInbox.Packet a = packet(0xffffffffL, 1000000000L);
        PcmInbox.Packet b = packet(1, 1020000000L);
        byte[] repaired = PcmGap.bridge(a, b);
        if (repaired.length != 960 * 4 || !Arrays.equals(b.pcm, Arrays.copyOfRange(repaired, 480 * 4, repaired.length)))
            throw new AssertionError("10 ms missing at sequence wrap must preserve source duration and real audio");
        if (PcmGap.bridge(a, packet(1, 1010000000L)).length != 480 * 4)
            throw new AssertionError("contiguous timestamps need zero padding");
        if (PcmGap.bridge(a, packet(2, 1040000000L)) != null || PcmGap.bridge(a, packet(1, 1000000001L)) != null
                || PcmGap.bridge(a, packet(5, 1020000000L)) != null || PcmGap.bridge(a, a) != null)
            throw new AssertionError("oversize and inconsistent gaps require resync");
    }
}
