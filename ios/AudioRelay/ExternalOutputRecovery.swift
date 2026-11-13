/// Only an interrupted external-output session may auto-resume.
struct ExternalOutputRecovery {
    private(set) var waiting = false
    mutating func restore(savedPin: String, currentPin: String, enabled: Bool) {
        waiting = enabled && !savedPin.isEmpty && savedPin == currentPin
    }
    mutating func lost(external: Bool, enabled: Bool) { waiting = external && enabled }
    func ready(externalReady: Bool, permitted: Bool) -> Bool { waiting && externalReady && permitted }
    mutating func cancel() { waiting = false }
}
