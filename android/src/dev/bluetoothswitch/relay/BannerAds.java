package dev.bluetoothswitch.relay;

import android.app.Activity;
import android.app.AlertDialog;
import android.graphics.Color;
import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import com.google.android.gms.ads.*;
import com.google.android.ump.*;

/** Foreground-only monetization. Never touches playback or the foreground service. */
final class BannerAds {
    private final Activity activity;
    private final LinearLayout container;
    private final ConsentInformation consent;
    private AdView ad;
    private boolean started, initialized, destroyed, resumed, allowed, loaded, gatheringConsent;
    private boolean muted;
    private final android.os.Handler retryHandler = new android.os.Handler(android.os.Looper.getMainLooper());
    private final Runnable retryLoad = this::updateVisibility;
    private long nextLoadAt;
    private long consentRevision;
    private String bannerStatus = "Not requested";
    private Runnable readinessChanged = () -> { };
    private Runnable consentChanged = () -> { };

    BannerAds(Activity activity, LinearLayout container) {
        this.activity = activity;
        this.container = container;
        consent = UserMessagingPlatform.getConsentInformation(activity);
        muted = activity.getSharedPreferences("advertising", Activity.MODE_PRIVATE).getBoolean("muted", true);
        container.setVisibility(View.GONE);
    }

    void start() {
        if (destroyed || gatheringConsent) return;
        // Google's sample app ID has no publisher consent messages configured.
        // Test builds request only Google's dedicated test unit; live builds never bypass UMP.
        if (BuildConfig.ADS_TEST_MODE) { initialize(); return; }
        gatheringConsent = true; consentRevision++; consentChanged.run(); updateVisibility();
        consent.requestConsentInfoUpdate(activity, new ConsentRequestParameters.Builder().build(), () -> {
            if (destroyed) return;
            UserMessagingPlatform.loadAndShowConsentFormIfRequired(activity, error -> {
                if (destroyed) return;
                gatheringConsent = false;
                if (error != null) android.util.Log.w("PairItAds", "Consent form unavailable (" + error.getErrorCode() + ")");
                if (consent.canRequestAds()) initialize();
                updateVisibility();
            });
        }, error -> {
            if (destroyed) return;
            gatheringConsent = false;
            android.util.Log.w("PairItAds", "Consent update unavailable (" + error.getErrorCode() + ")");
            if (consent.canRequestAds()) initialize();
            updateVisibility();
        });
        // Warm the SDK using valid previous-session consent, while the new check runs.
        // Requests and display still wait for the current consent check to finish.
        if (consent.canRequestAds()) initialize();
    }

    private void initialize() {
        if (destroyed) return;
        if (started) { if (initialized && !gatheringConsent) readinessChanged.run(); return; }
        started = true;
        MobileAds.setRequestConfiguration(new RequestConfiguration.Builder()
                .setMaxAdContentRating(RequestConfiguration.MAX_AD_CONTENT_RATING_G).build());
        new Thread(() -> {
            try {
                MobileAds.initialize(activity.getApplicationContext(), status ->
                    activity.runOnUiThread(() -> {
                        if (destroyed) return;
                        // The SDK requires initialization before muting. Mute before any request.
                        initialized = true;
                        MobileAds.setAppMuted(muted);
                        readinessChanged.run();
                        container.post(this::updateVisibility);
                    }));
            } catch (RuntimeException error) {
                // Advertising is optional; an SDK initialization failure cannot stop the app.
                android.util.Log.w("PairItAds", "Ad initialization unavailable", error);
            }
        }, "ad-initialization").start();
    }

    private void load() {
        if (destroyed || gatheringConsent || ad != null || !resumed || !allowed || android.os.SystemClock.uptimeMillis() < nextLoadAt
                || (!BuildConfig.ADS_TEST_MODE && !consent.canRequestAds())) return;
        View parent = (View) container.getParent();
        int width = Math.min(600, (int) ((parent.getWidth()-parent.getPaddingLeft()-parent.getPaddingRight()) / activity.getResources().getDisplayMetrics().density));
        if (width < 1) return;
        AdSize size = AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(activity, width);
        container.setOrientation(LinearLayout.VERTICAL);
        container.setGravity(Gravity.CENTER_HORIZONTAL);
        container.setBackgroundColor(0xe6ffffff);
        container.setPadding(0, dp(12), 0, dp(4));
        TextView label = new TextView(activity);
        label.setText(BuildConfig.ADS_TEST_MODE ? "Advertisement · test" : "Advertisement");
        label.setTextColor(GlassUI.SECONDARY); label.setTextSize(11); label.setGravity(Gravity.CENTER);
        label.setPadding(0, 0, 0, dp(4)); container.addView(label);
        ad = new AdView(activity); ad.setAdSize(size); ad.setAdUnitId(BuildConfig.BANNER_AD_UNIT_ID);
        container.addView(ad, new LinearLayout.LayoutParams(size.getWidthInPixels(activity), size.getHeightInPixels(activity)));
        loaded = false;
        bannerStatus = "Loading";
        container.setVisibility(View.GONE);
        final AdView requestedAd = ad;
        ad.setAdListener(new AdListener() {
            @Override public void onAdLoaded() {
                if (destroyed || ad != requestedAd) return;
                loaded = true;
                bannerStatus = "Loaded";
                updateVisibility();
            }
            @Override public void onAdFailedToLoad(LoadAdError error) {
                if (destroyed || ad != requestedAd) return;
                loaded = false;
                bannerStatus = "Unavailable (Google load code " + error.getCode() + ")";
                container.setVisibility(View.GONE);
                requestedAd.destroy(); ad = null;
                container.removeAllViews();
                nextLoadAt = android.os.SystemClock.uptimeMillis() + 60_000;
                updateVisibility();
            }
        });
        ad.loadAd(new AdRequest.Builder().build());
    }

    void privacyOptions() {
        if (destroyed || gatheringConsent) return;
        if (!BuildConfig.ADS_TEST_MODE && consent.getPrivacyOptionsRequirementStatus()
                == ConsentInformation.PrivacyOptionsRequirementStatus.UNKNOWN) {
            new AlertDialog.Builder(activity).setTitle("Ad privacy choices unavailable")
                    .setMessage("We couldn’t load your ad privacy settings. Check your internet connection and try again. You can continue using PairIt.")
                    .setPositiveButton("Try again", (dialog, which) -> start())
                    .setNegativeButton("Close", null).show();
            return;
        }
        if (!BuildConfig.ADS_TEST_MODE && consent.getPrivacyOptionsRequirementStatus()
                == ConsentInformation.PrivacyOptionsRequirementStatus.REQUIRED) {
            gatheringConsent = true; consentRevision++; consentChanged.run();
            if (ad != null) { ad.destroy(); ad = null; }
            loaded = false;
            bannerStatus = "Cleared for privacy update";
            container.removeAllViews(); container.setVisibility(View.GONE);
            UserMessagingPlatform.showPrivacyOptionsForm(activity, error -> {
                if (destroyed) return;
                gatheringConsent = false;
                if (error != null) new AlertDialog.Builder(activity).setTitle("Privacy choices unavailable")
                        .setMessage("Please try again when you have an internet connection.")
                        .setPositiveButton("OK", null).show();
                if (consent.canRequestAds()) { if (initialized) updateVisibility(); else initialize(); }
            });
        } else new AlertDialog.Builder(activity).setTitle("Ad privacy choices")
                .setMessage(BuildConfig.ADS_TEST_MODE ? "This build uses Google’s test ads. Paid ads and regional consent messages will be enabled after publisher setup."
                        : "No additional ad consent choices are currently required for your region. You can manage your advertising ID in Android settings and read how ads use data in our privacy policy.")
                .setPositiveButton("Done", null).show();
    }

    boolean isMuted() { return muted; }
    String diagnostics() {
        String privacy = gatheringConsent ? "Checking" : BuildConfig.ADS_TEST_MODE ? "Test mode"
                : consent.canRequestAds() ? "Requests allowed" : "Requests blocked";
        return "Ad mode: " + (BuildConfig.ADS_TEST_MODE ? "Google test units" : "Live")
                + "\nConsent SDK: " + privacy + "\nAd SDK: " + (initialized ? "Ready" : "Not ready")
                + "\nBanner: " + bannerStatus;
    }
    boolean canRequestFullscreen() { return initialized && !destroyed && !gatheringConsent && (BuildConfig.ADS_TEST_MODE || consent.canRequestAds()); }
    long consentRevision() { return consentRevision; }
    void onReadinessChanged(Runnable callback) { readinessChanged = callback; }
    void onConsentChanged(Runnable callback) { consentChanged = callback; }
    void setMuted(boolean value) {
        muted = value;
        activity.getSharedPreferences("advertising", Activity.MODE_PRIVATE).edit().putBoolean("muted", value).apply();
        if (initialized) MobileAds.setAppMuted(value);
    }
    void setVisibleToUser(boolean value) {
        if (allowed == value) return;
        allowed = value; updateVisibility();
    }
    private void updateVisibility() {
        if (destroyed) return;
        boolean active = resumed && allowed && !gatheringConsent && (BuildConfig.ADS_TEST_MODE || consent.canRequestAds());
        if (ad != null) {
            if (active) ad.resume(); else ad.pause();
            container.setVisibility(active && loaded ? View.VISIBLE : View.GONE);
        } else if (active && initialized) {
            retryHandler.removeCallbacks(retryLoad);
            long delay = nextLoadAt - android.os.SystemClock.uptimeMillis();
            if (delay > 0) retryHandler.postDelayed(retryLoad, delay);
            else load();
        }
        if (!active) retryHandler.removeCallbacks(retryLoad);
    }
    void resume() { resumed = true; updateVisibility(); }
    void pause() { resumed = false; updateVisibility(); }
    void destroy() { destroyed = true; retryHandler.removeCallbacksAndMessages(null); if (ad != null) { ad.destroy(); ad = null; } container.removeAllViews(); }
    private int dp(int value) { return Math.round(value * activity.getResources().getDisplayMetrics().density); }
}
