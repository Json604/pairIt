/// Only an interrupted external-output session may auto-resume.
struct ExternalOutputRecovery {
    private(set) var waiting = false
    mutating func lost(external: Bool, enabled: Bool) { waiting = external && enabled }
    func ready(externalReady: Bool, permitted: Bool) -> Bool { waiting && externalReady && permitted }
    mutating func cancel() { waiting = false }
}
