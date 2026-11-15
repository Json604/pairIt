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
    private ReleaseUpdates updates;
    private String updateURL;
    private boolean scanningCode;
    private Runnable pendingScanResult;
    private AlertDialog pairingDialog;
    private PairingInterstitial pairingAds;
    private AppOpenAds appOpenAds;
    private boolean appOpeningOpportunity=true;
    private String automaticAdPin="";
    private Runnable pendingPairingCompletion;
    private long pairingFlow;
    private PairingConfirmation pairingConfirmation;
    private String pairingResult = "Pairing saved. Confirming with your computer…";
    private AlertDialog pairingResultDialog;
    private static final int BG = 0xfff5f4f2, INK = GlassUI.INK, MUTED = GlassUI.SECONDARY, GREEN = GlassUI.BLUE, LINE = 0xb3ffffff;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private TextView title, subtitle, groupTiming;
    private TextView feedback;
    private Button mac, phone, refreshAudio, connectRefresh, connectSync;
    private LinearLayout connectTools;
    private LinearLayout sourceCard;
    private ActivitySpinner startSpinner;
    private RelayOutputSelector sourceFrame;
    private View sourceIndicator;
    private float sourceTarget=Float.NaN;
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
        public void run() { render();showPairingCompletion(); if (updates != null) updates.check(); if(pairingAds!=null)pairingAds.prepare(); handler.postDelayed(this, 500); }
    };

    private NearbyDevices nearby;
    private ListeningInvitations invitations;
    private AlertDialog invitationDialog;
    private NearbyPairingRequest nearbyRequest;
    private AlertDialog nearbyRequestDialog;
    private PairingConfirmation automaticConfirmation;
    private boolean trustedNearby;
    private boolean verifyingConnection;
    private final ExplicitConnectionIntent explicitIntent=new ExplicitConnectionIntent();
    private String confirmedPin="";
    private RelayState.Phase observedPhase;
    private DiscoveryField field;
    private FrameLayout stage;
    private LinearLayout card, devicesArea, nav, shortcuts;
    private Button panelAction;
    private boolean connectedLayout;
    private AlertDialog compactPanel;
    private Runnable discoveryAnchor;
    private ScrollView contentScroll;
    private TextView cardTitle, cardDetail, nearbyStatus;
    private Button primary, scanAnother, outputRoute;
    private SeekBar volume;
    private ImageView cardIcon;
    private LinearLayout cardHeader;
    private View navIndicator;
    private FrameLayout navFrame;
    private android.animation.ValueAnimator navAnimation;
    private float navTarget=Float.NaN;
    private long waitingStopFlow;
    private int tab;
    private String renderedKey = "";
    private final Button[] tabs = new Button[3];

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved); LegacyPurchaseCleanup.run(this); settings=new RelaySettings(this);
        setVolumeControlStream(android.media.AudioManager.STREAM_MUSIC);
        getWindow().getDecorView().setSystemUiVisibility(0);
        getWindow().setStatusBarColor(Color.BLACK);getWindow().setNavigationBarColor(Color.BLACK);
        FrameLayout root=new FrameLayout(this);root.addView(new GlassUI.Backdrop(this),new FrameLayout.LayoutParams(-1,-1));
        field=new DiscoveryField(this);root.addView(field,new FrameLayout.LayoutParams(-1,-1));
        FitColumn layout=new FitColumn();layout.setPadding(dp(22),dp(12),dp(22),dp(8));LinearLayout outer=column();contentScroll=new ScrollView(this);contentScroll.setFillViewport(true);contentScroll.setOnScrollChangeListener((v,x,y,oldX,oldY)->{if(discoveryAnchor!=null)discoveryAnchor.run();});contentScroll.setOverScrollMode(View.OVER_SCROLL_IF_CONTENT_SCROLLS);contentScroll.addView(layout,new ScrollView.LayoutParams(-1,-2));outer.addView(contentScroll,new LinearLayout.LayoutParams(-1,0,1));root.addView(outer,new FrameLayout.LayoutParams(-1,-1));setContentView(root);
        outer.setOnApplyWindowInsetsListener((v,insets)->{ if(Build.VERSION.SDK_INT>=30){android.graphics.Insets bars=insets.getInsets(WindowInsets.Type.systemBars());v.setPadding(bars.left,bars.top,bars.right,bars.bottom);}return insets;});
        LinearLayout header=row();ImageView brandIcon=new ImageView(this);brandIcon.setImageDrawable(new GlassUI.Glyph("headphones",Color.WHITE));header.addView(brandIcon,new LinearLayout.LayoutParams(dp(26),dp(26)));
        TextView brand=text("PairIt",21,Color.WHITE,true);brand.setGravity(Gravity.CENTER_VERTICAL);LinearLayout.LayoutParams brandParams=new LinearLayout.LayoutParams(0,-2,1);brandParams.setMarginStart(dp(9));header.addView(brand,brandParams);
        ImageView report=new ImageView(this);report.setImageDrawable(new GlassUI.Glyph("report",Color.WHITE));report.setPadding(dp(10),dp(10),dp(10),dp(10));report.setContentDescription("Report a problem");report.setBackground(shape(0x22ffffff,22,Color.TRANSPARENT));report.setOnClickListener(v->reportProblem());header.addView(report,new LinearLayout.LayoutParams(dp(44),dp(44)));
        layout.addView(header);
        Button updateButton=button("Update available",()->{if(updateURL!=null)updates.open(updateURL);});style(updateButton,true);updateButton.setVisibility(View.GONE);layout.addView(updateButton);
        updates=new ReleaseUpdates(this,(label,url)->{updateURL=url;updateButton.setText(label==null?"":label+" · Update");updateButton.setVisibility(label==null?View.GONE:View.VISIBLE);});
        space(layout,12);title=text("Nearby computers",27,Color.WHITE,true);layout.addView(title);space(layout,8);
        subtitle=text("Tap a computer to connect.",14,0xffcccccc,false);subtitle.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);layout.addView(subtitle);
        stage=new FrameLayout(this);stage.setMinimumHeight(dp(200));layout.addView(stage,new LinearLayout.LayoutParams(-1,-2));layout.flexible=stage;
        devicesArea=column();devicesArea.setGravity(Gravity.CENTER);stage.addView(devicesArea,new FrameLayout.LayoutParams(-1,-1));
        card=column();card.setPadding(dp(18),dp(17),dp(18),dp(17));card.setBackground(shape(0xfff6f6f8,28,Color.TRANSPARENT));layout.addView(card,new LinearLayout.LayoutParams(-1,-2));
        cardHeader=row();cardIcon=new ImageView(this);cardIcon.setPadding(dp(10),dp(10),dp(10),dp(10));cardIcon.setBackground(shape(0xffeeeeee,14,Color.TRANSPARENT));cardIcon.setImageDrawable(new GlassUI.Glyph("qr",INK));cardHeader.addView(cardIcon,new LinearLayout.LayoutParams(dp(42),dp(42)));
        LinearLayout labels=column();cardTitle=text("QR pairing",16,INK,true);labels.addView(cardTitle);space(labels,4);cardDetail=text("Scan the code on your computer.",12,MUTED,false);labels.addView(cardDetail);LinearLayout.LayoutParams labelParams=new LinearLayout.LayoutParams(0,-2,1);labelParams.setMarginStart(dp(12));cardHeader.addView(labels,labelParams);card.addView(cardHeader);space(card,12);
        sourceFrame=new RelayOutputSelector(this,()->{if(RelayService.state.phase!=RelayState.Phase.PLAYING)startFromButton();},this::changeComputerOutput);mac=sourceFrame.phone;phone=sourceFrame.computer;card.addView(sourceFrame);space(card,8);
        outputRoute=button("Phone output",this::outputDialog);style(outputRoute,false);outputRoute.setGravity(Gravity.CENTER_VERTICAL|Gravity.START);outputRoute.setTextSize(12);
        primary=button("Scan QR code",()->{if(tab==1){if(togetherHostProblem().isEmpty())shareApp();else selectTab(0);}else if(tab==2)settingsDialog();else if(settings.paired())startFromButton();else scanPairingCode("");});style(primary,true);primary.setTextSize(14);FrameLayout primaryFrame=new FrameLayout(this);primary.setMinHeight(dp(48));primaryFrame.addView(primary,new FrameLayout.LayoutParams(-1,-2));startSpinner=new ActivitySpinner(this);startSpinner.setVisibility(View.GONE);FrameLayout.LayoutParams spinnerParams=new FrameLayout.LayoutParams(dp(20),dp(20),Gravity.START|Gravity.CENTER_VERTICAL);spinnerParams.setMarginStart(dp(16));primaryFrame.addView(startSpinner,spinnerParams);card.addView(primaryFrame,new LinearLayout.LayoutParams(-1,-2));
        scanAnother=button("Scan QR code",()->scanPairingCode(""));style(scanAnother,false);
        GlassUI.Glyph scanIcon=new GlassUI.Glyph("qr",INK);scanIcon.setBounds(0,0,dp(18),dp(18));scanAnother.setCompoundDrawables(scanIcon,null,null,null);scanAnother.setCompoundDrawablePadding(dp(8));
        volume=new SeekBar(this);volume.setMax(100);android.media.AudioManager audio=getSystemService(android.media.AudioManager.class);volume.setProgress(audio.getStreamVolume(android.media.AudioManager.STREAM_MUSIC)*100/Math.max(1,audio.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)));volume.setContentDescription("Phone volume");volume.setProgressTintList(ColorStateList.valueOf(INK));volume.setThumbTintList(ColorStateList.valueOf(INK));volume.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){public void onStartTrackingTouch(SeekBar b){} public void onStopTrackingTouch(SeekBar b){} public void onProgressChanged(SeekBar b,int value,boolean user){if(user)audio.setStreamVolume(android.media.AudioManager.STREAM_MUSIC,Math.round(value*audio.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)/100f),0);}});
        refreshAudio=button("Refresh audio",()->{if(RelayService.state.phase==RelayState.Phase.PLAYING)dispatch("RESYNC");});style(refreshAudio,false);refreshAudio.setTextSize(13);refreshAudio.setMinHeight(dp(48));


        shortcuts=row();space(card,8);card.addView(shortcuts);
        shortcut(outputRoute,"Output","headphones");shortcut(scanAnother,"Scan QR","qr");panelAction=button("Get PC app",()->{if(connectedLayout)morePanel();else downloadsPanel();});shortcut(panelAction,"Get PC app","laptop");
        scanAnother.setOnClickListener(v->{if(connectedLayout)audioPanel();else scanPairingCode("");});
        connectTools=row();connectTools.setPadding(0,dp(8),0,0);
        connectRefresh=button("Refresh",this::refreshConnectPage);style(connectRefresh,false);connectRefresh.setTextSize(13);connectRefresh.setMinHeight(dp(48));
        connectSync=button("Audio / video sync",this::syncDialog);style(connectSync,false);connectSync.setTextSize(13);connectSync.setMinHeight(dp(48));
        LinearLayout.LayoutParams refreshParams=new LinearLayout.LayoutParams(0,-2,1);refreshParams.setMarginEnd(dp(6));
        connectTools.addView(connectRefresh,refreshParams);connectTools.addView(connectSync,new LinearLayout.LayoutParams(0,-2,1));card.addView(connectTools);
        groupTiming=text("",12,MUTED,false);groupTiming.setGravity(Gravity.CENTER);groupTiming.setPadding(0,dp(6),0,0);groupTiming.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);groupTiming.setVisibility(View.GONE);card.addView(groupTiming);
        nav=row();nav.setClipChildren(true);nav.setClipToPadding(true);nav.setPadding(dp(6),dp(6),dp(6),dp(6));navFrame=new FrameLayout(this);navFrame.setClipChildren(true);navFrame.setClipToPadding(true);navFrame.setBackground(shape(0xff111111,32,0xff333333));navIndicator=new View(this);navIndicator.setBackground(shape(0xffeeeeee,27,Color.TRANSPARENT));FrameLayout.LayoutParams indicatorParams=new FrameLayout.LayoutParams(0,dp(56));indicatorParams.setMargins(dp(6),dp(6),0,0);navFrame.addView(navIndicator,indicatorParams);navFrame.addView(nav,new FrameLayout.LayoutParams(-1,-2));navFrame.addOnLayoutChangeListener((v,l,t,r,b,ol,ot,or,ob)->{if(r-l!=or-ol||b-t!=ob-ot)moveIndicator(false);});
        String[] names={"Connect","Together","Settings"};String[] icons={"headphones","people","settings"};
        for(int i=0;i<3;i++){final int index=i;tabs[i]=button(names[i],()->selectTab(index));tabs[i].setTextSize(12);tabs[i].setMinHeight(dp(56));GlassUI.Glyph g=new GlassUI.Glyph(icons[i],i==0?INK:0xffbbbbbb);g.setBounds(0,0,dp(22),dp(22));tabs[i].setCompoundDrawables(null,g,null,null);nav.addView(tabs[i],new LinearLayout.LayoutParams(0,-2,1));}LinearLayout navContainer=column();navContainer.setPadding(dp(22),dp(6),dp(22),dp(8));navContainer.addView(navFrame);outer.addView(navContainer);
        LinearLayout ads=column();outer.addView(ads,new LinearLayout.LayoutParams(-1,-2));bannerAds=new BannerAds(this,ads);pairingAds=new PairingInterstitial(this,bannerAds,this::idleForPairingAd,this::updateAdVisibility);FrameLayout opening=new FrameLayout(this);opening.setBackgroundColor(Color.BLACK);opening.setClickable(true);opening.setVisibility(View.GONE);TextView openingLabel=text("PairIt",28,Color.WHITE,true);openingLabel.setGravity(Gravity.CENTER);opening.addView(openingLabel,new FrameLayout.LayoutParams(-1,-1));root.addView(opening,new FrameLayout.LayoutParams(-1,-1));
        appOpenAds=new AppOpenAds(this,bannerAds,()->idleForPairingAd()&&!scanningCode&&pairingDialog==null&&nearbyRequest==null&&!explicitIntent.active(),on->opening.setVisibility(on?View.VISIBLE:View.GONE),()->{updateAdVisibility();confirmTrustedNearby();});
        bannerAds.onReadinessChanged(()->{pairingAds.prepare();appOpenAds.prepare();});bannerAds.onConsentChanged(()->{pairingAds.consentChanged();appOpenAds.consentChanged();});
        feedback=text("",13,INK,false);feedback.setPadding(dp(16),dp(14),dp(16),dp(14));feedback.setBackground(shape(Color.WHITE,16,Color.TRANSPARENT));feedback.setVisibility(View.GONE);feedback.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        FrameLayout.LayoutParams toast=new FrameLayout.LayoutParams(-1,-2,Gravity.TOP);toast.setMargins(dp(24),dp(60),dp(24),0);root.addView(feedback,toast);
        invitations=new ListeningInvitations(new ListeningInvitations.UI(){
            public boolean canHost(){return togetherHostProblem().isEmpty();}
            public void confirm(String title,String code,java.util.function.Consumer<Boolean> answer){
                if(!visible||tab!=1||pairingDialog!=null||compactPanel!=null||AppOpenAds.isPresenting()||PairingInterstitial.isPresenting()){answer.accept(false);return;}
                if(invitations.hosting()&&!togetherHostProblem().isEmpty()){answer.accept(false);showFeedback(togetherHostProblem());return;}
                boolean hosting=invitations.hosting();
                invitationDialog=new GlassDialogBuilder(MainActivity.this).setTitle(title)
                    .setMessage((hosting?"You are inviting a guest to your computer. ":"You are joining as a guest. This connects you to the host’s computer and replaces your saved computer. ")+"Each phone uses its own speaker or headphones. Compare this code on both phones; only accept if it matches.\n\n"+code)
                    .setPositiveButton(hosting?"Invite guest":"Join listening",(d,w)->{if(hosting&&!togetherHostProblem().isEmpty()){answer.accept(false);showFeedback(togetherHostProblem());}else answer.accept(true);}).setNegativeButton("Decline",(d,w)->answer.accept(false)).create();
                invitationDialog.setOnCancelListener(d->answer.accept(false));invitationDialog.show();
            }
            public void received(String code){
                if(invitationDialog!=null){invitationDialog.dismiss();invitationDialog=null;}
                handler.post(()->{try{connectVerifiedCode(PairingCode.parse(code),true);}catch(Exception invalid){showFeedback("Invalid invitation. Ask your friend to try again.");}});
            }
            public void progress(String message){renderedKey="";render();}
            public void finished(String message){renderedKey="";render();if(invitationDialog!=null){invitationDialog.dismiss();invitationDialog=null;}if(!message.isEmpty()&&visible)showFeedback(message);}
        },handler::post);
        nearby=new NearbyDevices(this,()->{confirmTrustedNearby();renderedKey="";render();});selectTab(0);acceptPairing(getIntent());handler.post(bannerAds::start);
    }
    private void confirmTrustedNearby(){
        if(tab!=0||!visible||(appOpenAds!=null&&appOpenAds.isOpening())||AppOpenAds.isPresenting()||pairingDialog!=null||PairingInterstitial.isPresenting()||!settings.autoReconnect()||!settings.paired()||automaticConfirmation!=null||confirmedPin.equals(settings.pin()))return;
        for(NearbyDevices.Device device:nearby.snapshot())if(device.pin.equals(settings.pin())){
            final String savedPin=settings.pin();confirmedPin=savedPin;
            automaticConfirmation=new PairingConfirmation(PairingCode.saved(settings,settings.connectionHost(device.host)),confirmed->{
                automaticConfirmation=null;if(!settings.pin().equals(savedPin))return;trustedNearby=confirmed;if(confirmed){settings.discovered(device.host,savedPin);
                    if(!automaticAdPin.equals(savedPin)&&idleForPairingAd()&&System.currentTimeMillis()-getSharedPreferences("advertising",MODE_PRIVATE).getLong("lastFullscreenAd",0)>10_000){automaticAdPin=savedPin;long adFlow=pairingAds.begin();pairingAds.showAfterConnection(adFlow,()->{});}
                    else {automaticAdPin=savedPin;}}renderedKey="";render();
            });break;
        }
    }
    private void selectTab(int value){if(value!=tab&&contentScroll!=null)contentScroll.scrollTo(0,0);if(value!=tab)cancelExplicitConnection();tab=value;renderedKey="";if(nearby!=null){if(value!=1)stopInvitations();else nearby.invitationPort=invitations.start();if(value==2)nearby.stop();else nearby.start(value==1);}render();}
    private void moveIndicator(boolean animate){
        if(navFrame==null||navFrame.getWidth()==0)return;
        int width=Math.max(0,(navFrame.getWidth()-dp(12))/3);android.view.ViewGroup.LayoutParams lp=navIndicator.getLayoutParams();if(lp.width!=width||lp.height!=navFrame.getHeight()-dp(12)){lp.width=width;lp.height=navFrame.getHeight()-dp(12);navIndicator.setLayoutParams(lp);}
        float limit=navFrame.getWidth()-dp(12)-width;
        float target=Math.max(0,Math.min(width*tab,limit));
        if(animate&&target==navTarget)return;
        navTarget=target;if(navAnimation!=null)navAnimation.cancel();
        if(!animate||settings.reducedMotion()||GlassUI.duration(this,1)==0){navIndicator.setTranslationX(target);navIndicator.setScaleX(1);return;}
        final float from=navIndicator.getTranslationX();navAnimation=android.animation.ValueAnimator.ofFloat(0,1);navAnimation.setDuration(650);navAnimation.setInterpolator(new android.view.animation.LinearInterpolator());
        navAnimation.addUpdateListener(animation->{float t=(float)animation.getAnimatedValue();float spring=t==1?1:(float)(1-Math.exp(-7.5*t)*(Math.cos(10*t)+.75*Math.sin(10*t)));float proposed=from+(target-from)*spring;float bounded=Math.max(0,Math.min(limit,proposed));float compression=Math.min(.14f,Math.abs(proposed-bounded)/Math.max(1,width));navIndicator.setPivotX(proposed<0?0:width);navIndicator.setScaleX(1-compression);navIndicator.setTranslationX(bounded);});navAnimation.start();
    }
    private void requestNearbyPairing(NearbyDevices.Device device){
        cancelExplicitConnection();
        if(!device.platform.equals("macos")){scanPairingCode("");return;}
        try {
            NearbyPairingRequest request=new NearbyPairingRequest(device.pin);nearbyRequest=request;
            nearbyRequestDialog=new GlassDialogBuilder(this).setTitle("Approve on your computer")
                .setMessage("Match this code before approving:\n\n"+request.comparison)
                .setNegativeButton("Cancel",(dialog,which)->cancelNearbyPairing()).create();
            nearbyRequestDialog.setOnCancelListener(dialog->cancelNearbyPairing());nearbyRequestDialog.show();
            request.start(device,code->{
                if(nearbyRequest!=request)return;
                nearbyRequest=null;if(nearbyRequestDialog!=null){nearbyRequestDialog.dismiss();nearbyRequestDialog=null;}
                if(!visible||isFinishing()||isDestroyed())return;
                if(code==null){showFeedback("Request not approved. Try again or scan the QR code.");return;}
                // Let the dismissed dialog return focus before the authenticated exchange.
                handler.post(()->connectVerifiedCode(code,true));
            });
        }catch(Exception error){cancelNearbyPairing();showFeedback("Couldn’t request pairing. Scan the QR code instead.");}
    }
    private void cancelNearbyPairing(){
        if(nearbyRequest!=null){nearbyRequest.cancel();nearbyRequest=null;}
        if(nearbyRequestDialog!=null){nearbyRequestDialog.dismiss();nearbyRequestDialog=null;}
    }
    private void moveOutputIndicator(boolean animate){sourceFrame.select("OUTPUT_COMPUTER".equals(inFlight)||(!"PLAY".equals(inFlight)&&RelayService.computerOutputSelected),animate);}
    private void stopInvitations(){
        if(invitations!=null)invitations.stop();
        if(invitationDialog!=null){invitationDialog.dismiss();invitationDialog=null;}
    }
    private String togetherHostProblem(){
        RelayState.Phase phase=RelayService.state.phase;
        boolean connected=RelayService.hasControlConnection()&&(phase==RelayState.Phase.PLAYING||phase==RelayState.Phase.PAUSED||phase==RelayState.Phase.BUFFERING||phase==RelayState.Phase.COMPUTER_OUTPUT);
        return ListeningInvitations.hostProblem(connected,!RelayService.computerOutputSelected,settings.connectionOutput(getSystemService(android.media.AudioManager.class),false)!=null);
    }
    private void invitePhone(NearbyDevices.Device phone){
        String problem=togetherHostProblem();if(!problem.isEmpty()){showFeedback(problem);return;}
        try{PairingCode code=PairingCode.saved(settings,settings.connectionHost(null));invitations.invite(phone.host,phone.invitationPort,code.invitationCode(),code.name);}
        catch(Exception error){showFeedback("Connect to your computer again before inviting.");}
    }
    private void shareApp(){Intent share=new Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT,"Get PairIt: https://pairit.kartikey.xyz/downloads");startActivity(Intent.createChooser(share,"Share PairIt"));}
    private void showDevices(boolean together,boolean connected){
        devicesArea.removeAllViews();discoveryAnchor=null;
        if(connected&&!together){
            ImageView symbol=new ImageView(this);symbol.setImageDrawable(new GlassUI.Glyph(RelayService.computerOutputSelected?"mac":"headphones",Color.WHITE));
            devicesArea.addView(symbol,new LinearLayout.LayoutParams(dp(64),dp(64)));
            space(devicesArea,24);
            devicesArea.addView(new ListeningBars(this,RelayService.state.phase==RelayState.Phase.PLAYING),new LinearLayout.LayoutParams(-1,dp(28)));
            space(devicesArea,16);
            TextView status=text(RelayService.state.phase==RelayState.Phase.PLAYING?"Listening on this phone":RelayService.computerOutputSelected?"Playing on computer":RelayService.state.phase==RelayState.Phase.PAUSED?"Paused":RelayService.state.title.equals("Waiting for computer audio")?"Connected · play audio on your computer":RelayService.state.phase==RelayState.Phase.CONNECTING||RelayService.state.phase==RelayState.Phase.BUFFERING||RelayService.state.phase==RelayState.Phase.RECONNECTING?"Connecting…":"Ready to listen",13,Color.WHITE,false);
            status.setGravity(Gravity.CENTER);devicesArea.addView(status,new LinearLayout.LayoutParams(-1,-2));return;
        }
        java.util.List<NearbyDevices.Device> list=nearby==null?java.util.Collections.emptyList():nearby.snapshot();
        LinearLayout map=column();map.setGravity(Gravity.CENTER);map.setMinimumHeight(dp(112));devicesArea.addView(map,new LinearLayout.LayoutParams(-1,-2,1));
        LinearLayout deviceRow=null;
        java.util.List<android.view.View> phoneNodes=new java.util.ArrayList<>();
        int count=0;
        for(NearbyDevices.Device d:list){
            if(count>=4)break;final int position=count++;
            LinearLayout node=RelayComponents.nearby(this,d.name,together?d.platform:d.pin.equals(settings.pin())?"Paired":(d.platform.equals("macos")?"Mac":d.platform.equals("ios")?"iPhone":d.platform),together,()->{if(together)invitePhone(d);else if(settings.paired()&&d.pin.equals(settings.pin())){connectVerifiedCode(PairingCode.saved(settings,settings.connectionHost(d.host)),false);}else requestNearbyPairing(d);});
            if(together){phoneNodes.add(node);continue;}
            if(position%2==0){deviceRow=row();deviceRow.setGravity(Gravity.CENTER);map.addView(deviceRow,new LinearLayout.LayoutParams(-1,-2));}
            deviceRow.addView(node,new LinearLayout.LayoutParams(0,-2,1));

        }
        if(together&&!phoneNodes.isEmpty())map.addView(RelayComponents.phoneOrbit(this,phoneNodes),new LinearLayout.LayoutParams(-1,-2));
        if(count==0){TextView empty=text(together?"No phones nearby":"Looking for computers…",15,Color.WHITE,false);empty.setGravity(Gravity.CENTER);map.addView(empty,new LinearLayout.LayoutParams(-1,-2));}
        space(devicesArea,10);LinearLayout self=column();self.setGravity(Gravity.CENTER);ImageView orb=RelayComponents.ownPhone(this);self.addView(orb,new LinearLayout.LayoutParams(dp(48),dp(48)));space(self,5);TextView ownLabel=text("You",11,0xffdddddd,false);ownLabel.setGravity(Gravity.CENTER);self.addView(ownLabel,new LinearLayout.LayoutParams(-1,-2));devicesArea.addView(self);space(devicesArea,12);
        TextView countLabel=text(count==0?(together?"Open PairIt on another phone":"Open PairIt on your computer"):count+" "+(together?(count==1?"phone":"phones"):(count==1?"computer":"computers"))+" nearby · same Wi-Fi",11,Color.WHITE,false);countLabel.setGravity(Gravity.CENTER);devicesArea.addView(countLabel);space(devicesArea,12);
        Runnable anchor=()->{int[] y=new int[2],f=new int[2];orb.getLocationOnScreen(y);field.getLocationOnScreen(f);field.centerY=(y[1]-f[1]+orb.getHeight()/2f)/Math.max(1,field.getHeight());field.invalidate();};orb.post(anchor);discoveryAnchor=anchor;
    }
    private void settingsPage(){
        discoveryAnchor=null;devicesArea.removeAllViews();devicesArea.setGravity(Gravity.TOP);space(devicesArea,18);
        TextView connection=text("CONNECTION",10,0xffcccccc,false);connection.setLetterSpacing(.12f);devicesArea.addView(connection);space(devicesArea,9);
        LinearLayout connectionCard=column();connectionCard.setPadding(dp(16),dp(2),dp(16),dp(2));connectionCard.setBackground(shape(0xfff6f6f8,27,Color.TRANSPARENT));
        connectionCard.addView(preference("Auto-reconnect","Previously paired computers on this Wi-Fi.",settings.autoReconnect(),on->settings.autoReconnect(on)));
        connectionCard.addView(preference("Sound feedback","A short sound when connected.",settings.soundFeedback(),on->settings.soundFeedback(on)));
        connectionCard.addView(settingRow("Paired computers",settings.paired()?settings.computerName():"None",this::connectionDialog));devicesArea.addView(connectionCard,new LinearLayout.LayoutParams(-1,-2));space(devicesArea,18);
        TextView general=text("GENERAL",10,0xffcccccc,false);general.setLetterSpacing(.12f);devicesArea.addView(general);space(devicesArea,9);
        LinearLayout generalCard=column();generalCard.setPadding(dp(16),dp(2),dp(16),dp(2));generalCard.setBackground(shape(0xfff6f6f8,27,Color.TRANSPARENT));
        generalCard.addView(settingRow("Phone microphone","Use on your computer",()->{stopAudioForSettings();startActivity(new Intent(this,MicrophoneActivity.class));}));
        generalCard.addView(settingRow("Help & setup","",()->InformationActivity.open(this,"help")));
        generalCard.addView(settingRow("Privacy","",()->InformationActivity.open(this,"privacy")));
        generalCard.addView(settingRow("More settings","",this::settingsDialog));devicesArea.addView(generalCard,new LinearLayout.LayoutParams(-1,-2));
    }
    private View preference(String label,String detail,boolean checked,java.util.function.Consumer<Boolean> action){
        LinearLayout row=row();row.setPadding(0,dp(12),0,dp(12));LinearLayout labels=column();labels.addView(text(label,13,INK,true));space(labels,5);labels.addView(text(detail,10,MUTED,false));row.addView(labels,new LinearLayout.LayoutParams(0,-2,1));Switch control=new PlainSwitch(this);control.setContentDescription(label);control.setChecked(checked);control.setThumbTintList(ColorStateList.valueOf(Color.WHITE));control.setTrackTintList(new ColorStateList(new int[][]{new int[]{android.R.attr.state_checked},new int[]{}},new int[]{INK,0xffcccccc}));control.setOnCheckedChangeListener((b,on)->action.accept(on));row.addView(control);return row;
    }
    private LinearLayout computerDownloadButtons() {
        LinearLayout links=row();
        for (String platform : new String[]{"Mac", "Windows", "Linux"}) {
            Button link=button(platform,()->openDownload(platform.toLowerCase(java.util.Locale.ROOT)));
            style(link,false);link.setTextSize(11);link.setPadding(dp(5),0,dp(5),0);GlassUI.Glyph icon=new GlassUI.Glyph(platform.equals("Mac")?"laptop":platform.equals("Windows")?"windows":"linux",INK);icon.setBounds(0,0,dp(16),dp(16));link.setCompoundDrawables(icon,null,null,null);link.setCompoundDrawablePadding(dp(4));link.setContentDescription("Download PairIt for "+platform);LinearLayout.LayoutParams size=new LinearLayout.LayoutParams(0,dp(44),1);if(links.getChildCount()>0)size.setMarginStart(dp(5));links.addView(link,size);
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
    // This activity is exported for launcher/pairing links. Intent extras cannot
    // authorize playback: any other app can supply them. Start audio only from
    // our controls or the permission-protected Quick Settings tile service.
    @Override protected void onNewIntent(Intent intent) { super.onNewIntent(intent); setIntent(intent); acceptPairing(intent); }
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
        if(primary==null)return;RelayState state=RelayService.state;updateAdVisibility();
        if(inFlight!=null){
            boolean completed="OUTPUT_COMPUTER".equals(inFlight)?RelayService.computerOutputSelected:"PLAY".equals(inFlight)?state.phase==RelayState.Phase.PLAYING:state!=requestedFrom&&!RelayService.awaitingPlaybackAcknowledgment();
            if(completed||state.phase==RelayState.Phase.ERROR||state.phase==RelayState.Phase.HEADPHONES||SystemClock.uptimeMillis()-requestedAt>4000)inFlight=null;
        }
        boolean failed=state.phase==RelayState.Phase.ERROR||state.phase==RelayState.Phase.HEADPHONES;
        if(failed){trustedNearby=false;}
        observedPhase=state.phase;
        boolean connected=settings.paired()&&!failed&&(state.phase!=RelayState.Phase.IDLE)&&(state.phase!=RelayState.Phase.PHONE||RelayService.hasControlConnection());
        String key=tab+":"+verifyingConnection+":"+state.phase+":"+state.detail+":"+settings.paired()+":"+trustedNearby+":"+settings.output()+":"+RelayService.outputControlSupported+":"+RelayService.computerOutputSelected+":"+inFlight+":"+connected+":"+RelayService.computerVolume+":"+RelayService.groupTimingStatus;
        if(key.equals(renderedKey))return;renderedKey=key;
        for(int i=0;i<3;i++){tabs[i].setTextColor(i==tab?INK:0xffbbbbbb);tabs[i].setBackgroundColor(Color.TRANSPARENT);GlassUI.Glyph icon=new GlassUI.Glyph(i==0?"headphones":i==1?"people":"settings",i==tab?INK:0xffbbbbbb);icon.setBounds(0,0,dp(22),dp(22));tabs[i].setCompoundDrawables(null,icon,null,null);}
        moveIndicator(true);
        connectedLayout=connected;boolean together=tab==1,preferences=tab==2;
        title.setText(preferences?"Settings":together?"Listen together":verifyingConnection?"Connecting…":failed?state.title:connected?settings.computerName():"Nearby computers");
        subtitle.setText(preferences?"Connection and audio.":together?(togetherHostProblem().isEmpty()?"Hosting from "+settings.computerName():"Connect a computer to host, or wait for an invitation."):failed?state.detail:connected?state.phase==RelayState.Phase.ERROR||state.phase==RelayState.Phase.HEADPHONES?state.detail:state.phase==RelayState.Phase.PLAYING?"Connected":state.phase==RelayState.Phase.CONNECTING||state.phase==RelayState.Phase.RECONNECTING?"Connecting…":"Paired":"Tap a computer to connect.");
        field.reduced=settings.reducedMotion();field.active=!preferences&&(together||!connected);field.listening=false;field.playing=state.phase==RelayState.Phase.PLAYING;field.invalidate();
        card.setVisibility(preferences?View.GONE:View.VISIBLE);subtitle.setVisibility(preferences||connected&&!together?View.GONE:View.VISIBLE);devicesArea.setGravity(Gravity.CENTER);
        if(preferences)settingsPage();else showDevices(together,connected);
        cardTitle.setText(preferences?"Preferences":together?(togetherHostProblem().isEmpty()?"Invite a listener":"Connect or join"):connected?"Audio output":settings.paired()?"Saved computer":"QR pairing");
        cardDetail.setText(preferences?"Audio, pairing, privacy and updates.":together?(!togetherHostProblem().isEmpty()?togetherHostProblem():!invitations.notice().isEmpty()?invitations.notice():"Invite up to three guests. Each phone uses its own speaker or headphones. Keep Together open on both phones."):connected?(RelayService.hasControlConnection()?RelayService.computerVolume:""):settings.paired()?settings.computerName():"Scan the code on your computer.");
        cardIcon.setImageDrawable(new GlassUI.Glyph(together?"people":settings.paired()?"laptop":"qr",INK));cardDetail.setVisibility(!together&&connected&&RelayService.computerVolume.isEmpty()?View.GONE:View.VISIBLE);
        sourceFrame.setVisibility(!together&&!preferences&&connected?View.VISIBLE:View.GONE);boolean selectedComputer="OUTPUT_COMPUTER".equals(inFlight)||(!"PLAY".equals(inFlight)&&RelayService.computerOutputSelected);moveOutputIndicator(true);phone.setEnabled(RelayService.outputControlSupported&&inFlight==null);mac.setEnabled(inFlight==null);
        primary.setText(preferences?"Open settings":together?(togetherHostProblem().isEmpty()?"Share app":"Connect a computer"):!settings.paired()?"Scan QR code":!connected?"Connect":state.phase==RelayState.Phase.PLAYING?"Pause audio":"Start audio");primary.setEnabled(inFlight==null);primary.setVisibility(!together&&!preferences&&RelayService.computerOutputSelected?View.INVISIBLE:View.VISIBLE);GlassUI.Glyph actionIcon=new GlassUI.Glyph(together?"people":settings.paired()?"headphones":"qr",Color.WHITE);actionIcon.setBounds(0,0,dp(18),dp(18));primary.setCompoundDrawables(actionIcon,null,null,null);primary.setCompoundDrawablePadding(dp(8));
        shortcuts.setVisibility(!together&&!preferences?View.VISIBLE:View.GONE);
        scanAnother.setVisibility(View.VISIBLE);setShortcut(scanAnother,connected?"Audio":"Scan QR",connected?"settings":"qr");setShortcut(panelAction,connected?"More":"Get PC app",connected?"more":"laptop");
        scanAnother.setEnabled(!verifyingConnection&&inFlight==null);
        android.media.AudioManager routeManager=getSystemService(android.media.AudioManager.class);
        android.media.AudioDeviceInfo selectedRoute=settings.connectionOutput(routeManager,!connected);
        String routeName=OutputRoute.name(selectedRoute);
        setShortcut(outputRoute,"Output",OutputRoute.SPEAKER.accepts(selectedRoute)?"phone":"headphones");
        outputRoute.setContentDescription("Output, "+routeName);outputRoute.setVisibility(View.VISIBLE);
        if(!together&&!preferences&&settings.paired()&&selectedRoute!=null){cardTitle.setText(RelayService.computerOutputSelected?"Playing on computer":connected?"Phone audio output":"Ready to connect");cardDetail.setText((RelayService.computerOutputSelected?settings.computerName():routeName)+(connected&&!RelayService.computerVolume.isEmpty()?" · "+RelayService.computerVolume:""));cardDetail.setVisibility(View.VISIBLE);}
        boolean waitingForAudio=state.phase==RelayState.Phase.BUFFERING&&state.title.equals("Waiting for computer audio");
        boolean starting=!waitingForAudio&&!together&&!preferences&&!RelayService.computerOutputSelected&&(verifyingConnection||"PLAY".equals(inFlight)||state.phase==RelayState.Phase.CONNECTING||state.phase==RelayState.Phase.BUFFERING||state.phase==RelayState.Phase.RECONNECTING);
        boolean pausing=!together&&!preferences&&"MEDIA_PAUSE".equals(inFlight);
        startSpinner.setVisibility(starting||pausing?View.VISIBLE:View.GONE);
        if(waitingForAudio&&!together&&!preferences){primary.setText("Pause audio");primary.setEnabled(inFlight==null);}
        if(starting||pausing){primary.setText(pausing?"Pausing…":"Starting…");primary.setEnabled(false);primary.setCompoundDrawables(null,null,null,null);}

        connectTools.setVisibility(tab==0?View.VISIBLE:View.GONE);
        groupTiming.setText(RelayService.groupTimingStatus);groupTiming.setVisibility(tab==0&&connected&&!RelayService.groupTimingStatus.isEmpty()?View.VISIBLE:View.GONE);
        connectRefresh.setText(connected?"Refresh audio":"Refresh nearby");
        connectRefresh.setEnabled(!starting&&!pausing&&inFlight==null&&(!connected||(state.phase==RelayState.Phase.PLAYING&&!RelayService.computerOutputSelected)));
        connectRefresh.setAlpha(connectRefresh.isEnabled()?1f:.4f);
        connectRefresh.setContentDescription(connected?"Refresh audio timing without changing your computer":"Refresh nearby computers");
        connectSync.setEnabled(!starting&&!pausing&&inFlight==null);connectSync.setAlpha(connectSync.isEnabled()?1f:.4f);
        volume.setEnabled(connected&&!RelayService.computerOutputSelected);
        refreshAudio.setEnabled(inFlight==null&&state.phase==RelayState.Phase.PLAYING&&!RelayService.computerOutputSelected);refreshAudio.setAlpha(refreshAudio.isEnabled()?1f:.4f);

    }
    private void refreshConnectPage() {
        if(connectedLayout){if(RelayService.state.phase==RelayState.Phase.PLAYING&&!RelayService.computerOutputSelected)dispatch("RESYNC");return;}
        if(tab!=0||verifyingConnection||inFlight!=null)return;
        if(nearby!=null)nearby.start(false);
        renderedKey="";render();showFeedback("Looking for nearby computers…");
    }
    private void dispatch(String action) {
        if (PairingInterstitial.isPresenting() || AppOpenAds.isPresenting()) { showFeedback("Close the advertisement, then choose Start audio."); return; }
        if (inFlight != null || pendingAction != null) return;
        if (action.equals("PLAY") && RelayService.state.macSelected() && RelayService.state.phase != RelayState.Phase.PAUSED
                && RelayService.state.phase != RelayState.Phase.COMPUTER_OUTPUT) return;
        if (action.equals("USE_PHONE") && RelayService.state.phase == RelayState.Phase.PHONE) return;
        if ((action.equals("PLAY")) && !settings.paired()) { pair(); return; }
        if (action.equals("USE_PHONE") && RelayService.state.phase == RelayState.Phase.IDLE) return;
        if (action.equals("PLAY") && OutputRoute.BLUETOOTH.accepts(settings.connectionOutput(getSystemService(android.media.AudioManager.class),true)) && Build.VERSION.SDK_INT >= 31 && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
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
    private void changeComputerOutput() {
        if(!RelayService.computerOutputSelected)dispatch("OUTPUT_COMPUTER");
    }
    private void beginAction(String action) {
        requestedFrom=RelayService.state;requestedAt=SystemClock.uptimeMillis();inFlight=action;lastState=null;
        handler.removeCallbacks(hideFeedback);feedback.animate().cancel();feedback.setVisibility(View.GONE);
        render(); mac.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK);
    }
    private void disconnect() {
        automaticAdPin="";trustedNearby=false;renderedKey="";render();
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
        if(request==4){if(grants.length>0&&grants[0]==PackageManager.PERMISSION_GRANTED)outputDialog();else showFeedback("Allow Nearby devices to select Bluetooth headphones.");return;}
        if (request == 3 && (grants.length == 0 || grants[0] != PackageManager.PERMISSION_GRANTED))
            showFeedback("Playback still works. Allow notifications in Settings to keep the audio controls available while idle.");
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
        body.addView(text("Mac video timing is estimated from the actual output. Windows and Linux have no system-wide video compensation. Only the primary listener controls Mac compensation when several phones listen. Corrections apply without disconnecting. Some video players need their video restarted to use the new timing.", 15, MUTED, false));
        space(body, 20);
        TextView value = text(syncLabel(routeKey, wifi), 28, INK, true); value.setGravity(Gravity.CENTER); body.addView(value); space(body, 12);
        LinearLayout buttons = row();
        Button early = button("Sound is early", () -> adjustSync(routeKey, wifi, -10, value));
        Button late = button("Sound is late", () -> adjustSync(routeKey, wifi, 10, value));
        style(early, false); style(late, false);
        buttons.addView(early, new LinearLayout.LayoutParams(0, dp(56), 1)); buttons.addView(late, new LinearLayout.LayoutParams(0, dp(56), 1)); body.addView(buttons);
        boolean supported = !"linux".equals(settings.platform()) && !"windows".equals(settings.platform());
        early.setEnabled(supported && settings.profileEstimate(routeKey) >= 0); late.setEnabled(supported && settings.profileEstimate(routeKey) >= 0);
        space(body, 12); body.addView(text("Automatic timing uses your headphones’ playback timestamps. Each tap adds a saved 10 ms correction. Some video players need a reload. Bluetooth delay still affects games and live audio.", 12, MUTED, false));
        AlertDialog dialog = new GlassDialogBuilder(this).setTitle("Video sync").setView(body).setPositiveButton("Done", null)
                .setNeutralButton("Reset correction", null).create();
        dialog.setOnShowListener(d -> {
            dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setEnabled(supported);
            dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener(v -> {
                settings.profileCorrection(routeKey,0);value.setText(syncLabel(routeKey,wifi));
                value.announceForAccessibility("Correction reset to zero");
            });
        });dialog.show();
    }
    private void adjustSync(String routeKey, boolean wifi, int delta, TextView value) {
        if ("linux".equals(settings.platform()) || "windows".equals(settings.platform())) return;
        int next = Math.max(-500, Math.min(500, settings.profileCorrection(routeKey) + delta));
        settings.profileCorrection(routeKey, next); value.setText(syncLabel(routeKey, wifi));
    }
    private String syncLabel(String routeKey, boolean wifi) {
        int estimate = settings.profileEstimate(routeKey);
        return (estimate < 0 ? "Learning timing" : "Auto " + estimate + " ms") + "\nCorrection " + String.format(java.util.Locale.US, "%+d ms", settings.profileCorrection(routeKey));
    }
    private void connectionDialog() {
        new GlassDialogBuilder(this).setTitle("Connection & pairing")
                .setItems(new String[]{settings.paired()?"Pair another computer":"Pair computer", "Computer address", "Wi-Fi & USB setup", "Forget this computer"}, (dialog, which) -> {
                    if (which == 0) pair();
                    else if (which == 1) editAddress();
                    else if(which==3)forgetMac();
                    else new GlassDialogBuilder(this).setTitle("Local Wi-Fi or USB network")
                            .setMessage("Wi-Fi: keep your computer and phone on the same local network.\n\nUSB on Windows or compatible Linux desktops: connect this Android phone with a data cable, enable USB tethering in Android’s network settings, then enter the computer’s USB-network address shown in the desktop companion.\n\nAndroid USB networking on Mac requires a supported network interface; a cable alone is not enough.\n\nBoth paths use the same encrypted pairing. No USB debugging is needed. A manual address takes priority over discovery until you clear it. The app reports local network because it cannot reliably identify the physical cable path.")
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
    /** Natural height wins. Only spare viewport space is assigned to discovery. */
    private final class FitColumn extends LinearLayout {
        View flexible;
        FitColumn(){super(MainActivity.this);setOrientation(VERTICAL);}
        @Override protected void onMeasure(int width,int height){
            if(flexible!=null)flexible.getLayoutParams().height=LayoutParams.WRAP_CONTENT;
            super.onMeasure(width,MeasureSpec.makeMeasureSpec(0,MeasureSpec.UNSPECIFIED));
            int natural=getMeasuredHeight();
            if(flexible!=null&&MeasureSpec.getMode(height)==MeasureSpec.EXACTLY&&MeasureSpec.getSize(height)>natural){
                flexible.getLayoutParams().height=flexible.getMeasuredHeight()+MeasureSpec.getSize(height)-natural;
                super.onMeasure(width,height);
            }
        }
    }
    private void shortcut(Button button,String label,String icon){
        RelayComponents.shortcut(button,label,icon);
        LinearLayout.LayoutParams params=new LinearLayout.LayoutParams(0,-2,1);params.setMargins(dp(3),0,dp(3),0);shortcuts.addView(button,params);
    }
    private void setShortcut(Button button,String label,String icon){
        button.setText(label);GlassUI.Glyph glyph=new GlassUI.Glyph(icon,INK);glyph.setBounds(0,0,dp(20),dp(20));button.setCompoundDrawables(null,glyph,null,null);button.setCompoundDrawablePadding(dp(5));
    }
    private ScrollView panelScroll(View body){
        ScrollView scroll=new ScrollView(this){@Override protected void onMeasure(int w,int h){int cap=(int)(getResources().getDisplayMetrics().heightPixels*.65f);if(MeasureSpec.getMode(h)!=MeasureSpec.UNSPECIFIED)cap=Math.min(cap,MeasureSpec.getSize(h));super.onMeasure(w,MeasureSpec.makeMeasureSpec(cap,MeasureSpec.AT_MOST));}};
        scroll.setOverScrollMode(View.OVER_SCROLL_IF_CONTENT_SCROLLS);scroll.addView(body);return scroll;
    }
    private void showPanel(AlertDialog dialog){
        if(compactPanel!=null)compactPanel.dismiss();compactPanel=dialog;
        dialog.setOnDismissListener(d->{if(compactPanel==dialog)compactPanel=null;});dialog.show();
        Window window=dialog.getWindow();if(window==null)return;window.setGravity(Gravity.BOTTOM);window.setLayout(-1,-2);
        View decor=window.getDecorView();decor.setTranslationY(dp(24));decor.setAlpha(0);decor.animate().translationY(0).alpha(1).setDuration(GlassUI.duration(this,220)).setInterpolator(new android.view.animation.PathInterpolator(.22f,1,.36f,1)).start();
    }
    private void reportProblem() {
        ProblemReports reports=new ProblemReports(this);final boolean[] checkingQuota={true};LinearLayout body=column();
        body.addView(text("Reports are public on GitHub. Do not include personal information, passwords or pairing codes.",14,MUTED,false));space(body,12);

        EditText description=new EditText(this);description.setHint("What happened? What did you expect? Include steps to reproduce.");description.setTextColor(INK);description.setHintTextColor(MUTED);description.setMinLines(4);description.setGravity(Gravity.TOP);description.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE);description.setFilters(new android.text.InputFilter[]{new android.text.InputFilter.LengthFilter(4000)});description.setText(reports.saved("description"));body.addView(description);
        android.widget.CheckBox details=new android.widget.CheckBox(this);details.setText("Include app version and Android version");details.setTextColor(INK);details.setChecked(true);body.addView(details);
        TextView quotaText=text("",13,MUTED,false);body.addView(quotaText);
        TextView status=text("",13,MUTED,false);status.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);body.addView(status);space(body,10);
        Button submit=button("Submit public report",()->{});style(submit,true);FrameLayout sendFrame=new FrameLayout(this);sendFrame.addView(submit,new FrameLayout.LayoutParams(-1,dp(52)));ActivitySpinner spinner=new ActivitySpinner(this);spinner.setVisibility(View.GONE);FrameLayout.LayoutParams indicator=new FrameLayout.LayoutParams(dp(20),dp(20),Gravity.START|Gravity.CENTER_VERTICAL);indicator.setMarginStart(dp(16));sendFrame.addView(spinner,indicator);body.addView(sendFrame);
        android.text.TextWatcher watcher=new android.text.TextWatcher(){public void beforeTextChanged(CharSequence s,int a,int c,int f){}public void onTextChanged(CharSequence s,int a,int b,int c){reports.save("",description.getText().toString());}public void afterTextChanged(android.text.Editable e){}};description.addTextChangedListener(watcher);
        submit.setOnClickListener(v->{
            String text=description.getText().toString().trim();String title=text.replaceAll("\\s+"," ");if(title.length()>100)title=title.substring(0,100);
            if(checkingQuota[0]||reports.waitSeconds()>0)return;
            if(text.length()<10){status.setText("Describe the problem in at least 10 characters.");return;}
            try {
                final String payload=reports.payload(title,text,details.isChecked());submit.setEnabled(false);submit.setText("Sending…");spinner.setVisibility(View.VISIBLE);description.setEnabled(false);details.setEnabled(false);status.setText("Submitting your public report…");
                new Thread(()->{org.json.JSONObject response;try{response=ProblemReports.send(payload);}catch(Exception error){response=new org.json.JSONObject();}final org.json.JSONObject result=response;
                    runOnUiThread(()->{if(isDestroyed())return;reports.updateQuota(result);spinner.setVisibility(View.GONE);submit.setEnabled(reports.waitSeconds()==0);String url=result.optString("url");if(ProblemReports.validURL(url)){status.setText("Report sent. Thank you for helping improve PairIt.");submit.setEnabled(true);submit.setTag("sent");submit.setText("View issue ↗");submit.setOnClickListener(button->startActivity(new Intent(Intent.ACTION_VIEW,android.net.Uri.parse(url))));reports.completed();}else{status.setText(result.optString("message","Could not confirm submission. Your draft is kept. Retry safely."));submit.setText("Retry submission");description.setEnabled(true);details.setEnabled(true);}});
                },"PairIt-report").start();
            }catch(Exception error){status.setText("Could not prepare this report. Your draft is kept.");}
        });
        final Runnable timer=new Runnable(){public void run(){long seconds=reports.waitSeconds();quotaText.setText(seconds>0?String.format(java.util.Locale.ROOT,"Daily limit reached · Send another report in %02d:%02d:%02d",seconds/3600,(seconds/60)%60,seconds%60):"Up to 5 reports per phone installation in 24 hours.");if(submit.getTag()==null && spinner.getVisibility()!=View.VISIBLE)submit.setEnabled(!checkingQuota[0]&&seconds==0);if(body.isAttachedToWindow())body.postDelayed(this,1000);}};
        body.addOnAttachStateChangeListener(new View.OnAttachStateChangeListener(){public void onViewAttachedToWindow(View v){timer.run();}public void onViewDetachedFromWindow(View v){body.removeCallbacks(timer);}});
        openPanel("Report a problem",body);
        new Thread(()->{try{org.json.JSONObject quota=reports.quota();runOnUiThread(()->{if(!isDestroyed()){checkingQuota[0]=false;reports.updateQuota(quota);body.removeCallbacks(timer);timer.run();}});}catch(Exception ignored){runOnUiThread(()->{checkingQuota[0]=false;body.removeCallbacks(timer);timer.run();});}},"PairIt-report-quota").start();
    }

    private void openPanel(String title,LinearLayout body){
        body.setPadding(dp(20),dp(12),dp(20),dp(16));showPanel(new GlassDialogBuilder(this).setTitle(title).setView(panelScroll(body)).setNegativeButton("Done",null).create());
    }
    private void downloadsPanel(){
        LinearLayout body=column();String[] names={"Mac","Windows","Linux"};String[] platforms={"mac","windows","linux"};
        for(int i=0;i<names.length;i++){final String platform=platforms[i];Button choice=button(names[i]+"  ↗",()->openDownload(platform));style(choice,false);choice.setMinHeight(dp(52));GlassUI.Glyph icon=new GlassUI.Glyph(platform,INK);icon.setBounds(0,0,dp(22),dp(22));choice.setCompoundDrawables(icon,null,null,null);body.addView(choice,new LinearLayout.LayoutParams(-1,-2));space(body,8);}openPanel("Get PC app",body);
    }
    private void moveInto(LinearLayout parent,View child){if(child.getParent() instanceof ViewGroup)((ViewGroup)child.getParent()).removeView(child);parent.addView(child,new LinearLayout.LayoutParams(-1,-2));}
    private void audioPanel(){
        LinearLayout body=column();android.media.AudioManager audio=getSystemService(android.media.AudioManager.class);volume.setProgress(audio.getStreamVolume(android.media.AudioManager.STREAM_MUSIC)*100/Math.max(1,audio.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)));body.addView(text("Phone volume",14,INK,true));moveInto(body,volume);volume.setVisibility(View.VISIBLE);volume.setEnabled(!RelayService.computerOutputSelected);space(body,12);moveInto(body,refreshAudio);refreshAudio.setVisibility(View.VISIBLE);refreshAudio.setMinHeight(dp(48));openPanel("Audio",body);
    }
    private void morePanel(){
        LinearLayout body=column();Button pair=button("Pair another computer",()->{if(compactPanel!=null)compactPanel.dismiss();scanPairingCode("");});style(pair,false);pair.setMinHeight(dp(48));body.addView(pair);space(body,8);Button stop=button("Disconnect",()->{if(compactPanel!=null)compactPanel.dismiss();disconnect();});style(stop,true);stop.setMinHeight(dp(48));body.addView(stop);openPanel("Connection",body);
    }
    private void outputDialog() {
        android.media.AudioManager manager=getSystemService(android.media.AudioManager.class);
        LinearLayout body=column();body.setPadding(dp(20),dp(12),dp(20),dp(12));
        AlertDialog dialog=new GlassDialogBuilder(this).setTitle("Listen through").setView(panelScroll(body)).setNegativeButton("Done",null).create();
        int choices=0;
        for(android.media.AudioDeviceInfo device:manager.getDevices(android.media.AudioManager.GET_DEVICES_OUTPUTS)) {
            OutputRoute kind=null;for(OutputRoute candidate:OutputRoute.values())if(candidate.accepts(device)){kind=candidate;break;}
            if(kind==null)continue;choices++;final OutputRoute selected=kind;
            String name=kind==OutputRoute.SPEAKER?"Phone speaker":device.getProductName().toString();
            Button choice=button(name+"\n"+kind.label,()->{
                if(selected.find(manager,device.getId())==null){dialog.dismiss();showFeedback("That output disconnected. Choose another output.");return;}
                if(selected==OutputRoute.BLUETOOTH&&Build.VERSION.SDK_INT>=31&&checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT)!=PackageManager.PERMISSION_GRANTED){
                    dialog.dismiss();requestPermissions(new String[]{Manifest.permission.BLUETOOTH_CONNECT},4);return;
                }
                boolean live=RelayService.hasControlConnection();
                settings.manuallySelectOutput(selected,device.getId());
                if(live)startService(new Intent(this,RelayService.class).setAction("LOCAL_OUTPUT"));
                lastState=null;renderedKey="";render();dialog.dismiss();
            });style(choice,false);choice.setTextSize(13);choice.setGravity(Gravity.START|Gravity.CENTER_VERTICAL);
            GlassUI.Glyph glyph=new GlassUI.Glyph(kind==OutputRoute.SPEAKER?"phone":"headphones",INK);glyph.setBounds(0,0,dp(22),dp(22));choice.setCompoundDrawables(glyph,null,null,null);choice.setCompoundDrawablePadding(dp(12));
            android.media.AudioDeviceInfo current=settings.output().find(manager,settings.outputDeviceId());
            if(current!=null&&current.getId()==device.getId()) {
                GlassUI.Glyph check=new GlassUI.Glyph("check",INK);check.setBounds(0,0,dp(18),dp(18));choice.setCompoundDrawables(glyph,null,check,null);
                choice.setContentDescription(name+", "+kind.label+", selected");
            } else choice.setContentDescription(name+", "+kind.label);choice.setMinHeight(dp(62));body.addView(choice,new LinearLayout.LayoutParams(-1,-2));
        }
        if(choices==0)body.addView(text("No audio outputs available.",14,MUTED,false));
        showPanel(dialog);
    }
    private void sharedListeningDialog() {
        new GlassDialogBuilder(this).setTitle("Listen together")
                .setMessage("One computer, up to four phones.\n\n1. Connect each listener’s headphones to their own phone.\n2. Keep all phones and the computer on the same Wi-Fi.\n3. In PairIt on the computer, choose Listen together and pair each phone.\n4. Choose Start audio on every phone. Each listener controls their own volume and can pause independently.\n\nTwo headphones on one phone requires that phone’s built-in audio sharing and compatible headphones. PairIt cannot enable it on unsupported hardware. The separate-phone setup is the most compatible.\n\nEveryone hears the same stream, but different headphones can have different delays.")
                .setPositiveButton("Done", null).setNeutralButton("Bluetooth settings", (d,w)->startActivity(new Intent(android.provider.Settings.ACTION_BLUETOOTH_SETTINGS))).show();
    }
    private void backgroundControlsDialog() {
        new GlassDialogBuilder(this).setTitle("Background controls")
                .setMessage("Audio continues with the screen locked. The notification has Pause, Computer output and Disconnect controls. Switching output keeps the devices paired.\n\nHeadphone play/pause controls this phone’s audio. Volume stays with Android. Change tracks on the computer.")
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
                ++pairingFlow;
                if (pairingConfirmation != null) { pairingConfirmation.cancel(); pairingConfirmation = null; }
                pendingPairingCompletion = null;
                stopAudioForSettings();
                handler.postDelayed(()->{
                    trustedNearby=false;confirmedPin="";settings.forget();RelayService.state=new RelayState(RelayState.Phase.IDLE,"Pair computer","Pair a computer to start listening.");
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
            .setMessage("Version "+BuildConfig.VERSION_NAME+(publisher.isEmpty()?"":"\n"+publisher)+"\n\nComputer audio through this phone. Listen together with up to four phones and their headphones.\n\nNo account. No cloud audio server.\nSupported by a banner and dismissible ads on connection or app opening.")
            .setPositiveButton("Done",null).setNeutralButton("Diagnostics",(dialog,which)->diagnosticsDialog()).show();
    }
    private void pair() { pair("", ""); }
    private void pair(String initialCode, String message) {
        if (isFinishing() || isDestroyed()) return;
        if (pairingDialog != null) pairingDialog.dismiss();
        final long flow = ++pairingFlow;
        if (pairingConfirmation != null) { pairingConfirmation.cancel(); pairingConfirmation = null; }
        final long adFlow = pairingAds.begin();
        final boolean[] confirmed = {false};
        EditText input = new EditText(this); input.setHint("Paste pairing code"); input.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        input.setFilters(new android.text.InputFilter[]{new android.text.InputFilter.LengthFilter(4096)});
        input.setSaveEnabled(false); input.setText(initialCode);
        input.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO);input.setImeOptions(android.view.inputmethod.EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING);
        LinearLayout body = dialogBody();
        body.addView(text("Open PairIt on your computer.", 14, MUTED, false)); space(body,8);body.addView(computerDownloadButtons());space(body,16);
        Button scan = button("Scan QR code", () -> scanPairingCode(input.getText().toString())); style(scan, true);
        GlassUI.Glyph scanIcon=new GlassUI.Glyph("qr",Color.WHITE);scanIcon.setBounds(0,0,dp(22),dp(22));scan.setCompoundDrawables(scanIcon,null,null,null);body.addView(scan,new LinearLayout.LayoutParams(-1,dp(52))); space(body,8);
        space(body,8);
        body.addView(text("Or paste code",14,INK,true)); body.addView(input);

        TextView validation = text(message,13,MUTED,false); validation.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE); body.addView(validation);
        ScrollView scroll = new ScrollView(this); scroll.addView(body);
        AlertDialog dialog = new GlassDialogBuilder(this).setTitle(settings.paired() ? "Pair another computer" : "Pair computer")
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
                    pairingResult = "Pairing saved. Confirming with your computer…";
                    pairingConfirmation = new PairingConfirmation(parsed, reached -> {
                        if (flow != pairingFlow || isFinishing() || isDestroyed()) return;
                        pairingConfirmation = null;
                        pairingResult = reached ? "Paired with “" + parsed.name + "”. Your computer confirmed the connection."
                                : "Pairing saved on this phone. Your computer could not confirm it. Keep the companion open on the same network, or update it, then try Start audio.";
                        if (pairingResultDialog != null && pairingResultDialog.isShowing()) pairingResultDialog.setMessage(pairingCompletionMessage());
                        showFeedback(reached ? "Computer confirmed pairing." : "Pairing saved. Computer confirmation unavailable.");
                    });
                    dialog.dismiss(); inFlight = null; pendingAction = null; lastState = null; render();
                    showFeedback("Pairing saved. Confirming with your computer…");
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
                    error = "Scanner unavailable. Paste a code instead.";
                }
                final String resultCode = code, resultError = error;
                if(task.isCanceled()){updateAdVisibility();return;}
                pendingScanResult = () -> {if(resultError.isEmpty()){try{connectVerifiedCode(PairingCode.parse(resultCode),true);}catch(Exception invalid){pair(resultCode,"Invalid pairing code");}}else pair(resultCode,resultError);};
                showScanResult(); updateAdVisibility();
            });
        } catch (RuntimeException error) {
            scanningCode = false; pair(draft, "Couldn’t open the scanner. Paste your pairing code instead."); updateAdVisibility();
        }
    }
    private void startFromButton(){
        RelayState.Phase phase=RelayService.state.phase;
        if(phase==RelayState.Phase.PLAYING || phase==RelayState.Phase.BUFFERING && RelayService.state.title.equals("Waiting for computer audio")){dispatch("MEDIA_PAUSE");return;}
        if(settings.paired()&&(phase==RelayState.Phase.IDLE||phase==RelayState.Phase.ERROR||phase==RelayState.Phase.HEADPHONES))connectVerifiedCode(PairingCode.saved(settings,settings.connectionHost(null)),false);
        else dispatch("PLAY");
    }
    /** Explicit scan/tap intent: authenticate before saving, advertising success, ads or audio. */
    private void connectVerifiedCode(PairingCode code,boolean save){
        if(isFinishing()||isDestroyed()||!visible)return;
        if(RelayService.state.phase==RelayState.Phase.PLAYING&&code.pin.equals(settings.pin())){selectTab(0);return;}
        final long flow=++pairingFlow;explicitIntent.begin(flow);final long adFlow=pairingAds.begin();
        if(pairingConfirmation!=null)pairingConfirmation.cancel();pendingPairingCompletion=null;verifyingConnection=true;renderedKey="";render();
        pairingConfirmation=new PairingConfirmation(code,confirmed->{
            if(flow!=pairingFlow||!explicitIntent.matches(flow)||isFinishing()||isDestroyed())return;
            if(!visible||!hasWindowFocus()){cancelExplicitConnection();return;}
            pairingConfirmation=null;verifyingConnection=false;
            if(!confirmed){explicitIntent.cancel();pairingAds.cancelUnshown(adFlow);renderedKey="";render();if(visible)showFeedback("Couldn’t verify this computer. Keep PairIt open on the same Wi-Fi and try again.");return;}
            automaticAdPin=code.pin;
            if(save){waitingStopFlow=flow;stopAudioForSettings();settings.pair(code);}settings.discovered(code.host,code.pin);trustedNearby=true;confirmedPin=code.pin;tab=0;stopInvitations();nearby.start(false);renderedKey="";render();
            pairingAds.showAfterConnection(adFlow,()->{
                if(flow!=pairingFlow||!explicitIntent.matches(flow)||isFinishing()||isDestroyed())return;
                pendingPairingCompletion=()->startVerifiedAudio(flow,0);showPairingCompletion();
            });
        });
    }
    private void cancelExplicitConnection(){
        cancelNearbyPairing();
        if(!explicitIntent.active())return;
        explicitIntent.cancel();++pairingFlow;verifyingConnection=false;waitingStopFlow=0;pendingPairingCompletion=null;
        if(pairingConfirmation!=null){pairingConfirmation.cancel();pairingConfirmation=null;}
        if(pairingAds!=null)pairingAds.cancelUnshown();renderedKey="";
    }
    private void startVerifiedAudio(long flow,int attempt){
        if(flow!=pairingFlow||!explicitIntent.matches(flow)||!visible||!hasWindowFocus()||isFinishing()||isDestroyed()||PairingInterstitial.isPresenting())return;
        if(waitingStopFlow==flow&&RelayService.state.phase!=RelayState.Phase.IDLE){if(attempt<30)handler.postDelayed(()->startVerifiedAudio(flow,attempt+1),100);else showFeedback("Audio is still stopping. Tap Start audio to retry.");return;}waitingStopFlow=0;
        if(RelayService.state.phase==RelayState.Phase.IDLE||RelayService.state.phase==RelayState.Phase.PAUSED||RelayService.state.phase==RelayState.Phase.COMPUTER_OUTPUT||RelayService.state.phase==RelayState.Phase.PHONE||RelayService.state.phase==RelayState.Phase.ERROR||RelayService.state.phase==RelayState.Phase.HEADPHONES){if(explicitIntent.consume(flow,visible,hasWindowFocus()))dispatch("PLAY");return;}
        if(RelayService.state.phase==RelayState.Phase.PLAYING){explicitIntent.cancel();return;}
        if(attempt<30)handler.postDelayed(()->startVerifiedAudio(flow,attempt+1),100);else showFeedback("Audio is still stopping. Tap Start audio to retry.");
    }
    private void showScanResult() {
        if (!visible || pendingScanResult == null || isFinishing() || isDestroyed()) return;
        Runnable result = pendingScanResult; pendingScanResult = null; result.run();
    }
    private boolean idleForPairingAd() {
        return visible && !isFinishing() && !isDestroyed() && compactPanel==null
                && (invitations==null||!invitations.busy()) && inFlight == null && pendingAction == null
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
                .setMessage(pairingCompletionMessage())
                .setPositiveButton("Start audio", (d, which) -> dispatch("PLAY"))
                .setNegativeButton("Later", null).create();
        pairingDialog = dialog; pairingResultDialog = dialog; updateAdVisibility();
        dialog.setOnDismissListener(d -> { if (pairingDialog == dialog) pairingDialog = null; if (pairingResultDialog == dialog) pairingResultDialog = null; updateAdVisibility(); });
        dialog.show();
    }
    private String pairingCompletionMessage() { return pairingResult + "\n\nChoose Start audio when you’re ready. Nothing is playing yet."; }
    private void diagnosticsDialog() {
        String report = "PairIt " + BuildConfig.VERSION_NAME + " (" + BuildConfig.VERSION_CODE + ")\n" + RelayService.diagnostics + "\n\n" + bannerAds.diagnostics() + "\n" + pairingAds.diagnostics();
        TextView details = text(report, 13, INK, false); details.setTypeface(Typeface.MONOSPACE); details.setTextIsSelectable(true); details.setPadding(dp(20), dp(12), dp(20), dp(12));
        ScrollView scroll = new ScrollView(this); scroll.addView(details);
        new GlassDialogBuilder(this).setTitle("Diagnostics").setView(scroll).setPositiveButton("Done", null)
                .setNeutralButton("Copy", (dialog, which) -> { getSystemService(ClipboardManager.class).setPrimaryClip(ClipData.newPlainText(getString(R.string.app_name)+" diagnostics", report)); if(Build.VERSION.SDK_INT<33)showFeedback("Diagnostics copied"); })
                .setNegativeButton("Refresh audio", (dialog, which) -> { if (RelayService.state.macSelected()) dispatch("RESYNC"); }).show();
    }
    private View settingRow(String label, String detail, Runnable click) {
        LinearLayout line = row(); line.setPadding(0, dp(11), 0, dp(11)); line.setMinimumHeight(dp(44));
        LinearLayout labels = column(); labels.addView(text(label, 13, INK, true)); if(!detail.isEmpty()){space(labels,4);labels.addView(text(detail, 10, MUTED, false));}
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
                boolean blurAvailable = false;
                window.setBackgroundDrawable(GlassUI.dialogSurface(dp(18), blurAvailable));
                window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
                window.setDimAmount(.55f);
            }
            return dialog;
        }
        @Override public AlertDialog show() { AlertDialog dialog = create(); dialog.show(); return dialog; }
    }
    private LinearLayout dialogBody() { LinearLayout body = column(); body.setPadding(dp(24), dp(10), dp(24), dp(8)); return body; }
    private Button button(String text, Runnable action) { return RelayComponents.button(this,text,action); }
    private void segment(Button button,boolean selected,String name){button.setTextSize(12);button.setTextColor(selected?Color.WHITE:0xff666666);button.setBackgroundColor(Color.TRANSPARENT);GlassUI.Glyph icon=new GlassUI.Glyph(name,selected?Color.WHITE:0xff666666);icon.setBounds(0,0,dp(16),dp(16));button.setCompoundDrawables(icon,null,null,null);button.setCompoundDrawablePadding(dp(6));}
    private void style(Button button, boolean selected) { RelayComponents.style(button,selected); }
    private GradientDrawable shape(int color, int radius, int border) { GradientDrawable d = new GradientDrawable(); d.setColor(color); d.setCornerRadius(dp(radius)); if (border != Color.TRANSPARENT) d.setStroke(dp(1), border); return d; }
    private TextView text(String value, float size, int color, boolean bold) { return RelayComponents.text(this,value,size,color,bold); }
    private LinearLayout column() { LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL); return layout; }
    private LinearLayout row() { LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.HORIZONTAL); layout.setGravity(Gravity.CENTER_VERTICAL); return layout; }
    private void space(LinearLayout parent, int height) { parent.addView(new View(this), new LinearLayout.LayoutParams(1, dp(height))); }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    @Override public void onResume() {
        super.onResume(); if (updates != null) updates.checkOnResume(); visible = true; RelayService.restoreControlsNotification(this);
        if(bannerAds!=null)bannerAds.resume();confirmedPin="";trustedNearby=false; if(nearby!=null&&tab!=2){if(tab==1)nearby.invitationPort=invitations.start();nearby.start(tab==1);} renderedKey="";
        handler.removeCallbacks(refresh);handler.post(refresh);
        if(appOpeningOpportunity&&!scanningCode&&!PairingInterstitial.isPresenting()&&!AppOpenAds.isPresenting()){
            appOpeningOpportunity=false;appOpenAds.open();
        }
        pairingAds.prepare();appOpenAds.prepare();
        showScanResult();
        showPairingCompletion();
        RelayService.restoreOutputMonitoring(this);
    }
    @Override public void onPause() { visible = false;stopInvitations();if(appOpenAds!=null)appOpenAds.pause();if(!PairingInterstitial.isPresenting())cancelExplicitConnection(); cancelNearbyPairing(); if(nearby!=null)nearby.stop(); if(automaticConfirmation!=null){automaticConfirmation.cancel();automaticConfirmation=null;} if(pairingAds!=null)pairingAds.cancelUnshown(); if(bannerAds!=null)bannerAds.pause();handler.removeCallbacks(refresh); super.onPause(); }
    @Override public void onStop(){super.onStop();if(!PairingInterstitial.isPresenting()&&!AppOpenAds.isPresenting()&&!scanningCode)appOpeningOpportunity=true;}
    @Override public void onWindowFocusChanged(boolean focused) { super.onWindowFocusChanged(focused); updateAdVisibility(); if(pairingAds!=null)pairingAds.presentationWindowChanged(); if(focused)showPairingCompletion(); }
    private void updateAdVisibility() {
        if (bannerAds != null) bannerAds.setVisibleToUser(visible && !PairingInterstitial.isPresenting() && !AppOpenAds.isPresenting() && !scanningCode && pendingScanResult == null);
    }
    @Override public void onDestroy() { stopInvitations(); if(compactPanel!=null)compactPanel.dismiss(); if(appOpenAds!=null)appOpenAds.destroy();cancelNearbyPairing(); if(nearby!=null)nearby.stop();if(automaticConfirmation!=null)automaticConfirmation.cancel(); if (pairingConfirmation != null) pairingConfirmation.cancel(); if (updates != null) updates.destroy(); pendingScanResult = null; pendingPairingCompletion = null; if (pairingDialog != null) pairingDialog.dismiss(); if(pairingAds!=null)pairingAds.destroy(); if(bannerAds!=null)bannerAds.destroy();handler.removeCallbacksAndMessages(null);super.onDestroy(); }
}
