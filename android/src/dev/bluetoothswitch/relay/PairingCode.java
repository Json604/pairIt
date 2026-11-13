package dev.bluetoothswitch.relay;

import android.util.Base64;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

/** Validated, transient pairing data. Never log or put this in saved UI state. */
final class PairingCode {
    final String host, pin, token, name, platform;

    private PairingCode(String host, String pin, String token, String name, String platform) {
        this.host = host; this.pin = pin; this.token = token; this.name = name; this.platform = platform;
    }

    static PairingCode approved(NearbyDevices.Device device,String token) {
        if(!RelaySettings.validHost(device.host)||!device.pin.matches("[a-f0-9]{64}")||!token.matches("[a-f0-9]{64}"))throw new IllegalArgumentException("Invalid pairing response");
        return new PairingCode(device.host,device.pin,token,device.name,device.platform);
    }
    static PairingCode saved(RelaySettings settings,String host) {
        if(!settings.paired()||!RelaySettings.validHost(host))throw new IllegalArgumentException("Invalid saved pairing");
        return new PairingCode(host,settings.pin(),settings.token(),settings.computerName(),settings.platform());
    }

    String invitationCode() throws Exception {
        JSONObject json=new JSONObject();json.put("host",host);json.put("pin",pin);json.put("token",token);json.put("name",name);json.put("platform",platform);
        return "audiorelay://pair/"+Base64.encodeToString(json.toString().getBytes(StandardCharsets.UTF_8),Base64.URL_SAFE|Base64.NO_WRAP);
    }

    static PairingCode parse(String code) throws Exception {
        if (code == null || code.length() > 4096) throw new IllegalArgumentException("Invalid pairing code");
        String encoded = code.trim().replaceFirst("^audiorelay://pair/", "");
        JSONObject json = new JSONObject(new String(Base64.decode(encoded, Base64.URL_SAFE | Base64.NO_WRAP), StandardCharsets.UTF_8));
        String host = json.getString("host"), pin = json.getString("pin"), token = json.getString("token");
        if (!RelaySettings.validHost(host) || !pin.matches("[a-f0-9]{64}") || !token.matches("[a-f0-9]{64}"))
            throw new IllegalArgumentException("Invalid pairing code");
        String name = json.optString("name", "Computer").replaceAll("[\\p{Cntrl}]", "").trim();
        if (name.isEmpty()) name = "Computer";
        String platform = json.optString("platform", "");
        if (!platform.equals("macos") && !platform.equals("windows") && !platform.equals("linux")) platform = "";
        return new PairingCode(host, pin, token, name.substring(0, Math.min(64, name.length())), platform);
    }
}
