package dev.bluetoothswitch.relay;

import android.app.Activity;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import com.google.android.gms.ads.*;
import com.google.android.gms.ads.appopen.AppOpenAd;
import java.util.function.BooleanSupplier;

/** App-open format, never over an active session. A cold launch shows a plain loading
 * screen and waits (bounded) for the first ad; a return shows an already-loaded ad at once.
 * A new ad is requested as soon as one is shown, and late ads are kept, never shown late. */
final class AppOpenAds {
    private static boolean presenting;
    private final Activity activity;
    private final BannerAds consent;
    private final BooleanSupplier eligible;
    private final java.util.function.Consumer<Boolean> loadingScreen;
    private final Runnable finished;
    private final Handler main=new Handler(Looper.getMainLooper());
    private AppOpenAd cached;
    private boolean loading,opening,destroyed,showing;
    private long revision,loadedAt,deadline,retryAfter;
    private String status="Not requested";
    private final Runnable poll=this::attempt;
    AppOpenAds(Activity activity,BannerAds consent,BooleanSupplier eligible,java.util.function.Consumer<Boolean> loadingScreen,Runnable finished){
        this.activity=activity;this.consent=consent;this.eligible=eligible;this.loadingScreen=loadingScreen;this.finished=finished;
    }
    static boolean isPresenting(){return presenting;}
    boolean isOpening(){return opening;}
    String diagnostics(){return "App-open ad: "+status+(cached!=null?" (one ready)":loading?" (loading)":"");}
    private void status(String value){if(!status.equals(value)){status=value;android.util.Log.i("PairItAds","App-open: "+value);}}
    void prepare(){
        if(cached!=null&&SystemClock.elapsedRealtime()-loadedAt>=AdTiming.AD_EXPIRY_MS)cached=null;
        if(destroyed||loading||cached!=null||!MainActivity.visible||!consent.canLoadFullscreen()||BuildConfig.APP_OPEN_AD_UNIT_ID.isEmpty()||SystemClock.elapsedRealtime()<retryAfter)return;
        loading=true;long ticket=revision,privacy=consent.consentRevision();
        try { AppOpenAd.load(activity,BuildConfig.APP_OPEN_AD_UNIT_ID,new AdRequest.Builder().build(),new AppOpenAd.AppOpenAdLoadCallback(){
            @Override public void onAdLoaded(AppOpenAd ad){
                if(destroyed||ticket!=revision)return;loading=false;
                if(privacy!=consent.consentRevision()||!consent.canLoadFullscreen())return;
                cached=ad;loadedAt=SystemClock.elapsedRealtime();attempt();
            }
            @Override public void onAdFailedToLoad(LoadAdError error){
                if(destroyed||ticket!=revision)return;loading=false;retryAfter=SystemClock.elapsedRealtime()+30_000;
                status("Unavailable (Google load code "+error.getCode()+")");finishOpening();
            }
        }); } catch(RuntimeException error){loading=false;retryAfter=SystemClock.elapsedRealtime()+30_000;status("Ad request unavailable");finishOpening();}
    }
    /** @param coldStart a fresh launch: wait on the loading screen for the first ad. */
    void open(boolean coldStart){
        if(destroyed||presenting||opening)return;
        if(!eligible.getAsBoolean()){status("Skipped: audio active or screen busy");prepare();return;}
        long last=activity.getSharedPreferences("advertising",Activity.MODE_PRIVATE).getLong("lastFullscreenAd",0);
        if(!AdTiming.appOpenDue(System.currentTimeMillis(),last)){status("Skipped: shown in the last 3 minutes");prepare();return;}
        if(BuildConfig.APP_OPEN_AD_UNIT_ID.isEmpty()){status("Ad unit not configured");return;}
        if(cached!=null&&SystemClock.elapsedRealtime()-loadedAt>=AdTiming.AD_EXPIRY_MS)cached=null;
        boolean wait=cached==null&&coldStart&&online();
        if(cached==null&&!wait){status(coldStart?"Skipped: offline":"Skipped: no ad loaded yet (requested for next time)");prepare();return;}
        opening=true;deadline=SystemClock.elapsedRealtime()+(wait?AdTiming.COLD_WAIT_MS:AdTiming.PRESENT_WINDOW_MS);
        status(wait?"Loading for launch":"Showing loaded ad");
        if(wait)loadingScreen.accept(true);
        prepare();attempt();
    }
    private void attempt(){
        if(!opening)return;main.removeCallbacks(poll);
        if(destroyed||!eligible.getAsBoolean()){status("Skipped: audio active or screen busy");finishOpening();return;}
        if(SystemClock.elapsedRealtime()>=deadline){status(cached==null?"Skipped: not loaded within 6 s (kept loading for next time)":"Skipped: window not ready in time");finishOpening();return;}
        if(cached==null||!activity.hasWindowFocus()||!consent.canRequestFullscreen()){
            prepare();main.postDelayed(poll,50);return;
        }
        if(!PhoneAudioSession.acquire(this,"Close the advertisement to start audio.")){status("Skipped: audio session busy");finishOpening();return;}
        AppOpenAd ad=cached;cached=null;opening=false;showing=true;presenting=true;ConnectionChime.stopSound();
        ad.setFullScreenContentCallback(new FullScreenContentCallback(){
            @Override public void onAdShowedFullScreenContent(){status("Shown");activity.getSharedPreferences("advertising",Activity.MODE_PRIVATE).edit().putLong("lastFullscreenAd",System.currentTimeMillis()).apply();}
            @Override public void onAdDismissedFullScreenContent(){complete();}
            @Override public void onAdFailedToShowFullScreenContent(AdError error){status("Unavailable (Google show code "+error.getCode()+")");complete();}
        });
        try{ad.show(activity);}catch(RuntimeException error){complete();}
    }
    private void complete(){if(!showing)return;showing=false;presenting=false;PhoneAudioSession.release(this);if(!destroyed){loadingScreen.accept(false);finished.run();prepare();}}
    private void finishOpening(){if(!opening)return;opening=false;main.removeCallbacks(poll);loadingScreen.accept(false);if(!destroyed)finished.run();}
    private boolean online(){
        try{android.net.ConnectivityManager manager=activity.getSystemService(android.net.ConnectivityManager.class);
            android.net.NetworkCapabilities caps=manager.getNetworkCapabilities(manager.getActiveNetwork());
            return caps!=null&&caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET);}
        catch(RuntimeException error){return true;}
    }
    void pause(){finishOpening();}
    void consentChanged(){revision++;loading=false;cached=null;}
    void destroy(){destroyed=true;revision++;main.removeCallbacksAndMessages(null);cached=null;opening=false;}
}
