import Foundation
@main struct ExternalOutputRecoveryCheck {
    static func main() {
        var r = ExternalOutputRecovery()
        precondition(!r.ready(externalReady: true, permitted: true))
        r.lost(external: true, enabled: true)
        precondition(r.waiting && !r.ready(externalReady: false, permitted: true))
        precondition(!r.ready(externalReady: true, permitted: false))
        precondition(r.ready(externalReady: true, permitted: true))
        var restored = ExternalOutputRecovery()
        restored.restore(savedPin: "saved-pin", currentPin: "saved-pin", enabled: true)
        precondition(restored.ready(externalReady: true, permitted: true))
        restored.restore(savedPin: "old-pin", currentPin: "new-pin", enabled: true)
        precondition(!restored.waiting)
        restored.restore(savedPin: "saved-pin", currentPin: "saved-pin", enabled: false)
        precondition(!restored.waiting)
        restored.restore(savedPin: "", currentPin: "", enabled: true)
        precondition(!restored.waiting)
        r.cancel(); precondition(!r.ready(externalReady: true, permitted: true))
        r.lost(external: false, enabled: true); precondition(!r.waiting)
        r.lost(external: true, enabled: false); precondition(!r.waiting)
        print("PASS: external output recovery respects speakers, manual choices and readiness")
    }
}
