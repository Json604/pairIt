package dev.bluetoothswitch.relay;
import android.media.AudioDeviceInfo;
import java.util.List;
public final class OutputRouteCheck {
 public static void main(String[] args) {
  AudioDeviceInfo speaker=new AudioDeviceInfo(1,2), wired=new AudioDeviceInfo(2,3), bluetooth=new AudioDeviceInfo(3,8);
  check(OutputRoute.connection(List.of(speaker,bluetooth),OutputRoute.WIRED,-1,true)==bluetooth,"Automatic selection uses headset even after previous speaker session");
  check(OutputRoute.connection(List.of(speaker),OutputRoute.BLUETOOTH,99,true)==speaker,"Fresh install connects on speaker");
  check(OutputRoute.connection(List.of(speaker,wired),OutputRoute.BLUETOOTH,99,true)==wired,"Unavailable Bluetooth uses connected wired output");
  check(OutputRoute.connection(List.of(speaker,bluetooth),OutputRoute.BLUETOOTH,99,true)==bluetooth,"Reconnected headset gets new device ID");
  check(OutputRoute.connection(List.of(speaker,bluetooth),OutputRoute.SPEAKER,1,true)==speaker,"Available explicit speaker choice retained");
  check(OutputRoute.connection(List.of(speaker),OutputRoute.BLUETOOTH,3,false)==null,"Background reconnect cannot fall through to speaker");
  check(OutputRoute.connection(List.of(speaker,bluetooth),OutputRoute.BLUETOOTH,99,false)==null,"Background reconnect cannot change device ID");
  check(OutputRoute.connection(List.of(),OutputRoute.BLUETOOTH,-1,true)==null,"No output stays unavailable");
  check(!OutputRoute.BLUETOOTH.confirmed(List.of(speaker),3),"Actual speaker cannot confirm headset route");
  System.out.println("PASS: explicit connection output selection and background route protection");
 }
 static void check(boolean ok,String label){if(!ok)throw new AssertionError(label);}
}
