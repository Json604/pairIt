import SwiftUI
import AVFoundation

struct PairingView: View {
    @ObservedObject var receiver: RelayReceiver
    @ObservedObject var pairing: PairingStore
    @EnvironmentObject private var ads: BannerAds
    @Environment(\.scenePhase) private var scenePhase
    var initialCode = ""
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var error = ""
    @State private var scanning = false
    @State private var confirmForget = false
    @State private var saving = false
    @State private var savedName: String?
    @State private var confirmation: Bool?
    @State private var automaticStart = false
    @State private var finishedAdvertisement = false
    @State private var mounted = false
    @State private var adFlow: Int?
    @State private var actionGeneration = 0
    private var candidate: PairedMac? { try? PairedMac.parse(code) }

    var body: some View {
        NavigationStack {
            ZStack {
                RelayBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let savedName {
                            VStack(alignment: .leading, spacing: 20) {
                                Label(confirmation == true ? "Computer paired" : "Pairing saved", systemImage: "checkmark.shield").font(.title2)
                                Text(confirmation == true ? "\(savedName) confirmed the pairing. Nothing is playing yet."
                                     : confirmation == nil ? "Saved on this iPhone. Confirming with \(savedName)…"
                                     : "Saved on this iPhone. Your computer has not confirmed yet. Keep PairIt open on the same local network; you can still try Start audio.")
                                    .font(.subheadline).foregroundStyle(RelayPalette.secondary)
                                if automaticStart { ProgressView("Connecting…") } else {
                                Button("Start audio") {
                                    receiver.connect()
                                    dismiss()
                                }.buttonStyle(RelayPrimaryButtonStyle()).disabled(!finishedAdvertisement)
                                Button("Later") { dismiss() }.buttonStyle(RelayQuietButtonStyle())
                                }
                            }.padding(.top, 24)
                        } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Pair your computer.").font(RelayTypography.display(26)).tracking(-0.5)
                            Text("On your computer, open PairIt → Pair a phone. Keep both devices on the same local network.")
                                .font(.subheadline).foregroundStyle(RelayPalette.secondary)
                        }.padding(.top, 14)
                        ComputerDownloadLinks()
                        VStack(spacing: 18) {
                            Image(systemName: "qrcode.viewfinder").font(.system(size: 40, weight: .light)).foregroundStyle(RelayPalette.ink)
                                .frame(width: 90, height: 90).background(RelayPalette.sand, in: RoundedRectangle(cornerRadius: 24))
                            Button { error = ""; scanning = true } label: { Label("Scan QR code", systemImage: "camera") }
                                .buttonStyle(RelayPrimaryButtonStyle())
                            Text("Scan your computer’s PairIt code to pair.")
                                .font(.caption).foregroundStyle(RelayPalette.secondary)
                        }.padding(.vertical, 12)
                        VStack(alignment: .leading, spacing: 13) {
                            Text("Or paste a pairing code").font(.headline)
                            TextField("Pairing code from your computer", text: $code, axis: .vertical)
                                .lineLimit(2...4).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .font(.system(.footnote, design: .monospaced)).padding(14)
                                .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                                .accessibilityLabel("Pairing code")
                            if let mac = candidate {
                                Label("Ready to pair with \(mac.displayName)", systemImage: "checkmark.shield")
                                    .font(.subheadline).foregroundStyle(RelayPalette.deep)
                            }
                            if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(Color(red: 0.6, green: 0.16, blue: 0.12)).accessibilityLabel("Error: \(error)") }
                            Button(action: { save() }) {
                                HStack(spacing: 8) {
                                    if saving { ProgressView().tint(.white).accessibilityHidden(true) }
                                    Text(saving ? "Saving…" : "Pair computer")
                                }
                            }.buttonStyle(RelayPrimaryButtonStyle()).disabled(saving || candidate == nil)
                            Text("A short ad may appear after pairing is saved. Start audio separately when you’re ready.")
                                .font(.caption).foregroundStyle(RelayPalette.secondary)
                        }.padding(.vertical, 12)
                        if pairing.mac != nil {
                            Button("Forget this computer", role: .destructive) { confirmForget = true }.frame(maxWidth: .infinity, minHeight: 44)
                        }
                        Label("Your pairing code is private. Share it only with your devices.", systemImage: "lock")
                            .font(.footnote).foregroundStyle(RelayPalette.secondary)
                        }
                    }.padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
                }.scrollDismissesKeyboard(.interactively)
            }.navigationTitle("Connect your computer").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                .onAppear {
                    mounted = true
                    if code.isEmpty { code = initialCode }
                    if savedName == nil { adFlow = ads.pairingVideo.begin(audioIdle: receiver.audioIdleForAdvertisement) }
                }
                .onChange(of: ads.ready) { _, ready in
                    if ready, let adFlow { ads.pairingVideo.prepare(flow: adFlow, audioIdle: receiver.audioIdleForAdvertisement) }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        if automaticStart { actionGeneration += 1; automaticStart = false; saving = false; finishedAdvertisement = true }
                        if let adFlow { ads.pairingVideo.cancelUnshown(flow: adFlow) }
                        if !ads.fullscreenActive { finishedAdvertisement = true }
                    } else if mounted, savedName == nil { adFlow = ads.pairingVideo.begin(audioIdle: receiver.audioIdleForAdvertisement) }
                }
                .onDisappear {
                    mounted = false; actionGeneration += 1
                    if let adFlow { ads.pairingVideo.cancelUnshown(flow: adFlow) }
                }
                .onChange(of: code) { _, _ in error = "" }
                .sheet(isPresented: $scanning) {
                    ScannerSheet { result in
                        scanning = false
                        switch result {
                        case .success(let value):
                            code = value; error = ""
                            if (try? PairedMac.parse(value)) != nil { save(immediate: true) }
                            else { error = "This is not a PairIt pairing code." }
                        case .failure(let message): error = message.localizedDescription
                        }
                    }
                }
                .confirmationDialog("Forget this computer?", isPresented: $confirmForget, titleVisibility: .visible) {
                    Button("Forget computer", role: .destructive) { receiver.disconnect(); do { try pairing.forget(); dismiss() } catch { self.error = error.localizedDescription } }
                } message: { Text("You can pair again using the code in the desktop app.") }
        }.tint(RelayPalette.deep).foregroundStyle(RelayPalette.ink)
    }
    private func save(immediate: Bool = false) {
        guard !saving else { return }
        do {
            let mac = try PairedMac.parse(code)
            let action = actionGeneration, flow = adFlow
            saving = true; finishedAdvertisement = false; automaticStart = immediate
            Task { @MainActor in
                if immediate {
                    // Verify scanned credentials before replacing a working saved pairing.
                    let verified = await PairingConfirmation.confirm(mac)
                    guard mounted, action == actionGeneration, scenePhase == .active else { return }
                    guard verified else {
                        saving = false; automaticStart = false
                        error = "Couldn’t verify this computer. Keep PairIt open on the same Wi-Fi and scan again."
                        return
                    }
                }
                guard mounted, action == actionGeneration else { return }
                do {
                    // Save first, so Keychain errors cannot tear down the current session.
                    try pairing.save(mac); receiver.disconnect()
                    savedName = mac.displayName; saving = false; code = ""; confirmation = immediate ? true : nil
                    if immediate {
                        let start = {
                            guard mounted, action == actionGeneration, pairing.mac?.pin == mac.pin, scenePhase == .active, !scanning else { return }
                            finishedAdvertisement = true; receiver.connect(); dismiss()
                        }
                        if let flow {
                            ads.pairingVideo.showAfterConnection(flow: flow, eligible: {
                                mounted && action == actionGeneration && scenePhase == .active && !scanning && receiver.audioIdleForAdvertisement
                            }, next: start)
                        } else { start() }
                    } else {
                        Task { @MainActor in
                            let confirmed = await PairingConfirmation.confirm(mac, hostOverride: pairing.hostOverride)
                            guard mounted, action == actionGeneration, pairing.mac?.pin == mac.pin else { return }
                            confirmation = confirmed
                        }
                        guard let flow else { finishedAdvertisement = true; return }
                        ads.pairingVideo.showAfterPairing(flow: flow, eligible: {
                            mounted && action == actionGeneration && adFlow == flow && savedName != nil
                                && scenePhase == .active && !scanning && receiver.audioIdleForAdvertisement
                        }) {
                            guard mounted, action == actionGeneration, savedName != nil else { return }
                            finishedAdvertisement = true
                        }
                    }
                } catch { automaticStart = false; showError(error) }
            }
        } catch { showError(error) }
    }
    private func showError(_ error: Error) {
        saving = false; self.error = error.localizedDescription
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        UIAccessibility.post(notification: .announcement, argument: self.error)
    }
}

enum ScannerError: LocalizedError {
    case unavailable, denied, invalid, interrupted
    var errorDescription: String? {
        switch self {
        case .unavailable: return "A camera isn’t available. Paste the pairing code from your computer instead."
        case .denied: return "Camera access is off. You can enable it in iPhone Settings, or paste your pairing code."
        case .invalid: return "This isn’t a PairIt code. Open Pair a phone in the desktop app and try again."
        case .interrupted: return "Scanning stopped. Tap Scan QR code to try again, or paste the pairing code."
        }
    }
}

struct ScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let complete: (Result<String, ScannerError>) -> Void
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                QRScanner(complete: complete).ignoresSafeArea(edges: .bottom)
                Text("Point at the code in PairIt on your computer.")
                    .font(.subheadline).padding(18).frame(maxWidth: .infinity)
                    .background(.regularMaterial).padding(20)
            }.navigationTitle("Scan pairing code").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let complete: (Result<String, ScannerError>) -> Void
    func makeUIViewController(context: Context) -> QRScannerController { QRScannerController(complete: complete) }
    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) { }
    static func dismantleUIViewController(_ uiViewController: QRScannerController, coordinator: ()) { uiViewController.cancel() }
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "relay.pairing.camera")
    private let complete: (Result<String, ScannerError>) -> Void
    private var preview: AVCaptureVideoPreviewLayer?
    private var active = true // Capture queue owns this flag.
    private var completed = false // Main queue owns this flag.
    private var observers: [NSObjectProtocol] = []
    init(complete: @escaping (Result<String, ScannerError>) -> Void) { self.complete = complete; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use init(complete:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = UIColor(RelayPalette.ice)
        let preview = AVCaptureVideoPreviewLayer(session: session); preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview); self.preview = preview
        observers = [
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.finish(.failure(.interrupted)) },
            NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] _ in self?.finish(.failure(.unavailable)) },
            NotificationCenter.default.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { [weak self] _ in self?.finish(.failure(.interrupted)) }
        ]
        guard AVCaptureDevice.default(for: .video) != nil else { finish(.failure(.unavailable)); return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                if allowed { self?.start() } else { self?.finish(.failure(.denied)) }
            }
        default: finish(.failure(.denied))
        }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); cancel() }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    func cancel() { completed = true; stop() }
    func stop() { queue.async { self.active = false; self.session.stopRunning() } }
    private func start() {
        queue.async {
            guard self.active else { return }
            guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera) else {
                self.finish(.failure(.unavailable)); return
            }
            let output = AVCaptureMetadataOutput()
            self.session.beginConfiguration()
            guard self.session.canAddInput(input), self.session.canAddOutput(output) else {
                self.session.commitConfiguration(); self.finish(.failure(.unavailable)); return
            }
            self.session.addInput(input); self.session.addOutput(output)
            guard output.availableMetadataObjectTypes.contains(.qr) else {
                self.session.commitConfiguration(); self.finish(.failure(.unavailable)); return
            }
            output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
            self.session.commitConfiguration(); self.session.startRunning()
            if !self.session.isRunning { self.finish(.failure(.unavailable)) }
        }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        finish((try? PairedMac.parse(value)) != nil ? .success(value) : .failure(.invalid))
    }
    private func finish(_ result: Result<String, ScannerError>) {
        DispatchQueue.main.async {
            guard !self.completed else { return }; self.completed = true; self.stop(); self.complete(result)
        }
    }
}
