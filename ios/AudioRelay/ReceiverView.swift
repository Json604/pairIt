import SwiftUI
import AVKit

struct ReceiverView: View {
    @ObservedObject var receiver: RelayReceiver
    @ObservedObject var pairing: PairingStore
    @StateObject private var updates = ReleaseUpdates()
    @EnvironmentObject private var ads: BannerAds
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: ReceiverSheet?
    @State private var incomingCode = ""
    @State private var request: SourceAction?
    @State private var selectionCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduced
    private enum SourceAction { case mac, phone, disconnect }
    init(receiver: RelayReceiver, pairing: PairingStore) {
        self.receiver = receiver; self.pairing = pairing
    }
    private var connecting: Bool { [.connecting, .buffering, .reconnecting].contains(receiver.phase) || request == .mac }
    private var preview: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--preview-connected")
        #else
        return false
        #endif
    }
    var body: some View {
        ZStack {
            RelayBackdrop()
            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        RelayBrand(); Spacer()
                        Button { sheet = .settings } label: {
                            Image(systemName: "slider.horizontal.3").font(.system(size: 19)).frame(width: 44, height: 44)
                        }.frost(14).buttonStyle(RelayControlButtonStyle()).accessibilityLabel("Settings")
                    }.padding(.bottom, 30)
                    ReleaseUpdateNotice(updates: updates).padding(.bottom, updates.available == nil ? 0 : 16)
                    RelayStatusPill(title: pairing.mac == nil && !preview ? "LET’S GET CONNECTED" : status, active: receiver.phase == .playing, busy: connecting || request != nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(alignment: .center, spacing: 12) {
                        Text(pairing.mac == nil && !preview ? "Your sound.\nYour space." : receiver.title)
                            .font(RelayTypography.display(32)).tracking(-0.8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                    }.padding(.top, 8)
                    Text(pairing.mac == nil && !preview ? "Open PairIt on your computer, then pair this iPhone to get started." : receiver.detail)
                        .font(.system(.subheadline)).foregroundStyle(RelayPalette.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.top, 12)
                    if pairing.mac != nil || preview { sourceCard.padding(.top, 24) }
                    else { onboarding.padding(.top, 24) }
                    if receiver.phase == .headphones {
                        HStack(spacing: 12) {
                            Text("Choose your audio output").font(.subheadline)
                            Spacer(); AudioRoutePicker().frame(width: 44, height: 44)
                        }.padding(.horizontal, 20).frost(20).padding(.top, 14)
                    }
                    RelaySettingRow(icon: "person.2", title: "Listen together", detail: "Same computer. Up to four listeners.") { sheet = .shared }
                        .padding(.horizontal, 4).padding(.top, 18)
                    if receiver.phase != .idle {
                        Button { perform(.disconnect) } label: {
                            Text(request == .disconnect ? "Disconnecting…" : "Disconnect").frame(minHeight: 48)
                        }.buttonStyle(RelayControlButtonStyle(scales: false)).font(.subheadline).foregroundStyle(RelayPalette.secondary)
                            .disabled(request != nil).padding(.top, 8)
                    }
                    Label("Local & encrypted", systemImage: "lock")
                        .font(.system(size: 11)).foregroundStyle(RelayPalette.secondary).padding(.top, 18).padding(.bottom, 12)
                }.padding(.horizontal, 24).padding(.top, 10).frame(maxWidth: 500).frame(maxWidth: .infinity)
            }.scrollIndicators(.hidden)
        }.foregroundStyle(RelayPalette.ink)
            .safeAreaInset(edge: .bottom, spacing: 8) {
                BannerAdSlot(ads: ads, active: scenePhase == .active && sheet == nil && !ads.fullscreenActive)
            }
            .onReceive(Timer.publish(every: 900, on: .main, in: .common).autoconnect()) { _ in if scenePhase == .active { updates.check() } }
            .onAppear { updates.check() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { updates.check() } }
            .sensoryFeedback(.selection, trigger: selectionCount)
            .onReceive(receiver.$phase) { _ in request = nil }
            .sheet(item: $sheet) { value in
                switch value {
                case .pair: PairingView(receiver: receiver, pairing: pairing, initialCode: incomingCode)
                case .settings: ReceiverSettings(receiver: receiver, pairing: pairing)
                case .sync: VideoSyncView(receiver: receiver)
                case .address: ComputerAddressView(receiver: receiver, pairing: pairing)
                case .shared: SharedListeningView()
                }
            }
            .onOpenURL { url in
                guard url.scheme == "audiorelay" else { return }
                // Keep the SDK's presenting sheet alive until its dismissal callback.
                // Do not replay a shortcut later without another explicit user action.
                guard !AudioPresentationGate.isPresenting else {
                    if url.host == "listen" { receiver.connect() }
                    return
                }
                switch url.host {
                case "pair": incomingCode = url.absoluteString; sheet = .pair
                case "listen":
                    if pairing.mac == nil { incomingCode = ""; sheet = .pair }
                    else { sheet = nil; receiver.connect() }
                case "phone": sheet = nil; receiver.usePhone()
                default: break
                }
            }
    }
    private var status: String {
        if request == .disconnect { return "DISCONNECTING" }
        if request == .phone { return "SWITCHING TO IPHONE" }
        if request == .mac { return "CONNECTING" }
        switch receiver.phase {
        case .playing: return "CONNECTED"
        case .paused: return "PAUSED"
        case .connecting: return "CONNECTING"
        case .buffering: return "GETTING READY"
        case .reconnecting: return "RECONNECTING"
        case .phone: return "PHONE"
        case .headphones: return "CHOOSE OUTPUT"
        case .error: return "LET’S RECONNECT"
        case .idle: return "READY"
        }
    }
    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("LISTEN FROM").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(RelayPalette.secondary)
            HStack(spacing: 10) {
                source("Computer", icon: "desktopcomputer", selected: receiver.phase.macSelected, busy: connecting) { perform(.mac) }
                source("iPhone", icon: "iphone", selected: receiver.phase == .phone, busy: request == .phone) { perform(.phone) }
            }
            Rectangle().fill(RelayPalette.line).frame(height: 1)
            HStack(spacing: 12) {
                Image(systemName: receiver.output.icon).font(.system(size: 22, weight: .light)).foregroundStyle(RelayPalette.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(receiver.phase == .playing ? receiver.headphones : receiver.output.title).font(.system(.subheadline))
                    if receiver.phase == .playing { Text("Secured local network").font(.caption).foregroundStyle(RelayPalette.secondary) }
                }
                Spacer(minLength: 0)
                AudioRoutePicker().frame(width: 44, height: 44).accessibilityLabel("Choose audio output")
            }
            OutputControls(receiver: receiver)
            if receiver.phase.macSelected {
                Button(receiver.phase == .paused ? "Resume audio" : "Pause audio") {
                    if receiver.phase == .paused { receiver.connect() } else { receiver.pauseComputer() }
                }.buttonStyle(RelayQuietButtonStyle()).disabled(connecting)
            }
        }.padding(20).frost()
    }
    private func source(_ name: String, icon: String, selected: Bool, busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Image(systemName: icon).font(.system(size: 19, weight: .regular)).opacity(busy ? 0 : 1)
                    if busy { ProgressView().tint(selected ? .white : RelayPalette.deep).accessibilityHidden(true) }
                }.frame(width: 28, height: 28)
                Text(name).font(.system(.subheadline).weight(.semibold))
            }.frame(maxWidth: .infinity).frame(minHeight: 62)
                .foregroundStyle(selected ? .white : RelayPalette.ink)
                .background {
                    RoundedRectangle(cornerRadius: 13).fill(.white.opacity(0.46))
                    RoundedRectangle(cornerRadius: 13).fill(RelayPalette.ink).opacity(selected ? 1 : 0)
                }
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.7)))
        }.buttonStyle(RelayControlButtonStyle()).accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel("Listen to \(name)")
            .accessibilityValue(busy ? "Connecting" : selected ? "Selected" : "Not selected")
    }
    private func perform(_ action: SourceAction) {
        guard request == nil else { return }
        if action == .mac && receiver.phase.macSelected && receiver.phase != .paused { return }
        if action == .phone && receiver.phase == .phone { return }
        request = action; selectionCount += 1
        // Give the button its requested state before beginning a session action.
        // Actual selection/success still comes from the receiver, never a timer.
        DispatchQueue.main.async {
            switch action {
            case .mac: receiver.connect()
            case .phone: receiver.usePhone()
            case .disconnect: receiver.disconnect()
            }
        }
    }
    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "desktopcomputer").font(.system(size: 28, weight: .light)).frame(width: 52, height: 62)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Computer → iPhone").font(.subheadline.weight(.semibold))
                    Text("One local connection. Your choice of output.").font(.footnote).foregroundStyle(RelayPalette.secondary)
                }
                Spacer(minLength: 0)
            }.padding(16).frost()
            Button { incomingCode = ""; sheet = .pair } label: {
                HStack { Text("Pair your computer"); Spacer(); Image(systemName: "arrow.up.right") }
            }
                .buttonStyle(RelayPrimaryButtonStyle())
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "headphones").foregroundStyle(RelayPalette.blue)
                Text("Listen through your headphones, iPhone speaker or wired audio. PairIt connects directly over your local network.")
                    .font(.subheadline).foregroundStyle(RelayPalette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 8)
    }
}

enum ReceiverSheet: String, Identifiable { case pair, settings, sync, address, shared; var id: String { rawValue } }

struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(); view.tintColor = UIColor(RelayPalette.deep); view.activeTintColor = UIColor(RelayPalette.blue)
        view.prioritizesVideoDevices = false; return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) { }
}

struct VideoSyncView: View {
    @ObservedObject var receiver: RelayReceiver
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack {
                RelayBackdrop()
                ScrollView {
                    VStack(spacing: 22) {
                        Image(systemName: "waveform.path").font(.system(size: 38, weight: .light)).foregroundStyle(RelayPalette.blue).padding(.top, 20)
                        Text("Video sync").font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                        Text(receiver.supportsVideoCompensation ? "Automatic timing uses your selected output. With multiple listeners, only the primary listener controls Mac video timing." : "Windows loopback does not provide system video compensation. Software timing below is an estimate, not a sync guarantee.")
                            .font(.subheadline).foregroundStyle(RelayPalette.secondary).multilineTextAlignment(.center)
                        VStack(spacing: 16) {
                            Text(receiver.estimatedMs.map { "Automatic · \($0) ms" } ?? "Timing appears after you start listening")
                                .font(.subheadline).foregroundStyle(RelayPalette.secondary)
                            Text(String(format: "%+d ms", receiver.correction)).font(.system(size: 38, weight: .medium, design: .rounded)).monospacedDigit()
                            HStack(spacing: 10) {
                                Button("Sound is early") { receiver.adjustCorrection(-10) }.buttonStyle(RelayQuietButtonStyle())
                                Button("Sound is late") { receiver.adjustCorrection(10) }.buttonStyle(RelayQuietButtonStyle())
                            }.disabled(receiver.estimatedMs == nil || !receiver.supportsVideoCompensation)
                            Button(action: receiver.resetCorrection) { Text("Reset correction").frame(minHeight: 44) }
                                .font(.subheadline).buttonStyle(RelayControlButtonStyle(scales: false)).disabled(receiver.correction == 0 || !receiver.supportsVideoCompensation)
                        }.padding(24).frost()
                        Text("Corrections are saved for this output and playback mode. Some Mac video players need to reopen their output after a change. Bluetooth delay still affects games and live audio.")
                            .font(.footnote).foregroundStyle(RelayPalette.secondary)
                    }.padding(24)
                }
            }.navigationTitle("Video sync").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(RelayPalette.deep).foregroundStyle(RelayPalette.ink)
    }
}

struct ReceiverSettings: View {
    @EnvironmentObject private var ads: BannerAds
    @ObservedObject var receiver: RelayReceiver
    @ObservedObject var pairing: PairingStore
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: ReceiverSheet?
    @State private var showDiagnostics = false
    @State private var reportAd = false
    @Environment(\.openURL) private var openURL
    var body: some View {
        NavigationStack {
            ZStack {
                RelayBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(spacing: 0) {
                            RelaySettingRow(icon: "qrcode", title: pairing.mac == nil ? "Connect your computer" : "Pair another computer", detail: pairing.mac?.displayName ?? "Scan a code from the desktop app") { sheet = .pair }
                            Divider()
                            RelaySettingRow(icon: "network", title: "Computer address", detail: pairing.hostOverride ?? "Automatic discovery") { sheet = .address }
                            Divider()
                            RelaySettingRow(icon: "waveform.path", title: "Video sync", detail: "Automatic timing and saved correction") { sheet = .sync }
                            Divider()
                            RelaySettingRow(icon: "list.bullet.rectangle", title: "Diagnostics", detail: "Connection and playback details") { showDiagnostics = true }
                        }.padding(.horizontal, 20).frost()
                        RelaySettingRow(icon: "person.2", title: "Listen together", detail: "Add more listeners") { sheet = .shared }
                        VStack(alignment: .leading, spacing: 13) {
                            Text("How it works").font(.headline)
                            Text("Keep your computer and iPhone on the same local network. Select Bluetooth, iPhone speaker or wired audio, choose that route in the system picker, then tap Computer. Tap iPhone to release audio to your phone apps.")
                            Text("Several phones can listen, with different output delays. Updated Mac companions hold output during phone interruptions or a lost connection. Media may continue silently: pause it in the computer player if needed. Choose Computer here to return, or Use Mac speakers in the Mac app to release it.")
                            Text("Audio keeps playing with the screen locked. Use the Home/Lock Screen widget to switch sources. Headphone play/pause pauses and resumes this iPhone’s live relay without selecting iPhone. Track changes stay in the computer’s player. Volume stays on your iPhone or headphones.")
                        }.font(.subheadline).foregroundStyle(RelayPalette.secondary).padding(22).frost()
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Local by design", systemImage: "lock.shield").font(.headline).foregroundStyle(RelayPalette.ink)
                            Text("Audio is encrypted directly between your devices. There are no cloud audio servers or PairIt accounts. A Google AdMob banner and an eligible post-pairing advertisement support the app. Google may process IP-derived location, device identifiers, ad interactions and diagnostics for advertising, measurement and fraud prevention. Live ad requests require the available consent choices; this build requests non-personalized ads and does not request tracking permission. PairIt does not use your microphone. Pairing credentials stay in Keychain. Camera access only scans pairing codes; no photos are saved. Update checks fetch a public release list from GitHub, which receives normal web-request information such as your IP address. No audio, pairing credentials or device identifier is attached.")
                                .font(.footnote).foregroundStyle(RelayPalette.secondary)
                        }.padding(22).frost()
                        VStack(spacing: 0) {
                            RelaySettingRow(icon: "hand.raised", title: "Ad privacy choices", detail: "Review available advertising consent") { ads.showPrivacyOptions() }
                            Divider()
                            RelaySettingRow(icon: "flag", title: "Report an ad", detail: "Tell us about inappropriate advertising") { reportAd = true }
                            Divider()
                            Toggle("Mute ad sound", isOn: $ads.muted).padding(.vertical, 16)
                            Text("Ad sound starts muted. Advertising never receives your relayed audio or pairing credentials.")
                                .font(.footnote).foregroundStyle(RelayPalette.secondary).padding(.bottom, 16)
                            Link("Privacy policy", destination: URL(string: "https://pairit.kartikey.xyz/privacy.html")!).padding(.bottom, 16)
                        }.padding(.horizontal, 20).frost()
                        Text("PairIt 1.1 · Audio relay & shared listening")
                            .font(.caption).foregroundStyle(RelayPalette.secondary)
                    }.padding(24)
                }
            }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .sheet(item: $sheet) { value in
                    if value == .sync { VideoSyncView(receiver: receiver) }
                    else if value == .address { ComputerAddressView(receiver: receiver, pairing: pairing) }
                    else if value == .shared { SharedListeningView() }
                    else { PairingView(receiver: receiver, pairing: pairing) }
                }
                .sheet(isPresented: $showDiagnostics) {
                    NavigationStack {
                        ScrollView { Text(receiver.diagnostics + "\n\n" + ads.diagnostics).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(24) }
                            .navigationTitle("Diagnostics").navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showDiagnostics = false } } }
                            .safeAreaInset(edge: .bottom) {
                                Button(receiver.phase == .connecting || receiver.phase == .buffering ? "Refreshing…" : "Refresh audio", action: receiver.refreshAudio)
                                    .buttonStyle(RelayQuietButtonStyle()).disabled(receiver.phase != .playing).padding()
                            }
                    }
                }
        }.tint(RelayPalette.deep).foregroundStyle(RelayPalette.ink)
            .alert("Ad privacy choices", isPresented: Binding(get: { ads.privacyMessage != nil }, set: { if !$0 { ads.privacyMessage = nil } })) {
                Button("Done") { ads.privacyMessage = nil }
            } message: { Text(ads.privacyMessage ?? "") }
            .alert("Report an ad", isPresented: $reportAd) {
                Button("Email support") {
                    let subject = "PairIt iPhone — report an ad"
                    let body = "Advertiser or ad text:\nWhen it appeared:\nWhy it is inappropriate:\n\nPlease do not include pairing codes or other private information."
                    var url = URLComponents(); url.scheme = "mailto"; url.path = "kartikey060105@gmail.com"
                    url.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
                    if let destination = url.url { openURL(destination) }
                }
                Button("Copy support email") { UIPasteboard.general.string = "kartikey060105@gmail.com" }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Tell us the advertiser, when it appeared and what was inappropriate. You do not need to tap the ad. Email kartikey060105@gmail.com, or use the ad’s own reporting controls when available.")
            }
    }
}
