import SwiftUI
import Sparkle

/// Sparkle verifies signed archives and owns the daily reminder/install lifecycle.
@MainActor final class MacInstallerUpdates: ObservableObject {
    private let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    @Published private(set) var canCheck = false
    private var started = false

    init() { controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck) }
    func start() {
        guard !started else { return }
        started = true
        controller.startUpdater()
        // Explicit launch check in addition to Sparkle's 24-hour scheduler.
        if controller.updater.automaticallyChecksForUpdates {
            controller.updater.checkForUpdatesInBackground()
        }
    }
    func downloadAndInstall() { controller.checkForUpdates(nil) }
}
