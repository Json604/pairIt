package dev.bluetoothswitch.relay;

import android.app.Activity;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import com.google.android.gms.ads.*;
import com.google.android.gms.ads.appopen.AppOpenAd;
import java.util.function.BooleanSupplier;
import java.util.function.Consumer;

/** App-open format, only during a bounded opening screen, never over an active session. */
final class AppOpenAds {
    private static boolean presenting;
    private final Activity activity;
    private final BannerAds consent;
    private final BooleanSupplier eligible;
    private final Consumer<Boolean> openingScreen;
    private final Runnable finished;
    private final Handler main=new Handler(Looper.getMainLooper());
    private AppOpenAd cached;
    private boolean loading,opening,destroyed,showing;
    private long revision,loadedAt,deadline,retryAfter;
    private final Runnable poll=this::attempt;
    AppOpenAds(Activity activity,BannerAds consent,BooleanSupplier eligible,Consumer<Boolean> openingScreen,Runnable finished){
        this.activity=activity;this.consent=consent;this.eligible=eligible;this.openingScreen=openingScreen;this.finished=finished;
    }
    static boolean isPresenting(){return presenting;}
    boolean isOpening(){return opening;}
    void prepare(){
        if(cached!=null&&SystemClock.elapsedRealtime()-loadedAt>=55*60_000)cached=null;
        if(destroyed||loading||cached!=null||!MainActivity.visible||!consent.canRequestFullscreen()||BuildConfig.APP_OPEN_AD_UNIT_ID.isEmpty()||SystemClock.elapsedRealtime()<retryAfter)return;
        loading=true;long ticket=revision,privacy=consent.consentRevision();
        try { AppOpenAd.load(activity,BuildConfig.APP_OPEN_AD_UNIT_ID,new AdRequest.Builder().build(),new AppOpenAd.AppOpenAdLoadCallback(){
            @Override public void onAdLoaded(AppOpenAd ad){
                if(destroyed||ticket!=revision)return;loading=false;
                if(privacy!=consent.consentRevision()||!consent.canRequestFullscreen())return;
                cached=ad;loadedAt=SystemClock.elapsedRealtime();attempt();
            }
            @Override public void onAdFailedToLoad(LoadAdError error){
                if(destroyed||ticket!=revision)return;loading=false;retryAfter=SystemClock.elapsedRealtime()+60_000;
                android.util.Log.i("PairItAds","App-open unavailable: "+error.getCode());finishOpening();
            }
        }); } catch(RuntimeException error){loading=false;retryAfter=SystemClock.elapsedRealtime()+60_000;finishOpening();}
    }
    void open(){
        if(destroyed||presenting||PairingInterstitial.isPresenting()||opening||!eligible.getAsBoolean())return;
        long last=activity.getSharedPreferences("advertising",Activity.MODE_PRIVATE).getLong("lastFullscreenAd",0);
        if(!AdTiming.appOpenDue(System.currentTimeMillis(),last)){prepare();return;}
        if(BuildConfig.APP_OPEN_AD_UNIT_ID.isEmpty()){prepare();return;}
        opening=true;deadline=SystemClock.elapsedRealtime()+3000;openingScreen.accept(true);prepare();attempt();
    }
    private void attempt(){
        if(!opening)return;main.removeCallbacks(poll);
        if(destroyed||!eligible.getAsBoolean()||SystemClock.elapsedRealtime()>=deadline){finishOpening();return;}
        if(cached==null||!activity.hasWindowFocus()||!consent.canRequestFullscreen()){
            prepare();main.postDelayed(poll,50);return;
        }
        if(!PhoneAudioSession.acquire(this,"Close the advertisement to start audio.")){finishOpening();return;}
        AppOpenAd ad=cached;cached=null;opening=false;showing=true;presenting=true;ConnectionChime.stopSound();
        ad.setFullScreenContentCallback(new FullScreenContentCallback(){
            @Override public void onAdShowedFullScreenContent(){activity.getSharedPreferences("advertising",Activity.MODE_PRIVATE).edit().putLong("lastFullscreenAd",System.currentTimeMillis()).apply();}
            @Override public void onAdDismissedFullScreenContent(){complete();}
            @Override public void onAdFailedToShowFullScreenContent(AdError error){complete();}
        });
        try{ad.show(activity);}catch(RuntimeException error){complete();}
    }
    private void complete(){if(!showing)return;showing=false;presenting=false;PhoneAudioSession.release(this);if(!destroyed){openingScreen.accept(false);finished.run();prepare();}}
    private void finishOpening(){if(!opening)return;opening=false;main.removeCallbacks(poll);openingScreen.accept(false);if(!destroyed)finished.run();}
    void pause(){finishOpening();}
    void consentChanged(){revision++;loading=false;cached=null;}
    void destroy(){destroyed=true;revision++;main.removeCallbacksAndMessages(null);cached=null;opening=false;}
}
