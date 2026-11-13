package dev.bluetoothswitch.relay;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.RippleDrawable;
import android.view.Gravity;
import android.widget.*;

/** Presentation only. The live screen and tour supply their own actions and state. */
final class RelayComponents {
    static int dp(Context c,int value){return Math.round(value*c.getResources().getDisplayMetrics().density);}
    static Button button(Context c,String title,Runnable action){
        Button b=new Button(c);b.setText(title);b.setAllCaps(false);b.setTextSize(15);b.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));
        int p=dp(c,8);b.setPadding(p,p,p,p);b.setMinimumWidth(0);b.setMinWidth(0);GlassUI.pressFeedback(b);b.setOnClickListener(v->action.run());return b;
    }
    static TextView text(Context c,String title,float size,int color,boolean bold){
        TextView v=new TextView(c);v.setText(title);v.setTextSize(size);v.setTextColor(color);v.setIncludeFontPadding(false);
        v.setTypeface(Typeface.create(bold?"sans-serif-medium":"sans-serif",Typeface.NORMAL));v.setLineSpacing(dp(c,4),1);return v;
    }
    static void style(Button b,boolean selected){
        b.setTextColor(selected?Color.WHITE:GlassUI.INK);b.setBackgroundTintList(null);
        b.setBackground(new RippleDrawable(ColorStateList.valueOf(selected?0x30ffffff:0x18191919),selected?GlassUI.accent(dp(b.getContext(),13)):GlassUI.surface(dp(b.getContext(),13)),null));
    }
    static void shortcut(Button b,String title,String icon){
        Context c=b.getContext();style(b,false);b.setMinHeight(dp(c,64));b.setPadding(dp(c,5),dp(c,8),dp(c,5),dp(c,8));b.setTextSize(11);b.setGravity(Gravity.CENTER);b.setText(title);
        GlassUI.Glyph g=new GlassUI.Glyph(icon,GlassUI.INK);g.setBounds(0,0,dp(c,20),dp(c,20));b.setCompoundDrawables(null,g,null,null);b.setCompoundDrawablePadding(dp(c,5));
    }
    static ImageView ownPhone(Context c){
        ImageView orb=new ImageView(c);orb.setImageDrawable(new GlassUI.Glyph("phone",Color.WHITE));int p=dp(c,13);orb.setPadding(p,p,p,p);
        android.graphics.drawable.GradientDrawable bg=new android.graphics.drawable.GradientDrawable();bg.setColor(0x12ffffff);bg.setCornerRadius(dp(c,30));bg.setStroke(dp(c,1),0x50ffffff);orb.setBackground(bg);return orb;
    }
    /** A crown and two wings form each arc; measured rows keep large labels clear. */
    static LinearLayout phoneOrbit(Context c,java.util.List<android.view.View> nodes){
        LinearLayout orbit=new LinearLayout(c);orbit.setOrientation(LinearLayout.VERTICAL);
        for(int start=0;start<nodes.size();start+=3){
            int end=Math.min(start+3,nodes.size());
            LinearLayout crown=new LinearLayout(c);crown.setGravity(Gravity.CENTER);
            crown.addView(nodes.get(start),new LinearLayout.LayoutParams(0,-2,1));
            orbit.addView(crown,new LinearLayout.LayoutParams(-1,-2));
            if(start+1<end){
                LinearLayout wings=new LinearLayout(c);wings.setGravity(Gravity.TOP);
                wings.setPadding(0,dp(c,12),0,dp(c,8));
                for(int i=start+1;i<end;i++)wings.addView(nodes.get(i),new LinearLayout.LayoutParams(0,-2,1));
                if(end-start==2)wings.addView(new android.view.View(c),new LinearLayout.LayoutParams(0,1,1));
                orbit.addView(wings,new LinearLayout.LayoutParams(-1,-2));
            }
        }
        return orbit;
    }
    static LinearLayout nearby(Context c,String name,String detail,boolean phone,Runnable action){
        LinearLayout node=new LinearLayout(c);node.setOrientation(LinearLayout.VERTICAL);node.setGravity(Gravity.CENTER);
        ImageButton button=new ImageButton(c);button.setImageDrawable(new GlassUI.Glyph(phone?"phone":"laptop",GlassUI.INK));int p=dp(c,29);button.setPadding(p,p,p,p);button.setBackground(new GlassUI.NearbyCircle());button.setContentDescription(name+(phone?", share PairIt":", connect"));GlassUI.pressFeedback(button);button.setOnClickListener(v->action.run());
        node.addView(button,new LinearLayout.LayoutParams(dp(c,88),dp(c,88)));
        TextView label=text(c,name,12,Color.WHITE,true);label.setMaxLines(2);label.setEllipsize(android.text.TextUtils.TruncateAt.END);label.setGravity(Gravity.CENTER);node.addView(label,new LinearLayout.LayoutParams(-1,-2));
        TextView sub=text(c,detail,10,0xffcccccc,false);sub.setGravity(Gravity.CENTER);node.addView(sub);return node;
    }
}
