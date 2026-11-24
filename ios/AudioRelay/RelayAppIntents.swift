import AppIntents
import Foundation

/// Allows Apple Shortcuts Bluetooth automations ("When headphones connect -> Run Immediately")
/// to wake PairIt in the background even after iOS terminated the app.
struct ReconnectComputerIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Auto-reconnect to computer"
    static var description = IntentDescription("Wakes PairIt in the background and reconnects to your paired computer when Auto-reconnect is enabled and headphones are connected.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await RelayReceiver.shared.connectFromBluetoothTrigger()
        return .result()
    }
}

struct PairItAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ReconnectComputerIntent(),
            phrases: [
                "Auto-reconnect in \(.applicationName)",
                "Reconnect to computer in \(.applicationName)"
            ],
            shortTitle: "Auto-reconnect",
            systemImageName: "headphones"
        )
    }
}
