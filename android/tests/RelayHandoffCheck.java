package dev.bluetoothswitch.relay;

public final class RelayHandoffCheck {
    private static void require(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
    public static void main(String[] args) {
        RelayHandoff control = new RelayHandoff(RelayHandoff.Intent.LISTEN);
        control.acceptStatus(1 | 128 | (1 << 8));
        require(control.readyForAudio(), "Listening begins after its acknowledged intent");
        control.nextCommand();
        control.requestOutput(true);
        require(!control.readyForAudio(), "Selecting computer output suppresses local audio immediately");
        require(control.nextCommand().equals("OUTPUT COMPUTER\n"), "Computer output uses the existing control connection");
        control.acceptStatus(1 | 128 | 64 | (1 << 8));
        require(control.computerOutput(), "Computer output is acknowledged");
        require(!control.readyForAudio(), "Computer output never plays stale PCM locally");
        control.requestOutput(false);
        require(control.nextCommand().equals("OUTPUT PHONE\n"), "Explicit return requests phone output");
        require(!control.readyForAudio(), "Local playback waits for the phone-output acknowledgment");
        control.acceptStatus(1 | 128 | (1 << 8));
        require(control.readyForAudio(), "Local playback can return after acknowledgment");
        for (RelayHandoff.Intent intent : new RelayHandoff.Intent[]{RelayHandoff.Intent.PAUSE, RelayHandoff.Intent.PHONE}) {
            RelayHandoff parked = new RelayHandoff(intent);
            parked.acceptStatus(1 | 128 | 64 | 4 | (1 << 8));
            parked.acceptStatus(1 | 128 | 4 | (1 << 8));
            require(parked.intent() == intent && !parked.readyForAudio(), "Desktop output changes preserve parked phone intent");
        }
        RelayHandoff legacy = new RelayHandoff(RelayHandoff.Intent.LISTEN);
        legacy.requestOutput(false);
        legacy.acceptStatus(0);
        require(legacy.nextCommand().equals("ACTIVE 1\n"), "Legacy desktop receives no unsupported output command");
        RelayHandoff modernWithoutOutput = new RelayHandoff(RelayHandoff.Intent.LISTEN);
        modernWithoutOutput.requestOutput(false);
        modernWithoutOutput.acceptStatus(1);
        require(modernWithoutOutput.nextCommand().equals("RESUME 1\n"), "Handoff alone does not advertise output control");
        RelayHandoff interrupted = new RelayHandoff(RelayHandoff.Intent.LISTEN);
        interrupted.acceptStatus(1 | 128 | (1 << 8));
        interrupted.requestOutput(true); interrupted.nextCommand();
        require(interrupted.pendingOutput() == 1, "Sending OUTPUT does not acknowledge its application");
        RelayHandoff reconnected = new RelayHandoff(RelayHandoff.Intent.LISTEN);
        reconnected.requestOutput(interrupted.pendingOutput() == 1);
        reconnected.acceptStatus(1 | 128 | (1 << 8));
        require(!reconnected.readyForAudio(), "Unconfirmed Computer selection survives a reconnect");
        require(reconnected.nextCommand().startsWith("OUTPUT COMPUTER\n"), "Reconnect resends an unconfirmed destination");
        reconnected.acceptStatus(1 | 128 | 64 | (1 << 8));
        require(reconnected.pendingOutput() == -1, "Only matching status completes the destination request");
        System.out.println("PASS: computer output retains control, gates PCM, preserves pause and supports legacy peers");
    }
}
