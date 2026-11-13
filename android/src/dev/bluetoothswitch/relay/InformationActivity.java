package dev.bluetoothswitch.relay;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.RippleDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsets;
import android.widget.*;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

/** Readable native help/privacy pages, available without a network connection. */
public final class InformationActivity extends Activity {
    static void open(Context context, String section) {
        context.startActivity(new Intent(context, InformationActivity.class).putExtra("section", section));
    }
    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        boolean privacy = "privacy".equals(getIntent().getStringExtra("section"));
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        getWindow().setStatusBarColor(Color.TRANSPARENT);getWindow().setNavigationBarColor(0xfff5f4f2);
        FrameLayout root = new FrameLayout(this);root.setBackgroundColor(Color.WHITE);
        ScrollView scroll=new ScrollView(this);scroll.setFillViewport(true);scroll.setVerticalScrollBarEnabled(false);
        GlassUI.ContentColumn content=new GlassUI.ContentColumn(this);content.setPadding(dp(24),dp(12),dp(24),dp(32));
        scroll.addView(content,new FrameLayout.LayoutParams(-1,-2,Gravity.TOP|Gravity.CENTER_HORIZONTAL));
        root.addView(scroll,new FrameLayout.LayoutParams(-1,-1));setContentView(root);
        scroll.setOnApplyWindowInsetsListener((view,insets)->{
            if(Build.VERSION.SDK_INT>=30){android.graphics.Insets bars=insets.getInsets(WindowInsets.Type.systemBars());view.setPadding(bars.left,bars.top,bars.right,bars.bottom);}
            else view.setPadding(insets.getSystemWindowInsetLeft(),insets.getSystemWindowInsetTop(),insets.getSystemWindowInsetRight(),insets.getSystemWindowInsetBottom());
            return insets;
        });
        LinearLayout header=new LinearLayout(this);header.setGravity(Gravity.CENTER_VERTICAL);
        Button back=new Button(this);back.setText("‹");back.setTextSize(30);back.setTextColor(GlassUI.INK);back.setPadding(0,0,0,0);back.setContentDescription("Back");
        back.setBackground(new RippleDrawable(ColorStateList.valueOf(0x18331f1a),null,GlassUI.surface(dp(12))));
        GlassUI.pressFeedback(back);back.setOnClickListener(v->finish());header.addView(back,new LinearLayout.LayoutParams(dp(48),dp(48)));
        TextView heading=label(privacy?"Privacy policy":"Help & desktop companion",22,true);heading.setAccessibilityHeading(true);
        LinearLayout.LayoutParams headingParams=new LinearLayout.LayoutParams(0,-2,1);headingParams.setMarginStart(dp(8));header.addView(heading,headingParams);content.addView(header);
        String document=readAsset(privacy?"privacy.txt":"help.txt");
        for(String paragraph:document.split("\n\n")) {
            if(paragraph.trim().isEmpty())continue;
            boolean title=paragraph.startsWith("## ");TextView text=label(title?paragraph.substring(3):paragraph,title?18:15,title);
            text.setTextIsSelectable(true);text.setLineSpacing(dp(4),1.05f);text.setAccessibilityHeading(title);
            LinearLayout.LayoutParams params=new LinearLayout.LayoutParams(-1,-2);params.topMargin=dp(title?26:16);content.addView(text,params);
        }
        String link=getString(privacy?R.string.privacy_url:R.string.mac_download_url);
        if(!link.isEmpty()) {
            Button action=new Button(this);action.setText(privacy?"Read online":"Get the computer companion");action.setAllCaps(false);action.setTextColor(Color.WHITE);action.setTextSize(15);
            action.setBackground(new RippleDrawable(ColorStateList.valueOf(0x30ffffff),GlassUI.accent(dp(13)),null));GlassUI.pressFeedback(action);
            action.setOnClickListener(v->openLink(link));LinearLayout.LayoutParams params=new LinearLayout.LayoutParams(-1,dp(54));params.topMargin=dp(28);content.addView(action,params);
        }
    }
    private String readAsset(String name) {
        try(InputStream input=getAssets().open(name);ByteArrayOutputStream output=new ByteArrayOutputStream()) {
            byte[] buffer=new byte[4096];int count;while((count=input.read(buffer))!=-1)output.write(buffer,0,count);
            return new String(output.toByteArray(),StandardCharsets.UTF_8);
        } catch(Exception error) { return "This page couldn’t be opened. Please reopen the app."; }
    }
    private void openLink(String url) {
        try { startActivity(new Intent(Intent.ACTION_VIEW,Uri.parse(url))); }
        catch(ActivityNotFoundException error) { new android.app.AlertDialog.Builder(this).setTitle("Open this link on another device").setMessage(url).setPositiveButton("Done",null).show(); }
    }
    private TextView label(String value,int size,boolean bold) {
        TextView view=new TextView(this);view.setText(value);view.setTextSize(size);view.setTextColor(bold?GlassUI.INK:GlassUI.SECONDARY);view.setIncludeFontPadding(false);
        view.setTypeface(Typeface.create(bold?"sans-serif-medium":"sans-serif",Typeface.NORMAL));return view;
    }
    private int dp(int value){return Math.round(value*getResources().getDisplayMetrics().density);}
}
