import SwiftUI
import AppKit
import CoreImage

final class MacCompanionModel: ObservableObject {
    enum SharingAction { case starting, pausing }
    struct Feedback: Identifiable {
        let id = UUID()
        let message: String
        let isError: Bool
    }
    @Published private(set) var page = 0
    @Published private(set) var forward = true
    @Published var sharing = false
    @Published var sharingAction: SharingAction?
    @Published var phoneNames = "Phone"
    @Published var connected = false
    @Published var outputInstalled = SyncOutput.installed
    @Published var volumeControlsInstalled = SyncOutput.volumeControlsInstalled
    @Published var microphoneEnabled = false
    @Published var microphoneStatus = "Microphone mode is off"
    @Published var microphoneDestinations = MicrophoneOutput.destinations()
    @Published var microphoneUID = UserDefaults.standard.string(forKey: "microphoneDestinationUID") ?? ""
    var enableMicrophone: (Bool) -> Void = { _ in }
    var selectMicrophone: (String) -> Void = { _ in }
    @Published var detail = "Getting your Mac ready."
    @Published var network = "Starting local Wi-Fi…"
    @Published private(set) var pairingCode = ""
    @Published private(set) var qrImage: NSImage?
    @Published private(set) var copied = false
    @Published private(set) var feedback: Feedback?
    @Published var address = "Finding local address…"
    @Published var addresses: [LocalIdentity.Address] = []
    @Published var receiverCount = 0
    @Published var parkedCount = 0
    @Published var outputHeld = false
    @Published var computerOutput = false
    @Published var playbackAction: Bool?
    @Published var pairingConfirmed = false
    @Published var receiverDetail = "No active listeners"
    let macName = Host.current().localizedName ?? "This Mac"
    private var history = [0]
    private var copyReset: DispatchWorkItem?
    private var feedbackReset: DispatchWorkItem?
    private let qrQueue = DispatchQueue(label: "relay.pairing.image", qos: .userInitiated)
    var resize: (Int) -> Void = { _ in }
    var toggleSharing: () -> Void = {}
    var retrySharing: () -> Void = {}
    var installOutput: () -> Void = {}
    var openPermissions: () -> Void = {}
    var quit: () -> Void = {}
    var changeAddress: () -> Void = {}
    var setPhonePlayback: (Bool) -> Void = { _ in }
    var selectOutput: (Bool) -> Void = { _ in }
    var panelWidth: CGFloat { page == 1 ? 500 : 300 }
    var panelHeight: CGFloat { page == 1 ? 330 : page == 0 ? (microphoneEnabled ? 340 : !outputInstalled ? 390 : ((connected || parkedCount > 0) ? 326 : (!sharing || connectionFailed ? 240 : 200)) + (outputInstalled && !volumeControlsInstalled ? 76 : 0)) : 440 }
    var needsAudioPermission: Bool { outputInstalled && detail.hasPrefix("Capture failed") }
    var connectionFailed: Bool { detail.hasPrefix("Couldn’t start") || network.hasPrefix("Wi-Fi unavailable") }

    func navigate(to destination: Int) {
        guard page != destination else { return }
        if destination == 1 { pairingConfirmed = false }
        if let index = history.firstIndex(of: destination) {
            history = Array(history.prefix(index + 1)); forward = false
        } else { history.append(destination); forward = true }
        withAnimation(RelayMotion.navigation) { page = destination }; resize(destination)
    }
    func back() {
        guard history.count > 1 else { return }
        history.removeLast(); forward = false
        withAnimation(RelayMotion.navigation) { page = history.last ?? 0 }; resize(page)
    }
    func updatePairing(_ code: String) {
        guard code != pairingCode else { return }
        pairingCode = code; qrImage = nil; copied = false; copyReset?.cancel()
        // QR creation is cached and kept out of body/layout and button animations.
        qrQueue.async { [weak self] in
            guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return }
            filter.setValue(Data(code.utf8), forKey: "inputMessage")
            filter.setValue("M", forKey: "inputCorrectionLevel")
            guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
                  let image = CIContext().createCGImage(output, from: output.extent) else { return }
            DispatchQueue.main.async {
                guard let self, self.pairingCode == code else { return }
                self.qrImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
        }
    }
    func copyCode() {
        guard !pairingCode.isEmpty else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(pairingCode, forType: .string) else {
            showFeedback("Couldn’t copy. Please try again.", isError: true); return
        }
        copyReset?.cancel()
        withAnimation(RelayMotion.navigation) { copied = true }
        announce("Pairing code copied.")
        let work = DispatchWorkItem { [weak self] in withAnimation(RelayMotion.navigation) { self?.copied = false } }
        copyReset = work; DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
    func showFeedback(_ message: String, isError: Bool = false) {
        feedbackReset?.cancel()
        feedback = isError ? Feedback(message: message, isError: true) : nil
        announce(message)
        // Errors stay until dismissed; useful instructions remain long enough to read.
        if !isError {
            let work = DispatchWorkItem { [weak self] in self?.dismissFeedback() }
            feedbackReset = work; DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        }
    }
    func dismissFeedback() {
        feedbackReset?.cancel()
        withAnimation(RelayMotion.navigation) { feedback = nil }
    }
    func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

struct MacCompanionView: View {
    @ObservedObject var model: MacCompanionModel
    @StateObject private var updates = ReleaseUpdates()
    @StateObject private var installerUpdates = MacInstallerUpdates()
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        ZStack(alignment: .bottom) {
            RelayBackdrop()
            VStack(spacing: 0) {
                header
                if let update = updates.available {
                    HStack(spacing: 8) {
                        Text("Update available · \(update.version)").font(.system(size: 11))
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Button("Download & Install") { installerUpdates.downloadAndInstall() }.disabled(!installerUpdates.canCheck).font(.system(size: 11, weight: .semibold))
                    }.padding(.horizontal, 20).padding(.vertical, 6)
                }
                if let feedback = model.feedback, feedback.isError {
                    Text(feedback.message).font(.system(size: 11)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 20).padding(.bottom, 6)
                }
                ZStack {
                    Group {
                        if model.page == 0 { ScrollView { overview } }
                        else if model.page == 1 { ScrollView { pairing.padding(20).padding(.top, 2) } }
                        else { ScrollView { Group { if model.page == 3 { sharedListening } else { settings } }.padding(28).padding(.top, 2) } }
                    }.id(model.page).transition(pageTransition)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            }
        }.foregroundStyle(RelayPalette.ink).preferredColorScheme(.light)
            .frame(width: model.panelWidth, height: model.panelHeight)
            .onChange(of: model.panelHeight) { _, _ in model.resize(model.page) }
            .onReceive(Timer.publish(every: 900, on: .main, in: .common).autoconnect()) { _ in updates.check() }
            .onAppear { updates.check() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in updates.check() }
    }
    private var pageTransition: AnyTransition {
        guard !reduced else { return .opacity }
        let direction: CGFloat = model.forward ? 1 : -1
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: 12 * direction)),
                           removal: .opacity.combined(with: .offset(x: -8 * direction)))
    }
    private var header: some View {
        HStack(spacing: 6) {
            ZStack {
                if model.page == 0 { EmptyView() }
                else {
                    Button(action: model.back) { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                        .buttonStyle(RelayControlButtonStyle()).accessibilityLabel("Back").help("Back")
                        .transition(.opacity)
                }
            }.frame(width: model.page == 0 ? 0 : 44, height: 44)
            if model.page == 0 { RelayBrand() }
            else { Text(model.page == 1 ? "Pair a phone" : model.page == 3 ? "Listen together" : "Settings")
                .font(RelayTypography.display(20, strong: true)).contentTransition(.opacity).accessibilityAddTraits(.isHeader) }
            Spacer()
            if let update = updates.available {
                Button { installerUpdates.downloadAndInstall() } label: { Image(systemName: "arrow.down.circle").frame(width: 28, height: 32) }
                    .disabled(!installerUpdates.canCheck)
                    .help("Update PairIt to \(update.version)").accessibilityLabel("Update available")
            }
            Button { model.navigate(to: 2) } label: { Image(systemName: "slider.horizontal.3").frame(width: 32, height: 32) }
                .buttonStyle(RelayControlButtonStyle()).help("Settings").accessibilityLabel("Settings")
                .opacity(model.page == 2 ? 0 : 1).disabled(model.page == 2).accessibilityHidden(model.page == 2)
        }.padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 4)
    }
    private var stateTitle: String {
        if model.sharingAction == .starting { return "Starting sharing" }
        if model.sharingAction == .pausing { return "Pausing sharing" }
        if model.needsAudioPermission { return "Mac audio needs attention" }
        if model.computerOutput && model.sharing { return "Mac speakers selected" }
        if model.outputHeld { return "Mac output held" }
        if model.pairingConfirmed && !model.connected && model.sharing { return "Phone paired" }
        return model.needsAudioPermission ? "Allow Mac audio" : model.connectionFailed ? "Connection unavailable" : model.connected ? "\(model.receiverCount) \(model.receiverCount == 1 ? "phone" : "phones") connected" : !model.outputInstalled ? "Set up Mac audio" : model.sharing ? "Ready to connect" : "Sharing stopped"
    }
    private var stateDetail: String {
        if model.sharingAction == .starting { return "Making your Mac available on local Wi-Fi." }
        if model.sharingAction == .pausing { return "Returning audio to your Mac’s usual output." }
        if model.needsAudioPermission { return "Mac audio could not start. Check audio recording permission, then choose Phone headphones to retry. Your phones stay connected." }
        if model.computerOutput && model.sharing { return "Phones stay connected. Resume paused audio on the phone." }
        if model.outputHeld { return (model.detail.hasPrefix("Phone unavailable") ? "Phone unavailable. " : "") + "Resume in PairIt on your phone. Media may still be playing silently; pause it in the player if needed." }
        if model.receiverCount > 1 || model.parkedCount > 0 { return model.receiverDetail }
        if model.pairingConfirmed && !model.connected && model.sharing { return "Choose Start audio on your phone." }
        if model.connectionFailed { return model.detail.hasPrefix("Couldn’t start") ? model.detail : model.network }
        return model.needsAudioPermission ? "Allow audio recording in System Settings, then reconnect your phone." : model.connectionFailed ? "Check your local network, then try sharing again." : model.connected ? "Listening through your phone." : !model.outputInstalled ? "A one-time setup helps compatible players align video and sound." : model.sharing ? "Pair your phone to listen through its headphones." : "Make this Mac available to your phone again."
    }
    private var primaryTitle: String {
        if model.sharingAction == .starting { return "Starting…" }
        if model.sharingAction == .pausing { return "Pausing…" }
        if model.needsAudioPermission { return "Open audio permissions" }
        if model.computerOutput && model.connected { return "Use phone headphones" }
        if model.outputHeld { return "Use Mac speakers" }
        return model.needsAudioPermission ? "Open audio permissions" : model.connectionFailed ? "Try again" : !model.outputInstalled ? "Set up audio" : !model.sharing ? "Start sharing" : model.connected ? "Use Mac speakers" : "Pair a phone"
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.macName).font(.system(size: 15, weight: .semibold)).lineLimit(2)
            if model.microphoneEnabled {
                Text("Phone microphone").font(.system(size: 12, weight: .semibold))
                Text(model.microphoneStatus).font(.system(size: 11)).foregroundStyle(RelayPalette.secondary)
                Text("Select your virtual cable as the microphone in your calling app. Start recording explicitly in PairIt on your phone.")
                    .font(.system(size: 11)).foregroundStyle(RelayPalette.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Turn off microphone mode") { model.enableMicrophone(false) }.buttonStyle(RelayPrimaryButtonStyle())
                Button("Pair a phone") { model.navigate(to: 1) }.buttonStyle(RelayQuietButtonStyle())
            } else if model.needsAudioPermission || model.connectionFailed || !model.outputInstalled || !model.sharing {
                Text(stateTitle).font(.system(size: 12)).foregroundStyle(RelayPalette.secondary)
                if !model.outputInstalled {
                    Text("Your Mac needs a small audio output before your phone can listen.")
                        .font(.system(size: 12)).foregroundStyle(RelayPalette.secondary).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Install the audio output", systemImage: "1.circle")
                        Label("Allow audio capture when asked", systemImage: "2.circle")
                        Label("Pair your phone and press Start audio", systemImage: "3.circle")
                    }.font(.system(size: 11)).padding(.vertical, 8)
                    Text("Installation needs your Mac password and briefly restarts system audio. Pause anything playing first.")
                        .font(.system(size: 10)).foregroundStyle(RelayPalette.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(stateDetail).font(.system(size: 11)).foregroundStyle(RelayPalette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Button(primaryTitle, action: primaryAction).buttonStyle(RelayPrimaryButtonStyle())
            } else if model.connected || model.parkedCount > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "iphone").font(.system(size: 21)).frame(width: 34, height: 36).background(Color(white: 0.93), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.phoneNames).font(.system(size: 12, weight: .semibold))
                        Text(model.computerOutput ? "Computer output" : model.receiverCount > 0 ? "Listening" : "Paused").font(.system(size: 11)).foregroundStyle(RelayPalette.secondary)
                    }
                    Spacer(); Image(systemName: "checkmark").font(.system(size: 12))
                }
                Divider()
                Text("Audio output").font(.system(size: 11)).foregroundStyle(RelayPalette.secondary)
                HStack(spacing: 4) {
                    outputButton("Phone", icon: "headphones", computer: false)
                    outputButton("Computer", icon: "desktopcomputer", computer: true)
                }.padding(5).background(Color(white: 0.92), in: RoundedRectangle(cornerRadius: 15)).clipShape(RoundedRectangle(cornerRadius: 15))
                Button { model.setPhonePlayback(model.receiverCount == 0 || model.computerOutput) } label: {
                    HStack(spacing:8){
                        if model.playbackAction != nil { ProgressView().controlSize(.small).tint(.white) }
                        else { Image(systemName:model.receiverCount > 0 && !model.computerOutput ? "pause.fill":"play.fill") }
                        Text(model.playbackAction == true ? "Resuming…" : model.playbackAction == false ? "Pausing…" : model.receiverCount > 0 && !model.computerOutput ? "Pause audio" : "Resume audio")
                    }
                }.buttonStyle(RelayPrimaryButtonStyle()).disabled(model.playbackAction != nil)
                HStack {
                    Button("Pair a phone") { model.navigate(to: 1) }
                    Spacer()
                    Button("Disconnect", action: model.toggleSharing)
                }.buttonStyle(.plain).font(.system(size: 11)).padding(.top, 2)
            } else {
                Text(model.sharingAction == nil ? "No phones connected" : "Connecting…").font(.system(size: 12)).foregroundStyle(RelayPalette.secondary)
                Button { model.navigate(to: 1) } label: { Label("Pair a phone", systemImage: "qrcode") }.buttonStyle(RelayPrimaryButtonStyle())
            }
            if model.outputInstalled && !model.volumeControlsInstalled {
                Divider()
                Button("Enable Mac volume keys", action: model.installOutput).buttonStyle(RelayQuietButtonStyle())
                Text("Update the audio output. Pause playback first; installation briefly restarts system audio.")
                    .font(.system(size: 10)).foregroundStyle(RelayPalette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 14)
    }
    private func outputButton(_ title: String, icon: String, computer: Bool) -> some View {
        let selected = model.computerOutput == computer
        return Button { model.selectOutput(computer) } label: {
            Label(title, systemImage: icon).font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity, minHeight: 38)
                .foregroundStyle(selected ? Color.white : Color(white: 0.4))
                .background(selected ? Color(white: 0.06) : .clear, in: RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(RelayControlButtonStyle()).disabled(model.sharingAction != nil)
    }
    private func primaryAction() {
        if model.needsAudioPermission { model.openPermissions() }
        else if model.connectionFailed { model.retrySharing() }
        else if !model.outputInstalled { model.installOutput() }
        else if !model.sharing { model.toggleSharing() }
        else if model.connected || model.outputHeld { model.selectOutput(!model.computerOutput) }
        else { model.navigate(to: 1) }
    }
    private var phoneDownloads: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Install PairIt on your phone").font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                Link(destination: URL(string: "https://pairit.kartikey.xyz/downloads.html#android")!) {
                    HStack(spacing: 6) { AndroidDownloadMark().frame(width: 15, height: 15); Text("Android"); Image(systemName: "arrow.up.right").font(.system(size: 9)) }
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                Link(destination: URL(string: "https://pairit.kartikey.xyz/downloads.html#iphone")!) {
                    HStack(spacing: 6) { Image(systemName: "apple.logo"); Text("iPhone"); Image(systemName: "arrow.up.right").font(.system(size: 9)) }
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
            }.font(.system(size: 12)).buttonStyle(.plain).tint(RelayPalette.ink)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(RelayPalette.line))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var pairing: some View {
        Group {
            if model.pairingConfirmed {
                VStack(spacing: 14) {
                    Label("Phone paired", systemImage: "checkmark.circle").font(.system(size: 22, weight: .semibold))
                    Text(model.connected ? model.phoneNames + " connected." : "Pairing confirmed on your phone.")
                        .font(.system(size: 12)).foregroundStyle(RelayPalette.secondary)
                    HStack(spacing: 12) {
                        Button("Done") { model.navigate(to: 0) }.buttonStyle(RelayPrimaryButtonStyle())
                        Button("Pair another phone") { model.pairingConfirmed = false }.buttonStyle(RelayQuietButtonStyle())
                    }
                }
            } else if !model.sharing || model.sharingAction != nil || model.connectionFailed {
                VStack(spacing: 14) {
                    Image(systemName: "wifi.slash").font(.system(size: 32, weight: .light))
                    Text("Start sharing to pair a phone.").font(.system(size: 13))
                    Button(model.sharingAction != nil ? "Starting…" : model.connectionFailed ? "Try again" : "Start sharing") {
                        if model.connectionFailed { model.retrySharing() } else { model.toggleSharing() }
                    }.buttonStyle(RelayPrimaryButtonStyle()).disabled(model.sharingAction != nil)
                }
            } else {
                HStack(alignment: .center, spacing: 18) {
                    ZStack {
                        if let image = model.qrImage { Image(nsImage: image).interpolation(.none).resizable().scaledToFit() }
                        else { ProgressView("Preparing code…").controlSize(.small) }
                    }.frame(width: 188, height: 188).padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(RelayPalette.line))
                        .accessibilityLabel("Pairing QR code. Copy pairing code is also available.")
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Scan with PairIt").font(.system(size: 17, weight: .semibold))
                        Text("Keep both devices on the same Wi-Fi. On your phone, choose Scan QR code.")
                            .font(.system(size: 12)).foregroundStyle(RelayPalette.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Link(destination: URL(string: "https://pairit.kartikey.xyz/downloads.html#android")!) {
                                HStack(spacing: 5) { AndroidDownloadMark().frame(width: 14, height: 14); Text("Android") }
                                    .font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity, minHeight: 34)
                                    .background(Color.white, in: RoundedRectangle(cornerRadius: 9))
                                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(RelayPalette.line))
                            }
                            Link(destination: URL(string: "https://pairit.kartikey.xyz/downloads.html#iphone")!) {
                                Label("iPhone", systemImage: "apple.logo").font(.system(size: 11, weight: .medium))
                                    .frame(maxWidth: .infinity, minHeight: 34)
                                    .background(Color.white, in: RoundedRectangle(cornerRadius: 9))
                                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(RelayPalette.line))
                            }
                        }.buttonStyle(.plain).tint(RelayPalette.ink)
                        Button(action: model.copyCode) {
                            Label(model.copied ? "Copied" : "Copy pairing code", systemImage: model.copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity, minHeight: 36)
                                .foregroundStyle(.white).background(RelayPalette.ink, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(RelayControlButtonStyle()).disabled(model.pairingCode.isEmpty)
                        Text(model.copied ? "Paste it into PairIt on your phone." : "Keep this code private.")
                            .font(.system(size: 10)).foregroundStyle(RelayPalette.secondary).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var sharedListening: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.computerOutput ? "\(model.receiverCount + model.parkedCount) connected · Mac speakers selected" : "\(model.receiverCount) listening · \(model.parkedCount) paused · Up to 4 phones").font(.system(size: 13, weight: .medium))
            Text("Output selection applies to everyone. Switching to Mac speakers keeps phones paired; paused listeners resume from their own phones.").font(.system(size: 12)).foregroundStyle(RelayPalette.secondary)
            VStack(alignment: .leading, spacing: 14) {
                Label("Each listener connects headphones to their own phone.", systemImage: "headphones")
                Label("Keep every phone on the same Wi-Fi as this Mac.", systemImage: "wifi")
                Label("Pair each phone, then choose Start audio.", systemImage: "qrcode")
            }.font(.system(size: 13)).padding(18).frost()
            Button { model.navigate(to: 1) } label: { Text(model.receiverCount + model.parkedCount >= 4 ? "Four listeners connected" : "Pair another phone").frame(maxWidth: .infinity) }
                .buttonStyle(RelayPrimaryButtonStyle()).disabled(model.receiverCount + model.parkedCount >= 4)
            Text("Headphone delays can vary. The first listener controls video timing.").font(.system(size: 11)).foregroundStyle(RelayPalette.secondary)
        }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 0) {
                if model.outputInstalled {
                    HStack(spacing: 14) {
                        Image(systemName: "speaker.wave.2").foregroundStyle(RelayPalette.blue).frame(width: 28, height: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Audio output").font(.body.weight(.medium))
                            Text(model.volumeControlsInstalled ? "Installed · volume keys ready" : "Update available for volume keys").font(.footnote).foregroundStyle(RelayPalette.secondary)
                        }
                        Spacer(); Image(systemName: "checkmark").foregroundStyle(RelayPalette.secondary)
                    }.padding(.vertical, 12)
                } else { RelaySettingRow(icon: "speaker.wave.2", title: "Audio output", detail: "Setup required", action: model.installOutput) }
                if model.outputInstalled && !model.volumeControlsInstalled {
                    RelaySettingRow(icon: "arrow.down.circle", title: "Update audio output", detail: "Enable Mac volume and mute keys", action: model.installOutput)
                }
                Divider().opacity(0.4)
                RelaySettingRow(icon: "lock.shield", title: "Audio permission", detail: "Manage in System Settings", action: model.openPermissions)
                Divider().opacity(0.4)
                RelaySettingRow(icon: "qrcode", title: "Pair a phone") { model.navigate(to: 1) }
                Divider().opacity(0.4)
                RelaySettingRow(icon: "arrow.clockwise", title: "Check for updates", detail: "Download, verify and install in PairIt") { installerUpdates.downloadAndInstall() }
                    .disabled(!installerUpdates.canCheck)
            }
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 10) {
                Text("PHONE MICROPHONE").font(.system(size: 10, weight: .medium)).tracking(0.8).foregroundStyle(RelayPalette.secondary)
                Text("Use your phone as a microphone for this Mac.").font(.system(size: 12))
                if model.microphoneDestinations.isEmpty {
                    Text("Install a compatible virtual audio cable first. PairIt will never send microphone audio to your speakers.").font(.system(size: 11)).foregroundStyle(RelayPalette.secondary)
                } else {
                    Picker("Virtual cable", selection: Binding(get: { model.microphoneUID }, set: model.selectMicrophone)) {
                        Text("Choose a cable").tag("")
                        ForEach(model.microphoneDestinations) { Text($0.name).tag($0.id) }
                    }.font(.system(size: 11))
                    Toggle("Allow phone microphone", isOn: Binding(get: { model.microphoneEnabled }, set: model.enableMicrophone))
                        .font(.system(size: 12)).disabled(!model.sharing || model.microphoneUID.isEmpty)
                }
                Text("Disconnect listening phones before enabling. Then select the cable as your calling app’s input. Nothing records until you start it on the phone.")
                    .font(.system(size: 10)).foregroundStyle(RelayPalette.secondary)
            }
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 12) {
                Text("LOCAL CONNECTION").font(.system(size: 10, weight: .medium)).tracking(0.8).foregroundStyle(RelayPalette.secondary)
                LabeledContent("Mac", value: model.macName)
                Picker("Pairing address", selection: $model.address) {
                    ForEach(model.addresses) { address in Text("\(address.host) · \(address.interface)").tag(address.host) }
                }.onChange(of: model.address) { model.changeAddress() }
                Text("Use the same local Wi-Fi on every device. If discovery is unavailable, choose a reachable address here and enter it in the phone’s Connection settings.")
                    .foregroundStyle(RelayPalette.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Up to four phones can listen. Only the primary phone controls Mac video timing; different outputs may be audible at different times.")
                    .foregroundStyle(RelayPalette.secondary).fixedSize(horizontal: false, vertical: true)
                Text(model.detail).foregroundStyle(RelayPalette.secondary).fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 12))
            phoneDownloads
            Text("Audio travels directly between your devices. No accounts, cloud audio servers or analytics.")
                .font(.system(size: 11)).foregroundStyle(RelayPalette.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("PairIt - AudioRelay 1.1").foregroundStyle(RelayPalette.secondary)
                Spacer(); Button(action: model.quit) { Text("Quit").frame(minWidth: 32, minHeight: 28) }.buttonStyle(RelayControlButtonStyle(scales: false))
            }.font(.system(size: 11))
        }
    }
}

private struct AndroidDownloadMark: View {
    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 14, y: size.height / 14)
            var head = Path()
            head.move(to: CGPoint(x: 2, y: 10)); head.addCurve(to: CGPoint(x: 12, y: 10), control1: CGPoint(x: 2, y: 2), control2: CGPoint(x: 12, y: 2)); head.closeSubpath()
            context.fill(head, with: .color(RelayPalette.ink))
            var antenna = Path()
            antenna.move(to: CGPoint(x: 4, y: 5)); antenna.addLine(to: CGPoint(x: 2, y: 2))
            antenna.move(to: CGPoint(x: 10, y: 5)); antenna.addLine(to: CGPoint(x: 12, y: 2))
            context.stroke(antenna, with: .color(RelayPalette.ink), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            for x in [4.3, 8.3] { context.fill(Path(ellipseIn: CGRect(x: x, y: 7, width: 1.4, height: 1.4)), with: .color(.white)) }
        }.accessibilityHidden(true)
    }
}
