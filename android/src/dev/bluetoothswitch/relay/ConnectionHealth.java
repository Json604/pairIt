package dev.bluetoothswitch.relay;

final class ConnectionHealth {
    static boolean identityRejected(Throwable error) {
        for(int depth=0; error!=null && depth<16; depth++,error=error.getCause()) {
            if(error instanceof java.security.cert.CertificateException ||
               error instanceof javax.net.ssl.SSLPeerUnverifiedException)return true;
        }
        return false;
    }
    static boolean shouldReconnect(boolean enabled, boolean listening, boolean stopped) {
        return enabled && listening && !stopped;
    }
    static boolean expired(long now, long lastTraffic, boolean listening, boolean computerOutput) {
        return listening && !computerOutput && now >= lastTraffic && now - lastTraffic >= 15_000;
    }
}
