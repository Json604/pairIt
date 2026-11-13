package dev.bluetoothswitch.relay;

/** A tour never advances in the background, during interaction, or beyond its last step. */
final class TourPlayback {
    static final long STEP_MS=9000;
    int step; long elapsed; boolean playing=true;
    void select(int next){step=Math.max(0,Math.min(3,next));elapsed=0;}
    boolean tick(long delta,boolean foreground){
        if(!foreground||!playing)return false;
        elapsed=Math.min(STEP_MS,elapsed+Math.max(0,Math.min(100,delta)));
        if(elapsed<STEP_MS)return false;
        if(step==3){playing=false;return false;}
        select(step+1);return true;
    }
    float progress(){return (float)elapsed/STEP_MS;}
}
