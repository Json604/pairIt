package dev.bluetoothswitch.relay;

import java.io.DataInputStream;
import java.io.IOException;

/** Decode a packet-independent IMA ADPCM block into interleaved signed little-endian PCM. */
final class ImaStereo {
    static final int MAGIC = 0x314D4441;
    private static final int[] INDEX_CHANGE = {-1, -1, -1, -1, 2, 4, 6, 8};
    private static final int[] STEPS = {
        7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,
        88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,
        598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,
        2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,
        11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767
    };

    static byte[] read(DataInputStream input, int frames) throws IOException {
        byte[] encoded = new byte[6 + frames - 1];
        input.readFully(encoded);
        if ((encoded[4] & 255) >= STEPS.length || (encoded[5] & 255) >= STEPS.length)
            throw new IOException("Invalid IMA step index");
        byte[] pcm = new byte[frames * 4];
        System.arraycopy(encoded, 0, pcm, 0, 4);
        for (int channel = 0; channel < 2; channel++) {
            int offset = channel * 2;
            int predictor = (short)((pcm[offset] & 255) | pcm[offset + 1] << 8);
            int index = encoded[4 + channel];
            for (int frame = 1; frame < frames; frame++) {
                int code = (encoded[5 + frame] >> (channel * 4)) & 15;
                int step = STEPS[index];
                int delta = step >> 3;
                if ((code & 1) != 0) delta += step >> 2;
                if ((code & 2) != 0) delta += step >> 1;
                if ((code & 4) != 0) delta += step;
                predictor = Math.max(-32768, Math.min(32767, predictor + ((code & 8) == 0 ? delta : -delta)));
                index = Math.max(0, Math.min(STEPS.length - 1, index + INDEX_CHANGE[code & 7]));
                offset += 4;
                pcm[offset] = (byte)predictor;
                pcm[offset + 1] = (byte)(predictor >> 8);
            }
        }
        return pcm;
    }
}
