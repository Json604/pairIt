import SwiftUI
import Sparkle

/// Sparkle verifies EdDSA archives and Developer ID identity, handles replacement
/// and relaunch, and asks for system authorization when the app folder needs it.
@MainActor final class MacInstallerUpdates: ObservableObject {
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    @Published private(set) var canCheck = false
    init() { controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck) }
    func downloadAndInstall() { controller.checkForUpdates(nil) }
}
