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
    @Published var connected = false
    @Published var outputInstalled = SyncOutput.installed
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
    @Published var receiverDetail = "No active listeners"
    let macName = Host.current().localizedName ?? "This Mac"
    private var history = [0]
    private var copyReset: DispatchWorkItem?
    private var feedbackReset: DispatchWorkItem?
    private let qrQueue = DispatchQueue(label: "relay.pairing.image", qos: .userInitiated)
    var toggleSharing: () -> Void = {}
    var retrySharing: () -> Void = {}
    var installOutput: () -> Void = {}
    var openPermissions: () -> Void = {}
    var quit: () -> Void = {}
    var changeAddress: () -> Void = {}
    var needsAudioPermission: Bool { detail.hasPrefix("Capture failed") }
    var connectionFailed: Bool { detail.hasPrefix("Couldn’t start") || network.hasPrefix("Wi-Fi unavailable") }

    func navigate(to destination: Int) {
        guard page != destination else { return }
        if let index = history.firstIndex(of: destination) {
            history = Array(history.prefix(index + 1)); forward = false
        } else { history.append(destination); forward = true }
        withAnimation(RelayMotion.navigation) { page = destination }
    }
    func back() {
        guard history.count > 1 else { return }
        history.removeLast(); forward = false
        withAnimation(RelayMotion.navigation) { page = history.last ?? 0 }
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
        withAnimation(RelayMotion.navigation) { feedback = Feedback(message: message, isError: isError) }
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
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        ZStack(alignment: .bottom) {
            RelayBackdrop()
            VStack(spacing: 0) {
                header
                ZStack {
                    Group {
                        if model.page == 0 { ScrollView { overview } }
                        else { ScrollView { Group { if model.page == 1 { pairing } else if model.page == 3 { sharedListening } else { settings } }.padding(28).padding(.top, 2) } }
                    }.id(model.page).transition(pageTransition)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            }
            if let feedback = model.feedback {
                HStack(spacing: 10) {
                    Image(systemName: feedback.isError ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(feedback.isError ? Color(red: 0.64, green: 0.30, blue: 0.12) : RelayPalette.blue)
                    Text(feedback.message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(action: model.dismissFeedback) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 44, height: 44) }
                        .buttonStyle(RelayControlButtonStyle()).accessibilityLabel("Dismiss message")
                }.padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.8)))
                    .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
                    .padding(16).transition(.opacity).zIndex(2)
            }
        }.foregroundStyle(RelayPalette.ink).preferredColorScheme(.light)
            .frame(width: 400, height: 560)
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
            Button { model.navigate(to: 2) } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44).frost(12) }
                .buttonStyle(RelayControlButtonStyle()).help("Settings").accessibilityLabel("Settings")
                .opacity(model.page == 2 ? 0 : 1).disabled(model.page == 2).accessibilityHidden(model.page == 2)
        }.padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 8)
    }
    private var stateTitle: String {
        if model.sharingAction == .starting { return "Starting sharing" }
        if model.sharingAction == .pausing { return "Pausing sharing" }
        if model.outputHeld { return "Mac output held" }
        return model.needsAudioPermission ? "Allow Mac audio" : model.connectionFailed ? "Connection unavailable" : model.connected ? "\(model.receiverCount) \(model.receiverCount == 1 ? "phone" : "phones") connected" : !model.outputInstalled ? "Set up Mac audio" : model.sharing ? "Ready to connect" : "Sharing paused"
    }
    private var stateDetail: String {
        if model.sharingAction == .starting { return "Making your Mac available on local Wi-Fi." }
        if model.sharingAction == .pausing { return "Returning audio to your Mac’s usual output." }
        if model.outputHeld { return (model.detail.hasPrefix("Phone unavailable") ? "Phone unavailable. " : "") + "Resume in PairIt on your phone. Media may still be playing silently; pause it in the player if needed." }
        if model.receiverCount > 1 || model.parkedCount > 0 { return model.receiverDetail }
        return model.needsAudioPermission ? "Allow audio recording in System Settings, then reconnect your phone." : model.connectionFailed ? "Check your local network, then try sharing again." : model.connected ? "Audio plays through your phone. Adjust volume on the phone or headphones." : !model.outputInstalled ? "A one-time setup keeps video and sound in sync." : model.sharing ? "Pair your phone to listen through its headphones." : "Make this Mac available to your phone again."
    }
    private var primaryTitle: String {
        if model.sharingAction == .starting { return "Starting…" }
        if model.sharingAction == .pausing { return "Pausing…" }
        if model.outputHeld { return "Use Mac speakers" }
        return model.needsAudioPermission ? "Open audio permissions" : model.connectionFailed ? "Try again" : !model.outputInstalled ? "Set up audio" : !model.sharing ? "Resume sharing" : model.connected ? "Pause sharing" : "Pair a phone"
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            RelayStatusPill(title: stateTitle.uppercased(), active: model.connected, busy: model.sharingAction != nil).padding(.top, 16)
            Text(model.sharing && !model.needsAudioPermission && !model.connectionFailed && model.outputInstalled && model.sharingAction == nil
                 ? (model.outputHeld ? "Your phone.\nYour next move." : model.connected ? "Connected.\nKeep listening." : "Your Mac.\nAnywhere you listen.") : stateTitle)
                .font(RelayTypography.display(28)).tracking(-0.6).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            Text(stateDetail).font(.system(size: 13)).foregroundStyle(RelayPalette.secondary)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            Color.clear.frame(height: 18)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "desktopcomputer").font(.system(size: 22, weight: .light)).frame(width: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.macName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(model.sharingAction != nil ? "Updating sharing…" : model.connectionFailed ? "Connection needs attention" : model.sharing ? "Available on local Wi-Fi" : "Sharing is off")
                            .font(.system(size: 11)).foregroundStyle(RelayPalette.secondary)
                    }
                    Spacer(minLength: 4)
                    Circle().fill(model.sharing && !model.connectionFailed ? Color(red: 0.16, green: 0.55, blue: 0.43) : RelayPalette.secondary.opacity(0.4)).frame(width: 6, height: 6)
                }.padding(.vertical, 15)
                Divider().opacity(0.4)
                HStack(spacing: 12) {
                    Image(systemName: "waveform.path").font(.system(size: 18)).frame(width: 32)
                    Text("Video sync").font(.system(size: 13)); Spacer()
                    Text(model.outputInstalled ? model.receiverCount > 1 ? "Primary phone" : "Automatic" : "Setup needed").font(.system(size: 12)).foregroundStyle(RelayPalette.secondary)
                }.padding(.vertical, 14)
            }.padding(.horizontal, 16).frost(18)
            Button(action: primaryAction) {
                HStack(spacing: 8) {
                    if model.sharingAction != nil { ProgressView().controlSize(.small).tint(.white).accessibilityHidden(true) }
                    Text(primaryTitle); Spacer(); Image(systemName: "arrow.up.right")
                }.frame(height: 18)
            }.buttonStyle(RelayPrimaryButtonStyle()).disabled(model.sharingAction != nil).padding(.top, 18)
            Button { model.navigate(to: 3) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.2").foregroundStyle(RelayPalette.secondary)
                    Text("Listen together"); Spacer()
                    Text("\(model.receiverCount + model.parkedCount)/4").foregroundStyle(RelayPalette.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 10))
                }.font(.system(size: 12)).padding(14).frost(14)
            }.buttonStyle(RelayControlButtonStyle()).padding(.top, 14)
            HStack {
                if model.connected { Button { model.navigate(to: 1) } label: { Text("Pair another phone").frame(height: 32) } }
                else if model.sharing {
                    Button(action: model.toggleSharing) { Text(model.sharingAction == .pausing ? "Pausing…" : "Pause sharing").frame(height: 32) }
                        .disabled(model.sharingAction != nil)
                }
                Spacer()
                Label("Local & encrypted", systemImage: "lock").font(.system(size: 10))
            }.buttonStyle(RelayControlButtonStyle(scales: false)).font(.system(size: 11)).foregroundStyle(RelayPalette.secondary).frame(height: 42)
        }.padding(.horizontal, 26).padding(.bottom, 18)
    }
    private func primaryAction() {
        if model.needsAudioPermission { model.openPermissions() }
        else if model.connectionFailed { model.retrySharing() }
        else if !model.outputInstalled { model.installOutput() }
        else if !model.sharing || model.connected || model.outputHeld { model.toggleSharing() }
        else { model.navigate(to: 1) }
    }
    private var pairing: some View {
        VStack(spacing: 18) {
            Text("Make the connection.").font(RelayTypography.display(25)).tracking(-0.5)
            Text("Keep your phone and Mac on the same Wi-Fi.").font(.system(size: 12)).foregroundStyle(RelayPalette.secondary).multilineTextAlignment(.center)
            if !model.sharing || model.sharingAction != nil || model.connectionFailed {
                Image(systemName: "wifi.slash").font(.system(size: 40, weight: .light)).padding(28)
                Button(model.sharingAction != nil ? "Starting…" : model.connectionFailed ? "Try again" : "Resume sharing") {
                    if model.connectionFailed { model.retrySharing() } else { model.toggleSharing() }
                }.buttonStyle(RelayPrimaryButtonStyle()).disabled(model.sharingAction != nil)
            } else {
                ZStack {
                    if let image = model.qrImage { Image(nsImage: image).interpolation(.none).resizable().scaledToFit() }
                    else { ProgressView("Preparing code…").controlSize(.small) }
                }.frame(width: 184, height: 184).padding(14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(RelayPalette.ink.opacity(0.06)))
                    .accessibilityLabel("Pairing QR code. Copy pairing code is also available.")
                Text("Open PairIt on Android or iPhone and choose Scan QR code.")
                    .font(.system(size: 12)).foregroundStyle(RelayPalette.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: model.copyCode) {
                    Label(model.copied ? "Copied" : "Copy pairing code", systemImage: model.copied ? "checkmark" : "doc.on.doc")
                        .frame(width: 180).contentTransition(.opacity)
                }.buttonStyle(RelayQuietButtonStyle()).disabled(model.pairingCode.isEmpty)
                Text(model.copied ? "Paste it into PairIt on your phone." : "Keep this code private.")
                    .font(.system(size: 10)).foregroundStyle(RelayPalette.secondary).frame(height: 14)
            }
        }.frame(maxWidth: .infinity)
    }
    private var sharedListening: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Same audio.\nMore company.").font(RelayTypography.display(26))
            Text("\(model.receiverCount) listening · \(model.parkedCount) paused · Up to 4 phones").font(.system(size: 13, weight: .medium))
            VStack(alignment: .leading, spacing: 14) {
                Label("Each listener connects headphones to their own phone.", systemImage: "headphones")
                Label("Keep every phone on the same Wi-Fi as this Mac.", systemImage: "wifi")
                Label("Pair each phone, then choose Computer on each one.", systemImage: "qrcode")
            }.font(.system(size: 13)).padding(18).frost()
            Button { model.navigate(to: 1) } label: { Text(model.receiverCount + model.parkedCount >= 4 ? "Four listeners connected" : "Pair another phone").frame(maxWidth: .infinity) }
                .buttonStyle(RelayPrimaryButtonStyle()).disabled(model.receiverCount + model.parkedCount >= 4)
            Text("Each listener controls their own volume and pause. Their headphones stay connected to their phone.").font(.system(size: 12)).foregroundStyle(RelayPalette.secondary)
            Text("Different headphones can have different delays. Only the primary listener controls Mac video timing; this is not guaranteed acoustic synchronization.").font(.system(size: 11)).foregroundStyle(RelayPalette.secondary)
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
                            Text("Installed").font(.footnote).foregroundStyle(RelayPalette.secondary)
                        }
                        Spacer(); Image(systemName: "checkmark").foregroundStyle(RelayPalette.secondary)
                    }.padding(.vertical, 12)
                } else { RelaySettingRow(icon: "speaker.wave.2", title: "Audio output", detail: "Setup required", action: model.installOutput) }
                Divider().opacity(0.4)
                RelaySettingRow(icon: "lock.shield", title: "Audio permission", detail: "Manage in System Settings", action: model.openPermissions)
                Divider().opacity(0.4)
                RelaySettingRow(icon: "qrcode", title: "Pair a phone") { model.navigate(to: 1) }
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
            Text("Audio travels directly between your devices. No accounts, cloud audio servers or analytics.")
                .font(.system(size: 11)).foregroundStyle(RelayPalette.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("PairIt 1.1 · Audio relay").foregroundStyle(RelayPalette.secondary)
                Spacer(); Button(action: model.quit) { Text("Quit").frame(minWidth: 32, minHeight: 28) }.buttonStyle(RelayControlButtonStyle(scales: false))
            }.font(.system(size: 11))
        }
    }
}
