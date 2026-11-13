import AVFAudio
import UIKit

/// Idle acknowledgment uses the existing session and current selected route, never changes either.
@MainActor final class ConnectionAcknowledgment {
    static let shared = ConnectionAcknowledgment()
    private var gate = ConnectionFeedbackGate()
    private var player: AVAudioPlayer?
    private var routeObserver: NSObjectProtocol?
    private init() {
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.player?.stop(); self?.player = nil }
        }
    }
    func stopSound() { player?.stop(); player = nil }
    func reset() { gate.reset(); stopSound() }
    func claim(_ value: String) -> Bool {
        guard gate.claim(value) else { return false }
        return UserDefaults.standard.object(forKey: "soundFeedback") as? Bool ?? true
    }
    func connected(_ pin: String, output: RelayOutput) {
        let session = AVAudioSession.sharedInstance()
        guard !AudioPresentationGate.isPresenting, !session.isOtherAudioPlaying,
              let route = output.currentRoute(),
              session.currentRoute.outputs.contains(where: { $0.uid == route.uid }) else { return }
        guard claim(pin) else { return }
        do {
            let candidate = try AVAudioPlayer(data: Self.wave(disconnect: false))
            candidate.volume = 1; candidate.prepareToPlay()
            guard session.currentRoute.outputs.contains(where: { $0.uid == route.uid }), candidate.play() else {
                gate.reset(); return
            }
            player = candidate
        } catch { gate.reset() }
    }
    func disconnected(output: RelayOutput) {
        guard gate.disconnected(), UserDefaults.standard.object(forKey: "soundFeedback") as? Bool ?? true,
              !AudioPresentationGate.isPresenting else { return }
        let session = AVAudioSession.sharedInstance()
        // Do not interrupt another app or create an unintended speaker fallback.
        guard !session.isOtherAudioPlaying, let route = output.currentRoute(),
              session.currentRoute.outputs.contains(where: { $0.uid == route.uid }) else { return }
        do {
            let candidate = try AVAudioPlayer(data: Self.wave(disconnect: true))
            candidate.volume = 1; candidate.prepareToPlay()
            guard session.currentRoute.outputs.contains(where: { $0.uid == route.uid }) else { return }
            player = candidate; candidate.play()
        } catch { player = nil }
    }
    private static func wave(disconnect: Bool) -> Data {
        let rate = 48000, frames = Int(48000 * ConnectionTone.duration)
        var data = Data()
        func text(_ s: String) { data.append(contentsOf: s.utf8) }
        func word<T: FixedWidthInteger>(_ x: T) { var value = x.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        text("RIFF"); word(UInt32(36 + frames * 2)); text("WAVEfmt "); word(UInt32(16))
        word(UInt16(1)); word(UInt16(1)); word(UInt32(rate)); word(UInt32(rate * 2)); word(UInt16(2)); word(UInt16(16))
        text("data"); word(UInt32(frames * 2))
        for frame in 0..<frames { word(Int16((disconnect ? ConnectionTone.disconnectSample(frame: frame, rate: Double(rate)) : ConnectionTone.sample(frame: frame, rate: Double(rate))) * 32767)) }
        return data
    }
}
