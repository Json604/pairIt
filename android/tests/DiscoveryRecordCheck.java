package dev.bluetoothswitch.relay;
import java.util.*;
import java.nio.charset.StandardCharsets;
public class DiscoveryRecordCheck {
    static void require(boolean valid){if(!valid)throw new AssertionError("Discovery role boundary failed");}
    static void put(Map<String,byte[]> a,String k,String v){a.put(k,v.getBytes(StandardCharsets.UTF_8));}
    public static void main(String[] args){
        Map<String,byte[]> a=new HashMap<>();put(a,"v","1");put(a,"role","computer");put(a,"platform","linux");put(a,"name","Desk");put(a,"pin",String.join("",Collections.nCopies(64,"a")));
        require(DiscoveryRecord.parse(a,false)!=null);require(DiscoveryRecord.parse(a,true)==null);
        put(a,"role","phone");put(a,"platform","android");require(DiscoveryRecord.parse(a,false)==null);require(DiscoveryRecord.parse(a,true)!=null);require(DiscoveryRecord.parse(a,true).pin.isEmpty());
        put(a,"name","Bad\u202Ename");require(DiscoveryRecord.parse(a,true)==null);
        a.put("name",new byte[]{(byte)0xC3,(byte)0x28});require(DiscoveryRecord.parse(a,true)==null);
        put(a,"name","Phone");put(a,"v","2");require(DiscoveryRecord.parse(a,true)==null);
        put(a,"v","1");put(a,"role","computer");put(a,"platform","macos");put(a,"pin","wrong");require(DiscoveryRecord.parse(a,false)==null);
        System.out.println("Discovery metadata role, version, pin and text checks passed");
    }
}
