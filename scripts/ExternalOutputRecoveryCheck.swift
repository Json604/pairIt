import Foundation
@main struct ExternalOutputRecoveryCheck {
    static func main() {
        var r = ExternalOutputRecovery()
        precondition(!r.ready(externalReady: true, permitted: true))
        r.lost(external: true, enabled: true)
        precondition(r.waiting && !r.ready(externalReady: false, permitted: true))
        precondition(!r.ready(externalReady: true, permitted: false))
        precondition(r.ready(externalReady: true, permitted: true))
        r.cancel(); precondition(!r.ready(externalReady: true, permitted: true))
        r.lost(external: false, enabled: true); precondition(!r.waiting)
        r.lost(external: true, enabled: false); precondition(!r.waiting)
        print("PASS: external output recovery respects speakers, manual choices and readiness")
    }
}
