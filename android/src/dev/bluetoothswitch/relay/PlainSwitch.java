package dev.bluetoothswitch.relay;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.widget.Switch;

/** Native switch semantics with the prototype's neutral, opaque appearance. */
final class PlainSwitch extends Switch {
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final float density;
    private float progress;
    private android.animation.ValueAnimator motion;
    PlainSwitch(Context context) {
        super(context);
        density = getResources().getDisplayMetrics().density;
        setShowText(false);
        setBackground(null);
        setPadding(0, 0, 0, 0);
        setMinWidth((int)(52*density));
        setMinimumHeight((int)(48*density));
    }
    @Override public void setChecked(boolean checked){
        super.setChecked(checked);
        if(motion!=null)motion.cancel();
        float target=checked?1:0;
        if(!isLaidOut()||!android.animation.ValueAnimator.areAnimatorsEnabled()){progress=target;invalidate();return;}
        motion=android.animation.ValueAnimator.ofFloat(progress,target);motion.setDuration(180);
        motion.setInterpolator(new android.view.animation.PathInterpolator(.22f,1,.36f,1));
        motion.addUpdateListener(value->{progress=(float)value.getAnimatedValue();invalidate();});motion.start();
    }
    @Override protected void onDetachedFromWindow(){if(motion!=null)motion.cancel();super.onDetachedFromWindow();}
    @Override protected void onDraw(Canvas canvas) {
        float left = (getWidth()-44*density)/2f;
        float top = (getHeight()-28*density)/2f;
        int shade=Math.round(204+(17-204)*progress);paint.setColor(Color.rgb(shade,shade,shade));
        paint.setAlpha(isEnabled()?255:120);
        canvas.drawRoundRect(left,top,left+44*density,top+28*density,14*density,14*density,paint);
        paint.setColor(Color.WHITE);
        canvas.drawCircle(left+(14+16*progress)*density,top+14*density,11*density,paint);
    }
}
