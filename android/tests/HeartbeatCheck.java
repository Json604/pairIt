package dev.bluetoothswitch.relay;
import java.io.*;
import java.nio.*;
public final class HeartbeatCheck {
    public static void main(String[] args) {
        ByteBuffer bytes=ByteBuffer.allocate(72).order(ByteOrder.LITTLE_ENDIAN);
        bytes.putInt(0x31435342).putInt(129).putLong(System.nanoTime()).putLong(1);
        bytes.putInt(0x31415342).putInt(0).putInt(48000).putInt(0).putLong(0);
        bytes.putInt(0x32435342).putInt(274).putLong(0).putLong(0);
        PcmInbox inbox=new PcmInbox();int[] heartbeats={0},commands={0},statuses={0};inbox.onDesktopRequest=value->{if(value!=274)throw new AssertionError();commands[0]++;};inbox.onControlStatus=value->statuses[0]++;inbox.onHeartbeat=()->heartbeats[0]++;
        inbox.read(new ByteArrayInputStream(bytes.array()));
        if(heartbeats[0]!=2||inbox.queuedPackets()!=0||commands[0]!=1||statuses[0]!=1)throw new AssertionError("Control/idle heartbeats must keep a silent connection healthy without pretending audio played");
        PcmInbox malformed=new PcmInbox();malformed.onHeartbeat=()->heartbeats[0]++;
        malformed.read(new ByteArrayInputStream(new byte[24]));
        if(heartbeats[0]!=2)throw new AssertionError("Malformed packets must not refresh liveness");
        System.out.println("Real PCM parser: silent heartbeats stay connected; malformed traffic does not");
    }
}
