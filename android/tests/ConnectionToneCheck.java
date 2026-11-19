package dev.bluetoothswitch.relay;
public class ConnectionToneCheck {
    public static void main(String[] args){
        for(int rate:new int[]{44100,48000}){
            double peak=0,tail=0;
            for(int i=0;i<rate;i++){double value=ConnectionTone.sample(i/(double)rate);if(!Double.isFinite(value)||Math.abs(value)>.08)throw new AssertionError("Tone clipped");peak=Math.max(peak,Math.abs(value));if(i>rate*.55)tail=Math.max(tail,Math.abs(value));}
            if(peak<.05||tail<.005)throw new AssertionError("Missing resolving tail");
        }
        if(ConnectionTone.sample(0)!=0||ConnectionTone.sample(.9)!=0||ConnectionTone.sample(-1)!=0||ConnectionTone.sample(Double.NaN)!=0)throw new AssertionError("Invalid endpoint");
        if(!AdTiming.appOpenDue(1000,0)||AdTiming.appOpenDue(180_999,1000)||!AdTiming.appOpenDue(181_000,1000)||AdTiming.appOpenDue(999,1000))throw new AssertionError("Three minute app-open cooldown boundary");
        if(!AdTiming.returnEligible(1000,0)||AdTiming.returnEligible(30_999,1000)||!AdTiming.returnEligible(31_000,1000)||!AdTiming.returnEligible(999,1000))throw new AssertionError("Warm-return absence boundary");
        if(AdTiming.PRESENT_WINDOW_MS>1_000||AdTiming.COLD_WAIT_MS>6_000||AdTiming.AD_EXPIRY_MS>=4*60*60_000L)throw new AssertionError("App-open wait/expiry bounds");
        if(AdTiming.bannerRetryMs(0)!=15_000||AdTiming.bannerRetryMs(1)!=30_000||AdTiming.bannerRetryMs(2)!=60_000||AdTiming.bannerRetryMs(9)!=60_000)throw new AssertionError("Banner retry backoff");
        System.out.println("Connection chime envelope, tail and app-open pacing passed");
    }
}
