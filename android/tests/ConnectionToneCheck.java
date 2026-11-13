package dev.bluetoothswitch.relay;
public class ConnectionToneCheck {
    public static void main(String[] args){
        for(int rate:new int[]{44100,48000}){
            double peak=0,tail=0;
            for(int i=0;i<rate;i++){double value=ConnectionTone.sample(i/(double)rate);if(!Double.isFinite(value)||Math.abs(value)>.08)throw new AssertionError("Tone clipped");peak=Math.max(peak,Math.abs(value));if(i>rate*.55)tail=Math.max(tail,Math.abs(value));}
            if(peak<.05||tail<.005)throw new AssertionError("Missing resolving tail");
        }
        if(ConnectionTone.sample(0)!=0||ConnectionTone.sample(.9)!=0||ConnectionTone.sample(-1)!=0||ConnectionTone.sample(Double.NaN)!=0)throw new AssertionError("Invalid endpoint");
        if(!AdTiming.appOpenDue(1000,0)||AdTiming.appOpenDue(1_800_999,1000)||!AdTiming.appOpenDue(1_801_000,1000)||AdTiming.appOpenDue(999,1000))throw new AssertionError("Thirty minute TTL boundary");
        System.out.println("Connection chime envelope, tail and app-open 30-minute TTL passed");
    }
}
