package dev.bluetoothswitch.relay;

public final class ExternalOutputRecoveryCheck {
    public static void main(String[] args) {
        ExternalOutputRecovery r = new ExternalOutputRecovery();
        if (r.ready(true, true)) throw new AssertionError("Unrelated attachment must not start playback");
        r.lost(true, true);
        if (!r.waiting() || r.ready(false, true) || r.ready(true, false)) throw new AssertionError("Wait for external output and permission");
        if (!r.ready(true, true)) throw new AssertionError("First or replacement headset can resume immediately");
        ExternalOutputRecovery restored = new ExternalOutputRecovery();
        restored.restore("saved-pin", "saved-pin", true);
        if (!restored.ready(true, true)) throw new AssertionError("Recovery survives service recreation");
        restored.restore("old-pin", "new-pin", true);
        if (restored.waiting()) throw new AssertionError("Never resume a different computer");
        restored.restore("saved-pin", "saved-pin", false);
        if (restored.waiting()) throw new AssertionError("Disabled recovery stays disabled after restart");
        restored.restore("", "", true);
        if (restored.waiting()) throw new AssertionError("No saved intent must stay idle");
        r.cancel(); if (r.ready(true, true)) throw new AssertionError("Manual choice cancels recovery");
        r.lost(false, true); if (r.waiting()) throw new AssertionError("Phone speaker is not an external loss");
        r.lost(true, false); if (r.waiting()) throw new AssertionError("Disabled auto reconnect must be respected");
        r.lost(true, true); r.cancel(); r.lost(false, true); if (r.waiting()) throw new AssertionError("No stale recovery");

        // Bluetooth wake filtering: media-audio profiles (A2DP, LE Audio) and LE Audio ACL only.
        if (!ExternalOutputRecovery.isBluetoothAudioBroadcast(ExternalOutputRecovery.ACTION_A2DP_STATE, ExternalOutputRecovery.PROFILE_CONNECTED, false))
            throw new AssertionError("A2DP connected must trigger wake");
        if (ExternalOutputRecovery.isBluetoothAudioBroadcast(ExternalOutputRecovery.ACTION_A2DP_STATE, 0, false))
            throw new AssertionError("A2DP disconnected must not trigger wake");
        if (!ExternalOutputRecovery.isBluetoothAudioBroadcast(ExternalOutputRecovery.ACTION_LE_AUDIO_STATE, ExternalOutputRecovery.PROFILE_CONNECTED, false))
            throw new AssertionError("LE Audio connected must trigger wake");
        if (ExternalOutputRecovery.isBluetoothAudioBroadcast(ExternalOutputRecovery.ACTION_LE_AUDIO_STATE, 1, false))
            throw new AssertionError("LE Audio connecting state must wait for connected");
        if (!ExternalOutputRecovery.isBluetoothAudioBroadcast(ExternalOutputRecovery.ACTION_ACL_CONNECTED, -1, true))
            throw new AssertionError("LE Audio UUID ACL connect must trigger wake");
        if (ExternalOutputRecovery.isBluetoothAudioBroadcast(ExternalOutputRecovery.ACTION_ACL_CONNECTED, -1, false))
            throw new AssertionError("Non-LE-Audio ACL connect (BLE tracker, watch, case ping) must not trigger wake");
        if (ExternalOutputRecovery.isBluetoothAudioBroadcast("android.bluetooth.headset.profile.action.CONNECTION_STATE_CHANGED", ExternalOutputRecovery.PROFILE_CONNECTED, false))
            throw new AssertionError("HFP-only headset profile (watch) must not trigger wake");
        if (ExternalOutputRecovery.isBluetoothAudioBroadcast("android.intent.action.BATTERY_OKAY", 2, false))
            throw new AssertionError("Unrelated broadcasts must never trigger wake");

        // LE Audio UUID helper
        if (!ExternalOutputRecovery.isLeAudioUuid(ExternalOutputRecovery.UUID_LE_AUDIO_ASCS)
                || !ExternalOutputRecovery.isLeAudioUuid(ExternalOutputRecovery.UUID_LE_AUDIO_PACS.toUpperCase())
                || !ExternalOutputRecovery.isLeAudioUuid(ExternalOutputRecovery.UUID_LE_AUDIO_TMAS))
            throw new AssertionError("Standard LE Audio UUIDs must match");
        if (ExternalOutputRecovery.isLeAudioUuid("0000111e-0000-1000-8000-00805f9b34fb") || ExternalOutputRecovery.isLeAudioUuid(null))
            throw new AssertionError("Non-LE-Audio UUIDs must not match");

        // Bluetooth wake eligibility: requires Auto-reconnect, matching saved pin, non-speaker, local network, and cooldown.
        if (!ExternalOutputRecovery.wakeAllowed(true, true, "pin-a", "pin-a", false, true, 20_000L, 0L))
            throw new AssertionError("Eligible background wake on local network must proceed");
        if (ExternalOutputRecovery.wakeAllowed(true, true, "pin-a", "pin-a", false, false, 20_000L, 0L))
            throw new AssertionError("Away from local Wi-Fi/LAN must block background wake");
        if (ExternalOutputRecovery.wakeAllowed(true, true, "pin-a", "pin-a", false, true, 25_000L, 20_000L))
            throw new AssertionError("Recent failed wake probe must respect cooldown");
        if (!ExternalOutputRecovery.wakeAllowed(true, true, "pin-a", "pin-a", false, true, 35_000L, 20_000L))
            throw new AssertionError("Expired cooldown must allow next Bluetooth wake");
        if (ExternalOutputRecovery.shouldWakeOnBluetooth(false, true, "pin-a", "pin-a", false))
            throw new AssertionError("Disabled auto-reconnect must block wake");
        if (ExternalOutputRecovery.shouldWakeOnBluetooth(true, false, "pin-a", "pin-a", false))
            throw new AssertionError("Unpaired state must block wake");
        if (ExternalOutputRecovery.shouldWakeOnBluetooth(true, true, "", "pin-a", false))
            throw new AssertionError("Explicitly stopped/paused session (empty pin) must block wake");
        if (ExternalOutputRecovery.shouldWakeOnBluetooth(true, true, "pin-old", "pin-new", false))
            throw new AssertionError("Different paired computer must block wake");
        if (ExternalOutputRecovery.shouldWakeOnBluetooth(true, true, "pin-a", "pin-a", true))
            throw new AssertionError("Phone speaker selection must block Bluetooth wake");

        System.out.println("PASS: external output loss, Bluetooth wake filtering, local-network & cooldown gating, speaker exclusion and manual cancellation");
    }
}
