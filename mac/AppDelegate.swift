import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var server = RelayServer()
    private lazy var wifi = WiFiServer(upstreamToken: server.gatewayToken)
    private let model = MacCompanionModel()
    private let lifecycle = DispatchQueue(label: "relay.companion.lifecycle", qos: .userInitiated)
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var terminationSignal: DispatchSourceSignal?
    private var setupTimer: Timer?
    private var presentationRetry: DispatchWorkItem?
    private var popoverRetryCount = 0
    private var escapeMonitor: Any?
    private let interfacePreview = ProcessInfo.processInfo.arguments.contains("--ui-preview") || ProcessInfo.processInfo.environment["PAIRIT_UI_PREVIEW"] == "1"
    private func traceUI(_ message: String) {
        if ProcessInfo.processInfo.arguments.contains("--ui-diagnostics") { log("UI " + message) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.bluetoothswitch.macrelay")
        if let existing = copies.first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(); NSApp.terminate(nil); return
        }
        if !interfacePreview { SyncOutput.recoverAfterCrash() }
        model.toggleSharing = { [weak self] in self?.toggleSharing() }
        model.selectOutput = { [weak self] speakers in
            guard let self, self.model.sharing, self.model.sharingAction == nil else { return }
            self.server.setComputerOutput(speakers)
        }
        model.retrySharing = { [weak self] in self?.startSharing() }
        model.installOutput = { [weak self] in self?.installOutput() }
        model.openPermissions = {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
        }
        model.quit = { NSApp.terminate(nil) }
        model.changeAddress = { [weak self] in
            guard let self, self.model.sharing else { return }
            self.model.updatePairing(self.wifi.pairingCode(for: self.model.address))
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "PairIt")
            button.toolTip = "PairIt"
            button.target = self; button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // A development-only review mode keeps the panel visible when the UI
        // inspection tool changes focus. Normal launches dismiss natively.
        popover.behavior = interfacePreview || ProcessInfo.processInfo.arguments.contains("--ui-review") ? .applicationDefined : .transient
        popover.delegate = self
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentSize = NSSize(width: 400, height: 560)
        let controller = NSHostingController(rootView: MacCompanionView(model: model))
        popover.contentViewController = controller
        // Build/layout the small control surface before the first click, rather
        // than doing its initial layout during the popover's opening animation.
        controller.view.frame.size = popover.contentSize
        controller.view.layoutSubtreeIfNeeded()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.popover.isShown else { return event }
            self.closePopover(animated: false); return nil
        }
        let menu = NSMenu(), appMenu = NSMenu(), entry = NSMenuItem()
        appMenu.addItem(NSMenuItem(title: "Quit PairIt", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        entry.submenu = appMenu; menu.addItem(entry); NSApp.mainMenu = menu
        signal(SIGTERM, SIG_IGN)
        terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSignal?.setEventHandler { NSApp.terminate(nil) }; terminationSignal?.resume()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        startSharing(announceCompletion: false)
        setupTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let installed = SyncOutput.installed
            if self.model.outputInstalled != installed { self.model.outputInstalled = installed }
            let addresses = LocalIdentity.addresses()
            if addresses != self.model.addresses { self.model.addresses = addresses }
            if !addresses.contains(where: { $0.host == self.model.address }), let first = addresses.first { self.model.address = first.host }

        }
        DispatchQueue.main.async { [weak self] in self?.showPopover() }
    }
    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closePopover(animated: false)
            guard let button = item.button else { return }
            let menu = NSMenu()
            let open = NSMenuItem(title: "Open PairIt", action: #selector(showPopover), keyEquivalent: "")
            open.target = self; menu.addItem(open)
            let pair = NSMenuItem(title: "Pair a phone…", action: #selector(pairPhone), keyEquivalent: "")
            pair.target = self; menu.addItem(pair)
            let sharing = NSMenuItem(title: model.sharing ? "Stop sharing" : "Start sharing", action: #selector(toggleSharing), keyEquivalent: "")
            sharing.target = self; sharing.isEnabled = model.sharingAction == nil
            menu.autoenablesItems = false; menu.addItem(sharing); menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Quit PairIt", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        } else if popover.isShown || presentationRetry != nil { closePopover() }
        else { showPopover() }
    }
    @objc private func showPopover() {
        guard !popover.isShown, let button = item.button else { return }
        traceUI("open requested anchor=\(String(describing: button.window?.frame)) retry=\(popoverRetryCount)")
        // The status-item's initial window has zero height. Keep one cancellable
        // retry; closing the popup must never let an old retry reopen it.
        guard let anchor = button.window, anchor.frame.height > 0 else {
            guard popoverRetryCount < 10 else { cancelPresentationRetry(); return }
            popoverRetryCount += 1
            presentationRetry?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.presentationRetry = nil; self?.showPopover() }
            presentationRetry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
            return
        }
        cancelPresentationRetry()
        popover.animates = RelayMotion.allowsSpatialMotion
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.title = "PairIt"
        popover.contentViewController?.view.window?.makeKey()
        traceUI("show returned shown=\(popover.isShown) visible=\(popover.contentViewController?.view.window?.isVisible ?? false)")
    }
    private func cancelPresentationRetry() {
        presentationRetry?.cancel(); presentationRetry = nil; popoverRetryCount = 0
    }
    private func closePopover(animated: Bool = true) {
        cancelPresentationRetry()
        popover.animates = animated && RelayMotion.allowsSpatialMotion
        popover.performClose(nil)
    }
    func popoverWillShow(_ notification: Notification) { item.button?.highlight(true) }
    func popoverWillClose(_ notification: Notification) { cancelPresentationRetry(); item.button?.highlight(false) }
    func popoverDidShow(_ notification: Notification) { traceUI("did show") }
    func popoverDidClose(_ notification: Notification) { traceUI("did close") }
    @objc private func pairPhone() { model.navigate(to: 1); showPopover() }
    @objc private func toggleSharing() {
        guard model.sharingAction == nil else { return }
        guard model.sharing else { startSharing(); return }
        model.sharingAction = .pausing
        let currentServer = server, currentWiFi = wifi
        lifecycle.async { [weak self] in
            // stop() can wait for capture cleanup. It must not block animation,
            // hover, navigation or the progress indicator on the main thread.
            currentWiFi.stop(); currentServer.stop()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.model.sharing = false; self.model.connected = false; self.model.receiverCount = 0; self.model.parkedCount = 0; self.model.outputHeld = false; self.model.computerOutput = false
                self.model.detail = "Sharing stopped. Your Mac is using its normal audio output."
                self.model.network = "Paused"; self.model.sharingAction = nil
                self.item.button?.toolTip = "PairIt · Sharing stopped"
                self.model.announce("Sharing stopped.")
            }
        }
    }
    private func startSharing(announceCompletion: Bool = true) {
        if interfacePreview {
            model.sharing = false; model.network = "Interface preview"
            model.detail = "Interface preview. No audio or network session is running."
            if announceCompletion { model.showFeedback("Interface preview. No audio session is running.") }
            return
        }
        guard model.sharingAction == nil else { return }
        model.sharingAction = .starting
        model.network = "Starting local Wi-Fi…"
        model.detail = "Getting your Mac ready."
        let previousServer = server, previousWiFi = wifi
        let nextServer = RelayServer()
        let nextWiFi = WiFiServer(upstreamToken: nextServer.gatewayToken)
        nextWiFi.reserveMicrophone = { [weak nextServer] in nextServer?.reserveMicrophone() ?? false }
        nextWiFi.releaseMicrophone = { [weak nextServer] in nextServer?.releaseMicrophone() }
        server = nextServer; wifi = nextWiFi
        nextServer.onStatus = { [weak self, weak nextServer] value in
            guard let self, self.server === nextServer, self.model.sharingAction != .pausing else { return }
            self.item.button?.toolTip = "PairIt · " + value
            self.model.outputHeld = value.contains("output held")
            if self.model.detail != value { self.model.detail = value }
        }
        nextWiFi.onStatus = { [weak self, weak nextWiFi] value in
            guard let self, self.wifi === nextWiFi, self.model.sharingAction != .pausing else { return }
            if self.model.network != value { self.model.network = value }
        }
        nextServer.onReceivers = { [weak self, weak nextServer] count, parked, detail in
            guard let self, self.server === nextServer else { return }
            let previouslyConnected = self.model.connected
            self.model.receiverCount = count; self.model.parkedCount = parked; self.model.receiverDetail = detail
            self.model.connected = count + parked > 0
            if self.model.connected && !previouslyConnected { self.model.pairingConfirmed = true }
        }
        nextServer.onOutputChanged = { [weak self, weak nextServer] speakers in
            guard let self, self.server === nextServer else { return }
            let changed = self.model.computerOutput != speakers
            self.model.computerOutput = speakers
            if changed { self.model.announce(speakers ? "Mac speakers selected. Phones stay connected." : "Phone headphones selected. Paused listeners resume on their phones.") }
        }
        nextWiFi.onPairingConfirmed = { [weak self, weak nextWiFi] in
            DispatchQueue.main.async {
                guard let self, self.wifi === nextWiFi else { return }
                self.model.pairingConfirmed = true
                self.model.showFeedback("Phone paired. Start audio on your phone when you’re ready.")
                self.item.button?.toolTip = "PairIt · Phone paired"
            }
        }
        lifecycle.async { [weak self] in
            previousWiFi.stop(); previousServer.stop()
            do {
                try nextServer.start(); try nextWiFi.start()
                let code = nextWiFi.pairingCode
                let address = LocalIdentity.currentHost()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.model.sharing = true; self.model.sharingAction = nil
                    self.model.address = address; self.model.updatePairing(code)
                    self.model.addresses = LocalIdentity.addresses()
                        if announceCompletion { self.model.announce("Sharing is on.") }
                }
            } catch {
                nextWiFi.stop(); nextServer.stop()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.model.sharing = false; self.model.connected = false; self.model.sharingAction = nil
                    self.model.detail = "Couldn’t start: \(error)"; log("ERROR \(error)")
                }
            }
        }
    }
    @objc private func installOutput() {
        guard let package = Bundle.main.url(forResource: "Audio Relay Output", withExtension: "pkg") else {
            model.showFeedback("Installer missing. Reinstall PairIt.", isError: true); return
        }
        NSWorkspace.shared.open(package, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            DispatchQueue.main.async {
                self?.model.showFeedback(error == nil ? "Continue in the Installer window." : "Couldn’t open Installer. Try again.", isError: error != nil)
            }
        }
    }
    @objc private func willSleep() { closePopover(animated: false); server.disconnect(); wifi.stopMicrophones() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPopover(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        setupTimer?.invalidate(); cancelPresentationRetry()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        let currentServer = server, currentWiFi = wifi
        lifecycle.sync { currentWiFi.stop(); currentServer.stop() }
    }
}
