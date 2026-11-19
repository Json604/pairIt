/// Match presentation time, not merely the instant each audio engine starts.
/// Zero target preserves solo timing and compatibility with older companions.
enum PresentationTiming {
    private static func desktop(_ platform: String) -> Bool { ["linux", "windows", "macos"].contains(platform) }
    /// Low latency learns network jitter instead of holding a fixed 320 ms cushion.
    /// Windows/Linux local outputs always learn; Low latency extends it to Mac and
    /// Bluetooth. Unknown/legacy computers keep Reliable. Unstable sessions fall back.
    static func adaptive(platform: String, bluetooth: Bool, lowLatency: Bool) -> Bool {
        if !bluetooth && (platform == "linux" || platform == "windows") { return true }
        return lowLatency && desktop(platform)
    }
    static func adaptive(platform: String, bluetooth: Bool) -> Bool { adaptive(platform: platform, bluetooth: bluetooth, lowLatency: false) }
    /// The original local Windows/Linux path keeps its 40 ms floor. Paths added by Low
    /// latency keep 60 ms, because a short learning window can miss Wi-Fi power-save gaps.
    static func floorMs(platform: String, bluetooth: Bool) -> Int {
        !bluetooth && (platform == "linux" || platform == "windows") ? 40 : 60
    }
    static func adaptiveCushion(jitter: Double, packet: Double, lead: Double) -> Int {
        adaptiveCushion(jitter: jitter, packet: packet, lead: lead, floor: 40)
    }
    static func adaptiveCushion(jitter: Double, packet: Double, lead: Double, floor: Int) -> Int {
        Int(min(320, max(Double(max(40, min(320, floor))), (jitter + 2 * packet + lead).rounded(.up))))
    }
    static func correctedDelay(_ delay: Int, correction: Int) -> Int {
        max(min(delay, 40), min(2500, delay - max(-500, min(500, correction))))
    }
    static func rateCorrection(errorMs: Double) -> Double {
        guard errorMs.isFinite, abs(errorMs) >= 1 else { return 0 }
        return max(-0.001, min(0.001, errorMs / 20000))
    }
    static func outputDelay(total: Int, render: Int) -> Int? {
        let value = total - render
        return (0...1000).contains(value) ? value : nil
    }
    static func renderDelay(minimum: Int, output: Int?, target: Int) -> Int {
        guard let output, (0...1000).contains(output), (1...2000).contains(target) else { return minimum }
        return max(minimum, target - output)
    }
}
