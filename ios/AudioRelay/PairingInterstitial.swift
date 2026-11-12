import SwiftUI
import GoogleMobileAds

/// An ad presentation excludes new audio starts, including remote commands.
/// Ownership survives changes to the SwiftUI sheet that initiated presentation.
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

@MainActor
final class PairingInterstitial: NSObject, FullScreenContentDelegate {
    private weak var ads: BannerAds?
    private var cached: InterstitialAd?
    private var onscreen: InterstitialAd?
    private var pairing = false
    private var loading = false
    private var generation = 0
    private var loadedAt: TimeInterval = 0
    private var retryAfter: TimeInterval = 0
    private var completion: (() -> Void)?
    private var pendingCompletion: (() -> Void)?
    private var pendingEligibility: (() -> Bool)?
    private var pendingFlow = 0
    private var pendingConsentRevision = 0
    private var presentationDeadline: TimeInterval = 0
    private var presentationCheck: Task<Void, Never>?
    private var loadFailure = "No ad ready"
    init(ads: BannerAds) { self.ads = ads }
    private var coolingDown: Bool {
        let elapsed = Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: "lastPairingVideo")
        return elapsed >= 0 && elapsed < 300
    }
    private var unitID: String {
        BannerAds.testMode ? "ca-app-pub-3940256099942544/4411468910" : Bundle.main.object(forInfoDictionaryKey: "PairItInterstitialAdUnitID") as? String ?? ""
    }
    func begin(audioIdle: Bool) -> Int { cancelUnshown(); pairing = true; prepare(flow: generation, audioIdle: audioIdle); return generation }
    func prepare(flow: Int, audioIdle: Bool) {
        guard flow == generation, pairing, !loading, cached == nil, pendingCompletion == nil else { return }
        guard !coolingDown else { setStatus("Five-minute frequency limit"); return }
        guard ProcessInfo.processInfo.systemUptime >= retryAfter else { setStatus(loadFailure); return }
        guard audioIdle, !AudioPresentationGate.isPresenting, UIApplication.shared.applicationState == .active else {
            setStatus("Audio active or app hidden"); return
        }
        guard let ads, ads.canRequestFullscreen else { setStatus("Ad privacy or SDK not ready"); return }
        guard !unitID.isEmpty else { setStatus("Ad unit not configured"); return }
        loading = true
        loadFailure = "No ad ready"; setStatus("Loading")
        let ticket = generation, consentRevision = ads.consentRevision
        let identifier = unitID
        let request = Request(); let extras = Extras(); extras.additionalParameters = ["npa": "1"]; request.register(extras)
        Task { [weak self] in
            do {
                let value = try await InterstitialAd.load(with: identifier, request: request)
                guard let self, self.generation == ticket, self.pairing else { return }
                self.loading = false
                guard ads.canRequestFullscreen, consentRevision == ads.consentRevision else {
                    self.setStatus("Ad privacy changed"); self.attemptPresentation(); return
                }
                self.cached = value; self.loadedAt = ProcessInfo.processInfo.systemUptime
                self.setStatus("Ready"); self.attemptPresentation()
            } catch {
                guard let self, self.generation == ticket else { return }
                self.loading = false; self.cached = nil; self.retryAfter = ProcessInfo.processInfo.systemUptime + 60
                self.loadFailure = "Unavailable (Google load code \((error as NSError).code))"
                self.setStatus(self.loadFailure); self.attemptPresentation()
            }
        }
    }
    func showAfterPairing(flow: Int, eligible: @escaping () -> Bool, next: @escaping () -> Void) {
        guard flow == generation, pairing else { next(); return }
        guard pendingCompletion == nil else { return }
        pendingCompletion = next; pendingEligibility = eligible; pendingFlow = flow
        pendingConsentRevision = ads?.consentRevision ?? -1
        presentationDeadline = ProcessInfo.processInfo.systemUptime + 1.2
        attemptPresentation()
    }
    private func attemptPresentation() {
        guard pendingCompletion != nil else { return }
        presentationCheck?.cancel(); presentationCheck = nil
        guard pendingFlow == generation, pairing else { skip("Pairing changed"); return }
        guard UIApplication.shared.applicationState == .active, let eligible = pendingEligibility, eligible() else {
            skip("Audio active or pairing screen unavailable"); return
        }
        guard let ads, ads.canRequestFullscreen, ads.consentRevision == pendingConsentRevision else {
            skip("Ad privacy or SDK not ready"); return
        }
        guard !unitID.isEmpty else { skip("Ad unit not configured"); return }
        guard !coolingDown else { skip("Five-minute frequency limit"); return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now < presentationDeadline else { skip(cached == nil ? "Ad not ready within 1.2 seconds" : "Window not ready within 1.2 seconds"); return }
        guard let candidate = cached else {
            guard loading else { skip(loadFailure); return }
            // Finish only an existing load; never request a new ad after pairing is saved.
            setStatus("Finishing existing ad load"); schedulePresentationCheck(); return
        }
        guard now - loadedAt < 55 * 60 else { skip("Cached ad expired"); return }
        guard let presenter = BannerAds.presenter, !presenter.isBeingDismissed, !presenter.isBeingPresented,
              presenter.viewIfLoaded?.window != nil else {
            setStatus("Waiting for pairing screen"); schedulePresentationCheck(); return
        }
        do { try candidate.canPresent(from: presenter) }
        catch { skip("Unavailable (Google presentation code \((error as NSError).code))"); return }
        guard AudioPresentationGate.acquire(self, audioIdle: eligible()) else { skip("Audio session busy"); return }
        let next = clearUnshown()
        onscreen = candidate; completion = next; ads.fullscreenActive = true
        setStatus("Presenting")
        candidate.fullScreenContentDelegate = self
        candidate.present(from: presenter)
    }
    private func schedulePresentationCheck() {
        let delay = min(0.05, max(0.001, presentationDeadline - ProcessInfo.processInfo.systemUptime))
        presentationCheck = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.attemptPresentation()
        }
    }
    private func skip(_ reason: String) {
        let next = clearUnshown(); setStatus("Skipped: \(reason)"); next?()
    }
    func adWillPresentFullScreenContent(_ ad: FullScreenPresentingAd) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastPairingVideo")
        setStatus("Shown")
    }
    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) { finish("Shown; closed") }
    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        finish("Unavailable (Google presentation code \((error as NSError).code))")
    }
    private func finish(_ result: String) {
        guard onscreen != nil else { return }
        onscreen?.fullScreenContentDelegate = nil; onscreen = nil
        AudioPresentationGate.release(self); ads?.fullscreenActive = false
        setStatus(result)
        let next = completion; completion = nil; next?()
    }
    private func clearUnshown() -> (() -> Void)? {
        let next = pendingCompletion; pendingCompletion = nil; pendingEligibility = nil
        presentationCheck?.cancel(); presentationCheck = nil
        generation += 1; pairing = false; loading = false; cached = nil
        return next
    }
    func cancelUnshown(flow: Int? = nil) {
        if let flow, flow != generation { return }
        let next = clearUnshown()
        if next != nil { setStatus("Skipped: pairing interrupted"); next?() }
        // Background, consent changes and sheet dismissal invalidate pending ads,
        // never the lease of a video already on screen.
    }
    private func setStatus(_ value: String) { ads?.updatePairingAdStatus(value) }
}
