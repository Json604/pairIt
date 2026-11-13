package dev.bluetoothswitch.relay;
final class AdTiming {
    static boolean appOpenDue(long now,long lastShown){return lastShown<=0||(now>=lastShown&&now-lastShown>=1_800_000);}
}
