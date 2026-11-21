package dev.bluetoothswitch.relay;

import java.io.BufferedReader;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.net.InetAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.util.concurrent.FutureTask;
import javax.net.ssl.*;

public final class BluetoothRelayTlsCheck {
    public static void main(String[] args) throws Exception {
        KeyStore store = KeyStore.getInstance("PKCS12");
        char[] password = "fixture".toCharArray();
        try (FileInputStream input = new FileInputStream(args[0])) { store.load(input, password); }
        KeyManagerFactory keys = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        keys.init(store, password);
        SSLContext context = SSLContext.getInstance("TLS");
        context.init(keys.getKeyManagers(), null, null);
        StringBuilder pin = new StringBuilder();
        for (byte value : MessageDigest.getInstance("SHA-256").digest(store.getCertificate("test").getEncoded()))
            pin.append(String.format("%02x", value & 255));

        try (SSLServerSocket mac = (SSLServerSocket)context.getServerSocketFactory()
                .createServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
            System.setProperty("radio.port", Integer.toString(mac.getLocalPort()));
            String credential = "a".repeat(64);
            for (boolean matching : new boolean[]{true, false, true}) {
                FutureTask<Void> server = new FutureTask<>(() -> {
                    try (SSLSocket socket = (SSLSocket)mac.accept()) {
                        socket.setSoTimeout(3000);
                        try {
                            String line = new BufferedReader(new InputStreamReader(socket.getInputStream(),
                                    StandardCharsets.US_ASCII)).readLine();
                            if (!matching || !credential.equals(line)) throw new AssertionError("unexpected credentials");
                            socket.getOutputStream().write("OK PAIR1\n".getBytes(StandardCharsets.US_ASCII));
                            socket.getOutputStream().flush();
                        } catch (IOException aborted) { if (matching) throw aborted; }
                    }
                    return null;
                });
                new Thread(server).start();
                try (Socket client = RelayConnection.openBluetoothPinned("00:11:22:33:44:55",
                        matching ? pin.toString() : "0".repeat(64), credential, raw -> {})) {
                    if (!matching || !"OK PAIR1".equals(RelayConnection.readLine(client, 64, 2000)))
                        throw new AssertionError("invalid preflight");
                } catch (SSLHandshakeException rejected) { if (matching) throw rejected; }
                server.get();
            }
        }
        System.setProperty("radio.stall", "true");
        java.util.concurrent.CompletableFuture<Socket> pending = new java.util.concurrent.CompletableFuture<>();
        FutureTask<Void> dial = new FutureTask<>(() -> {
            try (Socket ignored = RelayConnection.openBluetoothPinned("00:11:22:33:44:55",
                    pin.toString(), "STATUS1", pending::complete)) {
                throw new AssertionError("cancelled connection succeeded");
            } catch (IOException expected) { return null; }
        });
        new Thread(dial).start();
        pending.get(2, java.util.concurrent.TimeUnit.SECONDS).close();
        dial.get(2, java.util.concurrent.TimeUnit.SECONDS);
        System.out.println("PASS: RFCOMM adapter pinned TLS, token, remote close, wrong pin and successive sessions and pending dial cancellation");
    }
}
