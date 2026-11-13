package dev.bluetoothswitch.relay;

/** Port of ui-playground's radial-breath keyframes and positionDotField geometry.
 * CSS pixels map to Android dp; the field uses the actual screen and phone anchor.
 */
final class RadialMotion {
    static final double PERIOD = 1.8;
    static final double RING_GAP = 18;
    static int count(int ring) { return (int)Math.round(2*Math.PI*ring*RING_GAP/20); }
    static double angle(int ring,int point) { return point*2*Math.PI/count(ring)+ring*.035; }
    static double strength(int ring) { return round(.13+.52*falloff(ring),1000); }
    static double size(int ring) { return round(.85+1.4*falloff(ring),100); }
    private static double falloff(int ring) { return Math.exp(-Math.pow(ring*RING_GAP/470,2)); }
    static double round(double value,double precision) { return Math.round(value*precision)/precision; }

    // output = opacity multiplier, scale, outward translation multiplier.
    static void sample(double seconds,int ring,boolean reduced,double[] output) {
        if(reduced){set(output,.6,1,0);return;}
        double local=seconds+1.8-ring*.055;
        // CSS animation has no fill mode while a positive delay is pending.
        if(local<0){set(output,1,1,0);return;}
        double phase=(local%PERIOD)/PERIOD;
        if(phase<.15){mix(output,.07,.65,0,1,1.2,1,ease(phase/.15));return;}
        if(phase<.32){mix(output,1,1.2,1,.4,.95,.6,ease((phase-.15)/.17));return;}
        if(phase<.55){mix(output,.4,.95,.6,.07,.65,0,ease((phase-.32)/.23));return;}
        set(output,.07,.65,0);
    }
    private static void set(double[] v,double opacity,double scale,double shift){v[0]=opacity;v[1]=scale;v[2]=shift;}
    private static void mix(double[] v,double a,double b,double c,double x,double y,double z,double t){set(v,a+(x-a)*t,b+(y-b)*t,c+(z-c)*t);}
    /** CSS cubic-bezier(.37,0,.3,1), applied separately to each keyframe segment. */
    private static double ease(double x){
        double low=0,high=1,t=.5;
        for(int i=0;i<18;i++){t=(low+high)/2;double value=3*(1-t)*(1-t)*t*.37+3*(1-t)*t*t*.3+t*t*t;if(value<x)low=t;else high=t;}
        return 3*(1-t)*t*t+t*t*t;
    }
}
