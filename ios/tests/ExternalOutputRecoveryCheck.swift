@main
enum ExternalOutputRecoveryCheck {
    static func main() {
        var r = ExternalOutputRecovery()
        precondition(!r.ready(externalReady: true, permitted: true), "Unrelated attachment must not start playback")
        r.lost(external: true, enabled: true)
        precondition(r.waiting && !r.ready(externalReady: false, permitted: true) && !r.ready(externalReady: true, permitted: false))
        precondition(r.ready(externalReady: true, permitted: true))

        var restored = ExternalOutputRecovery()
        restored.restore(savedPin: "saved-pin", currentPin: "saved-pin", enabled: true)
        precondition(restored.ready(externalReady: true, permitted: true))
        restored.restore(savedPin: "old-pin", currentPin: "new-pin", enabled: true)
        precondition(!restored.waiting)
        restored.restore(savedPin: "saved-pin", currentPin: "saved-pin", enabled: false)
        precondition(!restored.waiting)

        precondition(ExternalOutputRecovery.canTriggerBluetoothReconnect(autoReconnect: true, paired: true, adPresenting: false, onCall: false))
        precondition(!ExternalOutputRecovery.canTriggerBluetoothReconnect(autoReconnect: false, paired: true, adPresenting: false, onCall: false))
        precondition(!ExternalOutputRecovery.canTriggerBluetoothReconnect(autoReconnect: true, paired: false, adPresenting: false, onCall: false))
        precondition(!ExternalOutputRecovery.canTriggerBluetoothReconnect(autoReconnect: true, paired: true, adPresenting: true, onCall: false))
        precondition(!ExternalOutputRecovery.canTriggerBluetoothReconnect(autoReconnect: true, paired: true, adPresenting: false, onCall: true))
        print("PASS: iOS external output recovery and Bluetooth trigger gating")
    }
}
