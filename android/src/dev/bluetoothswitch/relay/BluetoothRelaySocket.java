package dev.bluetoothswitch.relay;

import android.annotation.SuppressLint;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothSocket;
import java.io.IOException;
import java.net.Socket;
import java.util.UUID;
import java.util.function.Consumer;

/** Gives the platform TLS provider a real socket descriptor for an already-bonded RFCOMM peer. */
final class BluetoothRelaySocket {
    private static final UUID SERVICE = UUID.fromString("71f55b60-e473-4c78-a90b-ec41d2f86c11");
    @SuppressLint("MissingPermission") // The Preview picker requests CONNECT; revocation fails this attempt.
    static Socket open(String address, Consumer<Socket> opened) throws IOException {
        if (!BluetoothAdapter.checkBluetoothAddress(address))
            throw new IOException("Invalid Bluetooth selection");
        BluetoothAdapter adapter = BluetoothAdapter.getDefaultAdapter();
        if (adapter == null || !adapter.isEnabled()) throw new IOException("Turn on Bluetooth");
        BluetoothDevice device = adapter.getRemoteDevice(address);
        if (device.getBondState() != BluetoothDevice.BOND_BONDED) throw new IOException("Pair the Mac in Bluetooth settings");
        BluetoothSocket radio = device.createRfcommSocketToServiceRecord(SERVICE);
        BluetoothRelayBridge raw = new BluetoothRelayBridge(radio);
        try {
            opened.accept(raw);
            Thread deadline = new Thread(() -> {
                try { Thread.sleep(8000); raw.close(); }
                catch (InterruptedException | IOException ignored) { }
            }, "relay-bluetooth-connect-timeout");
            deadline.setDaemon(true);
            deadline.start();
            try { radio.connect(); }
            finally { deadline.interrupt(); }
            raw.attach(radio.getInputStream(), radio.getOutputStream());
            return raw;
        } catch (IOException | RuntimeException error) {
            raw.close();
            throw error;
        }
    }

}
