package dev.bluetoothswitch.relay;

import android.Manifest;
import android.bluetooth.BluetoothClass;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothProfile;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;

/** System-protected Bluetooth audio events can wake a process evicted in the background. */
public final class ExternalOutputReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        if (intent == null) return;
        String action = intent.getAction();
        int profileState = intent.getIntExtra(BluetoothProfile.EXTRA_STATE, -1);
        boolean hasDeviceClass = false;
        boolean audioClass = false;
        if (BluetoothDevice.ACTION_ACL_CONNECTED.equals(action)) {
            BluetoothDevice device = Build.VERSION.SDK_INT >= 33
                    ? intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice.class)
                    : legacyDevice(intent);
            if (device != null && (Build.VERSION.SDK_INT < 31
                    || context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED)) {
                try {
                    BluetoothClass deviceClass = device.getBluetoothClass();
                    if (deviceClass != null) {
                        hasDeviceClass = true;
                        audioClass = deviceClass.hasService(BluetoothClass.Service.AUDIO)
                                || deviceClass.getMajorDeviceClass() == BluetoothClass.Device.Major.AUDIO_VIDEO;
                    }
                } catch (SecurityException ignored) { }
            }
        }
        if (!ExternalOutputRecovery.isBluetoothAudioBroadcast(action, profileState, hasDeviceClass, audioClass)) return;
        // A Bluetooth audio link is only a wake-up signal. The service still requires
        // Auto-reconnect, persisted listening intent, the same pairing, and an active external audio route.
        RelayService.onBluetoothAudioConnected(context);
    }

    @SuppressWarnings("deprecation")
    private static BluetoothDevice legacyDevice(Intent intent) {
        return intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
    }
}
