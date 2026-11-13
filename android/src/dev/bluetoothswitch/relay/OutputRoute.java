package dev.bluetoothswitch.relay;

import android.media.AudioDeviceInfo;
import android.media.AudioManager;
import android.media.AudioRouting;
import android.os.Build;
import java.util.Collections;
import java.util.List;

/** A preference is advisory. Confirm every actual output before unmuting. */
enum OutputRoute {
    BLUETOOTH("Bluetooth headphones"), SPEAKER("Phone speaker"), WIRED("Wired / USB audio");
    final String label;
    OutputRoute(String label) { this.label = label; }
    static OutputRoute from(String value) {
        try { return valueOf(value); } catch (IllegalArgumentException error) { return BLUETOOTH; }
    }
    boolean accepts(AudioDeviceInfo device) {
        if (device == null) return false;
        int type = device.getType();
        if (this == SPEAKER) return type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER;
        if (this == WIRED) return type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES || type == AudioDeviceInfo.TYPE_WIRED_HEADSET
                || type == AudioDeviceInfo.TYPE_USB_HEADSET || type == AudioDeviceInfo.TYPE_USB_DEVICE;
        return type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP || (Build.VERSION.SDK_INT >= 31
                && (type == AudioDeviceInfo.TYPE_BLE_HEADSET || type == AudioDeviceInfo.TYPE_BLE_SPEAKER));
    }
    AudioDeviceInfo find(AudioManager audio) { return find(audio, -1); }
    AudioDeviceInfo find(AudioManager audio, int selectedId) {
        try { for (AudioDeviceInfo device : audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) if (accepts(device) && (selectedId < 0 || device.getId() == selectedId)) return device; }
        catch (SecurityException ignored) { }
        return null;
    }
    static List<AudioDeviceInfo> actual(AudioRouting routing) {
        if (Build.VERSION.SDK_INT >= 36) return routing.getRoutedDevices();
        AudioDeviceInfo device = routing.getRoutedDevice();
        return device == null ? Collections.emptyList() : Collections.singletonList(device);
    }
    boolean confirmed(AudioRouting routing, int selectedId) {
        return confirmed(actual(routing), selectedId);
    }
    boolean confirmed(List<AudioDeviceInfo> routes, int selectedId) {
        if (routes.isEmpty()) return false;
        // Also prevent an unnoticed switch to a different device in the same category.
        for (AudioDeviceInfo device : routes) if (!accepts(device) || device.getId() != selectedId) return false;
        return true;
    }
}
