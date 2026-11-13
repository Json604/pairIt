package dev.bluetoothswitch.relay;

/** Two soft bell notes with a rounded attack and a short, airy decay. */
final class ConnectionTone {
    static final double DURATION=.9;
    static double sample(double seconds){
        if(!Double.isFinite(seconds)||seconds<0||seconds>=DURATION)return 0;
        return note(seconds,659.255,.60)+note(seconds-.18,987.767,.72);
    }
    static double disconnectSample(double seconds){
        if(!Double.isFinite(seconds)||seconds<0||seconds>=.58)return 0;
        return .8*(note(seconds,659.255,.36)+note(seconds-.14,439.999,.44));
    }
    private static double note(double t,double frequency,double length){
        if(t<0||t>=length)return 0;
        double envelope=(1-Math.exp(-t/.008))*Math.exp(-t/.22)*Math.min(1,(length-t)/.08);
        return .058*envelope*(Math.sin(2*Math.PI*frequency*t)+.12*Math.exp(-t/.10)*Math.sin(2*Math.PI*frequency*2.01*t));
    }
}
