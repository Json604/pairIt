package dev.bluetoothswitch.relay;

/** Only an interrupted or active external-output session may auto-resume. */
final class ExternalOutputRecovery {
    static final String ACTION_ACL_CONNECTED = "android.bluetooth.device.action.ACL_CONNECTED";
    static final String ACTION_A2DP_STATE = "android.bluetooth.a2dp.profile.action.CONNECTION_STATE_CHANGED";
    static final String ACTION_HEADSET_STATE = "android.bluetooth.headset.profile.action.CONNECTION_STATE_CHANGED";
    static final String ACTION_LE_AUDIO_STATE = "android.bluetooth.action.LE_AUDIO_CONNECTION_STATE_CHANGED";
    static final int PROFILE_CONNECTED = 2;

    private volatile boolean waiting;
    void restore(String savedPin,String currentPin,boolean enabled){waiting=enabled&&!savedPin.isEmpty()&&savedPin.equals(currentPin);}
    void lost(boolean external,boolean enabled){waiting=external&&enabled;}
    boolean waiting(){return waiting;}
    boolean ready(boolean externalReady,boolean permitted){return waiting&&externalReady&&permitted;}
    void cancel(){waiting=false;}

    static boolean isBluetoothAudioBroadcast(String action, int profileState, boolean hasDeviceClass, boolean audioClass) {
        if (ACTION_A2DP_STATE.equals(action) || ACTION_HEADSET_STATE.equals(action) || ACTION_LE_AUDIO_STATE.equals(action))
            return profileState == PROFILE_CONNECTED;
        if (ACTION_ACL_CONNECTED.equals(action))
            return !hasDeviceClass || audioClass;
        return false;
    }

    static boolean shouldWakeOnBluetooth(boolean autoReconnect, boolean paired, String savedPin, String currentPin, boolean speakerSelected) {
        return autoReconnect && paired && !speakerSelected && !savedPin.isEmpty() && savedPin.equals(currentPin);
    }
}
