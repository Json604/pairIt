import Foundation
import Network

/// A short authenticated exchange that cannot request or start audio capture.
final class PairingConfirmation {
    private let computer: PairedMac
    private let host: String
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "pairit.pairing.confirmation")
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var reply = Data()
    private var completion: ((Bool) -> Void)?
    private let request: String
    private let expected: Data

    init(computer: PairedMac, hostOverride: String? = nil, port: UInt16 = 5002, request: String = " PAIR1", expected: String = "OK PAIR1") {
        self.computer = computer; host = hostOverride ?? computer.host
        self.port = NWEndpoint.Port(rawValue: port) ?? 5002
        self.request = request; self.expected = Data((expected + "\n").utf8)
    }
    /// Confirms a computer's CONNECT1 hint: only the computer holding this pairing (pinned
    /// TLS and token) can say it asked this installation to connect.
    static func confirmConnectRequest(_ computer: PairedMac, host: String, installation: String) async -> Bool {
        guard installation.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil, PairedMac.validHost(host) else { return false }
        return await withCheckedContinuation { continuation in
            let probe = PairingConfirmation(computer: computer, hostOverride: host, request: " WANT1 " + installation, expected: "OK WANT1")
            probe.start { continuation.resume(returning: $0) }
        }
    }
    static func confirm(_ computer: PairedMac, hostOverride: String? = nil) async -> Bool {
        await withCheckedContinuation { continuation in
            let probe = PairingConfirmation(computer: computer, hostOverride: hostOverride)
            probe.start { continuation.resume(returning: $0) }
        }
    }
    func start(completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            guard connection == nil, timer == nil else { completion(false); return }
            self.completion = completion
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 4)
            // Retain this one-shot probe until its bounded completion, including
            // when the pairing sheet is dismissed before the network replies.
            timer.setEventHandler { [self] in finish(false) }
            self.timer = timer; timer.resume()
            let current = NWConnection(host: .init(host), port: port,
                                       using: RelaySecurity.parameters(pin: computer.pin, queue: queue))
            connection = current
            current.stateUpdateHandler = { [weak self, weak current] state in
                guard let self, let current, self.connection === current else { return }
                switch state {
                case .ready:
                    current.send(content: Data((self.computer.token + self.request + "\n").utf8), completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        if error != nil { self.finish(false) } else { self.receive() }
                    })
                case .failed, .cancelled: self.finish(false)
                default: break
                }
            }
            current.start(queue: queue)
        }
    }
    private func receive() {
        guard let current = connection else { return }
        current.receive(minimumIncompleteLength: 1, maximumLength: 64) { [weak self, weak current] data, _, ended, error in
            guard let self, let current, self.connection === current else { return }
            if let data { self.reply.append(data) }
            guard self.reply.count <= 64 else { self.finish(false); return }
            if self.reply.contains(10) { self.finish(self.reply == self.expected); return }
            if ended || error != nil { self.finish(false); return }
            self.receive()
        }
    }
    private func finish(_ confirmed: Bool) {
        guard let complete = completion else { return }
        completion = nil
        timer?.setEventHandler {}; timer?.cancel(); timer = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        reply.removeAll(); complete(confirmed)
    }
}
