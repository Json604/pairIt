package dev.bluetoothswitch.relay;

import android.app.*;
import android.os.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.graphics.drawable.StateListDrawable;
import android.view.*;
import android.widget.*;
import android.Manifest;
import com.google.mlkit.vision.barcode.common.Barcode;
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions;
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning;

/** A small native control surface. Detailed transport counters stay in diagnostics. */
public class MainActivity extends Activity {
    static volatile boolean visible;
    private Button pauseAudio;
    private ReleaseUpdates updates;
    private String updateURL;
    private boolean scanningCode;
    private Runnable pendingScanResult;
    private AlertDialog pairingDialog;
    private PairingInterstitial pairingAds;
    private Runnable pendingPairingCompletion;
    private long pairingFlow;
    private static final int BG = 0xfff5f4f2, INK = GlassUI.INK, MUTED = GlassUI.SECONDARY, GREEN = GlassUI.BLUE, LINE = 0xb3ffffff;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private TextView title, subtitle, route, badge;
    private TextView feedback;
    private ProgressBar connectionProgress;
    private StateListDrawable macSurface, phoneSurface;
    private Button mac, phone, disconnect, pairMac, headphoneSettings;
    private LinearLayout sourceCard;
    private View syncRow, onboardingInfo;
    private RelaySettings settings;
    private BannerAds bannerAds;
    private RelayState lastState;
    private String pendingAction;
    private String inFlight;
    private RelayState requestedFrom;
    private long requestedAt;
    private final Runnable hideFeedback = () -> {
        if (feedback == null) return;
        feedback.animate().cancel();
        feedback.animate().alpha(0).setDuration(120).withEndAction(() -> feedback.setVisibility(View.GONE)).start();
    };
    private final Runnable refresh = new Runnable() {
        public void run() { render(); if (updates != null) updates.check(); handler.postDelayed(this, 500); }
    };

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved); settings = new RelaySettings(this);
        setVolumeControlStream(android.media.AudioManager.STREAM_MUSIC);
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        getWindow().setNavigationBarColor(BG); getWindow().setStatusBarColor(Color.TRANSPARENT);
        FrameLayout root = new FrameLayout(this);
        root.addView(new GlassUI.Backdrop(this), new FrameLayout.LayoutParams(-1, -1));
        ScrollView scroll = new ScrollView(this); scroll.setFillViewport(true); scroll.setClipToPadding(false); scroll.setVerticalScrollBarEnabled(false);
        LinearLayout content = new GlassUI.ContentColumn(this); content.setPadding(dp(24), dp(12), dp(24), dp(16));
        scroll.addView(content,new FrameLayout.LayoutParams(-1,-2,Gravity.TOP|Gravity.CENTER_HORIZONTAL)); LinearLayout layout = column();
        layout.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));
        LinearLayout adContainer = column(); layout.addView(adContainer,new LinearLayout.LayoutParams(-1,-2));
        root.addView(layout,new FrameLayout.LayoutParams(-1,-1)); setContentView(root);
        bannerAds = new BannerAds(this,adContainer);
        pairingAds = new PairingInterstitial(this, bannerAds, this::idleForPairingAd, this::updateAdVisibility);
        bannerAds.onReadinessChanged(() -> pairingAds.prepare());
        bannerAds.onConsentChanged(() -> pairingAds.consentChanged());
        feedback = text("", 13, INK, false); feedback.setPadding(dp(16),dp(14),dp(16),dp(14));
        feedback.setBackground(GlassUI.surface(dp(14))); feedback.setElevation(dp(8)); feedback.setVisibility(View.GONE);
        feedback.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        feedback.setOnClickListener(v -> { handler.removeCallbacks(hideFeedback); hideFeedback.run(); });
        FrameLayout.LayoutParams feedbackParams = new FrameLayout.LayoutParams(-1,-2,Gravity.BOTTOM);
        feedbackParams.setMargins(dp(24),0,dp(24),dp(30)); root.addView(feedback,feedbackParams);
        layout.setOnApplyWindowInsetsListener((view, insets) -> {
            if (Build.VERSION.SDK_INT >= 30) {
                android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars());
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom);
                feedbackParams.bottomMargin=dp(20)+bars.bottom+adContainer.getHeight();feedback.setLayoutParams(feedbackParams);
            } else view.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(), insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            return insets;
        });
        adContainer.addOnLayoutChangeListener((v,l,t,r,b,ol,ot,or,ob) -> layout.requestApplyInsets());
        LinearLayout brand = row();
        TextView name = text(getString(R.string.app_name) + " ·", 26, INK, true); name.setTypeface(GlassUI.heading(this));
        brand.addView(name, new LinearLayout.LayoutParams(0,-2,1));
        ImageButton options = new ImageButton(this); options.setImageDrawable(new GlassUI.Glyph("settings",INK));
        options.setPadding(dp(13),dp(13),dp(13),dp(13)); options.setBackground(new RippleDrawable(ColorStateList.valueOf(0x18191919), GlassUI.surface(dp(14)), null));
        options.setContentDescription("Settings"); options.setOnClickListener(v -> settingsDialog()); GlassUI.pressFeedback(options);
        brand.addView(options,new LinearLayout.LayoutParams(dp(48),dp(48))); content.addView(brand); space(content,16);
        Button updateButton = new Button(this); updateButton.setAllCaps(false); updateButton.setTextColor(INK);
        updateButton.setBackground(GlassUI.surface(dp(14))); updateButton.setMinHeight(dp(48));
        updateButton.setVisibility(View.GONE); content.addView(updateButton, new LinearLayout.LayoutParams(-1,-2));
        updates = new ReleaseUpdates(this, (label, url) -> {
            updateURL = url; updateButton.setText(label == null ? "" : label + " · Get update");
            updateButton.setVisibility(label == null ? View.GONE : View.VISIBLE);
        });
        updateButton.setOnClickListener(v -> { if (updateURL != null) updates.open(updateURL); });
        space(content,14);
        badge = text("LET’S GET CONNECTED",11,MUTED,true); badge.setLetterSpacing(.12f);
        LinearLayout badgeGroup=row();
        connectionProgress=new ProgressBar(this,null,android.R.attr.progressBarStyleSmall);connectionProgress.setIndeterminateTintList(ColorStateList.valueOf(GREEN));
        LinearLayout.LayoutParams progressParams=new LinearLayout.LayoutParams(dp(14),dp(14));progressParams.setMarginEnd(dp(7));
        badgeGroup.addView(connectionProgress,progressParams);badgeGroup.addView(badge);content.addView(badgeGroup);space(content,10);
        LinearLayout hero=row();
        title=text("Your sound.\nYour space.",32,INK,false);title.setTypeface(GlassUI.heading(this));title.setLetterSpacing(-.02f);
        title.setMinLines(2);
        hero.addView(title,new LinearLayout.LayoutParams(0,-2,1));
        content.addView(hero);
        space(content,12);subtitle=text("Open PairIt on your computer, then pair this phone to get started.",14,MUTED,false);
        subtitle.setMinLines(3);subtitle.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);content.addView(subtitle);space(content,24);
        LinearLayout introduction=row();introduction.setPadding(dp(18),dp(18),dp(18),dp(18));introduction.setBackground(GlassUI.surface(dp(18)));
        TextView device=text("",14,INK,false);GlassUI.Glyph desktop=new GlassUI.Glyph("mac",INK);desktop.setBounds(0,0,dp(32),dp(32));device.setCompoundDrawables(desktop,null,null,null);
        introduction.addView(device,new LinearLayout.LayoutParams(dp(52),dp(46)));
        LinearLayout introText=column();introText.addView(text("Computer → phone",15,INK,true));space(introText,5);introText.addView(text("One local connection. Your choice of output.",12,MUTED,false));
        introduction.addView(introText,new LinearLayout.LayoutParams(0,-2,1));LinearLayout onboarding=column();onboarding.addView(introduction);
        space(onboarding,12);onboarding.addView(text("First, install PairIt on your computer",13,MUTED,false));
        onboarding.addView(computerDownloadButtons());onboardingInfo=onboarding;content.addView(onboarding);
        sourceCard=column();sourceCard.setPadding(dp(18),dp(20),dp(18),dp(12));sourceCard.setBackground(GlassUI.surface(dp(18)));
        TextView label=text("LISTEN FROM",11,MUTED,true);label.setLetterSpacing(.10f);sourceCard.addView(label);space(sourceCard,14);
        LinearLayout sources=row();mac=button("Computer",()->dispatch("PLAY"));phone=button("Phone",()->dispatch("USE_PHONE"));
        macSurface=sourceStyle(mac,"mac");phoneSurface=sourceStyle(phone,"phone");
        LinearLayout.LayoutParams left=new LinearLayout.LayoutParams(0,dp(72),1);left.setMarginEnd(dp(5));sources.addView(mac,left);
        LinearLayout.LayoutParams right=new LinearLayout.LayoutParams(0,dp(72),1);right.setMarginStart(dp(5));sources.addView(phone,right);sourceCard.addView(sources);space(sourceCard,16);
        View divider=new View(this);divider.setBackgroundColor(0x18191919);sourceCard.addView(divider,new LinearLayout.LayoutParams(-1,dp(1)));
        route=text("Choose your output",13,INK,false);route.setMinHeight(dp(60));route.setGravity(Gravity.CENTER_VERTICAL);
        GlassUI.Glyph headphones=new GlassUI.Glyph("headphones",GREEN);headphones.setBounds(0,0,dp(23),dp(23));route.setCompoundDrawables(headphones,null,null,null);route.setCompoundDrawablePadding(dp(12));
        sourceCard.addView(route);
        pauseAudio=button("Pause audio",()->dispatch(RelayService.state.phase==RelayState.Phase.PAUSED?"PLAY":"MEDIA_PAUSE"));style(pauseAudio,false);sourceCard.addView(pauseAudio,new LinearLayout.LayoutParams(-1,dp(48)));
        route.setOnClickListener(v -> outputDialog());route.setContentDescription("Choose audio output");route.setFocusable(true);route.setClickable(true);content.addView(sourceCard);
        pairMac=button("Pair your computer  ↗",this::pair);style(pairMac,true);LinearLayout.LayoutParams pairParams=new LinearLayout.LayoutParams(-1,dp(56));pairParams.topMargin=dp(16);content.addView(pairMac,pairParams);
        headphoneSettings=button("Open Bluetooth settings",()->startActivity(new Intent(android.provider.Settings.ACTION_BLUETOOTH_SETTINGS)));style(headphoneSettings,false);
        LinearLayout.LayoutParams headphoneParams=new LinearLayout.LayoutParams(-1,dp(52));headphoneParams.topMargin=dp(12);content.addView(headphoneSettings,headphoneParams);
        syncRow=settingRow("Video sync","Timing for your selected output",this::syncDialog);LinearLayout.LayoutParams syncParams=new LinearLayout.LayoutParams(-1,-2);syncParams.topMargin=dp(14);content.addView(syncRow,syncParams);
        disconnect=button("Disconnect",this::disconnect);disconnect.setTextColor(MUTED);disconnect.setBackground(new RippleDrawable(ColorStateList.valueOf(0x12191919),null,shape(Color.WHITE,16,Color.TRANSPARENT)));content.addView(disconnect,new LinearLayout.LayoutParams(-1,dp(48)));
        space(content,18);
        Button together=button("Listen together  ›",this::sharedListeningDialog);style(together,false);content.addView(together,new LinearLayout.LayoutParams(-1,dp(54)));
        TextView sharedNote=text("Same computer. Up to four listeners.",12,MUTED,false);sharedNote.setPadding(dp(4),dp(8),dp(4),0);content.addView(sharedNote);
        space(content,24);TextView note=text("LOCAL & ENCRYPTED",10,MUTED,false);note.setLetterSpacing(.12f);note.setGravity(Gravity.CENTER);content.addView(note);
        if (!settings.paired() && RelayService.state.phase == RelayState.Phase.IDLE)
            RelayService.state=new RelayState(RelayState.Phase.IDLE,"Connect your computer","Open the companion on your computer, then pair this phone to get started.");
        render();acceptPairing(getIntent());acceptShortcut(getIntent());
        handler.post(() -> bannerAds.start());
    }
    private LinearLayout computerDownloadButtons() {
        LinearLayout links=row();
        for (String platform : new String[]{"Mac", "Windows"}) {
            Button link=button("Get " + platform + " app ↗",()->openDownload(platform.toLowerCase(java.util.Locale.ROOT)));
            style(link,false);links.addView(link,new LinearLayout.LayoutParams(0,dp(48),1));
        }
        return links;
    }
    private void openDownload(String platform) {
        try { startActivity(new Intent(Intent.ACTION_VIEW,android.net.Uri.parse("https://pairit.kartikey.xyz/downloads.html#"+platform))); }
        catch (android.content.ActivityNotFoundException error) { showFeedback("Open pairit.kartikey.xyz/downloads.html on your computer."); }
    }
    private void settingsDialog() {
        new GlassDialogBuilder(this).setTitle("Settings")
            .setItems(new String[]{"Connection & pairing","Audio output","Listen together","Video sync","Background controls","Add Quick Settings tile","Help & desktop companion","Privacy policy","Ad privacy choices","Ad sound","Report an ad","Contact support","About"},(dialog,which)->{
                if(which==0)connectionDialog();else if(which==1)outputDialog();else if(which==2)sharedListeningDialog();else if(which==3)syncDialog();else if(which==4)backgroundControlsDialog();else if(which==5)addQuickTile();else if(which==6)InformationActivity.open(this,"help");else if(which==7)InformationActivity.open(this,"privacy");else if(which==8)bannerAds.privacyOptions();else if(which==9)adSoundDialog();else if(which==10)reportAd();else if(which==11)contactSupport();else aboutDialog();
            }).setNegativeButton("Done",null).show();
    }
    @Override protected void onNewIntent(Intent intent) { super.onNewIntent(intent); setIntent(intent); acceptPairing(intent); acceptShortcut(intent); }
    private void acceptShortcut(Intent intent) {
        if (!intent.getBooleanExtra("listen_from_tile", false)) return;
        intent.removeExtra("listen_from_tile");
        handler.post(() -> dispatch("PLAY"));
    }
    private void addQuickTile() {
        if (Build.VERSION.SDK_INT >= 33) {
            int icon = R.drawable.ic_quick_tile;
            getSystemService(android.app.StatusBarManager.class).requestAddTileService(
                    new ComponentName(this, RelayTileService.class), getString(R.string.app_name), android.graphics.drawable.Icon.createWithResource(this, icon), getMainExecutor(), result -> {
                        if (result == android.app.StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED || result == android.app.StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED)
                            showFeedback(getString(R.string.app_name)+" is in Quick Settings");
                    });
        } else new GlassDialogBuilder(this).setTitle("Add to Quick Settings")
                .setMessage("Swipe down twice from the top of the screen, tap Edit, then drag the app’s tile into your active tiles. Tap the tile to switch between computer and phone audio.")
                .setPositiveButton("Done", null).show();
    }
    private void acceptPairing(Intent intent) {
        android.net.Uri uri = intent.getData();
        if (uri == null || !"audiorelay".equals(uri.getScheme()) || !"pair".equals(uri.getHost())) return;
        String code = uri.toString(); intent.setData(null);
        try { PairingCode.parse(code); pair(code, ""); }
        catch (Exception error) { pair("", "This isn’t a PairIt pairing code. Scan the code in the desktop app."); }
    }
    private void render() {
        RelayState state = RelayService.state;
        updateAdVisibility();
        if (inFlight != null && (state != requestedFrom || SystemClock.uptimeMillis() - requestedAt > 4000)) {
            boolean timedOut = state == requestedFrom;
            inFlight = null; lastState = null;
            if (timedOut) showFeedback("That action didn’t finish. Please try again.");
        }
        if (state != lastState) {
            boolean busy = inFlight != null || state.phase == RelayState.Phase.CONNECTING || state.phase == RelayState.Phase.BUFFERING || state.phase == RelayState.Phase.RECONNECTING;
            // Keep transport status changes from moving the controls under a finger.
            title.setText(inFlight != null ? (inFlight.equals("STOP") ? "Disconnecting" : inFlight.equals("USE_PHONE") ? "Phone audio" : inFlight.equals("MEDIA_PAUSE") ? "Listening paused" : "Computer audio") : homeTitle(state));
            subtitle.setText(inFlight != null ? (inFlight.equals("USE_PHONE") || inFlight.equals("STOP") ? "Releasing audio to your phone apps." : "Opening your local audio connection.") : state.detail);
            String label = state.phase == RelayState.Phase.PLAYING ? "CONNECTED" : state.phase == RelayState.Phase.IDLE ? "READY" : state.phase.name().replace('_', ' ');
            badge.setText(!settings.paired() ? "LET’S GET CONNECTED" : inFlight != null ? "UPDATING" : label);
            connectionProgress.setVisibility(busy ? View.VISIBLE : View.INVISIBLE);
            badge.setTextColor(state.phase == RelayState.Phase.ERROR || state.phase == RelayState.Phase.HEADPHONES ? 0xff98601b : GREEN);
            int fade = mac.isInTouchMode() ? GlassUI.duration(this,140) : 0;
            macSurface.setEnterFadeDuration(fade);macSurface.setExitFadeDuration(fade);
            phoneSurface.setEnterFadeDuration(fade);phoneSurface.setExitFadeDuration(fade);
            mac.setSelected(state.macSelected()); phone.setSelected(state.phase == RelayState.Phase.PHONE);
            mac.setText(state.phase == RelayState.Phase.ERROR ? "Try again" : "Computer");
            pauseAudio.setText(state.phase == RelayState.Phase.PAUSED ? "Resume audio" : "Pause audio");
            pauseAudio.setEnabled(inFlight == null);
            if (Build.VERSION.SDK_INT >= 30) {
                mac.setStateDescription(state.macSelected() ? "Selected" : "Not selected");
                phone.setStateDescription(state.phase == RelayState.Phase.PHONE ? "Selected" : "Not selected");
            }
            disconnect.setEnabled(state.phase != RelayState.Phase.IDLE && inFlight == null); disconnect.setAlpha(disconnect.isEnabled() ? 1 : 0.5f);
            disconnect.setText("STOP".equals(inFlight) ? "Disconnecting…" : "Disconnect");
            lastState = state;
        }
        sourceCard.setVisibility(settings.paired() ? View.VISIBLE : View.GONE);
        onboardingInfo.setVisibility(settings.paired() ? View.GONE : View.VISIBLE);
        pairMac.setVisibility(settings.paired() ? View.GONE : View.VISIBLE);
        syncRow.setVisibility(View.GONE);
        pauseAudio.setVisibility(state.macSelected() ? View.VISIBLE : View.GONE);
        headphoneSettings.setVisibility(state.phase == RelayState.Phase.HEADPHONES && settings.output() == OutputRoute.BLUETOOTH ? View.VISIBLE : View.GONE);
        disconnect.setVisibility(state.phase == RelayState.Phase.IDLE ? View.GONE : View.VISIBLE);
        String routeText = state.phase == RelayState.Phase.PLAYING ? RelayService.headphoneName + "\nSecured local network · change output ›" : settings.output().label + " · change ›";
        if (!android.text.TextUtils.equals(route.getText(),routeText)) route.setText(routeText);
    }
    private String homeTitle(RelayState state) {
        switch (state.phase) {
            case IDLE: return settings.paired() ? "Ready when\nyou are" : "Your sound.\nYour space.";
            case CONNECTING: case BUFFERING: case PLAYING: case RECONNECTING: return "Computer audio";
            case PAUSED: return "Listening paused";
            case PHONE: return "Phone audio";
            default: return state.title;
        }
    }
    private void dispatch(String action) {
        if (PairingInterstitial.isPresenting()) { showFeedback("Close the advertisement, then choose Computer to start audio."); return; }
        if (inFlight != null || pendingAction != null) return;
        if (action.equals("PLAY") && RelayService.state.macSelected() && RelayService.state.phase != RelayState.Phase.PAUSED) return;
        if (action.equals("USE_PHONE") && RelayService.state.phase == RelayState.Phase.PHONE) return;
        if ((action.equals("PLAY")) && !settings.paired()) { pair(); return; }
        if (action.equals("USE_PHONE") && RelayService.state.phase == RelayState.Phase.IDLE) return;
        if (action.equals("PLAY") && settings.output() == OutputRoute.BLUETOOTH && Build.VERSION.SDK_INT >= 31 && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
            pendingAction = action;
            requestPermissions(new String[]{Manifest.permission.BLUETOOTH_CONNECT}, 1); return;
        }
        if (action.equals("PLAY") && Build.VERSION.SDK_INT >= 33 && !settings.askedNotifications()
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            settings.askedNotifications(true); pendingAction = action;
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 3); return;
        }
        pendingPairingCompletion = null;
        beginAction(action);
        try { startForegroundService(new Intent(this, RelayService.class).setAction(action)); }
        catch (RuntimeException error) { inFlight = null; lastState = null; render(); showFeedback("Couldn’t start audio. Please try again."); }
        handler.postDelayed(this::render, 100);
    }
    private void beginAction(String action) {
        requestedFrom=RelayService.state;requestedAt=SystemClock.uptimeMillis();inFlight=action;lastState=null;
        handler.removeCallbacks(hideFeedback);feedback.animate().cancel();feedback.setVisibility(View.GONE);
        render(); mac.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK);
    }
    private void disconnect() {
        if(inFlight != null || RelayService.state.phase == RelayState.Phase.IDLE)return;
        beginAction("STOP");
        try{startService(new Intent(this,RelayService.class).setAction("STOP"));}
        catch(RuntimeException error){inFlight=null;lastState=null;render();showFeedback("Couldn’t disconnect. Please try again.");}
        handler.postDelayed(this::render,100);
    }
    private void showFeedback(String message) {
        handler.removeCallbacks(hideFeedback);feedback.animate().cancel();
        boolean visible = feedback.getVisibility() == View.VISIBLE;
        feedback.setText(message);feedback.setVisibility(View.VISIBLE);
        if(!visible){feedback.setAlpha(0);feedback.setTranslationY(feedback.isInTouchMode() && GlassUI.duration(this,1)>0 ? dp(6):0);}
        feedback.animate().alpha(1).translationY(0).setDuration(feedback.isInTouchMode() ? 180 : 0)
                .setInterpolator(new android.view.animation.PathInterpolator(.23f,1,.32f,1)).withEndAction(null).start();
        int duration=getSystemService(android.view.accessibility.AccessibilityManager.class).getRecommendedTimeoutMillis(4000,android.view.accessibility.AccessibilityManager.FLAG_CONTENT_TEXT);
        handler.postDelayed(hideFeedback,duration);
    }
    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] grants) {
        super.onRequestPermissionsResult(request, permissions, grants);
        if (request == 3 && (grants.length == 0 || grants[0] != PackageManager.PERMISSION_GRANTED))
            showFeedback("Playback still works. Allow notifications in Settings to keep the Phone/Computer switch available while idle.");
        if (request == 1 && (grants.length == 0 || grants[0] != PackageManager.PERMISSION_GRANTED)) {
            new GlassDialogBuilder(this).setTitle("Headphone access needed")
                    .setMessage("Allow Nearby devices to identify your Bluetooth headphones and keep sound off the phone speaker.")
                    .setPositiveButton("Open settings", (dialog, which) -> startActivity(new Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.parse("package:" + getPackageName()))))
                    .setNegativeButton("Later", null).show(); pendingAction = null; return;
        }
        String action = pendingAction; pendingAction = null; if (action != null) dispatch(action);
    }
    private void syncDialog() {
        final String routeKey = RelayService.timingProfileKey;
        final boolean wifi = settings.wifi();
        LinearLayout body = dialogBody();
        body.addView(text("Mac video timing is estimated from the actual output. Windows has no system-wide video compensation. Only the primary listener controls Mac compensation when several phones listen. Changing correction stops playback; choose Computer and replay the video afterward.", 15, MUTED, false));
        space(body, 20);
        TextView value = text(syncLabel(routeKey, wifi), 28, INK, true); value.setGravity(Gravity.CENTER); body.addView(value); space(body, 12);
        LinearLayout buttons = row();
        Button early = button("Sound is early", () -> adjustSync(routeKey, wifi, -10, value));
        Button late = button("Sound is late", () -> adjustSync(routeKey, wifi, 10, value));
        style(early, false); style(late, false);
        buttons.addView(early, new LinearLayout.LayoutParams(0, dp(56), 1)); buttons.addView(late, new LinearLayout.LayoutParams(0, dp(56), 1)); body.addView(buttons);
        early.setEnabled(settings.profileEstimate(routeKey) >= 0); late.setEnabled(settings.profileEstimate(routeKey) >= 0);
        space(body, 12); body.addView(text("Automatic timing uses your headphones’ playback timestamps. Each tap adds a saved 10 ms correction. Some video players need a reload. Bluetooth delay still affects games and live audio.", 12, MUTED, false));
        AlertDialog dialog = new GlassDialogBuilder(this).setTitle("Video sync").setView(body).setPositiveButton("Done", null)
                .setNeutralButton("Reset correction", null).create();
        dialog.setOnShowListener(d -> dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener(v -> {
            RelayService.stopFromUi(this); settings.profileCorrection(routeKey,0);value.setText(syncLabel(routeKey,wifi));
            value.announceForAccessibility("Correction reset to zero");
        }));dialog.show();
    }
    private void adjustSync(String routeKey, boolean wifi, int delta, TextView value) {
        int next = Math.max(-500, Math.min(500, settings.profileCorrection(routeKey) + delta));
        RelayService.stopFromUi(this); settings.profileCorrection(routeKey, next); value.setText(syncLabel(routeKey, wifi));
    }
    private String syncLabel(String routeKey, boolean wifi) {
        int estimate = settings.profileEstimate(routeKey);
        return (estimate < 0 ? "Learning timing" : "Auto " + estimate + " ms") + "\nCorrection " + String.format(java.util.Locale.US, "%+d ms", settings.profileCorrection(routeKey));
    }
    private void connectionDialog() {
        new GlassDialogBuilder(this).setTitle("Connection & pairing")
                .setItems(new String[]{settings.paired()?"Pair another computer":"Connect your computer", "Computer address", "Wi-Fi & USB setup", "Forget this computer"}, (dialog, which) -> {
                    if (which == 0) pair();
                    else if (which == 1) editAddress();
                    else if(which==3)forgetMac();
                    else new GlassDialogBuilder(this).setTitle("Local Wi-Fi or USB network")
                            .setMessage("Wi-Fi: keep your computer and phone on the same local network.\n\nUSB on Windows: connect this Android phone with a data cable, enable USB tethering in Android’s network settings, then enter the computer’s USB-network address shown in the desktop companion.\n\nAndroid USB networking on Mac requires a supported network interface; a cable alone is not enough.\n\nBoth paths use the same encrypted pairing. No USB debugging is needed. A manual address takes priority over discovery until you clear it. The app reports local network because it cannot reliably identify the physical cable path.")
                            .setPositiveButton("Done", null).show();
                }).setNegativeButton("Done", null).show();
    }
    private void editAddress() {
        EditText input = new EditText(this); input.setSingleLine(true); input.setText(settings.overrideHost()); input.setHint("Automatic discovery");
        input.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO);
        LinearLayout body = dialogBody(); body.addView(text("Enter the computer’s Wi-Fi or USB-network address. This overrides discovery and keeps certificate verification. Leave blank to use automatic discovery again.", 14, MUTED, false)); body.addView(input);
        AlertDialog dialog = new GlassDialogBuilder(this).setTitle("Computer address").setView(body).setPositiveButton("Save", null).setNegativeButton("Cancel", null).create();
        dialog.setOnShowListener(d -> dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
            String host = input.getText().toString().trim();
            if (!host.isEmpty() && !RelaySettings.validHost(host)) { input.setError("Enter an IP address or local hostname, without a port"); return; }
            stopAudioForSettings(); settings.host(host); dialog.dismiss(); showFeedback("Address saved. Start a new audio session to reconnect.");
        })); dialog.show();
    }
    private void outputDialog() {
        OutputRoute[] outputs = OutputRoute.values();
        new GlassDialogBuilder(this).setTitle("Listen through")
                .setSingleChoiceItems(new String[]{"Bluetooth headphones","Phone speaker","Wired headphones"}, settings.output().ordinal(), (dialog, which) -> {
                    if (settings.output() != outputs[which]) { stopAudioForSettings(); settings.output(outputs[which]); }
                    lastState = null; render(); dialog.dismiss();
                }).setNegativeButton("Done", null).show();
    }
    private void sharedListeningDialog() {
        new GlassDialogBuilder(this).setTitle("Listen together")
                .setMessage("One computer, up to four phones.\n\n1. Connect each listener’s headphones to their own phone.\n2. Keep all phones and the computer on the same Wi-Fi.\n3. In PairIt on the computer, choose Listen together and pair each phone.\n4. Choose Computer on every phone. Each listener controls their own volume and can pause independently.\n\nTwo headphones on one phone requires that phone’s built-in audio sharing and compatible headphones. PairIt cannot enable it on unsupported hardware. The separate-phone setup is the most compatible.\n\nEveryone hears the same stream, but different headphones can have different delays.")
                .setPositiveButton("Done", null).setNeutralButton("Bluetooth settings", (d,w)->startActivity(new Intent(android.provider.Settings.ACTION_BLUETOOTH_SETTINGS))).show();
    }
    private void backgroundControlsDialog() {
        new GlassDialogBuilder(this).setTitle("Background controls")
                .setMessage("Computer audio keeps playing when you lock the screen or use another app. The notification lets you pause, use Phone audio, return to Computer or disconnect.\n\nAllow notifications to keep the source switch visible while Phone is selected. Disconnect removes it. Android may hide it if you disable notifications or stop the app.\n\nHeadphone play/pause pauses and resumes this phone’s live relay; it never selects Phone. Volume and noise-control gestures stay with your headphones and Android. Track skipping is controlled in the computer’s player.")
                .setPositiveButton("Done", null).setNeutralButton("Notification settings", (d,w)->startActivity(new Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(android.provider.Settings.EXTRA_APP_PACKAGE,getPackageName()))).show();
    }
    private void openAppSettings() { startActivity(new Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.parse("package:" + getPackageName()))); }
    private void stopAudioForSettings() {
        RelayService.stopFromUi(this); RelayService.timingProfileKey = "";
    }
    private void forgetMac() {
        if(!settings.paired()){showFeedback("There’s no paired computer to forget.");return;}
        new GlassDialogBuilder(this).setTitle("Forget this computer?")
            .setMessage("This stops playback and removes this phone’s pairing and saved headphone timing. You can pair again with a code from your computer.")
            .setPositiveButton("Forget computer",(dialog,which)->{
                stopAudioForSettings();
                handler.postDelayed(()->{
                    settings.forget();RelayService.state=new RelayState(RelayState.Phase.IDLE,"Connect your computer","Pair a computer to start listening.");
                    lastState=null;render();showFeedback("Computer forgotten. Pair again whenever you’re ready.");
                },250);
            }).setNegativeButton("Cancel",null).show();
    }
    private void contactSupport() {
        String email=getString(R.string.support_email);
        if(email.isEmpty()){InformationActivity.open(this,"help");return;}
        Intent mail=new Intent(Intent.ACTION_SENDTO,android.net.Uri.fromParts("mailto",email,null))
            .putExtra(Intent.EXTRA_SUBJECT,getString(R.string.app_name)+" Android support")
            .putExtra(Intent.EXTRA_TEXT,"App version: "+BuildConfig.VERSION_NAME+"\nAndroid version: "+Build.VERSION.RELEASE+"\n\nWhat happened?\n");
        try{startActivity(mail);}catch(ActivityNotFoundException error){new GlassDialogBuilder(this).setTitle("Contact support").setMessage(email).setPositiveButton("Done",null).show();}
    }
    private void adSoundDialog() {
        new GlassDialogBuilder(this).setTitle("Ad sound")
                .setSingleChoiceItems(new String[]{"Muted (default)","Allow ad sound"}, bannerAds.isMuted() ? 0 : 1, (dialog, which) -> {
                    bannerAds.setMuted(which == 0); dialog.dismiss();
                    showFeedback(which == 0 ? "Ad sound muted" : "Ad sound allowed");
                }).setNegativeButton("Cancel",null).show();
    }
    private void reportAd() {
        String email = getString(R.string.support_email);
        new GlassDialogBuilder(this).setTitle("Report an ad")
                .setMessage("Tell us the advertiser, when it appeared and what was inappropriate. You do not need to tap the ad. You can also use the ad’s own reporting controls when available.\n\n" + email)
                .setPositiveButton("Email support", (dialog, which) -> {
                    Intent mail = new Intent(Intent.ACTION_SENDTO, android.net.Uri.fromParts("mailto",email,null))
                            .putExtra(Intent.EXTRA_SUBJECT,"PairIt Android — report an ad")
                            .putExtra(Intent.EXTRA_TEXT,"Advertiser or ad text:\nWhen it appeared:\nWhy it is inappropriate:\n\nPlease do not include pairing codes or other private information.");
                    try { startActivity(mail); } catch (ActivityNotFoundException error) { showFeedback("Email " + email); }
                }).setNeutralButton("Copy email",(dialog,which)->getSystemService(ClipboardManager.class).setPrimaryClip(ClipData.newPlainText("Support email",email)))
                .setNegativeButton("Cancel",null).show();
    }
    private void aboutDialog() {
        String publisher=getString(R.string.publisher_name);
        new GlassDialogBuilder(this).setTitle(getString(R.string.app_name))
            .setMessage("Version "+BuildConfig.VERSION_NAME+(publisher.isEmpty()?"":"\n"+publisher)+"\n\nComputer audio through this phone. Listen together with up to four phones and their headphones.\n\nNo account. No cloud audio server.\nSupported by a banner and an occasional dismissible full-screen ad after a new pairing is saved.")
            .setPositiveButton("Done",null).setNeutralButton("Diagnostics",(dialog,which)->diagnosticsDialog()).show();
    }
    private void pair() { pair("", ""); }
    private void pair(String initialCode, String message) {
        if (isFinishing() || isDestroyed()) return;
        if (pairingDialog != null) pairingDialog.dismiss();
        final long flow = ++pairingFlow;
        final long adFlow = pairingAds.begin();
        final boolean[] confirmed = {false};
        EditText input = new EditText(this); input.setHint("Paste pairing code"); input.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        input.setFilters(new android.text.InputFilter[]{new android.text.InputFilter.LengthFilter(4096)});
        input.setSaveEnabled(false); input.setText(initialCode);
        input.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO);input.setImeOptions(android.view.inputmethod.EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING);
        LinearLayout body = dialogBody();
        body.addView(text("On your computer, open PairIt → Pair a phone. Keep both devices on the same local network.", 14, MUTED, false)); space(body,8);body.addView(computerDownloadButtons());space(body,16);
        Button scan = button("Scan QR code", () -> scanPairingCode(input.getText().toString())); style(scan, true);
        body.addView(scan,new LinearLayout.LayoutParams(-1,dp(52))); space(body,8);
        body.addView(text("Camera images stay on your phone. You’ll confirm before connecting.",12,MUTED,false)); space(body,18);
        body.addView(text("Or paste a pairing code",14,INK,true)); body.addView(input);
        body.addView(text("A short ad may appear after pairing is saved. Start audio separately when you’re ready.",12,MUTED,false));
        TextView validation = text(message,13,MUTED,false); validation.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE); body.addView(validation);
        ScrollView scroll = new ScrollView(this); scroll.addView(body);
        AlertDialog dialog = new GlassDialogBuilder(this).setTitle(settings.paired() ? "Pair another computer" : "Connect your computer")
                .setView(scroll).setPositiveButton("Pair computer", null).setNegativeButton("Cancel", null).create();
        pairingDialog = dialog;
        updateAdVisibility();
        Runnable validate = () -> {
            try { PairingCode parsed = PairingCode.parse(input.getText().toString()); validation.setText(getString(R.string.pairing_computer_ready, parsed.name)); dialog.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(true); }
            catch (Exception error) { validation.setText(!message.isEmpty() ? message : input.length() == 0 ? "" : "Paste the complete PairIt code from your computer."); dialog.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(false); }
        };
        input.addTextChangedListener(new android.text.TextWatcher() {
            public void beforeTextChanged(CharSequence s,int start,int count,int after) { }
            public void onTextChanged(CharSequence s,int start,int before,int count) { validate.run(); }
            public void afterTextChanged(android.text.Editable s) { }
        });
        dialog.setOnShowListener(d -> {
            validate.run();
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
                try {
                    PairingCode parsed = PairingCode.parse(input.getText().toString());
                    stopAudioForSettings(); settings.pair(parsed); confirmed[0] = true;
                    dialog.dismiss(); inFlight = null; pendingAction = null; lastState = null; render();
                    showFeedback("Pairing saved. Start audio when you’re ready.");
                    getWindow().getDecorView().postOnAnimation(() -> {
                        if (isFinishing() || isDestroyed() || flow != pairingFlow) return;
                        pairingAds.showAfterPairing(adFlow, () -> {
                            if (flow != pairingFlow) return;
                            pendingPairingCompletion = () -> { if (flow == pairingFlow) pairingReady(); };
                            showPairingCompletion();
                        });
                    });
                } catch (Exception error) { input.requestFocus(); input.setError("Copy the complete pairing code from your computer"); }
            });
        });
        dialog.setOnDismissListener(d -> {
            if (pairingDialog == dialog) pairingDialog = null;
            if (!confirmed[0]) pairingAds.cancelUnshown(adFlow);
            updateAdVisibility();
        });
        dialog.getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN);
        dialog.show();
    }
    private void scanPairingCode(String draft) {
        if (scanningCode || !visible) return;
        scanningCode = true; updateAdVisibility();
        if (pairingDialog != null) pairingDialog.dismiss();
        GmsBarcodeScannerOptions options = new GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build();
        try {
            GmsBarcodeScanning.getClient(this, options).startScan().addOnCompleteListener(task -> {
                if (isFinishing() || isDestroyed()) return;
                scanningCode = false;
                String code = draft, error = "";
                if (task.isSuccessful()) {
                    try { String value = task.getResult().getRawValue(); PairingCode.parse(value); code = value; }
                    catch (Exception invalid) { error = "This isn’t a PairIt code. Scan Pair a phone in the desktop app, or paste its code."; }
                } else if (!task.isCanceled()) {
                    error = "Scanner unavailable. Check that Google Play services is up to date and online, then try again. You can paste the pairing code now.";
                }
                final String resultCode = code, resultError = error;
                pendingScanResult = () -> pair(resultCode, resultError);
                showScanResult(); updateAdVisibility();
            });
        } catch (RuntimeException error) {
            scanningCode = false; pair(draft, "Couldn’t open the scanner. Paste your pairing code instead."); updateAdVisibility();
        }
    }
    private void showScanResult() {
        if (!visible || pendingScanResult == null || isFinishing() || isDestroyed()) return;
        Runnable result = pendingScanResult; pendingScanResult = null; result.run();
    }
    private boolean idleForPairingAd() {
        return visible && !isFinishing() && !isDestroyed()
                && inFlight == null && pendingAction == null
                && PhoneAudioSession.available();
    }
    private void showPairingCompletion() {
        if (!visible || pendingPairingCompletion == null || isFinishing() || isDestroyed()) return;
        Runnable next = pendingPairingCompletion;
        getWindow().getDecorView().postOnAnimation(() -> {
            if (pendingPairingCompletion == next && visible && !isFinishing() && !isDestroyed() && hasWindowFocus() && pairingDialog == null && idleForPairingAd()) { pendingPairingCompletion = null; next.run(); }
        });
    }
    private void pairingReady() {
        if (pairingDialog != null) pairingDialog.dismiss();
        AlertDialog dialog = new GlassDialogBuilder(this).setTitle("Pairing saved")
                .setMessage("Ready to connect to “" + settings.computerName() + "”. Choose Start audio to open the encrypted connection. Nothing is playing yet.")
                .setPositiveButton("Start audio", (d, which) -> dispatch("PLAY"))
                .setNegativeButton("Later", null).create();
        pairingDialog = dialog; updateAdVisibility();
        dialog.setOnDismissListener(d -> { if (pairingDialog == dialog) pairingDialog = null; updateAdVisibility(); });
        dialog.show();
    }
    private void diagnosticsDialog() {
        String report = "PairIt " + BuildConfig.VERSION_NAME + " (" + BuildConfig.VERSION_CODE + ")\n" + RelayService.diagnostics + "\n\n" + bannerAds.diagnostics() + "\n" + pairingAds.diagnostics();
        TextView details = text(report, 13, INK, false); details.setTypeface(Typeface.MONOSPACE); details.setTextIsSelectable(true); details.setPadding(dp(20), dp(12), dp(20), dp(12));
        ScrollView scroll = new ScrollView(this); scroll.addView(details);
        new GlassDialogBuilder(this).setTitle("Diagnostics").setView(scroll).setPositiveButton("Done", null)
                .setNeutralButton("Copy", (dialog, which) -> { getSystemService(ClipboardManager.class).setPrimaryClip(ClipData.newPlainText(getString(R.string.app_name)+" diagnostics", report)); if(Build.VERSION.SDK_INT<33)showFeedback("Diagnostics copied"); })
                .setNegativeButton("Refresh audio", (dialog, which) -> { if (RelayService.state.macSelected()) dispatch("RESYNC"); }).show();
    }
    private View settingRow(String label, String detail, Runnable click) {
        LinearLayout line = row(); line.setPadding(0, dp(15), 0, dp(15)); line.setMinimumHeight(dp(64));
        LinearLayout labels = column(); labels.addView(text(label, 16, INK, true)); labels.addView(text(detail, 12, MUTED, false));
        line.addView(labels, new LinearLayout.LayoutParams(0, -2, 1)); line.addView(text("›", 26, MUTED, false));
        line.setBackground(new RippleDrawable(ColorStateList.valueOf(0x1422634b), null, shape(Color.WHITE, 12, Color.TRANSPARENT)));
        line.setClickable(true); line.setFocusable(true); line.setContentDescription(label + ". " + detail);
        line.setOnClickListener(v -> click.run()); return line;
    }
    private final class GlassDialogBuilder extends AlertDialog.Builder {
        GlassDialogBuilder(Context context) { super(context); }
        @Override public AlertDialog create() {
            AlertDialog dialog = super.create();
            Window window = dialog.getWindow();
            if (window != null) {
                // PhoneWindow applies blur to its decor immediately, even before show().
                // Materialize it first so every dialog can safely use the shared surface.
                window.getDecorView();
                boolean blurAvailable = Build.VERSION.SDK_INT >= 31 && getWindowManager().isCrossWindowBlurEnabled();
                window.setBackgroundDrawable(GlassUI.dialogSurface(dp(18), blurAvailable));
                window.setDimAmount(.16f);
                if (blurAvailable) window.setBackgroundBlurRadius(dp(28));
            }
            return dialog;
        }
        @Override public AlertDialog show() { AlertDialog dialog = create(); dialog.show(); return dialog; }
    }
    private LinearLayout dialogBody() { LinearLayout body = column(); body.setPadding(dp(24), dp(10), dp(24), dp(8)); return body; }
    private Button button(String text, Runnable action) {
        Button button = new Button(this); button.setText(text); button.setAllCaps(false); button.setTextSize(15); button.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        button.setPadding(dp(8), dp(8), dp(8), dp(8)); button.setMinimumWidth(0); button.setMinWidth(0);
        GlassUI.pressFeedback(button);button.setOnClickListener(v -> action.run()); return button;
    }
    private void style(Button button, boolean selected) {
        button.setTextColor(selected ? Color.WHITE : INK);button.setBackgroundTintList(null);
        button.setBackground(new RippleDrawable(ColorStateList.valueOf(selected ? 0x30ffffff : 0x18191919),selected ? GlassUI.accent(dp(13)) : GlassUI.surface(dp(13)),null));
    }
    private StateListDrawable sourceStyle(Button button,String name) {
        StateListDrawable surface=new StateListDrawable();
        surface.addState(new int[]{android.R.attr.state_selected},GlassUI.accent(dp(13)));surface.addState(new int[]{},GlassUI.surface(dp(13)));
        button.setBackgroundTintList(null);button.setBackground(new RippleDrawable(ColorStateList.valueOf(0x30191919),surface,shape(Color.WHITE,13,Color.TRANSPARENT)));
        button.setTextColor(new ColorStateList(new int[][]{new int[]{android.R.attr.state_selected},new int[]{}},new int[]{Color.WHITE,INK}));
        StateListDrawable icons=new StateListDrawable();icons.addState(new int[]{android.R.attr.state_selected},new GlassUI.Glyph(name,Color.WHITE));icons.addState(new int[]{},new GlassUI.Glyph(name,GREEN));
        icons.setBounds(0,0,dp(26),dp(26));button.setCompoundDrawables(null,icons,null,null);button.setCompoundDrawablePadding(dp(7));return surface;
    }
    private GradientDrawable shape(int color, int radius, int border) { GradientDrawable d = new GradientDrawable(); d.setColor(color); d.setCornerRadius(dp(radius)); if (border != Color.TRANSPARENT) d.setStroke(dp(1), border); return d; }
    private TextView text(String value, float size, int color, boolean bold) {
        TextView view = new TextView(this); view.setText(value); view.setTextSize(size); view.setTextColor(color); view.setIncludeFontPadding(false);
        view.setTypeface(Typeface.create(bold ? "sans-serif-medium" : "sans-serif", Typeface.NORMAL)); view.setLineSpacing(dp(4), 1); return view;
    }
    private LinearLayout column() { LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL); return layout; }
    private LinearLayout row() { LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.HORIZONTAL); layout.setGravity(Gravity.CENTER_VERTICAL); return layout; }
    private void space(LinearLayout parent, int height) { parent.addView(new View(this), new LinearLayout.LayoutParams(1, dp(height))); }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    @Override public void onResume() {
        super.onResume(); if (updates != null) updates.check(); visible = true; RelayService.restoreControlsNotification(this);
        if(bannerAds!=null)bannerAds.resume();
        handler.removeCallbacks(refresh);handler.post(refresh);
        showScanResult();
        showPairingCompletion();
    }
    @Override public void onPause() { visible = false; if(pairingAds!=null)pairingAds.cancelUnshown(); if(bannerAds!=null)bannerAds.pause();handler.removeCallbacks(refresh); super.onPause(); }
    @Override public void onWindowFocusChanged(boolean focused) { super.onWindowFocusChanged(focused); updateAdVisibility(); if(pairingAds!=null)pairingAds.presentationWindowChanged(); if(focused)showPairingCompletion(); }
    private void updateAdVisibility() {
        if (bannerAds != null) bannerAds.setVisibleToUser(hasWindowFocus() && !PairingInterstitial.isPresenting() && !scanningCode && pairingDialog == null && pendingScanResult == null);
    }
    @Override public void onDestroy() { if (updates != null) updates.destroy(); pendingScanResult = null; pendingPairingCompletion = null; if (pairingDialog != null) pairingDialog.dismiss(); if(pairingAds!=null)pairingAds.destroy(); if(bannerAds!=null)bannerAds.destroy();handler.removeCallbacksAndMessages(null);super.onDestroy(); }
}
