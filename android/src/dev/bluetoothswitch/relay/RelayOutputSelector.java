package dev.bluetoothswitch.relay;
import android.content.Context;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.view.*;
import android.widget.*;

/** The same bounded output highlight in the live app and the tutorial. */
final class RelayOutputSelector extends FrameLayout {
    final Button phone,computer;
    private final View indicator;
    private boolean selectedComputer;
    private float target=Float.NaN;
    RelayOutputSelector(Context c,Runnable onPhone,Runnable onComputer){
        super(c);setBackground(shape(0xffeaeaea,17));
        indicator=new View(c);indicator.setBackground(shape(0xff111111,12));LayoutParams highlight=new LayoutParams(0,dp(48));highlight.setMargins(dp(5),dp(5),0,0);addView(indicator,highlight);
        LinearLayout row=new LinearLayout(c);row.setPadding(dp(5),dp(5),dp(5),dp(5));
        phone=RelayComponents.button(c,"This phone",onPhone);computer=RelayComponents.button(c,"Computer",onComputer);
        phone.setMinHeight(dp(48));computer.setMinHeight(dp(48));row.addView(phone,new LinearLayout.LayoutParams(0,-2,1));row.addView(computer,new LinearLayout.LayoutParams(0,-2,1));addView(row,new LayoutParams(-1,-2));
        addOnLayoutChangeListener((v,l,t,r,b,ol,ot,or,ob)->{if(r-l!=or-ol||b-t!=ob-ot)select(selectedComputer,false);});select(false,false);
    }
    private int dp(int n){return RelayComponents.dp(getContext(),n);}
    private GradientDrawable shape(int color,int radius){GradientDrawable d=new GradientDrawable();d.setColor(color);d.setCornerRadius(dp(radius));return d;}
    void select(boolean selected,boolean animate){
        selectedComputer=selected;style(phone,!selected,"headphones");style(computer,selected,"laptop");if(getWidth()==0)return;
        int width=(getWidth()-dp(10))/2;ViewGroup.LayoutParams lp=indicator.getLayoutParams();if(lp.width!=width||lp.height!=getHeight()-dp(10)){lp.width=width;lp.height=getHeight()-dp(10);indicator.setLayoutParams(lp);}
        float next=selected?width:0;if(animate&&next==target)return;target=next;indicator.animate().cancel();
        if(!animate||!android.animation.ValueAnimator.areAnimatorsEnabled()){indicator.setTranslationX(next);return;}
        indicator.animate().translationX(next).setDuration(180).setInterpolator(new android.view.animation.PathInterpolator(.22f,1,.36f,1)).start();
    }
    private void style(Button b,boolean selected,String name){b.setTextSize(12);b.setTextColor(selected?Color.WHITE:0xff666666);b.setBackgroundColor(Color.TRANSPARENT);GlassUI.Glyph icon=new GlassUI.Glyph(name,selected?Color.WHITE:0xff666666);icon.setBounds(0,0,dp(16),dp(16));b.setCompoundDrawables(icon,null,null,null);b.setCompoundDrawablePadding(dp(6));}
}
