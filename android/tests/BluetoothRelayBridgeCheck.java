package dev.bluetoothswitch.relay;

import java.io.DataInputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.Arrays;

public final class BluetoothRelayBridgeCheck {
    public static void main(String[] args) throws Exception {
        try (ServerSocket endpoint = new ServerSocket(0, 1, InetAddress.getLoopbackAddress());
             Socket radio = new Socket(endpoint.getInetAddress(), endpoint.getLocalPort());
             Socket mac = endpoint.accept();
             BluetoothRelayBridge tls = new BluetoothRelayBridge(radio)) {
            tls.attach(radio.getInputStream(), radio.getOutputStream());
            mac.setSoTimeout(2000);
            tls.setSoTimeout(2000);
            byte[] audio = new byte[16000];
            for (int i = 0; i < audio.length; i++) audio[i] = (byte)i;
            tls.getOutputStream().write(33);
            if (mac.getInputStream().read() != 33) throw new AssertionError("control bytes");
            mac.getOutputStream().write(audio);
            mac.shutdownOutput();
            byte[] received = new byte[audio.length];
            new DataInputStream(tls.getInputStream()).readFully(received);
            if (!Arrays.equals(received, audio) || tls.getInputStream().read() != -1)
                throw new AssertionError("RFCOMM close must deliver the final bytes");
            tls.close();
            if (mac.getInputStream().read() != -1 || !radio.isClosed())
                throw new AssertionError("disconnect closes the radio");
        }
        System.out.println("PASS: Bluetooth bridge full duplex stream, remote EOF and disconnect");
    }
}
