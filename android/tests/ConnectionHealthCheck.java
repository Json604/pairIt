package dev.bluetoothswitch.relay;
public final class ConnectionHealthCheck {
    public static void main(String[] args) {
        if(ConnectionHealth.expired(15999,1000,true,false))throw new AssertionError("Retry window");
        if(!ConnectionHealth.expired(16000,1000,true,false))throw new AssertionError("Bounded timeout");
        if(ConnectionHealth.expired(16000,1000,false,false))throw new AssertionError("Manual pause");
        if(ConnectionHealth.expired(16000,1000,true,true))throw new AssertionError("Computer output");
        if(ConnectionHealth.expired(16000,15000,true,false))throw new AssertionError("Fresh audio resets timeout");
        // A long Wi-Fi outage ends the socket, not the user's auto-reconnect intent.
        if(!ConnectionHealth.expired(61000,1000,true,false) || !ConnectionHealth.shouldReconnect(true,true,false))
            throw new AssertionError("Network outage beyond watchdog must remain recoverable");
        if(ConnectionHealth.shouldReconnect(true,false,false))throw new AssertionError("Manual pause must stay paused");
        if(ConnectionHealth.shouldReconnect(true,true,true))throw new AssertionError("Disconnect must never auto-restart");
        if(ConnectionHealth.shouldReconnect(false,true,false))throw new AssertionError("Disabled auto-reconnect must be respected");
        var interrupted = new javax.net.ssl.SSLHandshakeException("Connection closed");
        if(ConnectionHealth.identityRejected(interrupted))throw new AssertionError("Handshake network loss must retry");
        interrupted.initCause(new java.security.cert.CertificateException("Pin mismatch"));
        if(!ConnectionHealth.identityRejected(interrupted))throw new AssertionError("Rejected certificate must stop");
        System.out.println("Connection timeout, fresh audio and intentional pause/output checks passed");
    }
}
