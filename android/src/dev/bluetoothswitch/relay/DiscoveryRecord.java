package dev.bluetoothswitch.relay;

import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.Map;

/** Strict boundary for unauthenticated multicast metadata. */
final class DiscoveryRecord {
    final String name, platform, pin;
    private DiscoveryRecord(String name,String platform,String pin){this.name=name;this.platform=platform;this.pin=pin;}
    static DiscoveryRecord parse(Map<String,byte[]> attributes,boolean phones){
        if(attributes==null||attributes.size()>12)return null;
        String role=value(attributes,"role"),platform=value(attributes,"platform"),name=value(attributes,"name"),pin=value(attributes,"pin");
        if(!"1".equals(value(attributes,"v"))||!role.equals(phones?"phone":"computer"))return null;
        if(!(phones?platform.matches("android|ios"):platform.matches("macos|windows|linux")))return null;
        if(name.isEmpty()||name.length()>64||name.codePoints().anyMatch(c->Character.isISOControl(c)||Character.getType(c)==Character.FORMAT))return null;
        if(!phones&&!pin.matches("[a-f0-9]{64}"))return null;
        return new DiscoveryRecord(name,platform,phones?"":pin);
    }
    private static String value(Map<String,byte[]> attributes,String key){
        byte[] value=attributes.get(key);if(value==null||value.length>256)return "";
        try{return StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(value)).toString().trim();}catch(Exception invalid){return "";}
    }
}
