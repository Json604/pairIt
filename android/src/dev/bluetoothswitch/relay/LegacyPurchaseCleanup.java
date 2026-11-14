package dev.bluetoothswitch.relay;

import android.content.Context;
import java.security.KeyStore;

/** Remove only purchase data left by the retired payment preview. Pairing and ad consent stay intact. */
final class LegacyPurchaseCleanup {
    static void run(Context context) {
        context.deleteSharedPreferences("pairit_pro");
        try {
            KeyStore store = KeyStore.getInstance("AndroidKeyStore");
            store.load(null);
            if (store.containsAlias("pairit.purchase")) store.deleteEntry("pairit.purchase");
        } catch (Exception unavailable) {
            // No code reads this retired key. Retry cleanup at the next app launch.
        }
    }
}
