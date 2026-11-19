import SwiftUI
import GoogleMobileAds
import UserMessagingPlatform

/// Advertising owns no receiver, pairing, microphone or audio-session objects.
@MainActor
final class BannerAds: ObservableObject {
    #if DEBUG || targetEnvironment(simulator)
    static let testMode = true
    #else
    static let testMode = false
    #endif
    @Published private(set) var ready = false
    @Published private(set) var privacyRequired = false
    @Published var privacyMessage: String?
    @Published var fullscreenActive = false
    @Published var openingScreen = false
    /// A cold launch is waiting for its app-open ad behind a static loading view.
    @Published var launchLoading = false
    private(set) var bannerStatus = "Not requested"
    private(set) var bannerVisible = false
    private(set) var consentRevision = 0
    lazy var appOpen = AppOpeningAds(ads: self)
    /// Presenting needs initialization to have completed.
    var canRequestFullscreen: Bool { initialized && !gatheringConsent && permitted }
    /// Loading only needs MobileAds.start to have been called with valid consent (no mediation).
    var canLoadFullscreen: Bool { (initializing || initialized) && !gatheringConsent && permitted }
    @Published var muted = UserDefaults.standard.object(forKey: "adSoundMuted") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(muted, forKey: "adSoundMuted")
            if initialized { MobileAds.shared.isApplicationMuted = muted }
        }
    }
    private var requestedConsent = false
    private var gatheringConsent = false
    private var initializing = false
    private var initialized = false
    var bannerID: String {
        Self.testMode ? "ca-app-pub-3940256099942544/2435281174" : Bundle.main.object(forInfoDictionaryKey: "PairItBannerAdUnitID") as? String ?? ""
    }
    private var permitted: Bool { Self.testMode || ConsentInformation.shared.canRequestAds }
    var diagnostics: String {
        let privacy = gatheringConsent ? "Checking" : Self.testMode ? "Test mode" : permitted ? "Requests allowed" : "Requests blocked"
        return "Ad mode: \(Self.testMode ? "Google test units" : "Live")\nConsent SDK: \(privacy)"
            + "\nAd SDK: \(initialized ? "Ready" : "Not ready")\nLast banner request: \(bannerStatus)"
            + "\nBanner visibility: \(bannerVisible ? "Visible" : "Hidden")\n" + appOpen.diagnostics
    }
    fileprivate func updateBannerStatus(_ value: String) { bannerStatus = value }
    fileprivate func updateBannerVisibility(_ value: Bool) { bannerVisible = value }

    /// Starts consent and the SDK from the foreground window, without waiting for the banner slot.
    func start() { if let presenter = Self.presenter { begin(from: presenter) } }
    func begin(from presenter: UIViewController) {
        guard UIApplication.shared.applicationState == .active, presenter.viewIfLoaded?.window != nil else { return }
        // Only Google's dedicated test unit bypasses publisher consent configuration.
        if Self.testMode { initializeIfPermitted(); return }
        guard !requestedConsent else { initializeIfPermitted(); return }
        requestedConsent = true; gatheringConsent = true
        consentRevision += 1; appOpen.consentChanged()
        ConsentInformation.shared.requestConsentInfoUpdate(with: RequestParameters()) { [weak self, weak presenter] error in
            Task { @MainActor in
                guard let self else { return }
                self.privacyRequired = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
                if error != nil {
                    self.gatheringConsent = false
                    self.initializeIfPermitted()
                    return
                }
                guard let presenter, presenter.viewIfLoaded?.window != nil,
                      UIApplication.shared.applicationState == .active else {
                    // Retry presentation when the foreground UI is available again.
                    self.requestedConsent = false; self.gatheringConsent = false
                    return
                }
                do { try await ConsentForm.loadAndPresentIfRequired(from: presenter) }
                catch { /* An unavailable form never blocks local audio. */ }
                self.gatheringConsent = false
                self.privacyRequired = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
                self.initializeIfPermitted()
            }
        }
        // Valid prior consent can warm the SDK; requests still wait for this check.
        initializeIfPermitted(warmOnly: true)
    }
    private func initializeIfPermitted(warmOnly: Bool = false) {
        guard permitted, (!gatheringConsent || warmOnly), UIApplication.shared.applicationState == .active else { setReady(false); return }
        if initialized { setReady(!gatheringConsent); return }
        guard !initializing, !bannerID.isEmpty else { return }
        initializing = true
        let sdk = MobileAds.shared
        sdk.requestConfiguration.maxAdContentRating = .general
        sdk.requestConfiguration.coarseLocationCollectionEnabled = false
        sdk.requestConfiguration.setPublisherFirstPartyIDEnabled(false)
        // Prevent the SDK from changing the receiver's AVAudioSession category.
        sdk.audioVideoManager.isAudioSessionApplicationManaged = true
        sdk.start { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.initialized = true; self.initializing = false
                MobileAds.shared.isApplicationMuted = self.muted
                self.setReady(self.permitted && !self.gatheringConsent)
            }
        }
    }
    private func setReady(_ value: Bool) { if ready != value { ready = value } }
    func showPrivacyOptions() {
        if Self.testMode {
            privacyMessage = "This build uses Google’s test ads. Live regional consent forms are checked with the release configuration after publisher setup."
            return
        }
        guard !gatheringConsent, let presenter = Self.presenter else { return }
        let status = ConsentInformation.shared.privacyOptionsRequirementStatus
        guard status == .required else {
            if status == .unknown {
                requestedConsent = false; begin(from: presenter)
                privacyMessage = "Ad privacy choices are unavailable. Check your internet connection and try again. PairIt remains usable."
            } else { privacyMessage = "No additional ad consent choices are currently required for your region. Read our privacy policy for how advertising uses data." }
            return
        }
        setReady(false); gatheringConsent = true
        consentRevision += 1; appOpen.consentChanged()
        ConsentForm.presentPrivacyOptionsForm(from: presenter) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.gatheringConsent = false
                self.privacyRequired = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
                if error != nil { self.privacyMessage = "Couldn’t open ad privacy choices. Please try again when you have an internet connection." }
                self.initializeIfPermitted()
            }
        }
    }
    static var presenter: UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return nil }
        while let presented = controller.presentedViewController, !presented.isBeingDismissed { controller = presented }
        return controller
    }
}

/// The slot remains mounted at zero height until an ad actually loads. A first-load
/// failure collapses it and retries after 15, 30, then 60 seconds; a failed refresh
/// keeps the ad already shown.
struct BannerAdSlot: View {
    @ObservedObject var ads: BannerAds
    let active: Bool
    @State private var height: CGFloat = 0
    var body: some View {
        VStack(spacing: 4) {
            if height > 0 {
                Text(BannerAds.testMode ? "Advertisement · test" : "Advertisement")
                    .font(.system(size: 11)).foregroundStyle(RelayPalette.secondary)
                    .padding(.top, 8)
            }
            BannerAdHost(ads: ads, active: active, height: $height)
                .frame(maxWidth: .infinity)
                .frame(height: height).clipped()
        }.frame(maxWidth: .infinity)
            .background(.white.opacity(0.9), ignoresSafeAreaEdges: [])
    }
}

private struct BannerAdHost: UIViewControllerRepresentable {
    @ObservedObject var ads: BannerAds
    let active: Bool
    @Binding var height: CGFloat
    func makeUIViewController(context: Context) -> BannerHostController {
        let controller = BannerHostController(ads: ads)
        controller.heightChanged = { height = $0 }
        return controller
    }
    func updateUIViewController(_ controller: BannerHostController, context: Context) {
        controller.setActive(active)
    }
    static func dismantleUIViewController(_ controller: BannerHostController, coordinator: ()) { controller.dismantle() }
}

@MainActor
private final class BannerHostController: UIViewController, BannerViewDelegate {
    private let ads: BannerAds
    private var banner: BannerView?
    private var active = false
    private var attemptedWidth: CGFloat = 0
    private var shownHeight: CGFloat = 0
    private var heightRevision = 0
    private var refreshRevision = 0
    private var refreshScheduled = false
    private var retryWork: DispatchWorkItem?
    private var nextLoadAt = Date.distantPast
    private var failures = 0
    private var loaded = false // The current BannerView has shown an ad.
    private var dismantled = false
    var heightChanged: (CGFloat) -> Void = { _ in }
    init(ads: BannerAds) { self.ads = ads; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = UIView(); view.backgroundColor = .clear }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); refresh() }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); refresh() }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); stop() }
    func setActive(_ value: Bool) {
        guard !dismantled else { return }
        guard active != value else { refresh(); return }
        active = value
        if value { scheduleRefresh() } else { stop() }
    }
    private func scheduleRefresh() {
        guard active, !dismantled, !refreshScheduled else { return }
        refreshScheduled = true
        let revision = refreshRevision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.refreshRevision == revision else { return }
            self.refreshScheduled = false
            guard self.active, !self.dismantled else { return }
            self.refresh()
        }
    }
    private func refresh() {
        guard active, !dismantled, isViewLoaded, view.window != nil, UIApplication.shared.applicationState == .active else { return }
        ads.begin(from: self)
        guard ads.ready else { if banner != nil { stop() }; return }
        guard Date() >= nextLoadAt else { scheduleRetry(); return }
        let width = floor(view.bounds.width - view.safeAreaInsets.left - view.safeAreaInsets.right)
        guard width >= 280, width != attemptedWidth else { return }
        stop(); attemptedWidth = width
        let size = currentOrientationAnchoredAdaptiveBanner(width: width)
        let next = BannerView(adSize: size)
        next.adUnitID = ads.bannerID; next.rootViewController = self; next.delegate = self
        next.translatesAutoresizingMaskIntoConstraints = false
        next.accessibilityLabel = "Advertisement"
        banner = next; view.addSubview(next)
        NSLayoutConstraint.activate([next.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     next.topAnchor.constraint(equalTo: view.topAnchor)])
        let request = Request()
        let extras = Extras(); extras.additionalParameters = ["npa": "1"]
        request.register(extras)
        ads.updateBannerStatus("Loading")
        next.load(request)
    }
    private func scheduleRetry() {
        guard active, !dismantled, retryWork == nil, UIApplication.shared.applicationState == .active else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWork = nil; self.refresh()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, nextLoadAt.timeIntervalSinceNow), execute: work)
    }
    func stop() {
        retryWork?.cancel(); retryWork = nil
        refreshRevision += 1; refreshScheduled = false
        banner?.delegate = nil; banner?.rootViewController = nil; banner?.removeFromSuperview(); banner = nil; loaded = false
        attemptedWidth = 0; publishHeight(0)
    }
    func dismantle() { dismantled = true; active = false; stop() }
    private func publishHeight(_ height: CGFloat) {
        ads.updateBannerVisibility(height > 0 && active && viewIfLoaded?.window != nil)
        guard shownHeight != height else { return }
        shownHeight = height; heightRevision += 1
        let revision = heightRevision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.heightRevision == revision else { return }
            self.heightChanged(height)
        }
    }
    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        guard banner === bannerView, active else { return }
        loaded = true; failures = 0
        ads.updateBannerStatus("Loaded")
        publishHeight(bannerView.adSize.size.height)
    }
    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        guard banner === bannerView else { return }
        // A failed automatic refresh keeps the creative that is already on screen.
        if loaded { ads.updateBannerStatus("Showing previous ad (refresh code \((error as NSError).code))"); return }
        ads.updateBannerStatus("Unavailable (Google load code \((error as NSError).code))")
        bannerView.removeFromSuperview(); bannerView.delegate = nil; banner = nil
        attemptedWidth = 0; nextLoadAt = Date().addingTimeInterval(AdTiming.bannerRetry(failures: failures)); failures += 1
        publishHeight(0)
        scheduleRetry()
    }
}
