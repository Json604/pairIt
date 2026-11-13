package dev.bluetoothswitch.relay;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.os.SystemClock;
import android.view.View;

/** Equalizer owns its layout space, so it cannot overlap the listening caption. */
final class ListeningBars extends View {
    private final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
    private final boolean playing;
    ListeningBars(Context context,boolean playing){super(context);this.playing=playing;setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);paint.setColor(Color.WHITE);}
    @Override protected void onDraw(Canvas canvas){
        if(!playing)return;
        float d=getResources().getDisplayMetrics().density;
        boolean motion=android.animation.ValueAnimator.areAnimatorsEnabled();
        double time=SystemClock.uptimeMillis()/1800.0;
        for(int i=0;i<11;i++){
            float half=(float)(motion?4+8*(.5+.5*Math.sin(time*8+i*.85)):8)*d;
            float x=getWidth()/2f+(i-5)*6*d;
            canvas.drawRoundRect(x-1.5f*d,getHeight()/2f-half,x+1.5f*d,getHeight()/2f+half,2*d,2*d,paint);
        }
        if(motion&&isShown())postInvalidateOnAnimation();
    }
}
