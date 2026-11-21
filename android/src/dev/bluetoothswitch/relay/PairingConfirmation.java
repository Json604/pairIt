package dev.bluetoothswitch.relay;

import android.os.Handler;
import android.os.Looper;
import java.net.Socket;
import java.io.IOException;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Consumer;

/** A short pinned control exchange; never opens playback or takes an audio lease. */
final class PairingConfirmation {
    private final Handler main = new Handler(Looper.getMainLooper());
    private final AtomicBoolean finished = new AtomicBoolean();
    private final AtomicReference<Socket> connection = new AtomicReference<>();
    private final Consumer<Boolean> completion;
    private final Runnable timeout = () -> finish(false);

    PairingConfirmation(PairingCode code, Consumer<Boolean> completion) {
        this(code, "", completion);
    }
    PairingConfirmation(PairingCode code, String bluetoothAddress, Consumer<Boolean> completion) {
        this.completion = completion;
        main.postDelayed(timeout, 12000);
        Thread worker = new Thread(() -> {
            boolean confirmed = false;
            try {
                Consumer<Socket> opened = socket -> {
                    connection.set(socket);
                    if (finished.get()) closeConnection();
                };
                if (bluetoothAddress.isEmpty()) {
                    confirmed = RelayConnection.confirmPairing(code.host, 5002, code.pin, code.token, opened);
                } else {
                    try (Socket socket = RelayConnection.openBluetoothPinned(bluetoothAddress, code.pin, code.token + " PAIR1", opened)) {
                        confirmed = "OK PAIR1".equals(RelayConnection.readLine(socket, 64, 2500));
                    }
                }
            } catch (Exception ignored) { } // Offline/older companions keep the saved pairing.
            final boolean result = confirmed;
            main.post(() -> finish(result));
        }, "pairing-confirmation");
        worker.setDaemon(true); worker.start();
    }
    private void finish(boolean confirmed) {
        if (!finished.compareAndSet(false, true)) return;
        main.removeCallbacks(timeout); closeConnection(); completion.accept(confirmed);
    }
    void cancel() { finished.set(true); main.removeCallbacksAndMessages(null); closeConnection(); }
    private void closeConnection() {
        Socket socket = connection.getAndSet(null);
        if (socket != null) try { socket.close(); } catch (IOException ignored) { }
    }
}
