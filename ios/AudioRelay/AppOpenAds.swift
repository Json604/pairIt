import SwiftUI
import Network
import GoogleMobileAds

/// An ad presentation excludes new audio starts, including remote commands.
/// Ownership survives changes to the SwiftUI view that initiated presentation.
enum AudioPresentationGate {
    private static let lock = NSLock()
    private static var owner: AnyObject?
    static var isPresenting: Bool { lock.lock(); defer { lock.unlock() }; return owner != nil }
    static func acquire(_ candidate: AnyObject, audioIdle: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard owner == nil, audioIdle else { return false }
        owner = candidate; return true
    }
    static func release(_ candidate: AnyObject) {
        lock.lock(); defer { lock.unlock() }
        if owner === candidate { owner = nil }
    }
}

/// App-open ad pacing, identical to Android's AdTiming. Banner refresh is configured in AdMob.
enum AdTiming {
    /// Minimum gap between two app-open ads.
    static let cooldown: TimeInterval = 180
    /// A warm return must follow a real absence, not a share sheet or settings hop.
    static let away: TimeInterval = 30
    static func appOpenDue(now: TimeInterval, lastShown: TimeInterval) -> Bool {
        lastShown <= 0 || (now >= lastShown && now - lastShown >= cooldown)
    }
    static func returnEligible(now: TimeInterval, backgroundedAt: TimeInterval) -> Bool {
        backgroundedAt <= 0 || now < backgroundedAt || now - backgroundedAt >= away
    }
    /// A cold launch waits (on a plain loading screen) up to this long for the first ad.
    static let coldWait: TimeInterval = 6
    /// A preloaded ad only needs the window to become presentable.
    static let presentationWait: TimeInterval = 1
    /// Google expires app-open ads after four hours; refresh a little earlier.
    static let adExpiry: TimeInterval = 4 * 60 * 60 - 5 * 60
    /// Initial no-fill retries back off; a banner that has shown an ad keeps it on refresh failure.
    static func bannerRetry(failures: Int) -> TimeInterval { min(60, 15 * TimeInterval(1 << max(0, min(2, failures)))) }
}

/// The original opening screen (black, "PairIt") while a cold launch waits for its app-open ad.
struct LaunchLoadingView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Text("PairIt").font(.title.bold()).foregroundStyle(.white)
        }.contentShape(Rectangle()).onTapGesture { }
            .accessibilityElement(children: .ignore).accessibilityLabel("Loading PairIt").accessibilityAddTraits(.isModal)
    }
}

/// App-open ads never interrupt an audio session. A cold launch that is online shows a plain
/// loading screen and waits (bounded) for the first ad; a return after 30 s away shows only an
/// already-loaded ad within about a second. Otherwise the opening is skipped and one is requested
/// for next time. A late ad is kept, never shown by surprise.
@MainActor
final class AppOpeningAds: NSObject, FullScreenContentDelegate {
    private weak var ads: BannerAds?
    private var cached: AppOpenAd?
    private var onscreen: AppOpenAd?
    private var loading = false
    private var loadGeneration = 0
    private var loadedAt: TimeInterval = 0
    private var retryAfter: TimeInterval = 0
    private var check: Task<Void, Never>?
    private var deadline: TimeInterval = 0
    private var eligibility: (() -> Bool)?
    private var opportunity = true, coldStart = true
    private var backgroundedAt: TimeInterval = 0
    private var status = "Not requested"
    private let path = NWPathMonitor()
    private var online: Bool? // Unknown until the first path update: assume online.
    init(ads: BannerAds) {
        self.ads = ads
        super.init()
        path.pathUpdateHandler = { [weak self] update in
            let satisfied = update.status == .satisfied
            Task { @MainActor in self?.online = satisfied }
        }
        path.start(queue: DispatchQueue(label: "pairit.ads.path"))
    }
    deinit { path.cancel() }
    var diagnostics: String { "App-open ad: " + status + (cached != nil ? " (one ready)" : loading ? " (loading)" : "") }
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var unitID: String {
        BannerAds.testMode ? "ca-app-pub-3940256099942544/5575463023" : Bundle.main.object(forInfoDictionaryKey: "PairItAppOpenAdUnitID") as? String ?? ""
    }
    private func setStatus(_ value: String) {
        guard status != value else { return }
        ads?.objectWillChange.send(); status = value
    }
    func prepare() {
        if cached != nil, uptime - loadedAt >= AdTiming.adExpiry { cached = nil }
        guard let ads, !loading, cached == nil, !unitID.isEmpty, uptime >= retryAfter,
              UIApplication.shared.applicationState == .active else { return }
        // Consent and SDK start do not wait for the banner slot. Without mediation the request
        // can go out once start has been called; presenting still waits for initialization.
        guard ads.canLoadFullscreen else { ads.start(); return }
        loading = true
        let generation = loadGeneration, privacy = ads.consentRevision, identifier = unitID
        let request = Request(); let extras = Extras(); extras.additionalParameters = ["npa": "1"]; request.register(extras)
        Task { [weak self] in
            do {
                let value = try await AppOpenAd.load(with: identifier, request: request)
                guard let self, generation == self.loadGeneration else { return }
                self.loading = false
                guard ads.canLoadFullscreen, privacy == ads.consentRevision else { return }
                self.cached = value; self.loadedAt = self.uptime
                if self.check == nil { self.setStatus("Loaded; kept for the next opening") }
            } catch {
                guard let self, generation == self.loadGeneration else { return }
                self.loading = false; self.retryAfter = self.uptime + 30
                self.setStatus("Unavailable (Google load code \((error as NSError).code))")
                self.endOpening()
            }
        }
    }
    /// The scene became active. Only a cold launch or a return after 30 s away is an opening.
    func foreground(eligible: @escaping () -> Bool) {
        ads?.start()
        guard opportunity, onscreen == nil else { prepare(); return }
        opportunity = false
        let cold = coldStart; coldStart = false
        guard cold || AdTiming.returnEligible(now: Date().timeIntervalSince1970, backgroundedAt: backgroundedAt) else {
            setStatus("Skipped: away less than 30 seconds"); prepare(); return
        }
        open(coldStart: cold, eligible: eligible)
    }
    /// The scene entered the background; the next foreground may be an opening.
    func background() {
        pause()
        if onscreen == nil { opportunity = true; backgroundedAt = Date().timeIntervalSince1970 }
    }
    private func open(coldStart: Bool, eligible: @escaping () -> Bool) {
        guard let ads, !ads.openingScreen, onscreen == nil, !AudioPresentationGate.isPresenting else { return }
        guard eligible() else { setStatus("Skipped: audio active or screen busy"); prepare(); return }
        let last = UserDefaults.standard.double(forKey: "lastFullscreenAd")
        guard AdTiming.appOpenDue(now: Date().timeIntervalSince1970, lastShown: last) else {
            setStatus("Skipped: shown in the last 3 minutes"); prepare(); return
        }
        guard !unitID.isEmpty else { setStatus("Ad unit not configured"); return }
        if cached != nil, uptime - loadedAt >= AdTiming.adExpiry { cached = nil }
        let wait = cached == nil && coldStart && online != false
        guard cached != nil || wait else {
            setStatus(coldStart ? "Skipped: offline" : "Skipped: no ad loaded yet (requested for next time)"); prepare(); return
        }
        eligibility = eligible; ads.openingScreen = true; ads.launchLoading = wait
        deadline = uptime + (wait ? AdTiming.coldWait : AdTiming.presentationWait)
        setStatus(wait ? "Loading for launch" : "Showing loaded ad"); prepare()
        check = Task { @MainActor [weak self] in
            // One short turn first, so an audio action from a widget or link is handled before any ad.
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            while !Task.isCancelled {
                guard let self, let ads = self.ads, ads.openingScreen, self.onscreen == nil else { return }
                guard self.eligibility?() == true else { self.setStatus("Skipped: audio active or screen busy"); self.endOpening(); return }
                guard self.uptime < self.deadline else {
                    self.setStatus(self.cached == nil ? "Skipped: not loaded within 6 s (kept loading for next time)" : "Skipped: window not ready in time")
                    self.endOpening(); return
                }
                if UIApplication.shared.applicationState == .active, let candidate = self.cached, ads.canRequestFullscreen,
                   let presenter = BannerAds.presenter, presenter.presentedViewController == nil,
                   !presenter.isBeingPresented, !presenter.isBeingDismissed, presenter.viewIfLoaded?.window != nil {
                    do { try candidate.canPresent(from: presenter) }
                    catch { self.cached = nil; self.setStatus("Unavailable (Google presentation code \((error as NSError).code))"); self.endOpening(); return }
                    guard AudioPresentationGate.acquire(self, audioIdle: self.eligibility?() == true) else {
                        self.setStatus("Skipped: audio session busy"); self.endOpening(); return
                    }
                    self.cached = nil; self.onscreen = candidate; ads.fullscreenActive = true; self.setStatus("Presenting")
                    candidate.fullScreenContentDelegate = self; candidate.present(from: presenter); return
                }
                self.prepare()
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            }
        }
    }
    func pause() { if onscreen == nil { endOpening() } }
    func consentChanged() { loadGeneration += 1; loading = false; cached = nil; endOpening() }
    /// `openingScreen` holds automatic confirmation, and the cold-launch loading view stays
    /// behind a presented ad, until the ad closes or the opening is skipped.
    private func endOpening() {
        check?.cancel(); check = nil; eligibility = nil
        if ads?.openingScreen == true { ads?.openingScreen = false }
        if ads?.launchLoading == true { ads?.launchLoading = false }
    }
    func adWillPresentFullScreenContent(_ ad: FullScreenPresentingAd) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastFullscreenAd")
        setStatus("Shown")
    }
    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) { finish() }
    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        setStatus("Unavailable (Google show code \((error as NSError).code))"); finish()
    }
    private func finish() {
        guard onscreen != nil else { return }
        onscreen?.fullScreenContentDelegate = nil; onscreen = nil
        AudioPresentationGate.release(self); ads?.fullscreenActive = false; endOpening(); prepare()
    }
}
