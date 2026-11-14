package dev.bluetoothswitch.relay;
import java.io.*;
import java.nio.*;
public final class PresentationWireCheck {
 static byte[] frame(int target,int listeners,int capable){return ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN).putInt(0x34435342).putInt(target).putInt(listeners).putInt(capable).array();}
 public static void main(String[] args)throws Exception {
  PcmInbox inbox=new PcmInbox();inbox.read(new ByteArrayInputStream(frame(510,2,2)));
  if(inbox.presentationTargetMs!=510||inbox.presentationListeners!=2||inbox.presentationCapable!=2)throw new AssertionError("valid presentation frame");
  for(byte[] invalid:new byte[][]{frame(2001,2,2),frame(-1,2,2),frame(500,5,2),frame(500,1,2)}) {
   PcmInbox rejected=new PcmInbox();rejected.read(new ByteArrayInputStream(invalid));
   try{rejected.next();throw new AssertionError("invalid frame accepted");}catch(IOException error){if(!error.getMessage().startsWith("Invalid presentation"))throw error;}
  }
  inbox=new PcmInbox();inbox.read(new ByteArrayInputStream(frame(0,2,1)));
  if(inbox.presentationTargetMs!=0||inbox.presentationCapable!=1)throw new AssertionError("legacy fallback");
  PcmInbox clockInbox = new PcmInbox();
  long sent = System.nanoTime();
  byte[] reply = ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN).putInt(0x31435342).putInt(1).putLong(sent).putLong(sent).array();
  clockInbox.read(new ByteArrayInputStream(reply));
  PcmInbox.Packet packet = new PcmInbox.Packet(48000,480,1000,1,new byte[1920]);
  long deadline = packet.capturedAt + clockInbox.clockOffset() + 320_000_000L;
  PlayoutTiming late = new PlayoutTiming(320, () -> deadline + 20_000_000L);
  if(late.start(clockInbox,packet,true,()->true)!=PlayoutTiming.TOO_LATE)throw new AssertionError("shared startup must reject audible lateness");
  PlayoutTiming solo = new PlayoutTiming(320, () -> deadline + 20_000_000L);
  if(solo.start(clockInbox,packet,false,()->true)!=PlayoutTiming.READY)throw new AssertionError("solo tolerance unchanged");
  if(solo.start(clockInbox,packet,false,()->false)!=PlayoutTiming.CANCELLED)throw new AssertionError("paused startup stays cancelled");
  System.out.println("PASS: bounded presentation frame parser and mixed-version status");
 }
}
