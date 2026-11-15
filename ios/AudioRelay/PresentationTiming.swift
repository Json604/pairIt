/// Match presentation time, not merely the instant each audio engine starts.
/// Zero target preserves solo timing and compatibility with older companions.
enum PresentationTiming {
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
