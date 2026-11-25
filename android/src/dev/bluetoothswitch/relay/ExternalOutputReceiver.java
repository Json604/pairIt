package dev.bluetoothswitch.relay;

import android.Manifest;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothProfile;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.ParcelUuid;

/** System-protected Bluetooth audio events can wake a stopped process on demand. */
public final class ExternalOutputReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        if (intent == null) return;
        String action = intent.getAction();
        int profileState = intent.getIntExtra(BluetoothProfile.EXTRA_STATE, -1);
        boolean hasLeAudioUuid = false;
        if (BluetoothDevice.ACTION_ACL_CONNECTED.equals(action)) {
            BluetoothDevice device = Build.VERSION.SDK_INT >= 33
                    ? intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice.class)
                    : legacyDevice(intent);
            if (device != null && (Build.VERSION.SDK_INT < 31
                    || context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED)) {
                try {
                    ParcelUuid[] uuids = device.getUuids();
                    if (uuids != null) {
                        for (ParcelUuid uuid : uuids) {
                            if (uuid != null && ExternalOutputRecovery.isLeAudioUuid(uuid.toString())) {
                                hasLeAudioUuid = true;
                                break;
                            }
                        }
                    }
                } catch (SecurityException ignored) { }
            }
        }
        if (!ExternalOutputRecovery.isBluetoothAudioBroadcast(action, profileState, hasLeAudioUuid)) return;
        // A Bluetooth media-audio connection is only a wake-up signal. The service still verifies
        // Auto-reconnect, local network, persisted intent, computer reachability and an active route.
        RelayService.onBluetoothAudioConnected(context);
    }

    @SuppressWarnings("deprecation")
    private static BluetoothDevice legacyDevice(Intent intent) {
        return intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
    }
}
