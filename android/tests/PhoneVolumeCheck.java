package dev.bluetoothswitch.relay;
public final class PhoneVolumeCheck {
    public static void main(String[] args) {
        check(PhoneVolume.level(7, 15) == 467, "index to wire level");
        check(PhoneVolume.level(0, 0) == 0 && PhoneVolume.level(20, 15) == 1000, "bounded level");
        check(PhoneVolume.index(529, 7, 15) == 8, "computer volume up moves one step");
        check(PhoneVolume.index(404, 7, 15) == 6, "computer volume down moves one step");
        check(PhoneVolume.index(500, 7, 15) == 8, "small request still moves a step");
        check(PhoneVolume.index(470, 7, 15) == 7, "own echo does not move");
        check(PhoneVolume.index(0, 7, 15) == 0 && PhoneVolume.index(1000, 7, 15) == 15, "absolute limits");
        check(PhoneVolume.index(-5, 3, 15) == 0 && PhoneVolume.index(5000, 3, 15) == 15, "invalid levels clamp");
        check(PhoneVolume.index(PhoneVolume.level(9, 25), 9, 25) == 9, "round trip is stable");
        System.out.println("PASS: phone volume mapping");
    }
    static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
