package dev.bluetoothswitch.relay;

import android.content.Context;
import android.net.wifi.WifiManager;
import android.os.PowerManager;

final class PlaybackLocks {
    private final PowerManager.WakeLock cpu;
    private final WifiManager.WifiLock wifi;
    PlaybackLocks(Context context) {
        cpu = ((PowerManager)context.getSystemService(Context.POWER_SERVICE))
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "AudioRelay:playback");
        cpu.setReferenceCounted(false);
        wifi = ((WifiManager)context.getApplicationContext().getSystemService(Context.WIFI_SERVICE))
                .createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "AudioRelay:stream");
        wifi.setReferenceCounted(false);
    }
    void acquire(boolean network) {
        cpu.acquire(120000); // Renew while actually playing; never retain an unbounded CPU lock.
        if (network && !wifi.isHeld()) wifi.acquire();
        if (!network && wifi.isHeld()) wifi.release();
    }
    void release() {
        if (cpu.isHeld()) cpu.release();
        if (wifi.isHeld()) wifi.release();
    }
}
