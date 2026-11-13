package dev.bluetoothswitch.relay;
import android.content.Context;
import android.graphics.*;
import android.view.View;
import android.os.SystemClock;
/** Coherent outward waves; decorative only and stopped when hidden or motion is disabled. */
final class DiscoveryField extends View {
    private final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
    private final double[] breath=new double[3];
    private long started;
    private int layoutWidth,layoutHeight,layoutCenter;
    boolean active=true, listening=false, reduced=false, playing=false;
    float centerY=.62f;
    DiscoveryField(Context c){super(c);setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);}
    @Override protected void onDraw(Canvas canvas){
        if(!active)return;
        float density=getResources().getDisplayMetrics().density;
        float time=SystemClock.uptimeMillis()/1800f;
        boolean animate=!reduced&&android.animation.ValueAnimator.areAnimatorsEnabled();
        if(listening){
            if(!playing)return;
            paint.setColor(Color.WHITE);
            for(int i=0;i<11;i++){float h=(animate?8+12*(float)(.5+.5*Math.sin(time*8+i*.85)):12)*density;float x=getWidth()/2f+(i-5)*7*density;canvas.drawRoundRect(x-1.7f*density,getHeight()*centerY-h,x+1.7f*density,getHeight()*centerY+h,2*density,2*density,paint);}
        }else{
            // Match CSS layout units, delays, angular offsets and per-segment easing.
            float width=getWidth()/density,height=getHeight()/density;
            float cx=width/2f,cy=height*centerY;
            int anchor=Math.round(cy);
            if(layoutWidth!=getWidth()||layoutHeight!=getHeight()||layoutCenter!=anchor){
                layoutWidth=getWidth();layoutHeight=getHeight();layoutCenter=anchor;started=SystemClock.uptimeMillis();
            }
            double elapsed=(SystemClock.uptimeMillis()-started)/1000.0;
            double reach=Math.hypot(Math.max(cx,width-cx),Math.max(cy,height-cy));
            paint.setColor(Color.WHITE);
            for(int ring=1;ring*RadialMotion.RING_GAP<reach+RadialMotion.RING_GAP;ring++){
                double radius=ring*RadialMotion.RING_GAP,size=RadialMotion.size(ring);
                RadialMotion.sample(elapsed,ring,!animate,breath);
                paint.setAlpha((int)Math.round(255*RadialMotion.strength(ring)*breath[0]));
                int count=RadialMotion.count(ring);
                for(int i=0;i<count;i++){
                    double angle=RadialMotion.angle(ring,i),cos=Math.cos(angle),sin=Math.sin(angle);
                    double left=RadialMotion.round(cx+cos*radius,10),top=RadialMotion.round(cy+sin*radius,10);
                    if(left< -4||left>width+4||top< -4||top>height+4)continue;
                    // CSS left/top locate the dot's corner; transforms use its center.
                    float x=(float)(left+size/2+RadialMotion.round(cos*2,100)*breath[2])*density;
                    float y=(float)(top+size/2+RadialMotion.round(sin*2,100)*breath[2])*density;
                    canvas.drawCircle(x,y,(float)(size/2*breath[1])*density,paint);
                }
            }
        }
        if(animate&&isShown())postInvalidateOnAnimation();
    }
}
