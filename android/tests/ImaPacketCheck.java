package dev.bluetoothswitch.relay;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

public final class ImaPacketCheck {
    private static final int IMA = 0x314D4441;

    private static byte[] packet(int magic, int rate, int frames, long capture, byte... payload) {
        return ByteBuffer.allocate(24 + payload.length).order(ByteOrder.LITTLE_ENDIAN)
                .putInt(magic).putInt(23).putInt(rate).putInt(frames).putLong(capture).put(payload).array();
    }

    private static void rejects(boolean negotiated, byte[] wire) throws Exception {
        PcmInbox inbox = new PcmInbox(negotiated);
        inbox.read(new ByteArrayInputStream(wire));
        try { inbox.next(); throw new AssertionError("invalid compressed frame accepted"); }
        catch (IOException expected) { }
    }

    public static void main(String[] args) throws Exception {
        byte[] wire = packet(IMA, 44100, 4, 700, (byte)0xe8,(byte)3,(byte)0x18,(byte)0xfc,
                (byte)0,(byte)0,(byte)0xf7,(byte)0x80,(byte)0x34);
        byte[] two = new byte[wire.length * 2];
        System.arraycopy(wire, 0, two, 0, wire.length);
        System.arraycopy(wire, 0, two, wire.length, wire.length);
        PcmInbox inbox = new PcmInbox(true);
        inbox.read(new ByteArrayInputStream(two));
        for (int i = 0; i < 2; i++) {
            PcmInbox.Packet next = inbox.next();
            if (next.rate != 44100 || next.frames != 4 || next.capturedAt != 700 || next.sequence != 23)
                throw new AssertionError("timing metadata changed");
            ByteBuffer pcm = ByteBuffer.wrap(next.pcm).order(ByteOrder.LITTLE_ENDIAN);
            for (int sample : new int[]{1000,-1000,1011,-1011,1013,-1013,1028,-1002})
                if (pcm.getShort() != sample) throw new AssertionError("decoded samples");
        }
        // Mac encoder interoperability vector, including nonzero initial step indices.
        PcmInbox mac = new PcmInbox(true);
        mac.read(new ByteArrayInputStream(packet(IMA, 48000, 5, 800,
                (byte)0xe8,(byte)3,(byte)0x18,(byte)0xfc,(byte)0x34,(byte)0x2d,
                (byte)0x3b,(byte)0x72,(byte)0x7f,(byte)0xf7)));
        ByteBuffer samples = ByteBuffer.wrap(mac.next().pcm).order(ByteOrder.LITTLE_ENDIAN);
        for (int expected : new int[]{1000,-1000,73,-524,674,401,-968,2388,2552,-1872})
            if (samples.getShort() != expected) throw new AssertionError("Mac encoder vector");
        for (int pos : new int[]{28, 29}) {
            byte[] invalidIndex = wire.clone();
            invalidIndex[pos] = (byte)89;
            rejects(true, invalidIndex);
        }
        rejects(false, wire);
        rejects(true, packet(IMA, 48000, 0, 0));
        rejects(true, packet(IMA, 48000, 8193, 12));
        rejects(true, packet(IMA, 96000, 1, 12));
        rejects(true, packet(IMA, 48000, 1, -1));
        rejects(true, java.util.Arrays.copyOf(wire, wire.length - 1));
        System.out.println("PASS: IMA stereo decoding, packet independence, bounded headers, capability and truncation");
    }
}
