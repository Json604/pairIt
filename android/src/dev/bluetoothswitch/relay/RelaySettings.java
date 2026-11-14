package dev.bluetoothswitch.relay;

import android.content.Context;
import android.content.SharedPreferences;
import java.util.UUID;

final class RelaySettings {
    private final SharedPreferences prefs;
    RelaySettings(Context context) { prefs = context.getSharedPreferences("relay", Context.MODE_PRIVATE); }
    boolean soundFeedback() { return prefs.getBoolean("sound_feedback",true); }
    void soundFeedback(boolean value) { prefs.edit().putBoolean("sound_feedback",value).apply(); }
    boolean autoReconnect() { return prefs.getBoolean("auto_reconnect", true); }
    void autoReconnect(boolean value) { prefs.edit().putBoolean("auto_reconnect",value).apply(); if(!value)outputRecovery(false); }
    String outputRecoveryPin() { return prefs.getString("output_recovery_pin", ""); }
    void outputRecovery(boolean waiting) {
        // Persist before returning from an output-loss/cancellation callback.
        prefs.edit().putString("output_recovery_pin", waiting ? pin() : "").commit();
    }
    boolean reducedMotion() { return !android.animation.ValueAnimator.areAnimatorsEnabled(); }
    String host() { return prefs.getString("host", ""); }
    String pin() { return prefs.getString("pin", ""); }
    String token() { return prefs.getString("token", ""); }
    // Both Wi-Fi and USB networking use the same pinned connection. Old ADB mode is retired.
    boolean wifi() { return true; }
    String overrideHost() { return prefs.getString("host_override", ""); }
    void host(String host) { prefs.edit().putString("host_override", host.trim()).apply(); }
    private static final class Candidate {final String pin,host;Candidate(String pin,String host){this.pin=pin;this.host=host;}}
    private static volatile Candidate candidate;
    void discovered(String host,String pin){if(pin.equals(pin())&&validHost(host))candidate=new Candidate(pin,host);}
    String connectionHost(String discovered) {
        if (!overrideHost().isEmpty()) return overrideHost();
        Candidate savedCandidate=candidate;
        return discovered == null || discovered.isEmpty() ? (savedCandidate!=null&&savedCandidate.pin.equals(pin())?savedCandidate.host:host()) : discovered;
    }
    String computerName() { return prefs.getString("computer_name", "Computer"); }
    String platform() { return prefs.getString("computer_platform", ""); }
    synchronized String installationId() {
        String id = prefs.getString("installation_id", "");
        if (!id.matches("[a-f0-9]{32}")) {
            id = UUID.randomUUID().toString().replace("-", "");
            prefs.edit().putString("installation_id", id).apply();
        }
        return id;
    }
    android.media.AudioDeviceInfo connectionOutput(android.media.AudioManager audio, boolean explicit) {
        boolean automatic = explicit && !prefs.getBoolean("output_manually_selected", false);
        return OutputRoute.connection(audio, automatic ? OutputRoute.WIRED : output(), automatic ? -1 : outputDeviceId(), explicit);
    }
    void manuallySelectOutput(OutputRoute route, int deviceId) {
        prefs.edit().putBoolean("output_manually_selected", true).apply();
        output(route, deviceId);
    }
    OutputRoute output() { return OutputRoute.from(prefs.getString("output", "BLUETOOTH")); }
    void output(OutputRoute route) { prefs.edit().putString("output", route.name()).remove("output_device_id").apply(); }
    int outputDeviceId() { return prefs.getInt("output_device_id", -1); }
    void output(OutputRoute route, int deviceId) { prefs.edit().putString("output",route.name()).putInt("output_device_id",deviceId).apply(); }
    boolean interactive() { return false; } // The two-feature app uses the proven Reliable path.
    void interactive(boolean value) { prefs.edit().putBoolean("interactive", value).apply(); }
    String timingRoute(String actualRoute, boolean interactive) {
        // Preserve the confirmed Bluetooth/Reliable key; isolate every new mode/transport.
        String key = actualRoute + (interactive ? ":interactive" : "");
        return overrideHost().isEmpty() ? key : key + ":manual:" + overrideHost();
    }
    boolean paired() { return pin().length() == 64 && token().length() == 64; }
    String controlsSource() { return prefs.getString("controls_source", ""); }
    void controlsSource(String value) { prefs.edit().putString("controls_source", value).apply(); }
    boolean askedNotifications() { return prefs.getBoolean("asked_controls_notifications", false); }
    void askedNotifications(boolean value) { prefs.edit().putBoolean("asked_controls_notifications", value).apply(); }
    private String route(String route, boolean wifi) { return pin() + ":" + route + ":" + wifi; }
    int estimate(String route, boolean wifi) { return prefs.getInt("estimate:" + route(route, wifi), -1); }
    int correction(String route, boolean wifi) { return prefs.getInt("correction:" + route(route, wifi), 0); }
    int compensation(String route, boolean wifi) {
        int estimate = estimate(route, wifi);
        return estimate < 0 ? -1 : Math.max(0, Math.min(2000, estimate + correction(route, wifi)));
    }
    void estimate(String route, boolean wifi, int value) {
        prefs.edit().putInt("estimate:" + route(route, wifi), value).apply();
    }
    void correction(String route, boolean wifi, int value) {
        prefs.edit().putInt("correction:" + route(route, wifi), Math.max(-500, Math.min(500, value))).apply();
    }
    static String profileKey(String pin, String override, String route, boolean interactive) {
        return pin + ":" + route + (interactive ? ":interactive" : "") + (override.isEmpty() ? "" : ":manual:" + override) + ":true";
    }
    int profileEstimate(String key) { return key.isEmpty() ? -1 : prefs.getInt("estimate:" + key, -1); }
    int profileCorrection(String key) { return prefs.getInt("correction:" + key, 0); }
    int profileCompensation(String key) {
        int estimate = profileEstimate(key);
        return estimate < 0 ? -1 : Math.max(0, Math.min(2000, estimate + profileCorrection(key)));
    }
    void profileEstimate(String key, int value) { if (!key.isEmpty()) prefs.edit().putInt("estimate:" + key, value).apply(); }
    void profileCorrection(String key, int value) {
        if (!key.isEmpty()) prefs.edit().putInt("correction:" + key, Math.max(-500, Math.min(500, value))).apply();
    }
    void pair(String code) throws Exception {
        pair(PairingCode.parse(code));
    }
    void pair(PairingCode code) {
        prefs.edit().putString("host", code.host).putString("pin", code.pin).putString("token", code.token)
                .putString("computer_name", code.name)
                .remove("output_recovery_pin").putString("computer_platform", code.platform).remove("host_override").putBoolean("wifi", true).apply();
    }
    static boolean validHost(String host) {
        if (host == null || host.isEmpty() || host.length() > 253) return false;
        if (host.contains(":")) return host.chars().filter(c -> c == ':').count() >= 2
                && host.matches("[a-fA-F0-9:]+(%[a-zA-Z0-9_.-]+)?");
        return host.matches("[a-zA-Z0-9._-]+");
    }
    void forget() { String id = installationId(); prefs.edit().clear().putString("installation_id", id).apply(); }
}
