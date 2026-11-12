package dev.bluetoothswitch.relay;

/** One immutable snapshot for controls, notification and accessibility. */
final class RelayState {
    enum Phase { IDLE, CONNECTING, BUFFERING, PLAYING, PAUSED, PHONE, RECONNECTING, HEADPHONES, ERROR }
    final Phase phase;
    final String title, detail;
    RelayState(Phase phase, String title, String detail) { this.phase = phase; this.title = title; this.detail = detail; }
    boolean macSelected() { return phase == Phase.CONNECTING || phase == Phase.BUFFERING || phase == Phase.PLAYING || phase == Phase.PAUSED || phase == Phase.RECONNECTING; }
}
