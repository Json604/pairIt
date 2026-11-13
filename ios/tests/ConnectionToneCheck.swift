import Foundation
@main struct ConnectionToneCheck {
    static func main() {
        for rate in [44100.0, 48000.0] {
            let samples = (0...Int(rate * ConnectionTone.duration)).map { ConnectionTone.sample(frame: $0, rate: rate) }
            precondition(samples.first == 0 && samples.last == 0)
            precondition(samples.allSatisfy { $0.isFinite && abs($0) < 0.08 })
            precondition(samples.contains { abs($0) > 0.05 })
        }
        precondition(ConnectionTone.sample(frame: -1, rate: 48000) == 0)
        precondition(ConnectionTone.sample(frame: 1, rate: .nan) == 0)
        let disconnectSamples = (0..<48000).map { ConnectionTone.disconnectSample(frame: $0, rate: 48000) }
        precondition(disconnectSamples.allSatisfy { $0.isFinite && abs($0) < 0.08 })
        precondition(disconnectSamples.contains { abs($0) > 0.02 })
        precondition(ConnectionTone.disconnectSample(frame: 48000, rate: 48000) == 0)
        var gate = ConnectionFeedbackGate()
        precondition(gate.claim("computer-a"))
        precondition(!gate.claim("computer-a"), "Rerender, resume or playback following handshake must not repeat cue")
        gate.reset()
        precondition(gate.claim("computer-a"), "A new verified connection may acknowledge again")
        precondition(gate.claim("computer-b"))
        precondition(gate.disconnected())
        precondition(!gate.disconnected(), "Only an established session disconnects once")
        print("Connection tone duration, endpoints and bounded amplitude passed")
    }
}
