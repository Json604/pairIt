package dev.bluetoothswitch.relay;

import android.content.Context;
import java.security.KeyStore;

/** Remove only purchase data left by the retired payment preview. Pairing and ad consent stay intact. */
final class LegacyPurchaseCleanup {
    /** Runs off the main thread, once per installation: opening the KeyStore is slow IPC
     * that otherwise delayed every app launch. */
    static void runInBackground(Context context) {
        Context app = context.getApplicationContext();
        android.content.SharedPreferences done = app.getSharedPreferences("maintenance", Context.MODE_PRIVATE);
        if (done.getBoolean("legacy_purchase_cleanup", false)) return;
        new Thread(() -> { if (run(app)) done.edit().putBoolean("legacy_purchase_cleanup", true).apply(); }, "legacy-cleanup").start();
    }
    static boolean run(Context context) {
        context.deleteSharedPreferences("pairit_pro");
        try {
            KeyStore store = KeyStore.getInstance("AndroidKeyStore");
            store.load(null);
            if (store.containsAlias("pairit.purchase")) store.deleteEntry("pairit.purchase");
            return true;
        } catch (Exception unavailable) {
            // No code reads this retired key. Retry cleanup at the next app launch.
            return false;
        }
    }
}
