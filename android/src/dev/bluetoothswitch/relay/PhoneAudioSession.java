package dev.bluetoothswitch.relay;

/** A lease outlives service teardown until its audio worker has released the OS device. */
final class PhoneAudioSession {
    private static Object owner;
    private static String reason = "Audio is finishing. Wait a moment, then choose Computer again.";
    static synchronized boolean acquire(Object session) {
        return acquire(session, "Audio is finishing. Wait a moment, then choose Computer again.");
    }
    static synchronized boolean acquire(Object session, String busyReason) {
        if (owner != null && owner != session) return false;
        owner = session; reason = busyReason; return true;
    }
    static synchronized boolean available() { return owner == null; }
    static synchronized boolean availableTo(Object session) { return owner == null || owner == session; }
    static synchronized String busyReason() { return reason; }
    static synchronized void release(Object session) { if (owner == session) owner = null; }
}
