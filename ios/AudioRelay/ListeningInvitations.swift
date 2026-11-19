import Foundation
import Network
import Combine

/// Foreground-only. Discovery carries no credentials; both users approve a matching transcript.
final class ListeningInvitations: ObservableObject {
    struct Prompt: Identifiable { let id = UUID(); let title: String; let comparison: String; let hosting: Bool }
    @Published var prompt: Prompt?
    @Published private(set) var notice = ""
    @Published private(set) var busy = false
    var received: ((String) -> Void)?
    /// A paired computer asks this phone to connect (CONNECT1 <pin>). The hint carries no
    /// credentials; the phone confirms it over the pinned channel before doing anything.
    var connectRequest: ((_ pin: String, _ host: String) -> Void)?
    private var lastConnectRequest = Date.distantPast
    var canHost: () -> Bool = { true }
    private var listener: NWListener?
    private var exchange: InvitationExchange?
    private var lastIncoming = Date.distantPast
    func start(ready: @escaping (Int) -> Void) {
        guard listener == nil else { return }
        do {
            let current = try NWListener(using: .tcp, on: .any); listener = current
            current.stateUpdateHandler = { [weak self, weak current] state in
                guard let self, let current, self.listener === current else { return }
                if case .ready = state { ready(Int(current.port?.rawValue ?? 0)) }
                if case .failed = state { self.notice = "Invitations unavailable. Reopen Together to retry." }
            }
            current.newConnectionHandler = { [weak self, weak current] connection in
                guard let self else { connection.cancel(); return }
                FirstLine.read(connection) { [weak self, weak current] first in
                    guard let self, let current, self.listener === current, let first else { connection.cancel(); return }
                    if let line = String(data: first.prefix(while: { $0 != 10 }), encoding: .ascii), line.hasPrefix("CONNECT1 ") {
                        let pin = String(line.dropFirst(9)), host = FirstLine.host(connection)
                        connection.cancel()
                        guard pin.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, let host,
                              Date().timeIntervalSince(self.lastConnectRequest) >= 2 else { return }
                        self.lastConnectRequest = Date(); self.connectRequest?(pin, host); return
                    }
                    guard !self.busy, Date().timeIntervalSince(self.lastIncoming) >= 3 else { connection.cancel(); return }
                    self.lastIncoming = Date(); self.begin(connection, code: nil, computer: nil, received: first)
                }
            }
            current.start(queue: .main)
        } catch { notice = "Invitations unavailable. Reopen Together to retry." }
    }
    func invite(_ phone: NearbyDevices.Device, code: String, computer: String) {
        guard !busy else { notice = "Finish the current invitation first."; return }
        guard let host = phone.host, let port = NWEndpoint.Port(rawValue: UInt16(clamping: phone.invitationPort)), phone.invitationPort > 0 else {
            notice = "Update PairIt on that phone to receive invitations."; return
        }
        begin(NWConnection(host: .init(host), port: port, using: .tcp), code: code, computer: computer)
    }
    private func begin(_ connection: NWConnection, code: String?, computer: String?, received: Data? = nil) {
        notice = code == nil ? "Invitation received. Compare the code with your host." : "Inviting listener… Keep PairIt open on both phones."; busy = true
        let session = InvitationExchange(connection: connection, code: code, computer: computer, received: received)
        exchange = session
        session.canHost = { [weak self] in self?.canHost() == true }
        session.ask = { [weak self, weak session] title, comparison in
            guard let self, self.exchange === session else { return }
            self.prompt = Prompt(title: title, comparison: comparison, hosting: code != nil)
        }
        session.finish = { [weak self, weak session] code, message in
            guard let self, self.exchange === session else { return }
            self.exchange = nil; self.busy = false; self.prompt = nil; self.notice = message
            if let code { self.received?(code) }
        }
        session.start()
    }
    func answer(_ accept: Bool) { prompt = nil; exchange?.answer(accept) }
    func stop() {
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil; listener?.cancel(); listener = nil
        exchange?.cancel(); exchange = nil; prompt = nil; busy = false
    }
    func message(_ text: String) { notice = text }
    static func hostProblem(connected: Bool, phoneOutput: Bool, available: Bool) -> String {
        if !connected { return "Connect this phone to a computer first, then invite a listener. Or keep Together open to join a friend’s invitation." }
        if !phoneOutput { return "Choose This phone on Connect before inviting a listener." }
        if !available { return "Choose an available audio output on this phone before inviting." }
        return ""
    }
}

/// Reads an incoming connection's first line (3 s, at most 1024 bytes) on the main queue.
/// Returns every byte received so far (the line and anything after it), or nil.
private enum FirstLine {
    static func read(_ connection: NWConnection, completion: @escaping (Data?) -> Void) {
        var buffer = Data(), done = false
        func finish(_ value: Data?) {
            guard !done else { return }; done = true
            connection.stateUpdateHandler = nil; completion(value)
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1025 - buffer.count) { data, _, complete, error in
                guard !done else { return }
                if let data { buffer.append(data) }
                if let newline = buffer.firstIndex(of: 10) { finish(newline <= 1024 ? buffer : nil); return }
                if buffer.count > 1024 || complete || error != nil { finish(nil); return }
                receive()
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: receive()
            case .failed, .cancelled: finish(nil)
            default: break
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if !done { finish(nil); connection.cancel() } }
        connection.start(queue: .main)
    }
    static func host(_ connection: NWConnection) -> String? {
        guard case .hostPort(let host, _) = connection.endpoint else { return nil }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }
}

private final class InvitationExchange {
    var ask: ((String, String) -> Void)?
    var canHost: () -> Bool = { true }
    var finish: ((String?, String) -> Void)?
    private let connection: NWConnection
    private let code: String?
    private let computer: String?
    private var crypto = InvitationCrypto()
    private var pending = Data()
    private var deadline: DispatchWorkItem?
    private var waiting: ((Bool) -> Void)?
    private var ended = false
    /// `received`: bytes already read (the first line) from an incoming, started connection.
    private let started: Bool
    init(connection: NWConnection, code: String?, computer: String?, received: Data? = nil) {
        self.connection = connection; self.code = code; self.computer = computer
        started = received != nil; pending = received ?? Data()
    }
    func start() {
        let timeout = DispatchWorkItem { [weak self] in self?.end(nil, "Invitation expired. Keep PairIt open on both phones and try again.") }
        deadline = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 65, execute: timeout)
        if started {
            // The listener already read the first line; continue the existing exchange.
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, !self.ended else { return }
                if case .failed = state { self.end(nil, "Couldn’t reach that phone. Keep PairIt open on both phones.") }
                if case .cancelled = state { self.end(nil, "Couldn’t reach that phone. Keep PairIt open on both phones.") }
            }
            receiveOffer(); return
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.ended else { return }
            switch state {
            case .ready:
                if self.code != nil {
                    let name = Data((self.computer ?? "Computer").utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                    self.send("INVITE1 " + InvitationCrypto.hex(self.crypto.publicKey) + " " + name) { self.senderReady() }
                } else { self.receiveOffer() }
            case .failed, .cancelled: self.end(nil, "Couldn’t reach that phone. Keep PairIt open on both phones.")
            default: break
            }
        }
        connection.start(queue: .main)
    }
    func answer(_ accepted: Bool) { let reply = waiting; waiting = nil; reply?(accepted) }
    private func approve(_ title: String, completion: @escaping (Bool) -> Void) { waiting = completion; ask?(title, crypto.comparison) }
    private func senderReady() {
        read(limit: 160) { line in
            guard line.hasPrefix("READY1 ") else { throw InvitationError.invalid }
            try self.crypto.agree(InvitationCrypto.unhex(String(line.dropFirst(7))), sender: true)
            self.approve("Host listening on " + (self.computer ?? "Computer")) { accepted in
                guard accepted else { self.end(nil, "Invitation declined."); return }
                self.read(limit: 16) { line in
                    guard line == "ACCEPT1", let code = self.code else { throw InvitationError.invalid }
                    guard self.canHost() else { self.end(nil, "Computer disconnected. Connect again before inviting."); return }
                    let encrypted = try self.crypto.seal(Data(code.utf8))
                    self.send("CODE1 " + InvitationCrypto.hex(encrypted)) {
                        self.read(limit: 16) { line in
                            guard line == "RECEIVED1" else { throw InvitationError.invalid }
                            self.end(nil, "Invitation accepted. Your guest is connecting to the computer.")
                        }
                    }
                }
            }
        }
    }
    private func receiveOffer() {
        read(limit: 1024) { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "INVITE1",
                  let nameData = Data(base64Encoded: String(parts[2]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")),
                  let name = String(data: nameData, encoding: .utf8), !name.isEmpty, name.count <= 80,
                  name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw InvitationError.invalid }
            try self.crypto.agree(InvitationCrypto.unhex(String(parts[1])), sender: false)
            self.send("READY1 " + InvitationCrypto.hex(self.crypto.publicKey)) {
                self.approve("Join listening on " + name + "?") { accepted in
                    guard accepted else { self.end(nil, "Invitation declined."); return }
                    self.send("ACCEPT1") {
                        self.read(limit: 16390) { line in
                            guard line.hasPrefix("CODE1 "), let code = String(data: try self.crypto.open(InvitationCrypto.unhex(String(line.dropFirst(6)))), encoding: .utf8) else { throw InvitationError.invalid }
                            _ = try PairedMac.parse(code)
                            self.send("RECEIVED1") { self.end(code, "") }
                        }
                    }
                }
            }
        }
    }
    private func send(_ line: String, next: @escaping () -> Void) {
        guard !ended else { return }
        connection.send(content: Data((line + "\n").utf8), completion: .contentProcessed { [weak self] error in
            guard let self, !self.ended else { return }
            if error != nil { self.end(nil, "Invitation interrupted. Try again.") } else { next() }
        })
    }
    private func read(limit: Int, completion: @escaping (String) throws -> Void) {
        guard !ended else { return }
        if let newline = pending.firstIndex(of: 10) {
            guard newline <= limit, let line = String(data: pending.prefix(upTo: newline), encoding: .ascii) else { end(nil, "Invalid invitation."); return }
            pending.removeSubrange(...newline)
            do { try completion(line) } catch { end(nil, "Invalid invitation. Try again.") }; return
        }
        guard pending.count <= limit else { end(nil, "Invalid invitation."); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(4096, limit + 1 - pending.count)) { [weak self] data, _, complete, error in
            guard let self, !self.ended else { return }
            if let data { self.pending.append(data) }
            if self.pending.contains(10) { self.read(limit: limit, completion: completion) }
            else if complete || error != nil { self.end(nil, "Invitation declined or interrupted.") }
            else { self.read(limit: limit, completion: completion) }
        }
    }
    private func end(_ code: String?, _ message: String) {
        guard !ended else { return }; ended = true
        deadline?.cancel(); deadline = nil; waiting = nil; ask = nil
        connection.stateUpdateHandler = nil; connection.cancel(); pending.removeAll()
        let callback = finish; finish = nil; callback?(code, message)
    }
    func cancel() { finish = nil; end(nil, "") }
}
