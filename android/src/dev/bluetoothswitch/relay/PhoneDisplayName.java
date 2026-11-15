package dev.bluetoothswitch.relay;
import android.content.Context;
import android.provider.Settings;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
final class PhoneDisplayName {
    static String get(Context context) {
        String value = null;
        try { value = Settings.Global.getString(context.getContentResolver(), "device_name"); } catch(SecurityException ignored) { }
        if(value == null || value.trim().isEmpty()) value = android.os.Build.MODEL;
        value = value.replaceAll("[\\p{Cntrl}\\p{Cf}]", "").trim();
        return value.isEmpty() ? "Android phone" : value.substring(0,Math.min(64,value.length()));
    }
    static String encoded(Context context) { return Base64.getEncoder().encodeToString(get(context).getBytes(StandardCharsets.UTF_8)); }
}
