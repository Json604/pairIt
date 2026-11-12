package dev.bluetoothswitch.relay;

/** A short fade-in at explicit discontinuities; not packet-loss concealment. */
final class PcmRamp {
    private int remaining, total;
    void restart(int rate) { remaining = total = Math.max(1, rate / 200); }
    void apply(byte[] pcm) {
        for (int frame = 0; frame < pcm.length / 4 && remaining > 0; frame++, remaining--) {
            double gain = (total - remaining) / (double) total;
            for (int channel = 0; channel < 2; channel++) {
                int offset = frame * 4 + channel * 2;
                short value = (short)((pcm[offset] & 255) | (pcm[offset + 1] << 8));
                short scaled = (short)(value * gain);
                pcm[offset] = (byte)scaled; pcm[offset + 1] = (byte)(scaled >> 8);
            }
        }
    }
}
