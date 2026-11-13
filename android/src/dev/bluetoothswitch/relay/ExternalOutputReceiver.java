package dev.bluetoothswitch.relay;

import android.bluetooth.BluetoothA2dp;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothHeadset;
import android.bluetooth.BluetoothProfile;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** System-protected Bluetooth events can wake a process that lost its audio callback. */
public final class ExternalOutputReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        if (intent == null) return;
        String action = intent.getAction();
        boolean connected = BluetoothDevice.ACTION_ACL_CONNECTED.equals(action)
                || ((BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED.equals(action)
                    || BluetoothHeadset.ACTION_CONNECTION_STATE_CHANGED.equals(action))
                    && intent.getIntExtra(BluetoothProfile.EXTRA_STATE, -1) == BluetoothProfile.STATE_CONNECTED);
        if (!connected) return;
        // A Bluetooth link is only a wake-up signal. The service still requires
        // persisted listening intent, the same pairing, and a real external audio route.
        RelayService.restoreOutputMonitoring(context);
    }
}
