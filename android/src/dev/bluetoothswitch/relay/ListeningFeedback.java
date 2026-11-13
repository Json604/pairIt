package dev.bluetoothswitch.relay;

/** An accepted listening session (or legacy PCM) establishes feedback; discovery never does. */
final class ListeningFeedback {
    private boolean listening;
    void audioStarted() { listening = true; }
    boolean established() { return listening; }
    boolean disconnected() { boolean notify = listening; listening = false; return notify; }
}
