package dev.bluetoothswitch.relay;

/** One connection's negotiated intent. Clock replies acknowledge, never imply user intent. */
final class RelayHandoff {
    enum Intent { LISTEN, PHONE, PAUSE, OUTPUT, RELEASE }
    private Intent intent;
    private int token = 1, sentToken, status, offeredToken;
    private boolean known;
    RelayHandoff(Intent initial) { intent = initial; }
    synchronized void request(Intent next) {
        if (next == intent) return;
        if (token == 0xFFFFFF) throw new IllegalStateException("Connection intent exhausted");
        intent = next; token++;
    }
    synchronized Intent intent() { return intent; }
    synchronized boolean supported() { return known && (status & 1) != 0; }
    synchronized boolean acknowledged() { return supported() && (status >>> 8) == token; }
    synchronized boolean held() { return acknowledged() && (status & 4) != 0; }
    synchronized boolean playerPaused() { return held() && (status & 8) != 0; }
    synchronized boolean isCurrentOffer(int value) {
        return intent == Intent.PHONE && status == value && (value >>> 8) == token && (value & 20) == 20;
    }
    synchronized boolean released() { return acknowledged() && (status & 32) != 0; }
    synchronized boolean readyForAudio() {
        return known && intent == Intent.LISTEN && (!supported() || acknowledged() && (status & 4) == 0);
    }
    synchronized boolean acceptStatus(int value) {
        status = value; known = true;
        if (intent != Intent.PHONE || !held() || (value & 16) == 0 || offeredToken == token) return false;
        offeredToken = token; return true;
    }
    synchronized String nextCommand() {
        if (!known || sentToken == token) return "";
        sentToken = token;
        if (!supported()) {
            // Older desktops keep streaming while the receiver drains silently.
            // Never send an unknown extension to a legacy strict parser.
            return intent == Intent.RELEASE ? "ACTIVE 0\n" : "ACTIVE 1\n";
        }
        switch (intent) {
            case LISTEN: return "RESUME " + token + "\n";
            case RELEASE: return "RELEASE " + token + "\n";
            default: return "PARK " + token + " " + intent.name() + "\n";
        }
    }
}
