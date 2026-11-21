package dev.bluetoothswitch.relay;

/** Bridge small sender gaps without changing the playout clock. */
final class PcmGap {
    static byte[] bridge(PcmInbox.Packet previous, PcmInbox.Packet current) {
        long missingPackets = (current.sequence - previous.sequence - 1) & 0xffffffffL;
        if (missingPackets < 1 || missingPackets > 4 || previous.rate != current.rate) return null;
        long elapsed = current.capturedAt - previous.capturedAt;
        long missing = Math.round(elapsed * (current.rate / 1e9)) - previous.frames;
        if (missing < 0 || missing > current.rate / 50) return null;
        if (missing == 0) return current.pcm;

        int frames = (int)missing;
        byte[] pcm = new byte[frames * 4 + current.pcm.length];
        System.arraycopy(current.pcm, 0, pcm, frames * 4, current.pcm.length);
        // Join the two endpoints with short ramps. Longer holes have silence in the middle.
        int fade = Math.min(current.rate / 200, (frames + 1) / 2);
        for (int channel = 0; channel < 2; channel++) {
            int tail = sample(previous.pcm, previous.pcm.length - 4 + channel * 2);
            int head = sample(current.pcm, channel * 2);
            for (int i = 0; i < frames; i++) {
                int value = (tail * Math.max(0, fade - i) + head * Math.max(0, fade - (frames - 1 - i))) / (fade + 1);
                int offset = i * 4 + channel * 2;
                pcm[offset] = (byte)value;
                pcm[offset + 1] = (byte)(value >> 8);
            }
        }
        return pcm;
    }

    private static short sample(byte[] pcm, int offset) {
        return (short)((pcm[offset] & 255) | (pcm[offset + 1] << 8));
    }
}
