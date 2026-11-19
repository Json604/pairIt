package dev.bluetoothswitch.relay;

/** Maps the 0..1000 wire level to Android's coarse media-volume steps. */
final class PhoneVolume {
    static int level(int index, int max) {
        if (max <= 0) return 0;
        return Math.round(Math.max(0, Math.min(max, index)) * 1000f / max);
    }
    /** A requested change that rounds to the current step still moves one step in its
     * direction, so every computer volume-key press is audible on phones with few steps. */
    static int index(int level, int current, int max) {
        if (max <= 0) return current;
        level = Math.max(0, Math.min(1000, level));
        int index = Math.round(level * max / 1000f);
        float currentLevel = current * 1000f / max, step = 1000f / max;
        if (index == current && Math.abs(level - currentLevel) >= step / 4f) index += level > currentLevel ? 1 : -1;
        return Math.max(0, Math.min(max, index));
    }
}
