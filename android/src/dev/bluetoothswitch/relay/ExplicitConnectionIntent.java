package dev.bluetoothswitch.relay;

/** An explicit connect action survives its own ad, but never leaving the app or tab. */
final class ExplicitConnectionIntent {
    private long flow;
    void begin(long value){flow=value;}
    boolean active(){return flow!=0;}
    boolean matches(long value){return value!=0&&value==flow;}
    void cancel(){flow=0;}
    void paused(boolean ownAdvertisement){if(!ownAdvertisement)cancel();}
    boolean consume(long value,boolean visible,boolean focused){
        if(!matches(value)||!visible||!focused)return false;
        cancel();return true;
    }
}
