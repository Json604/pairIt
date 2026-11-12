package dev.bluetoothswitch.relay;

import android.app.Activity;
import android.content.SharedPreferences;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import com.google.android.gms.ads.*;
import com.google.android.gms.ads.interstitial.*;
import java.util.function.BooleanSupplier;

/** One optional-to-serve ad at a completed pairing boundary, never an audio start. */
final class PairingInterstitial {
    private static final long PRESENTATION_WINDOW_MS = 1_200;
    private static volatile boolean presenting;
    private final Activity activity;
    private final BannerAds consentOwner;
    private final BooleanSupplier idleAndVisible;
    private final Runnable visibilityChanged;
    private final SharedPreferences preferences;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable checkPresentation = this::attemptPresentation;
    private InterstitialAd cached, onscreen;
    private boolean pairing, loading, destroyed, showing;
    private long generation, loadedAt, retryAfter;
    private long pendingFlow, pendingConsentRevision, presentationDeadline;
    private Runnable afterAd, pendingCompletion;
    private String status = "Waiting for a new pairing", loadFailure = "No ad ready";

    PairingInterstitial(Activity activity, BannerAds consentOwner, BooleanSupplier idleAndVisible, Runnable visibilityChanged) {
        this.activity = activity; this.consentOwner = consentOwner;
        this.idleAndVisible = idleAndVisible; this.visibilityChanged = visibilityChanged;
        preferences = activity.getSharedPreferences("advertising", Activity.MODE_PRIVATE);
    }
    static boolean isPresenting() { return presenting; }
    String diagnostics() { return "Pairing ad: " + status; }
    void presentationWindowChanged() { if (pendingCompletion != null) attemptPresentation(); }
    private boolean coolingDown() {
        long elapsed = System.currentTimeMillis() - preferences.getLong("lastPairingVideo", 0);
        return elapsed >= 0 && elapsed < 5 * 60_000;
    }
    long begin() { cancelUnshown(); pairing = true; prepare(); return generation; }
    void consentChanged() { cancelUnshown(); }
    void prepare() {
        if (destroyed || !pairing || loading || cached != null || pendingCompletion != null) return;
        if (coolingDown()) { setStatus("Five-minute frequency limit"); return; }
        if (SystemClock.elapsedRealtime() < retryAfter) { setStatus(loadFailure); return; }
        if (!idleAndVisible.getAsBoolean()) { setStatus("Audio active or app hidden"); return; }
        if (!consentOwner.canRequestFullscreen()) { setStatus("Ad privacy or SDK not ready"); return; }
        if (BuildConfig.INTERSTITIAL_AD_UNIT_ID.isEmpty()) { setStatus("Ad unit not configured"); return; }
        loading = true; long ticket = generation, consentRevision = consentOwner.consentRevision();
        loadFailure = "No ad ready"; setStatus("Loading");
        try {
            InterstitialAd.load(activity, BuildConfig.INTERSTITIAL_AD_UNIT_ID, new AdRequest.Builder().build(), new InterstitialAdLoadCallback() {
                @Override public void onAdLoaded(InterstitialAd value) {
                    if (destroyed || ticket != generation || !pairing) return;
                    loading = false;
                    if (consentRevision != consentOwner.consentRevision() || !consentOwner.canRequestFullscreen()) {
                        setStatus("Ad privacy changed"); attemptPresentation(); return;
                    }
                    cached = value; loadedAt = SystemClock.elapsedRealtime(); setStatus("Ready");
                    attemptPresentation();
                }
                @Override public void onAdFailedToLoad(LoadAdError error) {
                    if (destroyed || ticket != generation || !pairing) return;
                    loading = false; cached = null; retryAfter = SystemClock.elapsedRealtime() + 60_000;
                    loadFailure = "Unavailable (Google load code " + error.getCode() + ")";
                    setStatus(loadFailure); attemptPresentation();
                }
            });
        } catch (RuntimeException error) {
            loading = false; retryAfter = SystemClock.elapsedRealtime() + 60_000;
            loadFailure = "Ad request unavailable"; setStatus(loadFailure); attemptPresentation();
        }
    }
    void showAfterPairing(long flow, Runnable next) {
        if (flow != generation || !pairing) { next.run(); return; }
        if (pendingCompletion != null) return;
        pendingCompletion = next; pendingFlow = flow; pendingConsentRevision = consentOwner.consentRevision();
        presentationDeadline = SystemClock.elapsedRealtime() + PRESENTATION_WINDOW_MS;
        attemptPresentation();
    }
    private void attemptPresentation() {
        if (pendingCompletion == null) return;
        handler.removeCallbacks(checkPresentation);
        if (destroyed || pendingFlow != generation || !pairing) { skip("Pairing changed"); return; }
        if (activity.isFinishing() || activity.isDestroyed() || !idleAndVisible.getAsBoolean()) {
            skip("Audio active or app hidden"); return;
        }
        if (pendingConsentRevision != consentOwner.consentRevision() || !consentOwner.canRequestFullscreen()) {
            skip("Ad privacy or SDK not ready"); return;
        }
        if (BuildConfig.INTERSTITIAL_AD_UNIT_ID.isEmpty()) { skip("Ad unit not configured"); return; }
        if (coolingDown()) { skip("Five-minute frequency limit"); return; }
        long now = SystemClock.elapsedRealtime();
        if (now >= presentationDeadline) { skip(cached == null ? "Ad not ready within 1.2 seconds" : "Window not ready within 1.2 seconds"); return; }
        if (cached == null) {
            if (!loading) { skip(loadFailure); return; }
            // Only an existing request may finish here. Never start a new load after pairing.
            setStatus("Finishing existing ad load"); schedulePresentationCheck(); return;
        }
        if (now - loadedAt >= 55 * 60_000) { skip("Cached ad expired"); return; }
        if (!activity.hasWindowFocus()) {
            setStatus("Waiting for pairing dialog to close"); schedulePresentationCheck(); return;
        }
        if (!PhoneAudioSession.acquire(this, "Close the advertisement, then choose Computer to start audio.")) {
            skip("Audio session busy"); return;
        }
        InterstitialAd candidate = cached;
        Runnable next = clearUnshown();
        showing = true; presenting = true; onscreen = candidate; afterAd = next;
        setStatus("Presenting");
        visibilityChanged.run();
        try {
            candidate.setFullScreenContentCallback(new FullScreenContentCallback() {
                @Override public void onAdShowedFullScreenContent() {
                    if (onscreen != candidate) return;
                    preferences.edit().putLong("lastPairingVideo", System.currentTimeMillis()).apply();
                    setStatus("Shown");
                }
                @Override public void onAdDismissedFullScreenContent() { if (onscreen == candidate) finish("Shown; closed"); }
                @Override public void onAdFailedToShowFullScreenContent(AdError error) {
                    if (onscreen == candidate) finish("Unavailable (Google show code " + error.getCode() + ")");
                }
            });
            candidate.show(activity);
        } catch (RuntimeException error) { finish("Ad presentation unavailable"); }
    }
    private void schedulePresentationCheck() {
        handler.postDelayed(checkPresentation, Math.min(50, Math.max(1, presentationDeadline - SystemClock.elapsedRealtime())));
    }
    private void skip(String reason) {
        Runnable next = clearUnshown(); setStatus("Skipped: " + reason);
        if (!destroyed && next != null) next.run();
    }
    private void finish(String result) {
        if (!showing) return;
        showing = false; presenting = false; onscreen = null; PhoneAudioSession.release(this);
        setStatus(result);
        Runnable next = afterAd; afterAd = null;
        if (!destroyed) { visibilityChanged.run(); if (next != null) next.run(); }
    }
    private Runnable clearUnshown() {
        Runnable next = pendingCompletion; pendingCompletion = null;
        handler.removeCallbacks(checkPresentation);
        generation++; pairing = false; loading = false; cached = null;
        return next;
    }
    void cancelUnshown() {
        Runnable next = clearUnshown();
        if (next != null) { setStatus("Skipped: pairing interrupted"); if (!destroyed) next.run(); }
    }
    void cancelUnshown(long flow) { if (flow == generation) cancelUnshown(); }
    private void setStatus(String value) {
        if (status.equals(value)) return;
        status = value;
        android.util.Log.i("PairItAds", "Pairing ad: " + value);
    }
    void destroy() {
        destroyed = true; cancelUnshown(); afterAd = null;
        // AdActivity pauses/recreates its host. The lease belongs to this coordinator
        // until the SDK definitively reports dismissal or presentation failure.
        if (!showing) PhoneAudioSession.release(this);
    }
}
