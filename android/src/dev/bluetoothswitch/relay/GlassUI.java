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
    static final int INK = 0xff191919, SECONDARY = 0xff595452, BLUE = 0xffb83b14, ACCENT = 0xffff5a1f, PAPER = 0xfffafaf9, SAND = 0x75ffffff;
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
    @android.annotation.SuppressLint("ClickableViewAccessibility") // Native click/keyboard/TalkBack handling is retained.
    static void pressFeedback(View view) {
        view.setStateListAnimator(null);
        view.setOnTouchListener((control, event) -> {
            int action = event.getActionMasked();
            if (action == MotionEvent.ACTION_DOWN || action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
                boolean down = action == MotionEvent.ACTION_DOWN && control.isEnabled();
                control.animate().cancel();
                if (!ValueAnimator.areAnimatorsEnabled()) { control.setScaleX(1);control.setScaleY(1); }
                else control.animate().scaleX(down ? .97f : 1).scaleY(down ? .97f : 1)
                        .setDuration(down ? 100 : 160).setInterpolator(new PathInterpolator(.23f, 1, .32f, 1)).start();
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
    static GradientDrawable surface(float radius) {
        GradientDrawable d = new GradientDrawable(GradientDrawable.Orientation.TL_BR,
                new int[]{0x95ffffff, 0x66ffffff});
        d.setCornerRadius(radius); d.setStroke(1, 0xddffffff); return d;
    }
    static GradientDrawable dialogSurface(float radius, boolean blurAvailable) {
        GradientDrawable d = new GradientDrawable(GradientDrawable.Orientation.TL_BR,
                new int[]{blurAvailable ? 0xd9ffffff : PAPER, blurAvailable ? 0xe6fff4ed : PAPER});
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
            base = new LinearGradient(0, 0, w, h, new int[]{0xffffffff, 0xfff5f4f2, 0xfff5f3f0}, new float[]{0, .55f, 1}, Shader.TileMode.CLAMP);
            glow = new RadialGradient(w * .98f, h * .93f, Math.max(w, h) * .77f, new int[]{0xa3ff5a1f, 0x33ff5a1f, 0x00ff5a1f}, new float[]{0, .42f, 1}, Shader.TileMode.CLAMP);
            warmth = new RadialGradient(-w * .1f, h * .8f, w * 1.05f, new int[]{0xb8ffc99b, 0x00ffc99b}, null, Shader.TileMode.CLAMP);
        }
        @Override protected void onDraw(Canvas c) {
            float w = getWidth(), h = getHeight();
            paint.setShader(base);
            c.drawRect(0, 0, w, h, paint);
            paint.setShader(warmth); c.drawRect(0, 0, w, h, paint);
            paint.setShader(glow); c.drawRect(0, 0, w, h, paint);
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
            canvas.save();canvas.translate(getBounds().left,getBounds().top);canvas.scale(getBounds().width()/24f,getBounds().height()/24f);
            if (name.equals("mac")) {
                canvas.drawRoundRect(2,3,22,17,2,2,p);canvas.drawLine(12,17,12,21,p);canvas.drawLine(7,21,17,21,p);
            } else if(name.equals("phone")) {
                canvas.drawRoundRect(6,1,18,23,3,3,p);canvas.drawLine(10,4,14,4,p);canvas.drawLine(10,20,14,20,p);
            } else if(name.equals("headphones")) {
                canvas.drawArc(3,2,21,21,180,180,false,p);canvas.drawRoundRect(2.5f,11,7.5f,21,2,2,p);canvas.drawRoundRect(16.5f,11,21.5f,21,2,2,p);
            } else if(name.equals("settings")) {
                for(int i=0;i<3;i++){float y=5+i*7;canvas.drawLine(3,y,21,y,p);}
                p.setStyle(Paint.Style.FILL);p.setColor(PAPER);canvas.drawCircle(8,5,2.6f,p);canvas.drawCircle(16,12,2.6f,p);canvas.drawCircle(10,19,2.6f,p);
                p.setStyle(Paint.Style.STROKE);p.setColor(INK);canvas.drawCircle(8,5,2.6f,p);canvas.drawCircle(16,12,2.6f,p);canvas.drawCircle(10,19,2.6f,p);
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
