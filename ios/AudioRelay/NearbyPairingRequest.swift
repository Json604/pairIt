import Foundation
import Network
import CryptoKit
import Security

/// Discovery supplies a candidate only. The user must match the comparison code
/// and approve on the computer before this exchange returns pairing credentials.
final class NearbyPairingRequest {
    let comparison: String
    private let pin: String
    private let nonce: String
    private let queue = DispatchQueue(label: "pairit.nearby.pairing")
    private var connection: NWConnection?
    private var timeout: DispatchSourceTimer?
    private var completion: ((String?) -> Void)?
    private var cancelled = false
    private var reply = Data()

    init(pin: String) throws {
        guard pin.utf8.count == 64, pin.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw NSError(domain: "PairIt", code: 1)
        }
        self.pin = pin
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NSError(domain: "PairIt", code: 2)
        }
        nonce = bytes.map { String(format: "%02x", $0) }.joined()
        let digest = SHA256.hash(data: Data((pin + nonce).utf8)).map { String(format: "%02X", $0) }.joined()
        comparison = stride(from: 0, to: 16, by: 4).map { String(digest.dropFirst($0).prefix(4)) }.joined(separator: " ")
    }
    static func approvedToken(_ reply: Data) -> String? {
        guard reply.count == 77, let text = String(data: reply, encoding: .ascii),
              text.hasPrefix("OK REQUEST1 "), text.hasSuffix("\n") else { return nil }
        let token = String(text.dropFirst(12).dropLast())
        return token.count == 64 && token.allSatisfy { "0123456789abcdef".contains($0) } ? token : nil
    }
    func start(host: String, completion: @escaping (String?) -> Void) {
        queue.async { [self] in
            guard !cancelled, connection == nil, self.completion == nil else { return }
            self.completion = completion
            let timeout = DispatchSource.makeTimerSource(queue: queue)
            timeout.schedule(deadline: .now() + 45)
            timeout.setEventHandler { [self] in finish(nil) }
            self.timeout = timeout; timeout.resume()
            let current = NWConnection(host: .init(host), port: 5002, using: RelaySecurity.parameters(pin: pin, queue: queue))
            connection = current
            current.stateUpdateHandler = { [weak self, weak current] state in
                guard let self, let current, self.connection === current else { return }
                switch state {
                case .ready:
                    current.send(content: Data(("REQUEST1 " + self.nonce + "\n").utf8), completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        if error != nil { self.finish(nil) } else { self.receive() }
                    })
                case .failed, .cancelled: self.finish(nil)
                default: break
                }
            }
            current.start(queue: queue)
        }
    }
    func cancel() {
        queue.async { [self] in cancelled = true; completion = nil; finish(nil) }
    }
    private func receive() {
        guard let current = connection else { return }
        current.receive(minimumIncompleteLength: 1, maximumLength: 96) { [weak self, weak current] data, _, ended, error in
            guard let self, let current, self.connection === current else { return }
            if let data { self.reply.append(data) }
            if self.reply.count > 77 { self.finish(nil); return }
            if self.reply.contains(10) { self.finish(Self.approvedToken(self.reply)); return }
            if ended || error != nil { self.finish(nil); return }
            self.receive()
        }
    }
    private func finish(_ token: String?) {
        let complete = completion; completion = nil
        timeout?.setEventHandler {}; timeout?.cancel(); timeout = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        reply.removeAll()
        if let complete { DispatchQueue.main.async { complete(token) } }
    }
}
