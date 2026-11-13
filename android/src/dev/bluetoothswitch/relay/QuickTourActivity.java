package dev.bluetoothswitch.relay;

import android.app.*;
import android.os.*;
import android.graphics.*;
import android.graphics.drawable.*;
import android.view.*;
import android.widget.*;

/** Real presentation components with independent sample state and no transport/audio actions. */
public final class QuickTourActivity extends Activity {
    private final TourPlayback clock=new TourPlayback();
    private final Handler handler=new Handler(Looper.getMainLooper());
    private long lastTick;
    private boolean foreground,connected,computer,paused,disconnected;
    private DiscoveryField field;
    private LinearLayout deck;
    private FrameLayout visual;
    private Button play;
    private final Pill[] pills=new Pill[4];
    private AlertDialog panel;
    private final Runnable tick=new Runnable(){public void run(){
        long now=SystemClock.uptimeMillis();boolean changed=clock.tick(now-lastTick,foreground);lastTick=now;
        if(changed)render();else updateProgress();
        if(foreground)handler.postDelayed(this,32);
    }};
    static boolean completed(android.content.Context c){return c.getSharedPreferences("quickTour",MODE_PRIVATE).getBoolean("completed-v1",false);}
    @Override public void onCreate(Bundle saved){
        super.onCreate(saved);getWindow().getDecorView().setSystemUiVisibility(0);getWindow().setStatusBarColor(Color.BLACK);getWindow().setNavigationBarColor(Color.BLACK);
        if(saved!=null){clock.step=saved.getInt("step");clock.elapsed=saved.getLong("elapsed");clock.playing=saved.getBoolean("playing");connected=saved.getBoolean("connected");computer=saved.getBoolean("computer");paused=saved.getBoolean("paused");disconnected=saved.getBoolean("disconnected");}
        android.view.accessibility.AccessibilityManager accessibility=getSystemService(android.view.accessibility.AccessibilityManager.class);
        if(!android.animation.ValueAnimator.areAnimatorsEnabled()||accessibility.isTouchExplorationEnabled())clock.playing=false;
        if(Build.VERSION.SDK_INT>=33)getOnBackInvokedDispatcher().registerOnBackInvokedCallback(android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT,this::finishTour);
        render();
    }
    @Override public void onSaveInstanceState(Bundle state){super.onSaveInstanceState(state);state.putInt("step",clock.step);state.putLong("elapsed",clock.elapsed);state.putBoolean("playing",clock.playing);state.putBoolean("connected",connected);state.putBoolean("computer",computer);state.putBoolean("paused",paused);state.putBoolean("disconnected",disconnected);}
    @Override protected void onResume(){super.onResume();foreground=true;lastTick=SystemClock.uptimeMillis();handler.post(tick);}
    @Override protected void onPause(){foreground=false;handler.removeCallbacks(tick);super.onPause();}
    @Override protected void onDestroy(){handler.removeCallbacksAndMessages(null);if(panel!=null)panel.dismiss();super.onDestroy();}
    // API 33+ uses the registered dispatcher; this handles older Android versions.
    @android.annotation.SuppressLint("GestureBackNavigation")
    @Override public void onBackPressed(){finishTour();}
    private void finishTour(){getSharedPreferences("quickTour",MODE_PRIVATE).edit().putBoolean("completed-v1",true).apply();finish();}
    private int dp(int n){return RelayComponents.dp(this,n);}
    private TextView text(String s,int size,int color,boolean bold){return RelayComponents.text(this,s,size,color,bold);}
    private LinearLayout column(){LinearLayout v=new LinearLayout(this);v.setOrientation(LinearLayout.VERTICAL);return v;}
    private LinearLayout row(){LinearLayout v=new LinearLayout(this);v.setGravity(Gravity.CENTER_VERTICAL);return v;}
    private GradientDrawable shape(int color,int radius){GradientDrawable g=new GradientDrawable();g.setColor(color);g.setCornerRadius(dp(radius));return g;}
    private void gap(LinearLayout v,int size){v.addView(new View(this),new LinearLayout.LayoutParams(1,dp(size)));}
    private Button button(String s,Runnable action){Button b=RelayComponents.button(this,s,()->{clock.playing=false;updateProgress();action.run();});RelayComponents.style(b,true);b.setMinHeight(dp(48));return b;}
    private void select(int step){int before=clock.step;clock.select(step);connected=false;computer=false;paused=false;disconnected=false;render();if(before!=clock.step){visual.setAlpha(.6f);visual.animate().alpha(1).setDuration(GlassUI.duration(this,180)).start();}}
    private void render(){
        SwipeSurface root=new SwipeSurface();root.setBackgroundColor(Color.BLACK);root.addView(new GlassUI.Backdrop(this),new FrameLayout.LayoutParams(-1,-1));
        field=new DiscoveryField(this);field.active=clock.step==0&&!connected||clock.step==3;root.addView(field,new FrameLayout.LayoutParams(-1,-1));
        ScrollView scroll=new ScrollView(this);scroll.setFillViewport(true);Deck layout=new Deck();deck=layout;deck.setPadding(dp(16),dp(17),dp(16),dp(12));scroll.addView(deck);root.addView(scroll,new FrameLayout.LayoutParams(-1,-1));setContentView(root);
        root.setOnApplyWindowInsetsListener((v,insets)->{if(Build.VERSION.SDK_INT>=30){Insets b=insets.getInsets(WindowInsets.Type.systemBars());scroll.setPadding(b.left,b.top,b.right,b.bottom);}return insets;});
        LinearLayout brand=row();ImageView mark=new ImageView(this);mark.setImageDrawable(new GlassUI.Glyph("headphones",Color.WHITE));brand.addView(mark,new LinearLayout.LayoutParams(dp(27),dp(27)));TextView name=text("PairIt",21,Color.WHITE,true);LinearLayout.LayoutParams n=new LinearLayout.LayoutParams(0,-2,1);n.setMarginStart(dp(9));brand.addView(name,n);TextView tag=text("DEMO",10,0xffbbbbbb,false);tag.setPadding(dp(8),dp(5),dp(8),dp(5));tag.setBackground(shape(0x16ffffff,20));brand.addView(tag);deck.addView(brand);gap(deck,17);
        LinearLayout meta=row();meta.addView(text((clock.step+1)+" of 4",13,0xffcccccc,false),new LinearLayout.LayoutParams(0,-2,1));Button skip=button("Skip tour",this::finishTour);skip.setTextSize(12);skip.setTextColor(0xffcccccc);skip.setBackgroundColor(Color.TRANSPARENT);meta.addView(skip);deck.addView(meta);gap(deck,12);
        String[] titles={"Connect your computer","Choose where to listen","Control without opening PairIt","One computer. Listen together."};
        String[] notes={"Tap a nearby computer. If it isn’t listed, use Scan QR.","Switch output without disconnecting. Audio has volume and Refresh audio.","Swipe down for Pause, Computer and Disconnect. After a call, tap Resume.","Share movies, music and more from one computer with up to four phones. Everyone uses their own headphones."};
        deck.addView(text(titles[clock.step],29,Color.WHITE,true));gap(deck,17);deck.addView(text(notes[clock.step],14,0xffcccccc,false));gap(deck,17);
        visual=new FrameLayout(this);visual.setMinimumHeight(dp(300));layout.flexible=visual;deck.addView(visual,new LinearLayout.LayoutParams(-1,-2));
        LinearLayout sample=column();sample.setGravity(Gravity.CENTER);FrameLayout.LayoutParams content=new FrameLayout.LayoutParams(-1,-2,Gravity.CENTER);visual.addView(sample,content);
        if(clock.step==0&&connected)output(sample);
        else if(clock.step==0||clock.step==3)discovery(sample,clock.step==3);
        else if(clock.step==1)output(sample);
        else notification(sample);
        gap(deck,17);LinearLayout transport=row();transport.setGravity(Gravity.CENTER);
        for(int i=0;i<4;i++){final int index=i;Button dot=button("",()->select(index));dot.setContentDescription("Step "+(i+1)+": "+titles[i]);dot.setMinHeight(0);dot.setMinimumHeight(0);pills[i]=new Pill(i);dot.setBackground(pills[i]);transport.addView(dot,new LinearLayout.LayoutParams(dp(44),dp(44)));}
        View spacer=new View(this);transport.addView(spacer,new LinearLayout.LayoutParams(0,1,1));play=RelayComponents.button(this,"",()->{clock.playing=!clock.playing;if(clock.elapsed==TourPlayback.STEP_MS)clock.elapsed=0;lastTick=SystemClock.uptimeMillis();updateProgress();});play.setBackground(shape(0x22ffffff,22));transport.addView(play,new LinearLayout.LayoutParams(dp(44),dp(44)));deck.addView(transport);
        if(clock.step==3){gap(deck,12);deck.addView(button("Start using PairIt",this::finishTour));}
        else {gap(deck,10);TextView hint=text("Swipe to explore · Tap a dot to jump",11,0xffcccccc,false);hint.setGravity(Gravity.CENTER);deck.addView(hint);}
        updateProgress();
    }
    private void discovery(LinearLayout sample,boolean together){
        if(together){
            java.util.List<android.view.View> phones=new java.util.ArrayList<>();
            String[] names={"Alex’s phone","Sam’s phone","Maya’s phone"};
            String[] platforms={"Android","iPhone","Android"};
            for(int i=0;i<names.length;i++){
                LinearLayout node=RelayComponents.nearby(this,names[i],platforms[i],true,()->explain("Share PairIt","Share the app, then scan the same computer’s code. This demo sends nothing."));
                phones.add(node);
            }
            sample.addView(RelayComponents.phoneOrbit(this,phones),new LinearLayout.LayoutParams(-1,-2));
        }else sample.addView(RelayComponents.nearby(this,"MacBook Pro",connected?"Connected":"Paired",false,()->{clock.playing=false;connected=true;render();}));
        gap(sample,24);
        ImageView own=RelayComponents.ownPhone(this);sample.addView(own,new LinearLayout.LayoutParams(dp(48),dp(48)));gap(sample,5);TextView ownLabel=text("You",11,0xffdddddd,false);ownLabel.setGravity(Gravity.CENTER);sample.addView(ownLabel);gap(sample,16);
        own.post(()->{int[] a=new int[2],b=new int[2];own.getLocationOnScreen(a);field.getLocationOnScreen(b);field.centerY=(a[1]-b[1]+own.getHeight()/2f)/Math.max(1,field.getHeight());field.invalidate();});
        LinearLayout card=card();card.addView(text(together?"Invite to listen together":connected?"Connected":"Ready to connect",16,GlassUI.INK,true));gap(card,10);
        card.addView(button(together?"Share app":connected?"Pause audio":"Connect",()->{if(together)explain("Share PairIt","Share the app, then scan the same computer’s code.");else{connected=!connected;render();}}));
        if(!together){gap(card,10);LinearLayout shortcuts=row();tile(shortcuts,"Output","headphones",()->explain("Output","Choose headphones or your phone’s speaker."));tile(shortcuts,"Scan QR","qr",()->explain("Scan QR","Scan the pairing code shown on your computer."));tile(shortcuts,"Get PC app","laptop",()->explain("Get PC app","Downloads for Mac, Windows and Linux."));card.addView(shortcuts);}sample.addView(card);
    }
    private LinearLayout card(){LinearLayout c=column();c.setPadding(dp(18),dp(17),dp(18),dp(17));c.setBackground(shape(0xfff6f6f8,28));return c;}
    private void output(LinearLayout sample){
        ImageView symbol=new ImageView(this);sample.addView(symbol,new LinearLayout.LayoutParams(dp(64),dp(64)));gap(sample,24);
        ListeningBars bars=new ListeningBars(this,!computer&&!paused);sample.addView(bars,new LinearLayout.LayoutParams(-1,dp(28)));gap(sample,16);
        TextView status=text("",13,Color.WHITE,false);status.setGravity(Gravity.CENTER);sample.addView(status);gap(sample,24);
        LinearLayout card=card();card.addView(text("Audio output",16,GlassUI.INK,true));gap(card,12);
        final Runnable[] sync=new Runnable[1];
        RelayOutputSelector segment=new RelayOutputSelector(this,()->{clock.playing=false;computer=false;sync[0].run();},()->{clock.playing=false;computer=true;sync[0].run();});card.addView(segment);gap(card,8);
        Button primary=button("Pause audio",()->{paused=!paused;sync[0].run();});card.addView(primary);gap(card,12);
        LinearLayout shortcuts=row();tile(shortcuts,"Output","headphones",()->explain("Output","Choose headphones, a wired device or the phone speaker."));tile(shortcuts,"Audio","settings",()->explain("Audio","Change volume or refresh the audio buffer."));tile(shortcuts,"More","more",()->explain("More","Pair another computer or disconnect."));card.addView(shortcuts);sample.addView(card);
        sync[0]=()->{segment.select(computer,true);symbol.setImageDrawable(new GlassUI.Glyph(computer?"mac":"headphones",Color.WHITE));bars.setPlaying(!computer&&!paused);status.setText(computer?"Playing on computer":paused?"Paused":"Listening on this phone");primary.setText(paused?"Start audio":"Pause audio");primary.setVisibility(computer?View.INVISIBLE:View.VISIBLE);updateProgress();};sync[0].run();
    }
    private void tile(LinearLayout row,String name,String icon,Runnable action){Button b=button(name,action);RelayComponents.shortcut(b,name,icon);LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(0,-2,1);lp.setMargins(dp(3),0,dp(3),0);row.addView(b,lp);}
    private void notification(LinearLayout sample){
        if(disconnected){sample.addView(text("Disconnected",18,Color.WHITE,true));sample.addView(button("Try again",()->{disconnected=false;computer=false;paused=false;render();}));return;}
        Notification n=PlaybackNotification.build(this,"MacBook Pro",computer?"Playing on computer":paused?"Audio paused":"Playing on phone",computer||paused,computer,null,null,null,null);
        Notification.Builder builder=Notification.Builder.recoverBuilder(this,n);RemoteViews template=builder.createBigContentView();if(template==null)template=builder.createContentView();View view=template.apply(this,sample);boolean dark=(getResources().getConfiguration().uiMode & android.content.res.Configuration.UI_MODE_NIGHT_MASK)==android.content.res.Configuration.UI_MODE_NIGHT_YES;view.setBackground(shape(dark?0xff303136:0xfff6f6f8,25));sample.addView(view);wire(view);
    }
    private void wire(View v){if(v instanceof TextView){String label=((TextView)v).getText().toString();v.setEnabled(true);if(label.equalsIgnoreCase("Pause")||label.equalsIgnoreCase("Resume")||label.equalsIgnoreCase("Listen here"))v.setOnClickListener(w->{clock.playing=false;if(computer){computer=false;paused=false;}else paused=!paused;render();});else if(label.equalsIgnoreCase("Computer"))v.setOnClickListener(w->{clock.playing=false;computer=true;render();});else if(label.equalsIgnoreCase("Disconnect"))v.setOnClickListener(w->{clock.playing=false;disconnected=true;render();});}if(v instanceof ViewGroup){ViewGroup g=(ViewGroup)v;for(int i=0;i<g.getChildCount();i++)wire(g.getChildAt(i));}}
    private void explain(String title,String message){clock.playing=false;updateProgress();panel=new AlertDialog.Builder(this).setTitle(title).setMessage(message).setPositiveButton("Done",null).show();panel.getButton(-1).setTextColor(Color.BLACK);}
    private void updateProgress(){for(Pill p:pills)if(p!=null)p.invalidateSelf();if(play!=null){play.setText(clock.playing?"Ⅱ":"▶");play.setTextColor(Color.WHITE);play.setContentDescription(clock.playing?"Pause tutorial":"Play tutorial");}}
    private final class Pill extends Drawable {final int index;final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);Pill(int n){index=n;}public void draw(Canvas c){Rect b=getBounds();float w=dp(index==clock.step?32:7),h=dp(7),x=b.exactCenterX()-w/2,y=b.exactCenterY()-h/2;paint.setColor(0x66ffffff);c.drawRoundRect(x,y,x+w,y+h,h/2,h/2,paint);if(index==clock.step){paint.setColor(Color.WHITE);c.save();c.clipRect(x,y,x+w*clock.progress(),y+h);c.drawRoundRect(x,y,x+w,y+h,h/2,h/2,paint);c.restore();}}public void setAlpha(int a){}public void setColorFilter(ColorFilter f){}public int getOpacity(){return PixelFormat.TRANSLUCENT;}}
    private final class Deck extends LinearLayout {View flexible;Deck(){super(QuickTourActivity.this);setOrientation(VERTICAL);}protected void onMeasure(int w,int h){if(flexible!=null)flexible.getLayoutParams().height=-2;super.onMeasure(w,MeasureSpec.makeMeasureSpec(0,MeasureSpec.UNSPECIFIED));int natural=getMeasuredHeight();if(flexible!=null&&MeasureSpec.getMode(h)==MeasureSpec.EXACTLY&&MeasureSpec.getSize(h)>natural){flexible.getLayoutParams().height=flexible.getMeasuredHeight()+MeasureSpec.getSize(h)-natural;super.onMeasure(w,h);}}}
    private final class SwipeSurface extends FrameLayout {
        float x,y;boolean dragging;VelocityTracker velocity;
        SwipeSurface(){super(QuickTourActivity.this);}
        public boolean onInterceptTouchEvent(android.view.MotionEvent e){if(e.getActionMasked()==0){x=e.getX();y=e.getY();dragging=false;velocity=VelocityTracker.obtain();velocity.addMovement(e);}else if(e.getActionMasked()==2&&Math.abs(e.getX()-x)>dp(12)&&Math.abs(e.getX()-x)>Math.abs(e.getY()-y)*1.4f){dragging=true;clock.playing=false;updateProgress();return true;}else if(e.getActionMasked()==1||e.getActionMasked()==3){if(velocity!=null){velocity.recycle();velocity=null;}}return false;}
        public boolean onTouchEvent(android.view.MotionEvent e){if(!dragging)return super.onTouchEvent(e);if(velocity!=null)velocity.addMovement(e);float dx=e.getX()-x;if(e.getActionMasked()==2){float resistance=(clock.step==0&&dx>0||clock.step==3&&dx<0)?.2f:1;visual.setTranslationX(dx*resistance);return true;}if(e.getActionMasked()==1||e.getActionMasked()==3){if(velocity!=null)velocity.computeCurrentVelocity(1000);float speed=velocity==null?0:velocity.getXVelocity();if(e.getActionMasked()==1&&(Math.abs(dx)>getWidth()*.2f||Math.abs(speed)>700))select(clock.step+(dx<0?1:-1));else visual.animate().translationX(0).setDuration(180).start();if(velocity!=null){velocity.recycle();velocity=null;}dragging=false;return true;}return true;}
    }
}
