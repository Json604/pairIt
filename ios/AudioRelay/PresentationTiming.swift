/// Match presentation time, not merely the instant each audio engine starts.
/// Zero target preserves solo timing and compatibility with older companions.
enum PresentationTiming {
    static func adaptive(platform: String, bluetooth: Bool) -> Bool {
        !bluetooth && (platform == "linux" || platform == "windows")
    }
    static func adaptiveCushion(jitter: Double, packet: Double, lead: Double) -> Int {
        Int(min(320, max(40, (jitter + 2 * packet + lead).rounded(.up))))
    }
    static func canAnchor(capture: Double, now: Double, cushion: Double) -> Bool {
        now <= capture + cushion
    }

    /// Preserve queued audio across a short forward skip. Use the capture clock
    /// because packet sizes vary, and arrival time includes network jitter.
    static func gapPadding(previous: UInt32, sequence: UInt32, elapsedNs: Int64,
                           previousFrames: UInt32, rate: UInt32) -> Int? {
        let missingPackets = sequence &- previous &- 1
        guard (1...4).contains(missingPackets), elapsedNs >= 0, elapsedNs <= 1_000_000_000 else { return nil }
        let elapsedFrames = (elapsedNs * Int64(rate) + 500_000_000) / 1_000_000_000
        let missingFrames = elapsedFrames - Int64(previousFrames)
        guard (0...Int64(rate / 50)).contains(missingFrames) else { return nil }
        return Int(missingFrames)
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
