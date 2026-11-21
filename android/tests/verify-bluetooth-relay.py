#!/usr/bin/env python3
"""Exercise the Android RFCOMM client and pinned TLS with an isolated loopback radio."""
from pathlib import Path
from tempfile import TemporaryDirectory
import subprocess

android = Path(__file__).resolve().parents[1]
src = android / 'src/dev/bluetoothswitch/relay'
stubs = {
    'SuppressLint': 'package android.annotation; public @interface SuppressLint { String[] value(); }',
    'RelaySettings': '''package dev.bluetoothswitch.relay;
        class RelaySettings {
            boolean paired(){return false;} static boolean validHost(String h){return false;}
            String token(){return "";} String pin(){return "";}
        }''',
    'BluetoothAdapter': '''package android.bluetooth;
        public class BluetoothAdapter {
            public static boolean checkBluetoothAddress(String s){return true;}
            public static BluetoothAdapter getDefaultAdapter(){return new BluetoothAdapter();}
            public boolean isEnabled(){return true;}
            public BluetoothDevice getRemoteDevice(String address){return new BluetoothDevice();}
        }''',
    'BluetoothDevice': '''package android.bluetooth;
        public class BluetoothDevice {
            public static final int BOND_BONDED=12;
            public int getBondState(){return BOND_BONDED;}
            public BluetoothSocket createRfcommSocketToServiceRecord(java.util.UUID service) {
                if (!service.toString().equals("71f55b60-e473-4c78-a90b-ec41d2f86c11")) throw new AssertionError();
                return new BluetoothSocket();
            }
        }''',
    'BluetoothSocket': '''package android.bluetooth;
        import java.net.*; import java.io.*;
        public class BluetoothSocket extends Socket {
            public void connect() throws IOException {
                if (Boolean.getBoolean("radio.stall")) {
                    while (!isClosed()) {
                        try { Thread.sleep(5); } catch (InterruptedException error) { throw new IOException(error); }
                    }
                    throw new IOException("cancelled");
                }
                connect(new InetSocketAddress(InetAddress.getLoopbackAddress(), Integer.getInteger("radio.port")),2000);
            }
        }''',
}

with TemporaryDirectory(prefix='pairit-bluetooth-test-') as scratch:
    root = Path(scratch)
    for name, content in stubs.items():
        (root / (name + '.java')).write_text(content)
    cert = root / 'test.p12'
    subprocess.run(['keytool', '-genkeypair', '-alias', 'test', '-keystore', cert,
                    '-storepass', 'fixture', '-keypass', 'fixture', '-storetype', 'PKCS12',
                    '-dname', 'CN=PairIt fixture', '-keyalg', 'RSA', '-validity', '1'], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(['javac', '-d', root, *root.glob('*.java'), src/'BluetoothRelayBridge.java',
                    src/'BluetoothRelaySocket.java', src/'RelayConnection.java',
                    android/'tests/BluetoothRelayTlsCheck.java'], check=True)
    subprocess.run(['java', '-cp', root, 'dev.bluetoothswitch.relay.BluetoothRelayTlsCheck', cert],
                   check=True, timeout=25)
