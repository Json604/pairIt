package dev.bluetoothswitch.relay;

/** One connection's negotiated intent. Clock replies acknowledge, never imply user intent. */
final class RelayHandoff {
    enum Intent { LISTEN, PHONE, PAUSE, OUTPUT, RELEASE }
    private Intent intent;
    private int token = 1, sentToken, status, offeredToken;
    private int requestedOutput = -1, sentOutput = -1;
    private boolean known;
    private int consumedDesktopRequest;
    private int desktopStatus;
    RelayHandoff(Intent initial) { intent = initial; }
    synchronized void request(Intent next) {
        if (next == intent && desktopStatus == 0) return;
        desktopStatus=0;
        if (token == 0xFFFFFF) throw new IllegalStateException("Connection intent exhausted");
        intent = next; token++;
    }
    synchronized Intent intent() { return intent; }
    synchronized boolean supported() { return known && (status & 1) != 0; }
    synchronized boolean outputSupported() { return known && (status & 128) != 0; }
    synchronized boolean computerOutputConfirmed() { return outputSupported() && (status & 64) != 0; }
    synchronized boolean computerOutput() { return requestedOutput == 1 || computerOutputConfirmed(); }
    synchronized int pendingOutput() { return requestedOutput; }
    synchronized void requestOutput(boolean computer) { requestedOutput = computer ? 1 : 0; sentOutput = -1; }
    synchronized boolean acknowledged() { return supported() && (status >>> 8) == token; }
    synchronized boolean held() { return acknowledged() && (status & 4) != 0; }
    synchronized boolean playerPaused() { return held() && (status & 8) != 0; }
    synchronized boolean isCurrentOffer(int value) {
        return intent == Intent.PHONE && status == value && (value >>> 8) == token && (value & 20) == 20;
    }
    synchronized int desktopRequest(int command) {
        desktopStatus=command;
        if(!acknowledged() || intent==Intent.RELEASE || (command&2)==0 || (command>>>8)!=token)return -1;
        int key=(command & 0xFFFFFF00)|(command&16)|2;
        if(key==consumedDesktopRequest)return -1;
        consumedDesktopRequest=key;return (command&16)!=0?1:0;
    }
    synchronized boolean released() { return acknowledged() && (status & 32) != 0; }
    synchronized boolean readyForAudio() {
        return known && !computerOutput() && intent == Intent.LISTEN && (!supported() || acknowledged() && (status & 4) == 0);
    }
    synchronized boolean acceptStatus(int value) {
        status = value; known = true;
        if (!outputSupported() || requestedOutput >= 0 && sentOutput == requestedOutput
                && ((status & 64) != 0) == (requestedOutput == 1)) requestedOutput = sentOutput = -1;
        if (intent != Intent.PHONE || !held() || (value & 16) == 0 || offeredToken == token) return false;
        offeredToken = token; return true;
    }
    synchronized String nextCommand() {
        if (!known) return "";
        String output = "";
        if (outputSupported() && requestedOutput >= 0 && requestedOutput != sentOutput) {
            sentOutput = requestedOutput;
            output = "OUTPUT " + (requestedOutput == 1 ? "COMPUTER" : "PHONE") + "\n";
        }
        if (sentToken == token) return output;
        sentToken = token;
        if (!supported()) {
            // Older desktops keep streaming while the receiver drains silently.
            // Never send an unknown extension to a legacy strict parser.
            return output + (intent == Intent.RELEASE ? "ACTIVE 0\n" : "ACTIVE 1\n");
        }
        switch (intent) {
            case LISTEN: return output + "RESUME " + token + "\n";
            case RELEASE: return output + "RELEASE " + token + "\n";
            default: return output + "PARK " + token + " " + intent.name() + "\n";
        }
    }
}
