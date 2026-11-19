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
    @StateObject private var invitations = ListeningInvitations()
    @AppStorage("soundFeedback") private var soundFeedback = true
    @AppStorage("trustedAutoReconnect") private var autoReconnect = true
    @AppStorage("groupGuestPin") private var groupGuestPin = ""
    private var isGroupGuest: Bool { !groupGuestPin.isEmpty && groupGuestPin == pairing.mac?.pin }
    @State private var computerToForget: PairedMac?
    @State private var disconnecting = false
    @State private var checkingComputer = false
    @State private var occupiedComputer: String?
    @State private var attemptedPin: String?
    @State private var pairingReady = false
    @State private var confirmationTask: Task<Void, Never>?
    @State private var explicitIntent = 0
    @State private var connectionNotice = ""
    @State private var radialCenter = UnitPoint(x: 0.5, y: 0.65)
    @State private var tab = 0
    @ScaledMetric(relativeTo: .caption) private var navHeight: CGFloat = 56
    @State private var sharingApp = false
    @State private var showingMicrophone = false
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
    private var pageContent: some View {
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
                        Button { sheet = .report } label: { Image(systemName: "exclamationmark.bubble").font(.system(size: 19)).frame(width: 44, height: 44).background(.white.opacity(0.12), in: Circle()) }.buttonStyle(.plain).accessibilityLabel("Report a problem")
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
                }.scrollIndicators(.automatic).scrollBounceBehavior(.basedOnSize).id(tab)
            }
        }.overlay {
            if sheet != nil || sharingApp || requestingPairing { Color.black.opacity(0.28).ignoresSafeArea().allowsHitTesting(false) }
        }.foregroundStyle(.white)
    }

    private var observedContent: some View {
        pageContent
            .onReceive(invitations.$prompt) { prompt in
                if prompt != nil && (sheet != nil || sharingApp || isGroupGuest || AudioPresentationGate.isPresenting || scenePhase != .active) {
                    DispatchQueue.main.async { invitations.answer(false) }
                }
            }
            .onReceive(nearby.$computers) { computers in
                if !computers.isEmpty && connectionNotice == "Looking for nearby computers…" { connectionNotice = "" }
                if let mac = pairing.mac, !computers.contains(where: { $0.pin == mac.pin }), receiver.phase == .idle {
                    attemptedPin = nil; pairingReady = false
                }
                confirmTrustedNearby(computers)
            }
            .onChange(of: autoReconnect) { _, enabled in receiver.autoReconnectChanged(enabled) }
            .onChange(of: pairing.computers.map(\.pin)) { _, _ in
                // Saved computers changed: advertise their tags so they can offer Connect.
                nearby.computerTags = NearbyDevices.tags(tokens: pairing.computers.map(\.token), installation: RelayInstallation.identifier)
            }
            .onChange(of: ads.ready) { _, ready in if ready { ads.appOpen.prepare() } }
            .onChange(of: ads.openingScreen) { _, opening in if !opening { confirmTrustedNearby(nearby.computers) } }
            .onChange(of: receiver.computerDisconnects) { _, _ in
                // The computer's Disconnect matches this phone's Disconnect, including leaving a group.
                cancelExplicitConnection(); pairingReady = false; groupGuestPin = ""
            }
            .onChange(of: receiver.phase) { _, phase in
                if phase == .error || phase == .headphones { pairingReady = false; cancelExplicitConnection() }
            }
            .onChange(of: tab) { _, value in if value != 0 { cancelExplicitConnection(); cancelNearbyPairing() }; updateInvitations(active: scenePhase == .active) }
            .sheet(isPresented: $showingMicrophone) { MicrophoneView(receiver: receiver) }
            .sheet(isPresented: $sharingApp) { AppShareSheet() }
            .safeAreaInset(edge: .bottom, spacing: 8) {
                VStack(spacing: 8) {
                    navigation.padding(.horizontal, 16)
                    BannerAdSlot(ads: ads, active: scenePhase == .active && !ads.fullscreenActive)
                }
            }
    }

    private var lifecycleContent: some View {
        observedContent
            .onReceive(Timer.publish(every: 900, on: .main, in: .common).autoconnect()) { _ in if scenePhase == .active { updates.check() } }
            .onAppear {
                invitations.received = acceptInvitation
                invitations.connectRequest = computerConnectRequest
                invitations.canHost = { togetherHostProblem.isEmpty }
                // Start consent and the ad SDK at once, so the launch ad request goes out immediately.
                ads.start()
                updates.check(); nearby.start(); updateInvitations(active: scenePhase == .active)
                if scenePhase == .active { prepareOpeningAds() }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--preview-microphone") { showingMicrophone = true }
                if ProcessInfo.processInfo.arguments.contains("--preview-settings") { tab = 2 }
                if ProcessInfo.processInfo.arguments.contains("--preview-together") { tab = 1; updateInvitations(active: true) }
                #endif
            }
            .onDisappear { invitations.stop(); nearby.stop(); cancelExplicitConnection(); cancelNearbyPairing(); confirmationTask?.cancel() }
            .overlay { if ads.launchLoading { LaunchLoadingView() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { if receiver.phase == .idle { attemptedPin = nil }; updates.checkOnForeground(); nearby.start(); updateInvitations(active: true); prepareOpeningAds() }
                else { if phase == .background { ads.appOpen.background() } else { ads.appOpen.pause() }; invitations.stop(); nearby.stop(); cancelNearbyPairing(); if !ads.fullscreenActive { cancelExplicitConnection() }; confirmationTask?.cancel() }
            }
    }

    var body: some View {
        lifecycleContent
            .confirmationDialog("Forget this computer?", isPresented: Binding(get: { computerToForget != nil }, set: { if !$0 { computerToForget = nil } }), titleVisibility: .visible) {
                Button("Forget computer", role: .destructive) {
                    guard let computer = computerToForget else { return }
                    if computer.pin == pairing.mac?.pin { receiver.disconnect(); pairingReady = false }
                    do { try pairing.forget(pin: computer.pin) } catch { connectionNotice = error.localizedDescription }
                    computerToForget = nil
                }
            } message: { Text("You’ll need to pair again to reconnect. Your other saved computers stay available.") }
            .alert("Already connected", isPresented: Binding(get: { occupiedComputer != nil }, set: { if !$0 { occupiedComputer = nil } })) {
                Button("Listen Together") { tab = 1; occupiedComputer = nil }
                Button("Not now", role: .cancel) { occupiedComputer = nil }
            } message: {
                Text((occupiedComputer ?? "This computer is connected") + ". Want to join their group? Ask that person to open Listen Together and send you an invitation. Keep PairIt open on this phone.")
            }
            .alert("Approve on your computer", isPresented: $requestingPairing) {
                Button("Cancel", role: .cancel) { cancelNearbyPairing() }
            } message: {
                Text("Match this code before approving:\n\n" + comparisonCode)
            }
            .alert(invitations.prompt?.title ?? "Listening invitation", isPresented: Binding(get: { invitations.prompt != nil }, set: { if !$0 { invitations.answer(false) } })) {
                Button(invitations.prompt?.hosting == true ? "Invite guest" : "Join listening") {
                    if invitations.prompt?.hosting == true && !togetherHostProblem.isEmpty { invitations.answer(false); invitations.message(togetherHostProblem) }
                    else { invitations.answer(true) }
                }
                Button("Decline", role: .cancel) { invitations.answer(false) }
            } message: { Text((invitations.prompt?.hosting == true ? "You are inviting a guest to your computer. " : "You are joining as a guest. This connects you to the host’s computer and replaces your saved computer. ") + "Each phone uses its own speaker or headphones. Compare this code on both phones; only accept if it matches.\n\n" + (invitations.prompt?.comparison ?? "")) }
            .sensoryFeedback(.selection, trigger: selectionCount)
            .sheet(item: $sheet) { value in
                Group { switch value {
                case .report: ProblemReportView()
                case .pair: PairingView(receiver: receiver, pairing: pairing, initialCode: incomingCode)
                case .settings: ReceiverSettings(receiver: receiver, pairing: pairing)
                case .sync: VideoSyncView(receiver: receiver)
                case .address: ComputerAddressView(receiver: receiver, pairing: pairing)
                case .shared: SharedListeningView()
                case .output: PhoneOutputSheet(receiver: receiver)
                case .downloads: downloadsPanel
                case .audio: audioPanel
                case .connection: connectionPanel
                case .nearbyComputers: nearbyListPanel(together: false)
                case .nearbyPhones: nearbyListPanel(together: true)
                } }.tint(.black).preferredColorScheme(.light)
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
    private func selectComputer(_ device: NearbyDevices.Device) {
        guard !disconnecting, !checkingComputer, let pin = device.pin, let host = device.host else { return }
        if isGroupGuest && pin != pairing.mac?.pin { connectionNotice = togetherHostProblem; return }
        if receiver.phase.macSelected && pin == pairing.mac?.pin { return }
        checkingComputer = true; connectionNotice = "Checking computer…"
        Task { @MainActor in
            let status = await ComputerOccupancy.check(pin: pin, host: host)
            checkingComputer = false
            guard scenePhase == .active, tab == 0 else { return }
            connectionNotice = ""
            if status.count > 0 { occupiedComputer = device.name + " is connected to " + (status.names.isEmpty ? "another phone" : status.names); return }
            if let mac = pairing.savedComputer(pin: pin) { selectSavedComputer(mac, host: host) }
            else { requestNearbyPairing(device, named: status.count >= 0) }
        }
    }
    private func selectSavedComputer(_ mac: PairedMac, host: String? = nil) {
        guard !disconnecting else { return }
        if isGroupGuest { connectionNotice = togetherHostProblem; return }
        if receiver.phase.macSelected && mac.pin == pairing.mac?.pin { tab = 0; return }
        cancelExplicitConnection(); disconnecting = true
        receiver.disconnect {
            disconnecting = false
            do {
                try pairing.save(mac); pairingReady = false; tab = 0
                connectExplicitly(mac, host: pairing.hostOverride ?? host ?? mac.host)
            } catch { connectionNotice = error.localizedDescription }
        }
    }
    private func requestNearbyPairing(_ device: NearbyDevices.Device, named: Bool = false) {
        // These companions currently pair new phones through their private QR code.
        guard device.platform == "macos" else { incomingCode = ""; sheet = .pair; return }
        guard let pin = device.pin, let host = device.host, PairedMac.validHost(host),
              scenePhase == .active, !AudioPresentationGate.isPresenting else { return }
        cancelNearbyPairing(); cancelExplicitConnection(); connectionNotice = ""
        do {
            let request = try NearbyPairingRequest(pin: pin, encodedName: named ? NearbyDevices.encodedName : "")
            nearbyRequest = request; comparisonCode = request.comparison; requestingPairing = true
            request.start(host: host) { token in
                guard nearbyRequest === request else { return }
                nearbyRequest = nil; requestingPairing = false
                guard scenePhase == .active, tab == 0 else { return }
                guard let token else { connectionNotice = "Request not approved. Another phone may be connecting to this computer. Wait a moment, then try again or scan the QR code."; return }
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
    }
    private func connectExplicitly(_ mac: PairedMac, host: String?) {
        guard scenePhase == .active, sheet == nil, !AudioPresentationGate.isPresenting else { return }
        confirmationTask?.cancel(); cancelExplicitConnection(); connectionNotice = ""
        let intent = explicitIntent
        attemptedPin = mac.pin
        confirmationTask = Task { @MainActor in
            if !isGroupGuest && [.idle, .error].contains(receiver.phase) {
                let status = await ComputerOccupancy.check(pin: mac.pin, host: host ?? mac.host)
                guard !Task.isCancelled, intent == explicitIntent, scenePhase == .active else { return }
                if status.count > 0 {
                    occupiedComputer = mac.displayName + " is connected to " + (status.names.isEmpty ? "another phone" : status.names)
                    cancelExplicitConnection(); confirmationTask = nil; return
                }
            }
            let verified = await PairingConfirmation.confirm(mac, hostOverride: host)
            guard !Task.isCancelled, intent == explicitIntent, scenePhase == .active, pairing.mac?.pin == mac.pin else { return }
            confirmationTask = nil
            guard verified else { connectionNotice = "Computer unavailable. Keep PairIt open on the same Wi-Fi."; cancelExplicitConnection(); return }
            pairingReady = true
            guard tab == 0, sheet == nil else { return }
            receiver.connect()
        }
    }
    private func confirmTrustedNearby(_ computers: [NearbyDevices.Device]) {
        guard !disconnecting, autoReconnect, tab == 0, sheet == nil, nearbyRequest == nil, scenePhase == .active, !ads.openingScreen, !AudioPresentationGate.isPresenting,
              receiver.phase == .idle, let mac = pairing.mac, attemptedPin != mac.pin,
              let device = computers.first(where: { $0.pin == mac.pin }) else { return }
        confirm(mac, host: pairing.hostOverride ?? device.host)
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
                Capsule().fill(Color(white: 0.94)).frame(width: width, height: navHeight)
                    .offset(x: 7 + CGFloat(tab) * (width + 4))
                    .animation(reduced ? nil : .spring(response: 0.65, dampingFraction: 0.85), value: tab)
                HStack(spacing: 4) {
                    ForEach(0..<3) { index in
                        Button { tab = index; selectionCount += 1 } label: {
                            VStack(spacing: 5) {
                                Image(systemName: ["headphones", "person.2", "slider.horizontal.3"][index]).font(.system(size: 19))
                                Text(["Connect", "Together", "Settings"][index]).font(.caption)
                            }.frame(maxWidth: .infinity, minHeight: navHeight)
                                .foregroundStyle(tab == index ? Color.black : Color(white: 0.7))
                        }.buttonStyle(RelayControlButtonStyle()).accessibilityAddTraits(tab == index ? .isSelected : [])
                    }
                }.padding(7)
            }.clipShape(Capsule())
        }.frame(height: navHeight + 14)
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
            if nearby.computers.isEmpty {
                Image(systemName: "laptopcomputer").font(.system(size: 40, weight: .light))
                Text("Looking for computers…").font(.subheadline)
            } else {
                let list = sortedNearby(together: false)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: list.count == 1 ? 1 : 2), spacing: 18) {
                    nearbyNodes(list, together: false)
                }
            }
            Spacer(minLength: 20)
            VStack(spacing: 5) {
                Image(systemName: "iphone").font(.title2).frame(width: 46, height: 46)
                    .background(.white.opacity(0.08), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.3)))
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: PhoneAnchorPreference.self, value: CGPoint(x: proxy.frame(in: .named("phoneContent")).midX, y: proxy.frame(in: .named("phoneContent")).midY))
                    })
                Text(NearbyDevices.localName + " (you)").font(.caption)
            }
            if !nearby.computers.isEmpty {
                Text("\(nearby.computers.count) \(nearby.computers.count == 1 ? "computer" : "computers") nearby · same Wi-Fi").font(.caption)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: pairing.mac == nil ? "qrcode.viewfinder" : "laptopcomputer")
                        .font(.system(size: 20)).frame(width: 36, height: 36)
                        .background(Color(white: 0.93), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pairing.mac == nil ? "Pair a computer" : "Ready to connect").font(.headline)
                        Text(pairing.mac == nil ? "Scan the code on your computer." : receiver.currentOutputName)
                            .font(.caption).foregroundStyle(RelayPalette.secondary)
                    }.fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    if let mac = pairing.mac { connectExplicitly(mac, host: pairing.hostOverride) }
                    else { incomingCode = ""; sheet = .pair }
                } label: { Label(pairing.mac == nil ? "Scan QR code" : "Connect", systemImage: pairing.mac == nil ? "qrcode.viewfinder" : "headphones") }
                    .buttonStyle(RelayPrimaryButtonStyle())
                HStack(alignment: .top, spacing: 6) {
                    shortcut("Output", icon: "headphones", destination: .output)
                    shortcut("Scan QR", icon: "qrcode.viewfinder", destination: .pair)
                    shortcut("Get PC app", icon: "laptopcomputer", destination: .downloads)
                }
                connectTools(connected: false)
            }.padding(16).foregroundStyle(RelayPalette.ink).frost(26)

        }
    }
    private var connectedPage: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            if connecting { ProgressView().tint(.white).scaleEffect(1.3).frame(height: 110) }
            else { ListeningVisual(playing: receiver.phase == .playing && !receiver.computerPlayerPaused, computer: receiver.computerOutput, reduceMotion: reduced) }
            Text(connecting ? "Connecting…" : receiver.phase == .playing && receiver.computerPlayerPaused ? "Paused on computer · press play on your earphones" : receiver.phase == .playing ? "Listening through your phone" : receiver.phase == .computerOutput ? "Playing on computer" : pairingReady && receiver.phase == .idle ? "Paired" : receiver.title)
                .font(.subheadline).multilineTextAlignment(.center)
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                if !receiver.computerVolumeText.isEmpty {
                    Text(receiver.computerVolumeText).font(.caption).foregroundStyle(RelayPalette.secondary)
                        .accessibilityLabel(receiver.computerVolumeText + (receiver.computerVolumeLinked ? ". The computer’s volume keys change this iPhone’s volume." : ". Phone volume is separate."))
                }
                if receiver.supportsOutputControl {
                    HStack(spacing: 4) {
                        playbackDestination("This phone", icon: "iphone", computer: false)
                        playbackDestination("Computer", icon: "laptopcomputer", computer: true)
                    }.padding(5).background(Color(white: 0.92), in: RoundedRectangle(cornerRadius: 17)).clipShape(RoundedRectangle(cornerRadius: 17))
                }
                Group {
                    Button {
                        if receiver.phase == .playing || waitingForAudio { receiver.pauseComputer() }
                        else if receiver.phase == .idle, let mac = pairing.mac { connectExplicitly(mac, host: pairing.hostOverride) }
                        else { receiver.connect() }
                    } label: {
                        HStack(spacing: 10) {
                            if connecting || receiver.pausing { ProgressView().tint(.white) }
                            Text(receiver.pausing ? "Pausing…" : connecting ? "Starting…" : receiver.phase == .playing || waitingForAudio ? "Pause audio" : "Start audio")
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(RelayPrimaryButtonStyle()).disabled(connecting || receiver.pausing)
                }.opacity(receiver.computerOutput ? 0 : 1).allowsHitTesting(!receiver.computerOutput).accessibilityHidden(receiver.computerOutput)
                Text(receiver.currentOutputName).font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 6) {
                    shortcut("Output", icon: "headphones", destination: .output)
                    shortcut("Audio", icon: "slider.horizontal.3", destination: .audio)
                    shortcut("More", icon: "ellipsis", destination: .connection)
                }
                connectTools(connected: true)
                // Group timing wins; otherwise an updated Mac may need headphone controls allowed.
                if !(receiver.groupTimingStatus.isEmpty ? receiver.mediaControlHint : receiver.groupTimingStatus).isEmpty {
                    Text(receiver.groupTimingStatus.isEmpty ? receiver.mediaControlHint : receiver.groupTimingStatus).font(.caption).foregroundStyle(RelayPalette.secondary)
                        .multilineTextAlignment(.center)
                }

            }.padding(18).foregroundStyle(RelayPalette.ink).frost(26)
        }
    }
    private func connectTools(connected: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                if connected { receiver.refreshAudio() }
                else { nearby.stop(); nearby.start(); connectionNotice = "Looking for nearby computers…" }
            } label: {
                Label(connected ? "Refresh audio" : "Refresh nearby", systemImage: "arrow.clockwise")
                    .font(.caption).frame(maxWidth: .infinity, minHeight: 48)
            }.disabled(connecting || receiver.pausing || (connected && (receiver.phase != .playing || receiver.computerOutput)))
            Button { sheet = .sync } label: {
                Label("Audio / video sync", systemImage: "slider.horizontal.3")
                    .font(.caption).frame(maxWidth: .infinity, minHeight: 48)
            }.disabled(connecting || receiver.pausing)
        }.buttonStyle(RelayControlButtonStyle())
            .background(Color(white: 0.94), in: RoundedRectangle(cornerRadius: 14))
    }
    private func shortcut(_ title: String, icon: String, destination: ReceiverSheet) -> some View {
        RelayShortcut(title: title, icon: icon) { if destination == .pair { incomingCode = "" }; sheet = destination }
    }
    private var downloadsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Get PC app").font(.title3.bold())
                ForEach(["Mac", "Windows", "Linux"], id: \.self) { platform in
                    Link(destination: URL(string: "https://pairit.kartikey.xyz/downloads.html#" + platform.lowercased())!) {
                        HStack { Image(systemName: platform == "Mac" ? "laptopcomputer" : "desktopcomputer"); Text(platform); Spacer(); Image(systemName: "arrow.up.right") }
                            .padding(14).frame(minHeight: 48).background(Color(white: 0.94), in: RoundedRectangle(cornerRadius: 14))
                    }.foregroundStyle(.black)
                }
            }.padding(24)
        }.scrollBounceBehavior(.basedOnSize).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private var audioPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Audio").font(.title3.bold())
                Text("Phone volume").font(.subheadline)
                SystemVolumeControl().frame(height: 44).accessibilityLabel("Phone volume").disabled(receiver.computerOutput)
                Button("Refresh audio", action: receiver.refreshAudio).buttonStyle(RelayPrimaryButtonStyle())
                    .disabled(receiver.phase != .playing || receiver.computerOutput)
            }.padding(24)
        }.scrollBounceBehavior(.basedOnSize).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private var connectionPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Connection").font(.title3.bold())
                Button("Pair another computer") { incomingCode = ""; sheet = .pair }
                    .frame(maxWidth: .infinity, minHeight: 48)
                Button {
                    guard !disconnecting else { return }
                    disconnecting = true; pairingReady = false
                    receiver.disconnect { disconnecting = false; sheet = nil }
                } label: {
                    HStack { if disconnecting { ProgressView().tint(.white) }; Text(disconnecting ? "Disconnecting…" : "Disconnect") }.frame(maxWidth: .infinity)
                }.buttonStyle(RelayPrimaryButtonStyle()).disabled(disconnecting)
            }.padding(24)
        }.scrollBounceBehavior(.basedOnSize).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    /// Called whenever the scene is active: a cold launch or a return may be an opening.
    private func prepareOpeningAds() {
        ads.appOpen.foreground { receiver.audioIdleForAdvertisement && sheet == nil && !showingMicrophone && !sharingApp && !invitations.busy && confirmationTask == nil && nearbyRequest == nil }
    }
    private func playbackDestination(_ title: String, icon: String, computer: Bool) -> some View {
        RelayOutputChoice(title: title, icon: icon, selected: receiver.computerOutput == computer) {
            if computer { receiver.listenOnComputer() } else { receiver.connect() }
        }
    }
    /// "Connect" chosen on a paired computer. The CONNECT1 hint is only acted on after the
    /// computer confirms over its pinned channel (WANT1) that it asked for this phone.
    private func computerConnectRequest(pin: String, host: String) {
        guard scenePhase == .active, let saved = pairing.savedComputer(pin: pin), PairedMac.validHost(host),
              !AudioPresentationGate.isPresenting, !ads.openingScreen, sheet == nil, !sharingApp, !showingMicrophone,
              !requestingPairing, nearbyRequest == nil, !checkingComputer, !disconnecting, !invitations.busy else { return }
        if isGroupGuest && pin != pairing.mac?.pin { return }
        if receiver.phase == .playing && pin == pairing.mac?.pin { return }
        connectionNotice = "Connecting to \(saved.displayName)…"; checkingComputer = true
        Task { @MainActor in
            let wanted = await PairingConfirmation.confirmConnectRequest(saved, host: host, installation: RelayInstallation.identifier)
            checkingComputer = false
            if connectionNotice.hasPrefix("Connecting to ") { connectionNotice = "" }
            guard wanted, scenePhase == .active, sheet == nil, !AudioPresentationGate.isPresenting,
                  let current = pairing.savedComputer(pin: pin) else { return }
            tab = 0
            if receiver.phase.macSelected && pin == pairing.mac?.pin {
                // Already connected to this computer but not listening: start audio.
                if receiver.phase != .playing { receiver.connect() }
                return
            }
            if pin == pairing.mac?.pin { connectExplicitly(current, host: pairing.hostOverride ?? host); return }
            // The same path as tapping this saved computer: verify, connect and start audio.
            selectSavedComputer(current, host: host)
        }
    }
    private func updateInvitations(active: Bool) {
        guard active else { invitations.stop(); nearby.showTogether(false); return }
        invitations.start { port in
            guard scenePhase == .active else { return }
            nearby.computerTags = NearbyDevices.tags(tokens: pairing.computers.map(\.token), installation: RelayInstallation.identifier)
            nearby.showTogether(false); nearby.invitationPort = port; nearby.showTogether(true)
        }
    }
    /// Current and saved computers first, then names; phones by name. Stable for equal names.
    private func sortedNearby(together: Bool) -> [NearbyDevices.Device] {
        func rank(_ device: NearbyDevices.Device) -> Int {
            guard let pin = device.pin else { return 2 }
            return pin == pairing.mac?.pin ? 0 : pairing.savedComputer(pin: pin) != nil ? 1 : 2
        }
        return (together ? nearby.phones : nearby.computers).sorted { a, b in
            if !together, rank(a) != rank(b) { return rank(a) < rank(b) }
            let byName = a.name.caseInsensitiveCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return (a.pin ?? "") + (a.host ?? "") + a.id < (b.pin ?? "") + (b.host ?? "") + b.id
        }
    }
    /// Duplicate names get a stable " · 2" suffix in sorted order.
    private func nearbyLabel(_ device: NearbyDevices.Device, in list: [NearbyDevices.Device]) -> String {
        let same = list.filter { $0.name.caseInsensitiveCompare(device.name) == .orderedSame }
        guard same.count > 1, let index = same.firstIndex(where: { $0.id == device.id }) else { return device.name }
        return device.name + " · \(index + 1)"
    }
    private func nearbyDetail(_ device: NearbyDevices.Device, together: Bool) -> String {
        let platform = ["macos": "Mac", "windows": "Windows", "linux": "Linux", "ios": "iPhone", "android": "Android"][device.platform] ?? (together ? "Phone" : "Computer")
        guard !together, let pin = device.pin else { return platform }
        return pin == pairing.mac?.pin ? "Paired" : pairing.savedComputer(pin: pin) != nil ? "Saved" : platform
    }
    private func chooseNearby(_ device: NearbyDevices.Device, together: Bool) {
        if together { invitePhone(device) } else { selectComputer(device) }
    }
    /// Four fit around the map. A busy network shows three plus a complete, sorted list.
    @ViewBuilder private func nearbyNodes(_ list: [NearbyDevices.Device], together: Bool) -> some View {
        let shown = list.count <= 4 ? list.count : 3
        ForEach(Array(list.prefix(shown))) { device in
            RelayNearbyDevice(name: nearbyLabel(device, in: list), detail: nearbyDetail(device, together: together), phone: together) {
                chooseNearby(device, together: together)
            }
        }
        if list.count > 4 {
            RelayNearbyDevice(name: "\(list.count - shown) more", detail: together ? "Show all phones" : "Show all computers", icon: "ellipsis") {
                sheet = together ? .nearbyPhones : .nearbyComputers
            }
        }
    }
    private func nearbyListPanel(together: Bool) -> some View {
        let list = sortedNearby(together: together)
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text((together ? "Nearby phones" : "Nearby computers") + " · \(list.count)").font(.title3.bold())
                Text(together ? "Tap a phone to invite it. Compare the code on both phones before accepting." : "Tap a computer to connect. Saved computers are listed first.")
                    .font(.subheadline).foregroundStyle(RelayPalette.secondary)
                if list.isEmpty { Text(together ? "No phones nearby" : "No computers nearby").foregroundStyle(RelayPalette.secondary) }
                ForEach(list) { device in
                    Button {
                        sheet = nil
                        // Let the sheet dismissal finish before connecting or inviting.
                        DispatchQueue.main.async { chooseNearby(device, together: together) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: together ? "iphone" : "laptopcomputer").font(.system(size: 19)).frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(nearbyLabel(device, in: list)).font(.subheadline.weight(.medium))
                                Text(nearbyDetail(device, together: together)).font(.caption).foregroundStyle(RelayPalette.secondary)
                            }
                            Spacer()
                        }.padding(14).frame(minHeight: 56).background(Color(white: 0.94), in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(RelayControlButtonStyle(scales: false)).foregroundStyle(.black)
                }
            }.padding(24)
        }.scrollBounceBehavior(.basedOnSize).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private var togetherHostProblem: String {
        if isGroupGuest { return "You joined a listening group. Leave this group before hosting or joining another." }
        return ListeningInvitations.hostProblem(connected: [.playing, .paused, .buffering, .computerOutput].contains(receiver.phase), phoneOutput: !receiver.computerOutput,
            available: !AVAudioSession.sharedInstance().currentRoute.outputs.isEmpty)
    }
    private func invitePhone(_ phone: NearbyDevices.Device) {
        guard togetherHostProblem.isEmpty else { invitations.message(togetherHostProblem); return }
        guard let saved = pairing.mac else { invitations.message("Connect to a computer first, then invite a phone."); return }
        let host = pairing.hostOverride ?? nearby.computers.first(where: { $0.pin == saved.pin })?.host ?? saved.host
        let value = PairedMac(host: host, pin: saved.pin, token: saved.token, name: saved.name, platform: saved.platform, protocolVersion: saved.protocolVersion)
        guard let data = try? JSONEncoder().encode(value) else { return }
        let code = "audiorelay://pair/" + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        invitations.invite(phone, code: code, computer: saved.displayName)
    }
    private func acceptInvitation(_ code: String) {
        guard scenePhase == .active, !isGroupGuest, !AudioPresentationGate.isPresenting, let mac = try? PairedMac.parse(code) else { return }
        confirmationTask?.cancel()
        confirmationTask = Task { @MainActor in
            let verified = await PairingConfirmation.confirm(mac)
            guard !Task.isCancelled, scenePhase == .active else { return }
            confirmationTask = nil
            guard verified else { invitations.message("Computer unavailable. Keep all devices on the same Wi-Fi."); return }
            do { try pairing.save(mac); receiver.disconnect(); groupGuestPin = mac.pin; tab = 0
                // Wait for navigation to finish before beginning the existing explicit connection flow.
                DispatchQueue.main.async { connectExplicitly(mac, host: mac.host) }
            } catch { invitations.message("Couldn’t save this computer. Unlock your phone and try again.") }
        }
    }
    private var togetherPage: some View {
        VStack(spacing: 14) {
            Text(isGroupGuest ? "Guest · " + (pairing.mac?.displayName ?? "computer") : togetherHostProblem.isEmpty ? "Hosting from " + (pairing.mac?.displayName ?? "computer") : "Connect a computer to host, or wait for an invitation.").font(.subheadline).foregroundStyle(.white.opacity(0.75)).frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            if nearby.phones.isEmpty {
                Image(systemName: "person.2").font(.system(size: 40, weight: .light))
                Text("No phones nearby yet").font(.subheadline)
            } else {
                RelayPhoneOrbit { nearbyNodes(sortedNearby(together: true), together: true) }
            }
            VStack(spacing: 5) {
                Image(systemName: "iphone").font(.title2).frame(width: 46, height: 46)
                    .background(.white.opacity(0.08), in: Circle()).overlay(Circle().strokeBorder(.white.opacity(0.3)))
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: PhoneAnchorPreference.self, value: CGPoint(x: proxy.frame(in: .named("phoneContent")).midX, y: proxy.frame(in: .named("phoneContent")).midY))
                    })
                Text(NearbyDevices.localName + " (you)").font(.caption)
                if !nearby.phones.isEmpty {
                    Text("\(nearby.phones.count) \(nearby.phones.count == 1 ? "phone" : "phones") nearby · same Wi-Fi").font(.caption)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 10) {
                Text(isGroupGuest ? "Joined a group" : togetherHostProblem.isEmpty ? "Invite a listener" : "Connect or join").font(.headline)
                Text(togetherHostProblem.isEmpty ? "Invite up to three guests. Each phone uses its own speaker or headphones. Keep PairIt open on both phones." : togetherHostProblem).font(.caption).foregroundStyle(RelayPalette.secondary)
                Button { if isGroupGuest { receiver.disconnect(); groupGuestPin = "" } else if !togetherHostProblem.isEmpty { tab = 0 } else { sharingApp = true } } label: { Label(isGroupGuest ? "Leave group" : !togetherHostProblem.isEmpty ? "Connect a computer" : "Share app", systemImage: !togetherHostProblem.isEmpty ? "laptopcomputer" : "square.and.arrow.up") }.buttonStyle(RelayPrimaryButtonStyle())
            }.padding(18).foregroundStyle(RelayPalette.ink).frost(26)
            Text(invitations.notice.isEmpty ? "Share app is for friends who haven’t installed PairIt." : invitations.notice).font(.caption2)
        }
    }
    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.system(size: 25, weight: .semibold))
            Text("CONNECTION").font(.caption).tracking(1.5)
            VStack(spacing: 8) {
                Text("Paired computers").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                if pairing.computers.isEmpty { Text("No saved computers").foregroundStyle(RelayPalette.secondary) }
                ForEach(pairing.computers, id: \.pin) { computer in
                    HStack {
                        Button { selectSavedComputer(computer) } label: {
                            HStack { Text(computer.displayName); Spacer(); if computer.pin == pairing.mac?.pin { Text("Selected").font(.caption) } }
                        }.disabled(disconnecting).buttonStyle(RelayControlButtonStyle(scales: false))
                        Button {
                            computerToForget = computer
                        } label: { Image(systemName: "minus.circle").frame(width: 44, height: 44) }.disabled(disconnecting).accessibilityLabel("Forget " + computer.displayName)
                    }.frame(minHeight: 44)
                }
                Divider()
                Toggle("Auto-reconnect", isOn: $autoReconnect)
                Divider()
                Toggle("Sound feedback", isOn: $soundFeedback)
                Divider()
                Button { incomingCode = ""; sheet = .pair } label: {
                    HStack { Text("Pair another computer"); Spacer(); Image(systemName: "plus") }.frame(minHeight: 40)
                }.buttonStyle(RelayControlButtonStyle(scales: false))
            }.font(.system(size: 14)).padding(14).foregroundStyle(RelayPalette.ink).tint(.black).frost(26)
            Text("GENERAL").font(.caption).tracking(1.5)
            VStack(spacing: 8) {
                Button { showingMicrophone = true } label: {
                    HStack { Text("Phone microphone"); Spacer(); Image(systemName: "mic") }.frame(minHeight: 40)
                }.buttonStyle(RelayControlButtonStyle(scales: false))
                Divider()
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

enum ReceiverSheet: String, Identifiable { case pair, settings, sync, address, shared, output, downloads, audio, connection, report, nearbyComputers, nearbyPhones; var id: String { rawValue } }

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
                        Text(receiver.supportsVideoCompensation ? "Automatic timing uses your selected output. With multiple listeners, only the primary listener controls Mac video timing." : "Each tap adjusts this phone’s audio buffer by 10 ms without disconnecting. Reducing the buffer too far can cause stuttering; reset if playback becomes unstable.")
                            .font(.subheadline).foregroundStyle(RelayPalette.secondary).multilineTextAlignment(.center)
                        VStack(spacing: 16) {
                            Text(receiver.estimatedMs.map { "Automatic · \($0) ms" } ?? "Timing appears after you start listening")
                                .font(.subheadline).foregroundStyle(RelayPalette.secondary)
                            Text(String(format: "%+d ms", receiver.correction)).font(.system(size: 38, weight: .medium, design: .rounded)).monospacedDigit()
                            HStack(spacing: 10) {
                                Button("Sound is early") { receiver.adjustCorrection(-10) }.buttonStyle(RelayQuietButtonStyle())
                                Button("Sound is late") { receiver.adjustCorrection(10) }.buttonStyle(RelayQuietButtonStyle())
                            }.disabled(!receiver.canAdjustTiming)
                            Button(action: receiver.resetCorrection) { Text("Reset correction").frame(minHeight: 44) }
                                .font(.subheadline).buttonStyle(RelayControlButtonStyle(scales: false)).disabled(receiver.correction == 0)
                        }.padding(24).frost()
                        Text("Corrections are saved for this output and playback mode. Audio cannot be advanced beyond the available buffer. Some Mac players need to reopen their output after a change.")
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
                            Text("Lock-screen and headphone controls pause or resume this iPhone. On a Mac with PairIt’s headphone controls allowed, pausing also pauses the video or music playing on the Mac, and resuming plays it again. Volume keys on an updated Mac change this iPhone’s volume. Change tracks on the computer.")
                        }.font(.subheadline).foregroundStyle(RelayPalette.secondary).padding(22).frost()
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Local by design", systemImage: "lock.shield").font(.headline).foregroundStyle(RelayPalette.ink)
                            Text("Audio is encrypted directly between your devices. There are no cloud audio servers or PairIt accounts. A Google AdMob banner supports the app. An ad may appear when PairIt opens, at most every 3 minutes, never while this phone plays audio and never on connect. Google may process IP-derived location, device identifiers, ad interactions and diagnostics for advertising, measurement and fraud prevention. Live ad requests require the available consent choices; this build requests non-personalized ads and does not request tracking permission. Optional Phone microphone mode asks for permission and sends microphone audio directly to your paired computer only while its screen is open. No recording is saved. Pairing credentials stay in Keychain. Camera access only scans pairing codes; no photos are saved. Update checks fetch a public release list from GitHub, which receives normal web-request information such as your IP address. No audio, pairing credentials or device identifier is attached.")
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
            Text("Get computer app").font(.footnote).foregroundStyle(RelayPalette.secondary)
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

struct LaptopGlyph: Shape {
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

struct NearbyPresence: View {
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
        ScrollView { VStack(alignment: .leading, spacing: 18) {
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
        }.padding(24) }.scrollBounceBehavior(.basedOnSize).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            .onAppear { receiver.beginOutputChoice() }.onDisappear { receiver.endOutputChoice() }
            .onChange(of: receiver.headphones) { _, _ in dismiss() }
    }
}
