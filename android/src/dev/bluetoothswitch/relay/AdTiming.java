package dev.bluetoothswitch.relay;

/** App-open ad pacing. Banner refresh is configured in AdMob, not here. */
final class AdTiming {
    /** Minimum gap between two app-open ads. */
    static final long COOLDOWN_MS = 180_000;
    /** A warm return must follow a real absence, not a scanner, share sheet or settings hop. */
    static final long AWAY_MS = 30_000;
    static boolean appOpenDue(long now,long lastShown){return lastShown<=0||(now>=lastShown&&now-lastShown>=COOLDOWN_MS);}
    static boolean returnEligible(long now,long backgroundedAt){return backgroundedAt<=0||now<backgroundedAt||now-backgroundedAt>=AWAY_MS;}
    /** A cold launch waits (on a plain loading screen) up to this long for the first ad. */
    static final long COLD_WAIT_MS = 6_000;
    /** A preloaded ad only needs the window to become presentable. */
    static final long PRESENT_WINDOW_MS = 1_000;
    /** Google expires app-open ads after four hours; refresh a little earlier. */
    static final long AD_EXPIRY_MS = 4 * 60 * 60_000L - 5 * 60_000L;
    /** Initial no-fill retries back off; a banner that has shown an ad keeps it on refresh failure. */
    static long bannerRetryMs(int failures){return Math.min(60_000,15_000L<<Math.max(0,Math.min(2,failures)));}
}
