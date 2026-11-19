import AppKit
import ApplicationServices
import CoreGraphics

/// Sends the system Play/Pause media key, which macOS routes to the current Now Playing
/// app (Safari, Chrome, Music, Spotify, QuickTime…). Posting keys needs the user's
/// Accessibility permission; without it nothing is sent and phones keep the old behavior.
final class MacMediaKeys: RelayMediaControl {
    private let lock = NSLock()
    private var cached = false
    private var checkedAt: TimeInterval = -.infinity
    var available: Bool {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        // Event-post access can stay stale in a running process after the user allows it;
        // Accessibility trust (which also permits posting keys) is read live.
        if now - checkedAt >= 2 { cached = AXIsProcessTrusted() || CGPreflightPostEventAccess(); checkedAt = now }
        return cached
    }
    /// Shows the system prompt once; afterwards the user enables PairIt in
    /// System Settings › Privacy & Security › Accessibility.
    @discardableResult func requestAccess() -> Bool {
        let granted = AXIsProcessTrusted() || CGRequestPostEventAccess()
        lock.lock(); cached = granted; checkedAt = ProcessInfo.processInfo.systemUptime; lock.unlock()
        return granted
    }
    func refresh() { lock.lock(); checkedAt = -.infinity; lock.unlock() }
    func togglePlayPause() { DispatchQueue.main.async { Self.post(key: 16) } } // NX_KEYTYPE_PLAY
    func skip(forward: Bool) { DispatchQueue.main.async { Self.post(key: forward ? 17 : 18) } } // NX_KEYTYPE_NEXT / PREVIOUS
    private static func post(key: Int) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = (key << 16) | ((down ? 0xa : 0xb) << 8)
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        log("MEDIA key \(key) sent (allowed=\(CGPreflightPostEventAccess()))")
    }
}
