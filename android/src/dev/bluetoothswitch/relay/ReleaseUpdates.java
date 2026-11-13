package dev.bluetoothswitch.relay;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import com.google.android.play.core.appupdate.AppUpdateManagerFactory;
import com.google.android.play.core.install.model.UpdateAvailability;
import org.json.*;
import java.net.*;
import java.io.*;
import java.security.MessageDigest;
import java.util.concurrent.*;

/** UI-only checks. Never runs in the playback service or downloads executable code. */
final class ReleaseUpdates {
    interface Listener { void changed(String label, String url); }
    private final Activity activity;
    private final Listener listener;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final SharedPreferences cache;
    private final boolean play;
    private final boolean storeCapable;
    private boolean checking, destroyed;
    private long lastAttempt;
    private long availablePlayBuild;
    private android.app.AlertDialog prompt;
    private static final String FEED = "https://raw.githubusercontent.com/Json604/pairIt-download/main/release/updates.json";
    private static final String STORE = "https://play.google.com/store/apps/details?id=dev.bluetoothswitch.relay";
    ReleaseUpdates(Activity activity, Listener listener) {
        this.activity = activity; this.listener = listener;
        cache = activity.getSharedPreferences("release-updates-v1", 0);
        String installer = null;
        try { installer = activity.getPackageManager().getInstallerPackageName(activity.getPackageName()); } catch (Exception ignored) { }
        play = "com.android.vending".equals(installer);
        storeCapable = "dev.bluetoothswitch.relay".equals(activity.getPackageName());
        if (storeCapable && cache.getLong("playBuild", 0) > BuildConfig.VERSION_CODE)
            listener.changed("Update available · Google Play", STORE);
        if (!play) {
            try { JSONObject entry = new JSONObject(cache.getString("entry", "{}")); if (eligible(entry)) show(entry); }
            catch (Exception ignored) { }
        }
    }
    void checkOnResume() {
        // A foreground return should see a just-published Play update promptly.
        if (System.currentTimeMillis() - lastAttempt >= 60_000) lastAttempt = 0;
        check();
    }
    private void maybePrompt() {
        if (destroyed || availablePlayBuild <= BuildConfig.VERSION_CODE || prompt != null
                || activity.isFinishing() || !activity.hasWindowFocus() || PairingInterstitial.isPresenting()
                || cache.getLong("promptedBuild", 0) >= availablePlayBuild) return;
        prompt = new android.app.AlertDialog.Builder(activity).setTitle("PairIt update available")
                .setMessage("A newer version is available on Google Play. Update to get the latest fixes.")
                .setPositiveButton("Update", (dialog, which) -> open(STORE))
                .setNegativeButton("Later", null).create();
        prompt.setOnDismissListener(dialog -> prompt = null);
        prompt.show();
        cache.edit().putLong("promptedBuild", availablePlayBuild).apply();
    }
    void check() {
        maybePrompt();
        if (destroyed || checking || System.currentTimeMillis() - lastAttempt < 6 * 3600000L) return;
        lastAttempt = System.currentTimeMillis(); checking = true;
        if (storeCapable) {
            // Play determines eligibility for the user's actual track, rollout and signing key.
            AppUpdateManagerFactory.create(activity).getAppUpdateInfo().addOnSuccessListener(info -> {
                if (destroyed) return;
                checking = false;
                if (info.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE && info.availableVersionCode() > BuildConfig.VERSION_CODE) {
                    availablePlayBuild = info.availableVersionCode();
                    cache.edit().putLong("playBuild", availablePlayBuild).apply();
                    maybePrompt();
                    listener.changed("Update available · Google Play", STORE);
                } else {
                    availablePlayBuild = 0; cache.edit().remove("playBuild").apply();
                    if (play) listener.changed(null, null); else { checking = true; checkDirect(); }
                }
            }).addOnFailureListener(error -> { if (destroyed) return; if (play) retryLater(); else checkDirect(); });
            return;
        }
        checkDirect();
    }
    private void checkDirect() {
        if (destroyed) return;
        worker.execute(() -> {
            HttpURLConnection connection = null;
            try {
                connection = (HttpURLConnection) new URL(FEED).openConnection();
                connection.setConnectTimeout(12000); connection.setReadTimeout(12000);
                connection.setInstanceFollowRedirects(false); connection.setUseCaches(false);
                if (connection.getResponseCode() != 200) throw new IOException("Unavailable");
                ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                try (InputStream in = connection.getInputStream()) {
                    byte[] buffer = new byte[4096]; int n;
                    while ((n = in.read(buffer)) != -1) { if (bytes.size() + n > 65536) throw new IOException("Oversize"); bytes.write(buffer, 0, n); }
                }
                JSONObject feed = new JSONObject(bytes.toString("UTF-8"));
                JSONArray releases = feed.getJSONArray("releases");
                if (feed.getInt("schema") != 1 || releases.length() > 100) throw new IOException("Unsupported feed");
                JSONObject newest = null;
                for (int i=0; i<releases.length(); i++) {
                    JSONObject item = releases.getJSONObject(i);
                    if (eligible(item) && (newest == null || item.getLong("build") > newest.getLong("build"))) newest = item;
                }
                final JSONObject result = newest;
                main.post(() -> {
                    if (destroyed) return;
                    checking = false;
                    if (result == null) { cache.edit().remove("entry").apply(); listener.changed(null, null); }
                    else { cache.edit().putString("entry", result.toString()).apply(); show(result); }
                });
            } catch (Exception ignored) { main.post(this::retryLater); }
            finally { if (connection != null) connection.disconnect(); }
        });
    }
    private boolean eligible(JSONObject item) throws Exception {
        if (!"android".equals(item.optString("platform")) || !activity.getPackageName().equals(item.optString("bundleID"))
            || item.optLong("build") <= BuildConfig.VERSION_CODE || item.optInt("minimumSDK", Integer.MAX_VALUE) > Build.VERSION.SDK_INT
            || !item.optString("version").matches("[0-9]+\\.[0-9]+\\.[0-9]+([.-][A-Za-z0-9.]+)?")) return false;
        if (!ReleaseDownloadLink.trusted(item.optString("url"))) return false;
        // APK updates require the same package and certificate; never send a Play-signed
        // or locally re-signed copy to an incompatible upload-key APK.
        android.content.pm.Signature[] signatures = activity.getPackageManager().getPackageInfo(activity.getPackageName(), PackageManager.GET_SIGNING_CERTIFICATES).signingInfo.getApkContentsSigners();
        if (signatures.length != 1) return false;
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(signatures[0].toByteArray());
        StringBuilder hex = new StringBuilder(); for (byte b : digest) hex.append(String.format(java.util.Locale.ROOT,"%02x", b & 255));
        return hex.toString().equals(item.optString("signerSHA256"));
    }
    private void show(JSONObject entry) { listener.changed("Update available · " + entry.optString("version"), entry.optString("url")); }
    private void retryLater() { if (destroyed) return; checking = false; lastAttempt = System.currentTimeMillis() - 6 * 3600000L + 300000L; }
    void open(String url) {
        try { activity.startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url))); }
        catch (android.content.ActivityNotFoundException error) { android.widget.Toast.makeText(activity,"No browser or store available to open the update.",android.widget.Toast.LENGTH_LONG).show(); }
    }
    void destroy() { destroyed = true; if (prompt != null) prompt.dismiss(); worker.shutdownNow(); main.removeCallbacksAndMessages(null); }
}
