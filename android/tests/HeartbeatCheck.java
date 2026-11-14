package dev.bluetoothswitch.relay;
import java.io.*;
import java.nio.*;
public final class HeartbeatCheck {
    public static void main(String[] args) throws Exception {
        ByteBuffer bytes=ByteBuffer.allocate(96).order(ByteOrder.LITTLE_ENDIAN);
        bytes.putInt(0x31435342).putInt(129).putLong(System.nanoTime()).putLong(1);
        bytes.putInt(0x31415342).putInt(0).putInt(48000).putInt(0).putLong(0);
        bytes.putInt(0x32435342).putInt(274).putLong(0).putLong(0);
        bytes.putInt(0x33435342).putInt(0x10000|250).putLong(0).putLong(0);
        PcmInbox inbox=new PcmInbox();int[] heartbeats={0},commands={0},statuses={0};inbox.onDesktopRequest=value->{if(value!=274)throw new AssertionError();commands[0]++;};inbox.onControlStatus=value->statuses[0]++;inbox.onHeartbeat=()->heartbeats[0]++;
        int[] volume={-1};inbox.onComputerVolume=value->volume[0]=value;
        inbox.read(new ByteArrayInputStream(bytes.array()));
        if(volume[0]!=(0x10000|250))throw new AssertionError("Computer volume must reach the phone independently of PCM");
        if(heartbeats[0]!=2||inbox.queuedPackets()!=0||commands[0]!=1||statuses[0]!=1)throw new AssertionError("Control/idle heartbeats must keep a silent connection healthy without pretending audio played");
        PcmInbox malformed=new PcmInbox();malformed.onHeartbeat=()->heartbeats[0]++;
        malformed.read(new ByteArrayInputStream(new byte[24]));
        if(heartbeats[0]!=2)throw new AssertionError("Malformed packets must not refresh liveness");
        ByteBuffer rejected=ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN);
        rejected.putInt(0x31455342).putInt(1);
        PcmInbox full=new PcmInbox();full.read(new ByteArrayInputStream(rejected.array()));
        try { full.next(); throw new AssertionError("Group-full rejection lost"); }
        catch(PcmInbox.GroupFull expected) { }
        System.out.println("Real PCM parser: silent heartbeats stay connected; malformed traffic does not");
    }
}
