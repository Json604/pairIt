import SwiftUI
import AVKit
import MediaPlayer

struct ReceiverView: View {
    @ObservedObject var receiver: RelayReceiver
    @ObservedObject var pairing: PairingStore
    @StateObject private var updates = ReleaseUpdates()
    @EnvironmentObject private var ads: BannerAds
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: ReceiverSheet?
    @StateObject private var nearby = NearbyDevices()
    @AppStorage("soundFeedback") private var soundFeedback = true
    @AppStorage("trustedAutoReconnect") private var autoReconnect = true
    @State private var attemptedPin: String?
    @State private var pairingReady = false
    @State private var confirmationTask: Task<Void, Never>?
    @State private var explicitIntent = 0
    @State private var connectionAdFlow: Int?
    @State private var connectionNotice = ""
    @State private var radialCenter = UnitPoint(x: 0.5, y: 0.65)
    @State private var tab = 0
    @State private var sharingApp = false
    @State private var nearbyRequest: NearbyPairingRequest?
    @State private var requestingPairing = false
    @State private var comparisonCode = ""
    @State private var incomingCode = ""
    @State private var selectionCount = 0
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    private var reduced: Bool { systemReduced }
    init(receiver: RelayReceiver, pairing: PairingStore) {
        self.receiver = receiver; self.pairing = pairing
    }
    private var waitingForAudio: Bool { receiver.phase == .buffering && receiver.title == "Connected · play audio on your computer" }
    private var connecting: Bool { (!waitingForAudio && [.connecting, .buffering, .reconnecting].contains(receiver.phase)) || confirmationTask != nil }
    var body: some View {
        ZStack {
            PhoneBackdrop()
            if tab == 1 || (tab == 0 && !receiver.phase.macSelected && !pairingReady) {
                DiscoveryVisual(center: tab == 1 ? .center : radialCenter, reduceMotion: reduced)
            }
            GeometryReader { geometry in
                ScrollView {
                VStack(spacing: 14) {
                    HStack {
                        HStack(spacing: 7) { PairItMark(tint: .white).frame(width: 24, height: 24); Text("PairIt").font(.system(size: 18, weight: .semibold)) }
                        Spacer()

                    }
                    ReleaseUpdateNotice(updates: updates)
                    if tab == 2 { settingsPage }
                    else {
                        Text(tab == 1 ? "Listen together" : (receiver.phase.macSelected || pairingReady || connecting) ? (pairing.mac?.displayName ?? "Computer") : "Nearby computers")
                            .font(.system(size: 25, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                        if tab == 1 { togetherPage }
                        else if receiver.phase.macSelected || connecting || pairingReady { connectedPage }
                        else { discoveryPage }
                    }
                }.padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 8)
                    .frame(width: geometry.size.width)
                    .frame(minHeight: geometry.size.height)
                    .onPreferenceChange(PhoneAnchorPreference.self) { point in
                        guard geometry.size.width > 0, geometry.size.height > 0 else { return }
                        radialCenter = UnitPoint(x: point.x / geometry.size.width, y: point.y / geometry.size.height)
                    }
                    .coordinateSpace(name: "phoneContent")
                }.scrollIndicators(.hidden)
            }
        }.foregroundStyle(.white)

            .onReceive(nearby.$computers) { computers in
                if let mac = pairing.mac, !computers.contains(where: { $0.pin == mac.pin }), receiver.phase == .idle {
                    attemptedPin = nil; pairingReady = false
                }
                guard autoReconnect, tab == 0, sheet == nil, nearbyRequest == nil, scenePhase == .active, !ads.openingScreen, !AudioPresentationGate.isPresenting,
                      receiver.phase == .idle, let mac = pairing.mac, attemptedPin != mac.pin,
                      let device = computers.first(where: { $0.pin == mac.pin }) else { return }
                confirm(mac, host: pairing.hostOverride ?? device.host)

            }
            .onChange(of: ads.ready) { _, ready in
                if ready { ads.pairingVideo.preload(audioIdle: receiver.audioIdleForAdvertisement); ads.appOpen.prepare() }
            }
            .onChange(of: receiver.phase) { _, phase in
                if phase == .error || phase == .headphones { pairingReady = false; cancelExplicitConnection() }
            }
            .onChange(of: tab) { _, value in if value != 0 { cancelExplicitConnection(); cancelNearbyPairing() }; nearby.showTogether(value == 1 && scenePhase == .active) }
            .sheet(isPresented: $sharingApp) { AppShareSheet() }
            .safeAreaInset(edge: .bottom, spacing: 8) {
                VStack(spacing: 8) {
                    navigation.padding(.horizontal, 16)
                    BannerAdSlot(ads: ads, active: scenePhase == .active && !ads.fullscreenActive)
                }
            }
            .onReceive(Timer.publish(every: 900, on: .main, in: .common).autoconnect()) { _ in if scenePhase == .active { updates.check() } }
            .onAppear {
                updates.check(); nearby.start(); prepareOpeningAds()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--preview-settings") { tab = 2 }
                if ProcessInfo.processInfo.arguments.contains("--preview-together") { tab = 1; nearby.showTogether(true) }
                #endif
            }
            .onDisappear { nearby.stop(); cancelExplicitConnection(); cancelNearbyPairing(); confirmationTask?.cancel() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { if receiver.phase == .idle { attemptedPin = nil }; updates.checkOnForeground(); nearby.start(); nearby.showTogether(tab == 1); prepareOpeningAds() }
                else { ads.appOpen.pause(); nearby.stop(); cancelNearbyPairing(); if !ads.fullscreenActive { cancelExplicitConnection() }; confirmationTask?.cancel() }
            }
            .overlay {
                if ads.openingScreen { ZStack { Color.black.ignoresSafeArea(); Text("PairIt").font(.title.bold()).foregroundStyle(.white) } }
            }
            .alert("Approve on your computer", isPresented: $requestingPairing) {
                Button("Cancel", role: .cancel) { cancelNearbyPairing() }
            } message: {
                Text("Match this code before approving:\n\n" + comparisonCode)
            }
            .sensoryFeedback(.selection, trigger: selectionCount)
            .sheet(item: $sheet) { value in
                Group { switch value {
                case .pair: PairingView(receiver: receiver, pairing: pairing, initialCode: incomingCode)
                case .settings: ReceiverSettings(receiver: receiver, pairing: pairing)
                case .sync: VideoSyncView(receiver: receiver)
                case .address: ComputerAddressView(receiver: receiver, pairing: pairing)
                case .shared: SharedListeningView()
                case .output: PhoneOutputSheet(receiver: receiver)
                } }.preferredColorScheme(.light)
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
    private func cancelNearbyPairing() {
        nearbyRequest?.cancel(); nearbyRequest = nil; requestingPairing = false
    }
    private func requestNearbyPairing(_ device: NearbyDevices.Device) {
        // These companions currently pair new phones through their private QR code.
        guard device.platform == "macos" else { incomingCode = ""; sheet = .pair; return }
        guard let pin = device.pin, let host = device.host, PairedMac.validHost(host),
              scenePhase == .active, !AudioPresentationGate.isPresenting else { return }
        cancelNearbyPairing(); cancelExplicitConnection(); connectionNotice = ""
        do {
            let request = try NearbyPairingRequest(pin: pin)
            nearbyRequest = request; comparisonCode = request.comparison; requestingPairing = true
            request.start(host: host) { token in
                guard nearbyRequest === request else { return }
                nearbyRequest = nil; requestingPairing = false
                guard scenePhase == .active, tab == 0 else { return }
                guard let token else { connectionNotice = "Request not approved. Try again or scan the QR code."; return }
                let computer = PairedMac(host: host, pin: pin, token: token, name: device.name, platform: device.platform, protocolVersion: "2")
                do {
                    try pairing.save(computer); receiver.disconnect()
                    connectExplicitly(computer, host: host)
                } catch { connectionNotice = error.localizedDescription }
            }
        } catch { connectionNotice = "Couldn’t request pairing. Scan the QR code instead." }
    }
    private func cancelExplicitConnection() {
        confirmationTask?.cancel(); confirmationTask = nil
        explicitIntent += 1
        if let flow = connectionAdFlow { ads.pairingVideo.cancelUnshown(flow: flow) }
        connectionAdFlow = nil
    }
    private func connectExplicitly(_ mac: PairedMac, host: String?) {
        guard scenePhase == .active, sheet == nil, !AudioPresentationGate.isPresenting else { return }
        confirmationTask?.cancel(); cancelExplicitConnection(); connectionNotice = ""
        let intent = explicitIntent
        attemptedPin = mac.pin
        let flow = ads.pairingVideo.begin(audioIdle: receiver.audioIdleForAdvertisement)
        connectionAdFlow = flow
        confirmationTask = Task { @MainActor in
            let verified = await PairingConfirmation.confirm(mac, hostOverride: host)
            guard !Task.isCancelled, intent == explicitIntent, scenePhase == .active, pairing.mac?.pin == mac.pin else { return }
            confirmationTask = nil
            guard verified else { connectionNotice = "Computer unavailable. Keep PairIt open on the same Wi-Fi."; cancelExplicitConnection(); return }
            pairingReady = true
            ads.pairingVideo.showAfterConnection(flow: flow, eligible: {
                explicitIntent == intent && scenePhase == .active && tab == 0 && sheet == nil && receiver.audioIdleForAdvertisement
            }) {
                guard explicitIntent == intent, scenePhase == .active, tab == 0, sheet == nil, pairing.mac?.pin == mac.pin else { return }
                connectionAdFlow = nil; receiver.connect()
            }
        }
    }
    private func confirm(_ mac: PairedMac, host: String?) {
        guard confirmationTask == nil, scenePhase == .active, sheet == nil, !AudioPresentationGate.isPresenting else { return }
        attemptedPin = mac.pin
        let intent = explicitIntent
        confirmationTask = Task { @MainActor in
            let confirmed = await PairingConfirmation.confirm(mac, hostOverride: host)
            guard !Task.isCancelled, intent == explicitIntent else { return }
            confirmationTask = nil
            guard scenePhase == .active, sheet == nil, pairing.mac?.pin == mac.pin, !AudioPresentationGate.isPresenting else { return }
            pairingReady = confirmed
        }
    }
    private var navigation: some View {
        GeometryReader { geometry in
            let width = (geometry.size.width - 22) / 3
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.06))
                Capsule().fill(Color(white: 0.94)).frame(width: width, height: 62)
                    .offset(x: 7 + CGFloat(tab) * (width + 4))
                    .animation(reduced ? nil : .spring(response: 0.65, dampingFraction: 0.85), value: tab)
                HStack(spacing: 4) {
                    ForEach(0..<3) { index in
                        Button { tab = index; selectionCount += 1 } label: {
                            VStack(spacing: 5) {
                                Image(systemName: ["headphones", "person.2", "slider.horizontal.3"][index]).font(.system(size: 19))
                                Text(["Connect", "Together", "Settings"][index]).font(.caption)
                            }.frame(maxWidth: .infinity, minHeight: 62)
                                .foregroundStyle(tab == index ? Color.black : Color(white: 0.7))
                        }.buttonStyle(RelayControlButtonStyle()).accessibilityAddTraits(tab == index ? .isSelected : [])
                    }
                }.padding(7)
            }.clipShape(Capsule())
        }.frame(height: 76)
    }
    private var discoveryPage: some View {
        VStack(spacing: 12) {
            if !connectionNotice.isEmpty { Text(connectionNotice).font(.caption) }
            if receiver.phase == .error || receiver.phase == .headphones {
                HStack {
                    Text(receiver.detail).font(.caption).fixedSize(horizontal: false, vertical: true)
                    if receiver.phase == .headphones { AudioRoutePicker().frame(width: 44, height: 44).background(.white, in: Circle()) }
                }
            }
            Text(nearby.computers.isEmpty ? "Open PairIt on your computer on the same Wi-Fi." : "Tap a computer to connect.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.75)).frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 5)
            if nearby.computers.isEmpty {
                Image(systemName: "laptopcomputer").font(.system(size: 40, weight: .light))
                Text("Looking for computers…").font(.subheadline)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: nearby.computers.count == 1 ? 1 : 2), spacing: 18) {
                    ForEach(Array(nearby.computers.prefix(6))) { device in
                        Button {
                            if let mac = pairing.mac, device.pin == mac.pin { connectExplicitly(mac, host: pairing.hostOverride ?? device.host) }
                            else { requestNearbyPairing(device) }
                        } label: {
                            VStack(spacing: 6) {
                                LaptopGlyph().stroke(Color(white: 0.15), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)).frame(width: 26, height: 26)
                                    .frame(width: 100, height: 100).background(NearbyPresence())
                                Text(device.name).font(.caption.bold()).lineLimit(1)
                                Text(device.pin == pairing.mac?.pin ? "Paired" : (["macos": "macOS", "windows": "Windows", "linux": "Linux"][device.platform] ?? "Computer")).font(.caption2).foregroundStyle(.white.opacity(0.7))
                            }
                        }.buttonStyle(RelayControlButtonStyle())
                    }
                }
            }
            Spacer(minLength: 5)
            VStack(spacing: 5) {
                Image(systemName: "iphone").font(.title2).frame(width: 46, height: 46)
                    .background(.white.opacity(0.08), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.3)))
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: PhoneAnchorPreference.self, value: CGPoint(x: proxy.frame(in: .named("phoneContent")).midX, y: proxy.frame(in: .named("phoneContent")).midY))
                    })
                Text("You").font(.caption)
            }
            if !nearby.computers.isEmpty {
                Text("\(nearby.computers.count) \(nearby.computers.count == 1 ? "computer" : "computers") nearby · same Wi-Fi").font(.caption)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "qrcode.viewfinder").font(.system(size: 22)).frame(width: 40, height: 40)
                        .background(Color(white: 0.93), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("QR pairing").font(.system(size: 16, weight: .semibold))
                        Text("Scan the code on your computer.").font(.system(size: 11)).foregroundStyle(RelayPalette.secondary)
                    }
                }
                Button { incomingCode = ""; sheet = .pair } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }.buttonStyle(RelayPrimaryButtonStyle())
                if let mac = pairing.mac {
                    Button("Connect to \(mac.displayName)") { connectExplicitly(mac, host: pairing.hostOverride) }.font(.caption).frame(maxWidth: .infinity, minHeight: 30)
                }
            }.padding(18).foregroundStyle(RelayPalette.ink).frost(26)
        }
    }
    private var connectedPage: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            if connecting { ProgressView().tint(.white).scaleEffect(1.3).frame(height: 110) }
            else { ListeningVisual(playing: receiver.phase == .playing, computer: receiver.computerOutput, reduceMotion: reduced) }
            Text(connecting ? "Connecting…" : receiver.phase == .playing ? "Listening through your phone" : receiver.phase == .computerOutput ? "Playing on computer" : pairingReady && receiver.phase == .idle ? "Paired" : receiver.title)
                .font(.subheadline).multilineTextAlignment(.center)
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                if receiver.supportsOutputControl {
                    HStack(spacing: 4) {
                        playbackDestination("This phone", icon: "iphone", computer: false)
                        playbackDestination("Computer", icon: "laptopcomputer", computer: true)
                    }.padding(5).background(Color(white: 0.92), in: RoundedRectangle(cornerRadius: 17)).clipShape(RoundedRectangle(cornerRadius: 17))
                }
                if !receiver.computerOutput {
                    Button { sheet = .output } label: {
                        HStack(spacing: 10) {
                            Image(systemName: receiver.output.icon).frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(receiver.currentOutputName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(receiver.output.title).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(); Image(systemName: "chevron.right").font(.system(size: 12))
                        }.padding(.horizontal, 12).frame(minHeight: 58)
                            .background(.white, in: RoundedRectangle(cornerRadius: 13))
                            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color(white: 0.86)))
                    }.buttonStyle(.plain).foregroundStyle(.black)
                }
                Group {
                    Button {
                        if receiver.phase == .playing || waitingForAudio { receiver.pauseComputer() }
                        else if receiver.phase == .idle, let mac = pairing.mac { connectExplicitly(mac, host: pairing.hostOverride) }
                        else { receiver.connect() }
                    } label: {
                        HStack(spacing: 10) {
                            if connecting { ProgressView().tint(.white) }
                            Text(connecting ? "Starting…" : receiver.phase == .playing || waitingForAudio ? "Pause audio" : "Start audio")
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(RelayPrimaryButtonStyle()).disabled(connecting)
                }.opacity(receiver.computerOutput ? 0 : 1).allowsHitTesting(!receiver.computerOutput).accessibilityHidden(receiver.computerOutput)
                SystemVolumeControl().frame(height: 26).accessibilityLabel("Phone volume")
                    .opacity(receiver.computerOutput ? 0 : 1).allowsHitTesting(!receiver.computerOutput).accessibilityHidden(receiver.computerOutput)
                HStack {
                    Button(action: receiver.refreshAudio) {
                        Text("Refresh audio").padding(.horizontal, 12).frame(height: 44)
                            .background(Color(white: 0.92), in: RoundedRectangle(cornerRadius: 12))
                    }.disabled(receiver.phase != .playing || receiver.computerOutput)
                    Spacer(minLength: 12)
                    Button { pairingReady = false; receiver.disconnect() } label: {
                        Text("Disconnect").padding(.horizontal, 12).frame(height: 44)
                            .background(Color(white: 0.92), in: RoundedRectangle(cornerRadius: 12))
                    }
                }.font(.caption).frame(minHeight: 44).buttonStyle(RelayControlButtonStyle(scales: false))
            }.padding(18).foregroundStyle(RelayPalette.ink).frost(26)
        }
    }
    private func prepareOpeningAds() {
        ads.pairingVideo.preload(audioIdle: receiver.audioIdleForAdvertisement)
        ads.appOpen.prepare()
        ads.appOpen.open { receiver.audioIdleForAdvertisement && sheet == nil && !sharingApp && confirmationTask == nil && nearbyRequest == nil }
    }
    private func playbackDestination(_ title: String, icon: String, computer: Bool) -> some View {
        let selected = receiver.computerOutput == computer
        return Button { if computer { receiver.listenOnComputer() } else { receiver.connect() } } label: {
            Label(title, systemImage: icon).font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(selected ? Color.white : Color(white: 0.4))
                .background(selected ? Color(white: 0.06) : .clear, in: RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(RelayControlButtonStyle(scales: false)).animation(reduced ? nil : .easeOut(duration: 0.18), value: selected)
    }
    private var togetherPage: some View {
        VStack(spacing: 14) {
            Text("Nearby phones with PairIt open here.").font(.subheadline).foregroundStyle(.white.opacity(0.75)).frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            if nearby.phones.isEmpty {
                Image(systemName: "person.2").font(.system(size: 40, weight: .light))
                Text("No phones nearby yet").font(.subheadline)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                    ForEach(Array(nearby.phones.prefix(6))) { phone in
                        Button { sharingApp = true } label: {
                            VStack { Image(systemName: "iphone").font(.title).frame(width: 100, height: 100).background(NearbyPresence()).foregroundStyle(.black); Text(phone.name).font(.caption).lineLimit(1) }
                        }.buttonStyle(RelayControlButtonStyle())
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 10) {
                Text("Invite a listener").font(.headline)
                Text("Share PairIt, then scan the same computer’s code. Up to four phones.").font(.caption).foregroundStyle(RelayPalette.secondary)
                Button { sharingApp = true } label: { Label("Share app", systemImage: "square.and.arrow.up") }.buttonStyle(RelayPrimaryButtonStyle())
            }.padding(18).foregroundStyle(RelayPalette.ink).frost(26)
            Text("Choose the recipient in the share sheet.").font(.caption2)
        }
    }
    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.system(size: 25, weight: .semibold))
            Text("CONNECTION").font(.caption).tracking(1.5)
            VStack(spacing: 8) {
                Toggle("Auto-reconnect", isOn: $autoReconnect)
                Divider()
                Toggle("Sound feedback", isOn: $soundFeedback)
                Divider()
                Button { incomingCode = ""; sheet = .pair } label: {
                    HStack { Text("Paired computer"); Spacer(); Image(systemName: "arrow.right") }.frame(minHeight: 40)
                }.buttonStyle(RelayControlButtonStyle(scales: false))
            }.font(.system(size: 14)).padding(14).foregroundStyle(RelayPalette.ink).tint(.black).frost(26)
            Text("GENERAL").font(.caption).tracking(1.5)
            VStack(spacing: 8) {
                Button { sheet = .settings } label: {
                    HStack { Text("Help & setup"); Spacer(); Image(systemName: "arrow.right") }.frame(minHeight: 40)
                }.buttonStyle(RelayControlButtonStyle(scales: false))
                Divider()
                Link(destination: URL(string: "https://pairit.kartikey.xyz/privacy.html")!) {
                    HStack { Text("Privacy"); Spacer(); Image(systemName: "arrow.up.right") }.frame(minHeight: 40)
                }
            }.font(.system(size: 14)).padding(14).foregroundStyle(RelayPalette.ink).tint(.black).frost(26)
            Spacer(minLength: 0)
        }
    }

}

enum ReceiverSheet: String, Identifiable { case pair, settings, sync, address, shared, output; var id: String { rawValue } }

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
                        Text(receiver.supportsVideoCompensation ? "Automatic timing uses your selected output. With multiple listeners, only the primary listener controls Mac video timing." : "This computer does not provide system video compensation. Software timing below is an estimate, not a sync guarantee.")
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
                            HStack { Text("Phone output"); Spacer(); OutputControls(receiver: receiver) }.padding(.vertical, 12)
                            Divider()
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
                            Text("Use the same Wi-Fi. Select an output in Settings, then choose its route in the system picker and tap Start audio.")
                            Text("Phone / Computer switches the shared playback destination. Pairings stay saved; paused listeners stay paused. Each phone controls its own volume.")
                            Text("Phone interruptions and lost connections stop local playback. Updated Mac companions hold their relay output, so media may continue silently; pause the computer player if needed. Return to PairIt explicitly after an interruption or background suspension.")
                            Text("Lock-screen and headphone controls pause or resume audio. Change tracks on the computer.")
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
                        ComputerDownloadLinks()
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

struct ComputerDownloadLinks: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("First, install PairIt on your computer").font(.footnote).foregroundStyle(RelayPalette.secondary)
            HStack(spacing: 8) {
                download("Mac", icon: "apple.logo", anchor: "mac")
                download("Windows", icon: "desktopcomputer", anchor: "windows")
                download("Linux", icon: "terminal", anchor: "linux")
            }

        }
    }
    private func download(_ name: String, icon: String, anchor: String) -> some View {
        Link(destination: URL(string: "https://pairit.kartikey.xyz/downloads.html#" + anchor)!) {
            Label(name, systemImage: icon).font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color(white: 0.94), in: RoundedRectangle(cornerRadius: 10))
        }.tint(.black)
    }

}

private struct AppShareSheet: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [URL(string: "https://pairit.kartikey.xyz/downloads")!], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct PhoneAnchorPreference: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

private struct SystemVolumeControl: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(); view.showsRouteButton = false; view.tintColor = .black; return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

private struct LaptopGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.addRoundedRect(in: CGRect(x: w * 0.2, y: h * 0.18, width: w * 0.6, height: h * 0.48), cornerSize: CGSize(width: 2, height: 2))
        path.move(to: CGPoint(x: w * 0.2, y: h * 0.68)); path.addLine(to: CGPoint(x: w * 0.1, y: h * 0.84))
        path.addLine(to: CGPoint(x: w * 0.9, y: h * 0.84)); path.addLine(to: CGPoint(x: w * 0.8, y: h * 0.68)); path.closeSubpath()
        path.move(to: CGPoint(x: w * 0.4, y: h * 0.77)); path.addLine(to: CGPoint(x: w * 0.6, y: h * 0.77))
        return path
    }
}

private struct NearbyPresence: View {
    @Environment(\.accessibilityReduceMotion) private var reduced
    private func ease(_ x: Double) -> Double {
        var low = 0.0, high = 1.0
        for _ in 0..<20 {
            let t = (low + high) / 2, u = 1 - t
            let value = 3 * u * u * t * 0.22 + 3 * u * t * t * 0.36 + t * t * t
            if value < x { low = t } else { high = t }
        }
        let t = (low + high) / 2, u = 1 - t
        return 3 * u * u * t * 0.61 + 3 * u * t * t + t * t * t
    }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduced)) { context in
            ZStack {
                Circle().fill(Color(white: 238.0 / 255)).frame(width: 68, height: 68)
                ForEach(0..<(reduced ? 1 : 2), id: \.self) { ring in
                    let phase = (context.date.timeIntervalSinceReferenceDate / 2.3 + Double(ring) * 0.5).truncatingRemainder(dividingBy: 1)
                    let scale = reduced ? 1 : 0.9 + 0.33 * ease(phase)
                    let opacity = reduced ? 0.65 : phase < 0.15 ? 0.65 * ease(phase / 0.15) : 0.65 * (1 - ease((phase - 0.15) / 0.85))
                    Circle().strokeBorder(Color(red: 177.0 / 255, green: 215.0 / 255, blue: 1).opacity(opacity), lineWidth: 1.5)
                        .frame(width: 82, height: 82).scaleEffect(scale)
                }
            }.frame(width: 100, height: 100)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct PhoneOutputSheet: View {
    @ObservedObject var receiver: RelayReceiver
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Listen through").font(.title3.weight(.semibold))
            HStack(spacing: 12) {
                Image(systemName: receiver.output.icon).font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(receiver.currentOutputName).font(.subheadline.weight(.medium))
                    Text("Choose an output with the system picker.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                AudioRoutePicker().frame(width: 48, height: 48).accessibilityLabel("Choose audio output")
            }
            Button("Done") { dismiss() }.buttonStyle(RelayPrimaryButtonStyle())
        }.padding(24).presentationDetents([.height(250)]).presentationDragIndicator(.visible)
            .onAppear { receiver.beginOutputChoice() }.onDisappear { receiver.endOutputChoice() }
            .onChange(of: receiver.headphones) { _, _ in dismiss() }
    }
}
