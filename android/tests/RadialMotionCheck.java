package dev.bluetoothswitch.relay;

/** Numerical parity checks for the approved web prototype's CSS keyframes. */
public class RadialMotionCheck {
    static void close(double actual,double expected){if(Math.abs(actual-expected)>.00002)throw new AssertionError(actual+" != "+expected);}
    static double[] at(double phase){double[] v=new double[3];RadialMotion.sample(phase*1.8+1*.055,1,false,v);return v;}
    public static void main(String[] args){
        double[] start=at(0),peak=at(.15),shoulder=at(.32),rest=at(.55),end=at(.85);
        close(start[0],.07);close(start[1],.65);close(start[2],0);
        close(peak[0],1);close(peak[1],1.2);close(peak[2],1);
        close(shoulder[0],.4);close(shoulder[1],.95);close(shoulder[2],.6);
        close(rest[0],.07);close(end[0],.07);close(end[2],0);
        double[] midpoint=at(.075);close(midpoint[0],.7432745790919619);close(midpoint[1],1.0481731381726656);close(midpoint[2],.7239511603139375);
        double[] first=new double[3],next=new double[3];
        RadialMotion.sample(.4,7,false,first);RadialMotion.sample(.455,8,false,next);
        for(int i=0;i<3;i++)close(first[i],next[i]);
        RadialMotion.sample(2.2,7,false,next);for(int i=0;i<3;i++)close(first[i],next[i]);
        RadialMotion.sample(0,40,false,next);close(next[0],1);close(next[1],1);close(next[2],0);
        RadialMotion.sample(200,40,true,next);close(next[0],.6);close(next[1],1);close(next[2],0);
        if(RadialMotion.count(1)!=6||RadialMotion.count(10)!=57)throw new AssertionError("Ring counts differ from prototype");
        close(RadialMotion.angle(10,0),.35);close(RadialMotion.size(1),2.25);close(RadialMotion.strength(1),.649);
        for(int ring=1;ring<70;ring++)for(int frame=0;frame<180;frame++){
            RadialMotion.sample(frame/60.0,ring,false,next);
            if(next[0]<.0699||next[0]>1.0001||next[1]<.6499||next[1]>1.2001||next[2]<0||next[2]>1.0001)throw new AssertionError("Invalid CSS interpolation");
        }
        System.out.println("Prototype radial geometry, keyframes, delay, period and reduced-motion checks passed");
    }
}
