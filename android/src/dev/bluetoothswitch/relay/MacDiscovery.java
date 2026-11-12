package dev.bluetoothswitch.relay;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;

/** Discovery locates a candidate only. TLS pinning still authenticates the Mac. */
final class MacDiscovery {
    private final NsdManager manager;
    private NsdManager.DiscoveryListener listener;
    volatile String host;
    MacDiscovery(Context context) { manager = context.getSystemService(NsdManager.class); }
    void start(String pin) {
        stop();
        if (pin.length() != 64) return;
        listener = new NsdManager.DiscoveryListener() {
            public void onDiscoveryStarted(String type) { }
            public void onDiscoveryStopped(String type) { }
            public void onStartDiscoveryFailed(String type, int error) { }
            public void onStopDiscoveryFailed(String type, int error) { }
            public void onServiceLost(NsdServiceInfo info) { host = null; }
            public void onServiceFound(NsdServiceInfo info) {
                if (!info.getServiceName().startsWith("AudioRelay-" + pin.substring(0, 8))) return;
                manager.resolveService(info, new NsdManager.ResolveListener() {
                    public void onResolveFailed(NsdServiceInfo service, int error) { }
                    public void onServiceResolved(NsdServiceInfo service) {
                        if (service.getHost() != null) host = service.getHost().getHostAddress();
                    }
                });
            }
        };
        try { manager.discoverServices("_audiorelay._tcp.", NsdManager.PROTOCOL_DNS_SD, listener); }
        catch (RuntimeException ignored) { listener = null; }
    }
    void stop() {
        if (listener != null) try { manager.stopServiceDiscovery(listener); } catch (RuntimeException ignored) { }
        listener = null; host = null;
    }
}
