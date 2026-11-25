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
    /// Read-only pinned-TLS check that the paired computer is awake, sharing, and has a free slot.
    /// Does not start computer capture or touch iOS AVAudioSession.
    static func probeAvailable(_ computer: PairedMac, hostOverride: String? = nil, timeoutSeconds: Double = 2.5) async -> Bool {
        let targetHost = hostOverride ?? computer.host
        guard PairedMac.validHost(targetHost) else { return false }
        let direct = await probeEndpoint(.hostPort(host: .init(targetHost), port: 5002), pin: computer.pin, timeoutSeconds: timeoutSeconds)
        if direct || hostOverride != nil { return direct }
        // If DHCP moved the computer, look up its Bonjour service briefly before giving up.
        guard let bonjour = await discoverComputerEndpoint(pin: computer.pin, timeoutSeconds: 2.5) else { return false }
        return await probeEndpoint(bonjour, pin: computer.pin, timeoutSeconds: timeoutSeconds)
    }
    private static func probeEndpoint(_ endpoint: NWEndpoint, pin: String, timeoutSeconds: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "pairit.status.probe")
            let connection = NWConnection(to: endpoint, using: RelaySecurity.parameters(pin: pin, queue: queue))
            var finished = false
            var reply = Data()
            var timer: DispatchSourceTimer?
            let finish: (Bool) -> Void = { ok in
                guard !finished else { return }
                finished = true
                timer?.setEventHandler {}; timer?.cancel(); timer = nil
                connection.stateUpdateHandler = nil; connection.cancel()
                continuation.resume(returning: ok)
            }
            var receive: (() -> Void)!
            receive = {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, ended, error in
                    if let data { reply.append(data) }
                    guard reply.count <= 256 else { finish(false); return }
                    if let newline = reply.firstIndex(of: 10),
                       let line = String(data: reply.prefix(upTo: newline), encoding: .utf8),
                       line.hasPrefix("OK STATUS1 ") {
                        let rest = line.dropFirst(11)
                        let countStr = rest.split(separator: " ").first.map(String.init) ?? ""
                        let count = Int(countStr) ?? 4
                        finish(count >= 0 && count < 4)
                        return
                    }
                    if ended || error != nil { finish(false); return }
                    receive()
                }
            }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + timeoutSeconds)
            t.setEventHandler { finish(false) }
            timer = t; t.resume()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Data("STATUS1\n".utf8), completion: .contentProcessed { error in
                        if error != nil { finish(false) } else { receive() }
                    })
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }
    private static func discoverComputerEndpoint(pin: String, timeoutSeconds: Double) async -> NWEndpoint? {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "pairit.status.browse")
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_audiorelay._tcp", domain: nil), using: .tcp)
            var finished = false
            var timer: DispatchSourceTimer?
            let finish: (NWEndpoint?) -> Void = { endpoint in
                guard !finished else { return }
                finished = true
                timer?.setEventHandler {}; timer?.cancel(); timer = nil
                browser.browseResultsChangedHandler = nil
                browser.stateUpdateHandler = nil
                browser.cancel()
                continuation.resume(returning: endpoint)
            }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + timeoutSeconds)
            t.setEventHandler { finish(nil) }
            timer = t; t.resume()
            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard case .bonjour(let txt) = result.metadata,
                          txt["role"] == "computer", txt["pin"] == pin else { continue }
                    finish(result.endpoint)
                    return
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { finish(nil) }
            }
            browser.start(queue: queue)
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
