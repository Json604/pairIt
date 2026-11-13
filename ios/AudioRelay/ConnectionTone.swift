import Foundation

/// Mixed into existing relay PCM. Never creates a session, changes routing, or plays independently.
enum ConnectionTone {
    static let duration = 0.9
    static func disconnectSample(frame: Int, rate: Double) -> Float {
        guard frame >= 0, rate.isFinite, rate > 0 else { return 0 }
        let t = Double(frame) / rate
        guard t < 0.58 else { return 0 }
        func note(_ elapsed: Double, _ frequency: Double, _ length: Double) -> Double {
            guard elapsed >= 0, elapsed < length else { return 0 }
            let envelope = (1 - exp(-elapsed / 0.008)) * exp(-elapsed / 0.22) * min(1, (length - elapsed) / 0.08)
            return 0.058 * envelope * (sin(2 * .pi * frequency * elapsed) + 0.12 * exp(-elapsed / 0.10) * sin(2 * .pi * frequency * 2.01 * elapsed))
        }
        return Float(0.8 * (note(t,659.255,0.36) + note(t-0.14,439.999,0.44)))
    }
    static func sample(frame: Int, rate: Double) -> Float {
        guard frame >= 0, rate.isFinite, rate > 0 else { return 0 }
        let t = Double(frame) / rate
        guard t < duration else { return 0 }
        func note(_ elapsed: Double, _ frequency: Double, _ length: Double) -> Double {
            guard elapsed >= 0, elapsed < length else { return 0 }
            let envelope = (1 - exp(-elapsed / 0.008)) * exp(-elapsed / 0.22) * min(1, (length - elapsed) / 0.08)
            return 0.058 * envelope * (sin(2 * .pi * frequency * elapsed) + 0.12 * exp(-elapsed / 0.10) * sin(2 * .pi * frequency * 2.01 * elapsed))
        }
        return Float(note(t,659.255,0.60) + note(t-0.18,987.767,0.72))
    }
}

struct ConnectionFeedbackGate {
    private var pin: String?
    mutating func claim(_ value: String) -> Bool {
        guard pin != value else { return false }; pin = value; return true
    }
    mutating func disconnected() -> Bool { let connected = pin != nil; pin = nil; return connected }
    mutating func reset() { pin = nil }
}
