// Actual iPhone network transport on macOS, generated PCM only. No audio engine.
import Foundation
import Darwin

enum RelayInstallation { static let identifier = String(repeating: "a", count: 32) }
enum RelayPlaybackMode { case reliable, interactive }

@main struct ReceiverHandoffHarness {
    static func main() throws {
        let boundaryPacket = RelayPacket(sequence: 0, rate: 48000, frames: 1, capturedAt: .max, pcm: Data(count: 4))
        precondition(boundaryPacket.localCaptureSeconds(clockOffset: 1).isFinite,
                     "Untrusted timestamp adjustment must not overflow before stale-packet rejection")
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let mac = try JSONDecoder().decode(PairedMac.self, from: JSONSerialization.data(withJSONObject: config["computer"]!))
        if config["pairingProbe"] as? Bool == true {
            let done = DispatchSemaphore(value: 0)
            let probe = PairingConfirmation(computer: mac, hostOverride: "127.0.0.1", port: UInt16(config["port"] as! Int))
            probe.start { confirmed in
                print(confirmed ? "{\"confirmed\":true}" : "{\"confirmed\":false}")
                done.signal()
            }
            guard done.wait(timeout: .now() + 6) == .success else { exit(2) }
            return
        }
        let queue = DispatchQueue(label: "pairit.synthetic.receiver")
        let transport = RelayTransport(mac: mac, queue: queue, hostOverride: "127.0.0.1", port: UInt16(config["port"] as! Int))
        let done = DispatchSemaphore(value: 0)
        var packets = 0, atPark = 0, atResume = 0, parkAcks = 0, violations = 0
        let modern = config["modern"] as! Bool
        let outputCase = config["outputCase"] as? Bool ?? false
        let resumeCase = config["resumeCase"] as? Bool ?? false
        let lostAckCase = config["lostAckCase"] as? Bool ?? false
        var computerOutput = false, outputSupported = false, atComputer = 0, outputEvents = 0
        queue.async {
            transport.onPacket = { _, _ in packets += 1 }
            transport.onHandoff = { value in if value & 4 != 0 { parkAcks += 1 } }
            transport.onOutput = { supported, computer in
                outputEvents += 1
                outputSupported = supported; computerOutput = computer
                if computer { atComputer = packets }
            }
            transport.start()
        }
        if resumeCase || lostAckCase {
            var atChoice = 0
            if lostAckCase {
                queue.asyncAfter(deadline: .now() + 0.6) { atChoice = packets; transport.requestOutput(computer: true) }
            } else {
                queue.asyncAfter(deadline: .now() + 0.6) { transport.park("PHONE") }
                queue.asyncAfter(deadline: .now() + 0.8) { transport.suspend() }
                queue.asyncAfter(deadline: .now() + 1) {
                    transport.requestOutput(computer: false)
                    transport.resume()
                }
            }
            queue.asyncAfter(deadline: .now() + 2) {
                if computerOutput != lostAckCase || packets == 0 || transport.connections != 2 { violations += 1 }
                if lostAckCase && packets != atChoice { violations += 1 }
                if transport.pendingComputerOutput != nil { violations += 1 }
                transport.stop()
            }
            queue.asyncAfter(deadline: .now() + 4.2) {
                transport.suspend()
                print("{\"violations\":\(violations),\"connections\":\(transport.connections),\"packets\":\(packets)}")
                done.signal()
            }
            guard done.wait(timeout: .now() + 6) == .success else { exit(2) }
            if violations != 0 { exit(1) }
            return
        }
        if outputCase {
            queue.asyncAfter(deadline: .now() + 0.7) { transport.requestOutput(computer: true) }
            queue.asyncAfter(deadline: .now() + 1.1) {
                if modern && (!outputSupported || !computerOutput || packets != atComputer || packets == 0) { violations += 1 }
                if !modern && (outputSupported || computerOutput || packets == 0) { violations += 1 }
                atResume = packets; transport.requestOutput(computer: false)
            }
            queue.asyncAfter(deadline: .now() + 1.5) {
                if computerOutput || packets <= atResume { violations += 1 }
            }
        }
        queue.asyncAfter(deadline: .now() + 1.3) { atPark = packets; transport.park("PHONE") }
        queue.asyncAfter(deadline: .now() + 2) {
            if packets != atPark || packets == 0 { violations += 1 }
            atResume = packets; transport.resume()
        }
        queue.asyncAfter(deadline: .now() + 2.8) {
            if packets <= atResume { violations += 1 }
            atPark = packets; transport.park("OUTPUT")
        }
        if outputCase {
            queue.asyncAfter(deadline: .now() + 2.9) { transport.requestOutput(computer: true) }
            queue.asyncAfter(deadline: .now() + 3) { transport.requestOutput(computer: false) }
            queue.asyncAfter(deadline: .now() + 3.15) { if packets != atPark { violations += 1 } }
        }
        queue.asyncAfter(deadline: .now() + 3.2) { transport.stop() }
        queue.asyncAfter(deadline: .now() + 5.4) {
            transport.suspend()
            if modern && parkAcks < 2 { violations += 1 }
            if transport.connections != 1 { violations += 1 }
            if outputEvents < 2 { violations += 1 } // A newly prepared listener gets the current output on resume.
            let report: [String: Any] = ["packets": packets, "park_acknowledgments": parkAcks, "violations": violations, "connections": transport.connections]
            print(String(data: try! JSONSerialization.data(withJSONObject: report), encoding: .utf8)!)
            done.signal()
        }
        guard done.wait(timeout: .now() + 7) == .success else { exit(2) }
        if violations != 0 { exit(1) }
    }
}
