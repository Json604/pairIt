package dev.bluetoothswitch.relay;

import android.content.SharedPreferences;
import java.util.*;

/** Saved credentials stay in the same private preferences as the active pairing. */
final class PairingArchive {
    private final SharedPreferences prefs;
    PairingArchive(SharedPreferences prefs) { this.prefs = prefs; }
    private String key(String pin) { return "saved_computer:" + pin + ":"; }
    void save(PairingCode code, SharedPreferences.Editor edit) {
        Set<String> pins = new HashSet<>(prefs.getStringSet("saved_computers", Collections.emptySet()));
        pins.add(code.pin); String key = key(code.pin);
        edit.putStringSet("saved_computers", pins).putString(key+"host",code.host).putString(key+"token",code.token)
            .putString(key+"name",code.name).putString(key+"platform",code.platform);
    }
    PairingCode get(String pin) {
        if (!prefs.getStringSet("saved_computers",Collections.emptySet()).contains(pin)) return null;
        String key = key(pin);
        try { return PairingCode.stored(prefs.getString(key+"host",""),pin,prefs.getString(key+"token",""),prefs.getString(key+"name","Computer"),prefs.getString(key+"platform","")); }
        catch (IllegalArgumentException error) { return null; }
    }
    List<PairingCode> all() {
        List<PairingCode> result = new ArrayList<>();
        for (String pin : prefs.getStringSet("saved_computers",Collections.emptySet())) { PairingCode code=get(pin);if(code!=null)result.add(code); }
        result.sort(Comparator.comparing(c->c.name,String.CASE_INSENSITIVE_ORDER)); return result;
    }
    void remove(String pin, SharedPreferences.Editor edit) {
        Set<String> pins = new HashSet<>(prefs.getStringSet("saved_computers",Collections.emptySet()));pins.remove(pin);
        edit.putStringSet("saved_computers",pins);String key=key(pin);
        for(String field:new String[]{"host","token","name","platform"})edit.remove(key+field);
    }
}
