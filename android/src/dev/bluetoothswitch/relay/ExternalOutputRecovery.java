package dev.bluetoothswitch.relay;

/** Only an interrupted or active external-output session may auto-resume. */
final class ExternalOutputRecovery {
    static final String ACTION_ACL_CONNECTED = "android.bluetooth.device.action.ACL_CONNECTED";
    static final String ACTION_A2DP_STATE = "android.bluetooth.a2dp.profile.action.CONNECTION_STATE_CHANGED";
    static final String ACTION_LE_AUDIO_STATE = "android.bluetooth.action.LE_AUDIO_CONNECTION_STATE_CHANGED";
    static final int PROFILE_CONNECTED = 2;
    // Standard Bluetooth LE Audio service UUIDs (ASCS, PACS, TMAS).
    static final String UUID_LE_AUDIO_ASCS = "0000184e-0000-1000-8000-00805f9b34fb";
    static final String UUID_LE_AUDIO_PACS = "00001850-0000-1000-8000-00805f9b34fb";
    static final String UUID_LE_AUDIO_TMAS = "00001853-0000-1000-8000-00805f9b34fb";
    static final long WAKE_FAILURE_COOLDOWN_MS = 15_000L;
    static final long BLUETOOTH_WAKE_TIMEOUT_MS = 10_000L;
    static final long OUTPUT_WAIT_TIMEOUT_MS = 25_000L;
    static final long BACKGROUND_RECONNECT_TIMEOUT_MS = 90_000L;

    private volatile boolean waiting;
    void restore(String savedPin, String currentPin, boolean enabled) { waiting = enabled && !savedPin.isEmpty() && savedPin.equals(currentPin); }
    void lost(boolean external, boolean enabled) { waiting = external && enabled; }
    boolean waiting() { return waiting; }
    boolean ready(boolean externalReady, boolean permitted) { return waiting && externalReady && permitted; }
    void cancel() { waiting = false; }

    static boolean isLeAudioUuid(String uuid) {
        if (uuid == null) return false;
        return UUID_LE_AUDIO_ASCS.equalsIgnoreCase(uuid)
                || UUID_LE_AUDIO_PACS.equalsIgnoreCase(uuid)
                || UUID_LE_AUDIO_TMAS.equalsIgnoreCase(uuid);
    }

    /**
     * Classic Bluetooth media devices always emit A2DP STATE_CONNECTED when their media route
     * actually connects (avoiding false wakes on watches, BLE trackers, or earbud case-lid pings).
     * LE Audio devices emit LE_AUDIO_CONNECTION_STATE_CHANGED or ACL_CONNECTED with cached LE Audio UUIDs.
     */
    static boolean isBluetoothAudioBroadcast(String action, int profileState, boolean hasLeAudioUuid) {
        if (ACTION_A2DP_STATE.equals(action) || ACTION_LE_AUDIO_STATE.equals(action))
            return profileState == PROFILE_CONNECTED;
        if (ACTION_ACL_CONNECTED.equals(action))
            return hasLeAudioUuid;
        return false;
    }

    static boolean shouldWakeOnBluetooth(boolean autoReconnect, boolean paired, String savedPin, String currentPin, boolean speakerSelected) {
        return autoReconnect && paired && !speakerSelected && !savedPin.isEmpty() && savedPin.equals(currentPin);
    }

    static boolean wakeAllowed(boolean autoReconnect, boolean paired, String savedPin, String currentPin,
                               boolean speakerSelected, boolean hasLocalNetwork, long nowMs, long lastFailedWakeMs) {
        if (!shouldWakeOnBluetooth(autoReconnect, paired, savedPin, currentPin, speakerSelected)) return false;
        if (!hasLocalNetwork) return false;
        return lastFailedWakeMs == 0L || nowMs < lastFailedWakeMs || nowMs - lastFailedWakeMs >= WAKE_FAILURE_COOLDOWN_MS;
    }
}
