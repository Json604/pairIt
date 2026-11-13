package dev.bluetoothswitch.relay;

import android.content.Context;
import android.graphics.*;
import android.graphics.drawable.*;
import android.os.Build;
import android.view.View;
import android.animation.ValueAnimator;
import android.view.MotionEvent;
import android.view.animation.PathInterpolator;

/** Static visual layers. No timers, networking, or work on the playback thread. */
final class GlassUI {
    static final int INK = 0xff191919, SECONDARY = 0xff616161, BLUE = 0xff191919, ACCENT = 0xff191919, PAPER = 0xfffafafa, SAND = 0x75ffffff;
    private static Typeface heading;
    static Typeface heading(Context context) {
        if (heading == null) heading = Typeface.createFromAsset(context.getAssets(), "fonts/ChakraPetch-Regular.ttf");
        return heading;
    }
    static final class ContentColumn extends android.widget.LinearLayout {
        ContentColumn(Context context) { super(context);setOrientation(VERTICAL); }
        @Override protected void onMeasure(int width, int height) {
            int limit=Math.round(600*getResources().getDisplayMetrics().density);
            super.onMeasure(MeasureSpec.makeMeasureSpec(Math.min(MeasureSpec.getSize(width),limit),MeasureSpec.getMode(width)),height);
        }
    }
    static int duration(Context context, int milliseconds) {
        if (!ValueAnimator.areAnimatorsEnabled()) return 0;
        float scale = android.provider.Settings.Global.getFloat(context.getContentResolver(), android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1);
        return Math.round(milliseconds * scale);
    }
    /** Critically damped spring, normalized and bounded: controls never cross their box. */
    static final class SettlingSpring implements android.view.animation.Interpolator {
        public float getInterpolation(float input){double t=Math.max(0,Math.min(1,input));return t==1?1:(float)Math.max(0,Math.min(1,1-Math.exp(-7.5*t)*(Math.cos(10*t)+.75*Math.sin(10*t))));}
    }
    @android.annotation.SuppressLint("ClickableViewAccessibility") // Native click/keyboard/TalkBack handling is retained.
    static void pressFeedback(View view) {
        view.setStateListAnimator(null);
        view.setOnTouchListener((control, event) -> {
            int action = event.getActionMasked();
            if (action == MotionEvent.ACTION_DOWN || action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
                boolean down = action == MotionEvent.ACTION_DOWN && control.isEnabled();
                control.animate().cancel();
                if (!ValueAnimator.areAnimatorsEnabled() || new RelaySettings(control.getContext()).reducedMotion()) { control.setScaleX(1);control.setScaleY(1); }
                else control.animate().scaleX(down ? .95f : 1).scaleY(down ? .95f : 1)
                        .setDuration(down ? 220 : 550).setInterpolator(new SettlingSpring()).start();
            }
            // Never consume the event: scrolling cancels naturally, and native ripple/click stays intact.
            return false;
        });
        view.addOnAttachStateChangeListener(new View.OnAttachStateChangeListener() {
            @Override public void onViewAttachedToWindow(View control) { }
            @Override public void onViewDetachedFromWindow(View control) {
                control.animate().cancel();control.setScaleX(1);control.setScaleY(1);
            }
        });
    }
    /** Option 1 from circle-options.html: 68dp disc, two 2.3s outward rings. */
    static final class NearbyCircle extends Drawable {
        private final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
        private final PathInterpolator ease=new PathInterpolator(.22f,.61f,.36f,1);
        @Override public void draw(Canvas canvas) {
            Rect b=getBounds();float unit=Math.min(b.width(),b.height())/100f;
            boolean moving=ValueAnimator.areAnimatorsEnabled();
            paint.setStyle(Paint.Style.FILL);paint.setColor(0xffeeeeee);
            canvas.drawCircle(b.exactCenterX(),b.exactCenterY(),34*unit,paint);
            paint.setStyle(Paint.Style.STROKE);
            for(int ring=0;ring<(moving?2:1);ring++) {
                float phase=(android.os.SystemClock.uptimeMillis()%2300)/2300f+ring*.5f;phase%=1;
                float scale=moving?.9f+.33f*ease.getInterpolation(phase):1;
                float opacity=moving?(phase<.15f?.65f*ease.getInterpolation(phase/.15f):.65f*(1-ease.getInterpolation((phase-.15f)/.85f))):.65f;
                paint.setStrokeWidth(1.5f*unit*scale);
                paint.setColor(Color.argb(Math.round(opacity*255),177,215,255));
                canvas.drawCircle(b.exactCenterX(),b.exactCenterY(),40.25f*unit*scale,paint);
            }
            if(moving&&isVisible())scheduleSelf(tick,android.os.SystemClock.uptimeMillis()+16);
        }
        private final Runnable tick=this::invalidateSelf;
        @Override public boolean setVisible(boolean visible,boolean restart){if(!visible)unscheduleSelf(tick);return super.setVisible(visible,restart);}
        @Override public void setAlpha(int alpha) { }
        @Override public void setColorFilter(ColorFilter filter) { }
        @Override public int getOpacity(){return PixelFormat.TRANSLUCENT;}
    }
    static GradientDrawable surface(float radius) {
        GradientDrawable d = new GradientDrawable(GradientDrawable.Orientation.TL_BR,
                new int[]{0xfff6f6f8, 0xfff6f6f8});
        d.setCornerRadius(radius); d.setStroke(1, 0xddffffff); return d;
    }
    static GradientDrawable dialogSurface(float radius, boolean blurAvailable) {
        GradientDrawable d = new GradientDrawable(GradientDrawable.Orientation.TL_BR,
                new int[]{blurAvailable ? 0xd9ffffff : PAPER, PAPER});
        d.setCornerRadius(radius); d.setStroke(1, 0xeeffffff); return d;
    }
    static GradientDrawable accent(float radius) {
        GradientDrawable d = new GradientDrawable(GradientDrawable.Orientation.TL_BR,
                new int[]{INK, INK});
        d.setCornerRadius(radius); d.setStroke(1, 0x60ffffff); return d;
    }
    static final class Backdrop extends View {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private Shader base, glow, warmth;
        Backdrop(Context context) {
            super(context); setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
            // Gradients already have soft edges; an extra full-screen blur is unnecessary.
        }
        @Override protected void onSizeChanged(int w, int h, int oldw, int oldh) {
            if (w == 0 || h == 0) return;
            base = new LinearGradient(0,0,0,h,new int[]{Color.BLACK,Color.BLACK,Color.BLACK},new float[]{0,.48f,1},Shader.TileMode.CLAMP);
            RadialGradient blue=new RadialGradient(0,0,1,new int[]{0xff278ff1,0xff145ac4,0x00145ac4},new float[]{0,.28f,.73f},Shader.TileMode.CLAMP);Matrix blueMatrix=new Matrix();blueMatrix.setScale(w*1.1f,h*.68f);blueMatrix.postTranslate(w*.05f,h*.94f);blue.setLocalMatrix(blueMatrix);warmth=blue;
            RadialGradient navy=new RadialGradient(0,0,1,new int[]{0xff071b64,0x00071b64},new float[]{0,.75f},Shader.TileMode.CLAMP);Matrix navyMatrix=new Matrix();navyMatrix.setScale(w,h*.65f);navyMatrix.postTranslate(w*.9f,h*.75f);navy.setLocalMatrix(navyMatrix);glow=navy;
        }
        @Override protected void onDraw(Canvas c) {
            float w = getWidth(), h = getHeight();
            paint.setShader(base);
            c.drawRect(0, 0, w, h, paint);
            paint.setShader(glow); c.drawRect(0, 0, w, h, paint);
            paint.setShader(warmth); c.drawRect(0, 0, w, h, paint);
            paint.setShader(null);
        }
    }
    /** Decorative brand mark, never a fabricated live level meter. */
    static final class Emblem extends View {
        private final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final float[] bars = {.16f,.29f,.48f,.30f,.60f,.40f,.22f,.34f,.14f};
        Emblem(Context context) { super(context); setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO); }
        @Override protected void onDraw(Canvas c) {
            float size = Math.min(getWidth(), getHeight()) * .76f, x = getWidth()/2f, y = getHeight()/2f;
            p.setColor(0x20ff4f1f);c.drawCircle(x,y,size*.61f,p);
            p.setColor(ACCENT);c.drawCircle(x,y,size*.5f,p);
            p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(1);p.setColor(0x90ffffff);c.drawCircle(x,y,size*.46f,p);p.setStyle(Paint.Style.FILL);
            p.setColor(Color.WHITE);
            for(int i=0;i<bars.length;i++) {
                float bx=x+(i-4)*size*.08f, half=size*bars[i]*.5f, width=size*.035f;
                c.drawRoundRect(bx-width*.5f,y-half,bx+width*.5f,y+half,width,width,p);
            }
        }
    }
    static final class Glyph extends Drawable {
        private final String name;
        private final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        Glyph(String name, int color) { this.name=name;p.setColor(color);p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(1.65f);p.setStrokeCap(Paint.Cap.ROUND);p.setStrokeJoin(Paint.Join.ROUND); }
        @Override public void draw(Canvas canvas) {
            int original=p.getColor();canvas.save();canvas.translate(getBounds().left,getBounds().top);canvas.scale(getBounds().width()/24f,getBounds().height()/24f);
            if(name.equals("qr")){
                canvas.drawRoundRect(3,3,9,9,1,1,p);canvas.drawRoundRect(15,3,21,9,1,1,p);canvas.drawRoundRect(3,15,9,21,1,1,p);canvas.drawLine(15,15,18,15,p);canvas.drawLine(18,15,18,18,p);canvas.drawLine(21,18,21,21,p);canvas.drawLine(15,21,18,21,p);
            }else if(name.equals("windows")){
                canvas.drawRect(3,3,10,10,p);canvas.drawRect(14,3,21,10,p);canvas.drawRect(3,14,10,21,p);canvas.drawRect(14,14,21,21,p);
            }else if(name.equals("linux")){
                canvas.drawOval(6,3,18,21,p);canvas.drawOval(8,10,16,20,p);canvas.drawCircle(10,7,.6f,p);canvas.drawCircle(14,7,.6f,p);canvas.drawLine(10,10,14,10,p);canvas.drawLine(3,21,8,21,p);canvas.drawLine(16,21,21,21,p);
            }else if(name.equals("laptop")){
                canvas.drawRoundRect(4,3,20,16,1.5f,1.5f,p);canvas.drawLine(4,16,2,21,p);canvas.drawLine(2,21,22,21,p);canvas.drawLine(22,21,20,16,p);canvas.drawLine(9,18.5f,15,18.5f,p);
            }else if (name.equals("mac")) {
                canvas.drawRoundRect(2,3,22,17,2,2,p);canvas.drawLine(12,17,12,21,p);canvas.drawLine(7,21,17,21,p);
            } else if(name.equals("phone")) {
                canvas.drawRoundRect(6,1,18,23,3,3,p);canvas.drawLine(10,4,14,4,p);canvas.drawLine(10,20,14,20,p);
            } else if(name.equals("headphones")) {
                canvas.drawArc(3,2,21,21,180,180,false,p);canvas.drawRoundRect(2.5f,11,7.5f,21,2,2,p);canvas.drawRoundRect(16.5f,11,21.5f,21,2,2,p);
            } else if(name.equals("people")) {
                canvas.drawCircle(9,7,4,p);canvas.drawArc(2,13,16,29,180,180,false,p);canvas.drawArc(14,3,22,11,-90,180,false,p);canvas.drawArc(13,13,24,29,-90,90,false,p);
            } else if(name.equals("settings")) {
                for(int i=0;i<3;i++){float y=5+i*7;canvas.drawLine(3,y,21,y,p);}
                p.setStyle(Paint.Style.FILL);p.setColor(PAPER);canvas.drawCircle(8,5,2.6f,p);canvas.drawCircle(16,12,2.6f,p);canvas.drawCircle(10,19,2.6f,p);
                p.setStyle(Paint.Style.STROKE);p.setColor(original);canvas.drawCircle(8,5,2.6f,p);canvas.drawCircle(16,12,2.6f,p);canvas.drawCircle(10,19,2.6f,p);
            } else if(name.equals("more")) {
                p.setStyle(Paint.Style.FILL);for(int i=0;i<3;i++)canvas.drawCircle(5+i*7,12,1.6f,p);p.setStyle(Paint.Style.STROKE);
            } else if(name.equals("lock")) {
                canvas.drawRoundRect(5,10,19,22,3,3,p);canvas.drawArc(8,2,16,16,180,180,false,p);canvas.drawLine(12,15,12,18,p);
            } else {
                canvas.drawArc(2,3,20,21,-60,120,false,p);canvas.drawArc(1,7,12,17,-60,120,false,p);
                p.setStyle(Paint.Style.FILL);canvas.drawCircle(4,12,1.5f,p);p.setStyle(Paint.Style.STROKE);
            }
            canvas.restore();
        }
        @Override public void setAlpha(int alpha){p.setAlpha(alpha);}
        @Override public void setColorFilter(ColorFilter filter){p.setColorFilter(filter);}
        @Override public int getOpacity(){return PixelFormat.TRANSLUCENT;}
    }
}
