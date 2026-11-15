import AVFAudio
import Foundation

/// AudioEngine drives continuous playout. Network jitter does not reschedule
/// individual packets. This iPhone implementation still needs real-device QA.
final class RelayPlayback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let speed = AVAudioUnitVarispeed()
    private var format: AVAudioFormat?
    private var scheduled: Int64 = 0
    private var sourceAnchor: Double = 0
    private var startDeadline: Double = 0
    private var started: Double = 0
    private var previous: UInt32?
    private var fadeFrames = 0
    private var feedbackFrame: Int?
    func requestConnectionFeedback() { feedbackFrame = 0 }
    private var estimates: [Double] = []
    private var lastEstimate: Double = 0
    private var lockedEstimate = false
    private var lastDrift: Double = 0, referencePhase: Double?, filteredError = 0.0
    private let requestedMode: RelayPlaybackMode
    private var learning: [(residual: Double, duration: Double)] = []
    private var learningStarted: Int64?
    private var learned = false, reliableFallback = false
    private var recoveryTimes: [Double] = []
    private var cushion = 0.320, prime = 0.120
    private var minimumCushionMs = 320, outputDelayMs: Int?, presentationTargetMs = 0
    private var localCorrection = 0
    func setLocalCorrection(_ value: Int) { localCorrection = max(-500,min(500,value)); applyPresentationTarget() }
    private var correctedRenderDelay: Int {
        PresentationTiming.correctedDelay(PresentationTiming.renderDelay(minimum: minimumCushionMs, output: outputDelayMs, target: presentationTargetMs), correction: localCorrection)
    }
    var onOutputTiming: ((Int, Int?) -> Void)?
    func setPresentationTarget(_ value: Int) {
        guard (0...2000).contains(value) else { return }
        presentationTargetMs = value; applyPresentationTarget()
    }
    private func applyPresentationTarget() {
        let delay = correctedRenderDelay
        guard abs(cushion - Double(delay) / 1000) > 0.0005 else { return }
        cushion = Double(delay) / 1000
        // Preserve TLS, output selection and route calibration. Only re-anchor
        // queued audio when the group's presentation deadline changes.
        player.stop(); resetEpoch(); onRecovery?()
    }
    private(set) var mode: RelayPlaybackMode
    private(set) var recoveries = 0, receivedFrames: Int64 = 0
    private(set) var playing = false
    var onPlaying: (() -> Void)?
    var onEstimate: ((Int) -> Void)?
    var onRecovery: (() -> Void)?
    var onError: ((String) -> Void)?
    var onModeChange: ((RelayPlaybackMode, String) -> Void)?
    var diagnostics: String {
        "Mode: \(mode.title)\nReceived frames: \(receivedFrames)\nAutomatic recoveries: \(recoveries)\nOutput estimate: \(Int(player.outputPresentationLatency * 1000)) ms\nPlayback rate: \(speed.rate)\nNetwork prefill: \(Int((cushion * 1000).rounded())) ms\nInteractive learning: \(mode == .interactive && !learned ? "in progress" : "complete")"
    }
    init(mode: RelayPlaybackMode = .reliable) { requestedMode = mode; self.mode = mode; engine.attach(player); engine.attach(speed) }
    func stop() { player.stop(); engine.stop(); resetEpoch(); resetLearning() }
    func reset() { player.stop(); resetEpoch(); resetLearning() }
    func configurationChanged(_ object: AnyObject?) {
        guard object === engine, !engine.isRunning else { return }
        outputDelayMs = nil
        reset(); format = nil; onRecovery?()
    }
    private func resetEpoch() {
        scheduled = 0; sourceAnchor = 0; previous = nil; playing = false
        feedbackFrame = nil
        fadeFrames = 0; estimates.removeAll(); lockedEstimate = false; lastEstimate = 0
        lastDrift = 0; referencePhase = nil; filteredError = 0; speed.rate = 1
    }
    private func configure(rate: Double) throws {
        if format?.sampleRate == rate && engine.isRunning { return }
        outputDelayMs = nil
        stop()
        guard let next = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        engine.disconnectNodeOutput(player); engine.disconnectNodeOutput(speed)
        engine.connect(player, to: speed, format: next)
        engine.connect(speed, to: engine.mainMixerNode, format: next)
        format = next; engine.prepare(); try engine.start()
    }
    func accept(_ packet: RelayPacket, clockOffset: Int64) {
        do { try configure(rate: Double(packet.rate)) }
        catch { onError?("Your iPhone couldn’t start audio playback. Try reconnecting your headphones."); return }
        guard let format else { return }
        let now = Double(RelayClock.nanoseconds) / 1e9
        let source = packet.localCaptureSeconds(clockOffset: clockOffset)
        guard source.isFinite, (-1...5).contains(now - source) else { return }
        if mode == .interactive && !learned {
            learn(packet)
            return // Learning samples are discarded; the next packet supplies a fresh anchor.
        }
        let discontinuity = previous.map { packet.sequence != ($0 &+ 1) } ?? false
        if discontinuity { recover() }
        previous = packet.sequence; receivedFrames += Int64(packet.frames)
        if playing, let stamp = player.lastRenderTime, let position = player.playerTime(forNodeTime: stamp), position.isSampleTimeValid {
            let remaining = scheduled - position.sampleTime
            if remaining < 0 || remaining > Int64(format.sampleRate * max(1.2, cushion + prime + 0.250)) { recover() }
        }
        if scheduled == 0 { sourceAnchor = source; startDeadline = source + cushion; fadeFrames = Int(format.sampleRate * 0.005) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(packet.frames)), let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(packet.frames)
        packet.pcm.withUnsafeBytes { raw in
            for frame in 0..<Int(packet.frames) {
                let totalFade = max(1, Int(format.sampleRate * 0.005))
                let gain: Float = fadeFrames > 0 ? Float(totalFade - fadeFrames) / Float(totalFade) : 1
                let feedback = feedbackFrame.map { ConnectionTone.sample(frame: $0, rate: format.sampleRate) } ?? 0
                if let frame = feedbackFrame { feedbackFrame = frame + 1 < Int(format.sampleRate * ConnectionTone.duration) ? frame + 1 : nil }
                for channel in 0..<2 {
                    let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: (frame * 2 + channel) * 2, as: Int16.self))
                    channels[channel][frame] = max(-1, min(1, Float(value) / 32768 * gain + feedback))
                }
                fadeFrames = max(0, fadeFrames - 1)
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil); scheduled += Int64(packet.frames)
        if !playing && Double(scheduled) / format.sampleRate >= prime {
            if now - startDeadline > (presentationTargetMs > 0 && outputDelayMs != nil ? 0.005 : 0.100) { recover(); return }
            let start = max(startDeadline, now + 0.005)
            player.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: start)))
            playing = true; started = start; onPlaying?()
        }
        if playing && now - started > 2.5 { observe(now: now, rate: format.sampleRate) }
    }
    private func resetLearning() {
        learning.removeAll(keepingCapacity: true); learningStarted = nil; learned = false
        mode = reliableFallback ? .reliable : requestedMode
        minimumCushionMs = 320; cushion = Double(correctedRenderDelay) / 1000; prime = 0.120
        onOutputTiming?(minimumCushionMs, outputDelayMs)
    }
    private func learn(_ packet: RelayPacket) {
        if learningStarted == nil { learningStarted = packet.receivedAt }
        let lead = AVAudioSession.sharedInstance().ioBufferDuration * 2
        guard lead.isFinite, lead > 0, lead <= 0.320 else { fallback("This output needs Reliable playback."); return }
        guard packet.receivedAt - learningStarted! <= 1_000_000_000 else { fallback("Not enough arrival samples. Using Reliable."); return }
        learning.append((Double(packet.receivedAt - packet.capturedAt) / 1e9, Double(packet.frames) / Double(packet.rate)))
        guard learning.count >= 64 else { return }
        let minimum = learning.map(\.residual).min()!
        let sorted = learning.map { max(0, $0.residual - minimum) }.sorted()
        let jitter = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
        let packetDuration = learning.map(\.duration).max()!
        cushion = min(0.320, max(lead, ceil((jitter + packetDuration * 2 + lead) * 1000) / 1000))
        minimumCushionMs = Int((cushion * 1000).rounded())
        cushion = Double(correctedRenderDelay) / 1000
        onOutputTiming?(minimumCushionMs, outputDelayMs)
        prime = lead
        learned = true; learning.removeAll(keepingCapacity: true)
        onModeChange?(.interactive, "Interactive preview · \(Int((cushion * 1000).rounded())) ms network prefill")
    }
    private func fallback(_ reason: String) {
        reliableFallback = true; mode = .reliable; minimumCushionMs = 320; cushion = Double(correctedRenderDelay) / 1000; prime = 0.120
        onOutputTiming?(minimumCushionMs, outputDelayMs)
        learning.removeAll(); learned = true
        onModeChange?(.reliable, reason)
    }
    private func recover() {
        recoveries += 1
        let now = Double(RelayClock.nanoseconds) / 1e9
        recoveryTimes = recoveryTimes.filter { now - $0 <= 15 }; recoveryTimes.append(now)
        player.stop(); resetEpoch()
        if mode == .interactive && recoveryTimes.count >= 3 { fallback("Connection needs more headroom. Using Reliable for this session.") }
        onRecovery?()
    }
    private func observe(now: Double, rate: Double) {
        guard let stamp = player.lastRenderTime, stamp.isHostTimeValid,
              let position = player.playerTime(forNodeTime: stamp), position.isSampleTimeValid, position.sampleTime >= 0 else { return }
        let rendered = Double(position.sampleTime) / rate
        let renderHost = AVAudioTime.seconds(forHostTime: stamp.hostTime)
        let phase = renderHost - sourceAnchor - rendered
        if now - lastDrift >= 2 {
            lastDrift = now
            if referencePhase == nil { referencePhase = phase }
            let aligned = presentationTargetMs > 0 && outputDelayMs != nil
            let error = aligned ? phase + player.outputPresentationLatency - Double(presentationTargetMs + correctedRenderDelay - PresentationTiming.renderDelay(minimum: minimumCushionMs, output: outputDelayMs, target: presentationTargetMs)) / 1000 : phase - referencePhase!
            filteredError = filteredError * 0.8 + error * 0.2
            let correction = aligned ? PresentationTiming.rateCorrection(errorMs: filteredError * 1000)
                : (abs(filteredError) < 0.004 ? 0 : max(-0.001, min(0.001, filteredError / 20)))
            speed.rate = Float(1 + correction)
        }
        guard !lockedEstimate, now - lastEstimate >= 0.5 else { return }
        lastEstimate = now
        // outputPresentationLatency already includes the hardware path. Do not
        // add AVAudioSession.outputLatency again and double-count Bluetooth.
        let estimate = (phase + player.outputPresentationLatency) * 1000
        guard estimate.isFinite, (0...2000).contains(estimate) else { return }
        estimates.append(estimate)
        guard estimates.count == 7 else { return }
        let sorted = estimates.sorted(); estimates.removeAll()
        guard sorted[5] - sorted[1] <= 30 else { return }
        lockedEstimate = true
        let total = Int(sorted[3].rounded())
        onEstimate?(total)
        if outputDelayMs == nil {
            outputDelayMs = PresentationTiming.outputDelay(total: total, render: Int((cushion * 1000).rounded()))
            onOutputTiming?(minimumCushionMs, outputDelayMs)
            applyPresentationTarget()
        }
    }
}
