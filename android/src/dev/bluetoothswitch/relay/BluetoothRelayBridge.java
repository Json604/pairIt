package dev.bluetoothswitch.relay;

import java.io.Closeable;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.concurrent.atomic.AtomicBoolean;

/** Carries encrypted bytes between the platform TLS socket and a connected RFCOMM stream. */
final class BluetoothRelayBridge extends Socket {
    private final Closeable radio;
    private final AtomicBoolean closed = new AtomicBoolean();
    private volatile Socket peer;

    BluetoothRelayBridge(Closeable radio) { this.radio = radio; }

    void attach(InputStream radioInput, OutputStream radioOutput) throws IOException {
        InetAddress loopback = InetAddress.getLoopbackAddress();
        try (ServerSocket listener = new ServerSocket(0, 1, loopback)) {
            listener.setSoTimeout(2000);
            connect(new InetSocketAddress(loopback, listener.getLocalPort()), 2000);
            peer = listener.accept();
            if (!peer.getRemoteSocketAddress().equals(getLocalSocketAddress()) || closed.get())
                throw new IOException("Bluetooth bridge cancelled");
            setTcpNoDelay(true);
            peer.setTcpNoDelay(true);
            pump(peer.getInputStream(), radioOutput, false, "relay-bluetooth-send");
            pump(radioInput, peer.getOutputStream(), true, "relay-bluetooth-receive");
        } catch (IOException error) {
            closeQuietly(peer);
            throw error;
        }
    }

    private void pump(InputStream input, OutputStream output, boolean fromRadio, String name) {
        Thread worker = new Thread(() -> {
            try {
                byte[] buffer = new byte[8192];
                int count;
                while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
            } catch (IOException ignored) {
                // A remote disconnect can appear as either EOF or an IOException.
            }
            if (fromRadio) {
                // Let TLS consume bytes already delivered, particularly the final pairing reply.
                try { peer.shutdownOutput(); } catch (IOException ignored) { }
            } else closeQuietly(this);
        }, name);
        worker.setDaemon(true);
        worker.start();
    }

    @Override public void close() throws IOException {
        if (!closed.compareAndSet(false, true)) return;
        try { super.close(); }
        finally { closeQuietly(peer); closeQuietly(radio); }
    }

    private static void closeQuietly(Closeable resource) {
        if (resource != null) try { resource.close(); } catch (IOException ignored) { }
    }
}
