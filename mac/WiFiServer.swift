import Foundation
import Network
import Security

/// TLS and discovery live in the app. No shell bridge or fixed interface binding.
final class WiFiServer {
    private let queue = DispatchQueue(label: "relay.wifi", qos: .userInitiated)
    private var listener: NWListener?
    private var peers: [UUID: WiFiPeer] = [:]
    private var config: [String: String] = [:]
    private var microphoneEnabled = false
    private var microphoneUID = ""
    private var microphoneGeneration = 0
    private var microphoneLease: UUID?
    private var stopped = false
    private let microphoneWork = DispatchQueue(label: "pairit.microphone.session", qos: .userInitiated)
    private let microphoneWorkers = DispatchGroup()
    private let port: UInt16
    private let upstreamPort: UInt16
    private let identityProvider: () throws -> LocalIdentity
    private let makeMicrophone: () -> MicrophoneSink
    var reserveMicrophone: () -> Bool = { false }
    var releaseMicrophone: () -> Void = {}
    var onMicrophoneStatus: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    init(port: UInt16 = 5002, upstreamPort: UInt16 = 5001,
         identityProvider: @escaping () throws -> LocalIdentity = { try LocalIdentity.load() },
         makeMicrophone: @escaping () -> MicrophoneSink = { MicrophoneOutput() }) {
        self.port = port; self.upstreamPort = upstreamPort
        self.identityProvider = identityProvider; self.makeMicrophone = makeMicrophone
    }
    var pairingCode: String {
        pairingCode(for: LocalIdentity.currentHost())
    }
    func pairingCode(for host: String) -> String {
        var pairing = config; pairing["host"] = host
        pairing["name"] = Host.current().localizedName ?? "Mac"
        pairing["platform"] = "macos"; pairing["protocol"] = "2"
        guard let data = try? JSONSerialization.data(withJSONObject: pairing) else { return "" }
        return "audiorelay://pair/" + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
    func start() throws {
        let identity = try identityProvider()
        config = identity.config; stopped = false
        let identityData = try Data(contentsOf: identity.directory.appendingPathComponent("identity.p12"))
        var items: CFArray?
        var options: [String: Any] = [kSecImportExportPassphrase as String: config["token"]!]
        if #available(macOS 15.0, *) { options[kSecImportToMemoryOnly as String] = true }
        let result = SecPKCS12Import(identityData as CFData, options as CFDictionary, &items)
        guard result == errSecSuccess, let imported = items as? [[String: Any]],
              let value = imported.first?[kSecImportItemIdentity as String] else {
            throw AudioFailure(description: "Could not load local TLS identity (\(result))")
        }
        let secIdentity = value as! SecIdentity
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(secIdentity)!)
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true; tcp.enableKeepalive = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(name: "AudioRelay-\(config["pin"]!.prefix(8))", type: "_audiorelay._tcp")
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.status("Ready for your phone")
            case .failed(let error): self?.status("Wi-Fi unavailable: \(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            // Pending authentication is separate from the four capture slots.
            guard let self, !self.stopped, self.peers.count < 12 else { connection.cancel(); return }
            let id = UUID()
            let peer = WiFiPeer(connection: connection, token: self.config["token"]!, queue: self.queue, upstreamPort: self.upstreamPort)
            peer.onAuthenticated = { [weak peer] in peer?.connectUpstream() }
            peer.onMicrophone = { [weak self] completion in
                guard let self else { completion(.failure("DISABLED")); return }
                self.beginMicrophone(completion: completion)
            }
            peer.onMicrophoneStarted = { [weak self] in self?.microphoneStatus("Phone microphone connected") }
            peer.onClose = { [weak self] in self?.peers.removeValue(forKey: id) }
            self.peers[id] = peer; peer.start()
        }
        self.listener = listener; listener.start(queue: queue)
    }
    private func status(_ message: String) { DispatchQueue.main.async { [weak self] in self?.onStatus?(message) } }
    private func microphoneStatus(_ message: String) { DispatchQueue.main.async { [weak self] in self?.onMicrophoneStatus?(message) } }
    private func beginMicrophone(completion: @escaping (MicrophoneAdmission) -> Void) {
        // Admission and revocation are serialized with authentication, not with CoreAudio.
        guard !stopped, microphoneEnabled else { completion(.failure("DISABLED")); return }
        guard microphoneLease == nil, reserveMicrophone() else { completion(.failure("BUSY")); return }
        let lease = UUID(), generation = microphoneGeneration, uid = microphoneUID
        microphoneLease = lease; microphoneWorkers.enter()
        let make = makeMicrophone, work = microphoneWork, callbacks = queue
        microphoneWork.async { [self] in
            let output = make()
            do {
                try output.start(uid: uid)
                let session = GatewayMicrophoneSession(sink: output, work: work, callbacks: callbacks) { [self] in
                    finishMicrophoneLease(lease)
                }
                callbacks.async { [self] in
                    guard !stopped, microphoneEnabled, microphoneGeneration == generation, microphoneLease == lease else {
                        session.close { completion(.failure("DISABLED")) }; return
                    }
                    completion(.success(session))
                }
            } catch {
                output.stop()
                callbacks.async { [self] in
                    finishMicrophoneLease(lease)
                    if !stopped && microphoneEnabled && microphoneGeneration == generation {
                        microphoneStatus("Choose an available virtual audio cable")
                    }
                    completion(.failure("OUTPUT"))
                }
            }
        }
    }
    private func finishMicrophoneLease(_ lease: UUID) {
        // Token validation prevents late cleanup from releasing a newer admission.
        if microphoneLease == lease {
            microphoneLease = nil; releaseMicrophone()
            microphoneStatus(microphoneEnabled && !stopped ? "Ready for phone microphone" : "Microphone input is off")
        }
        microphoneWorkers.leave()
    }
    func configureMicrophone(enabled: Bool, uid: String) {
        queue.async {
            self.microphoneGeneration += 1
            self.microphoneEnabled = enabled; self.microphoneUID = uid
            for peer in Array(self.peers.values) where peer.isMicrophone { peer.stop() }
            self.microphoneStatus(enabled ? "Ready for phone microphone" : "Microphone input is off")
        }
    }
    func stopMicrophones() {
        queue.async {
            self.microphoneGeneration += 1
            for peer in Array(self.peers.values) where peer.isMicrophone { peer.stop() }
        }
    }
    func stop() {
        queue.sync {
            stopped = true; microphoneEnabled = false; microphoneGeneration += 1
            listener?.cancel(); listener = nil
            for peer in Array(peers.values) { peer.stop() }
            peers.removeAll()
        }
        // Called from the app lifecycle worker. Keep the TLS queue free to finish
        // canceled admissions and only return after the old sink has actually stopped.
        microphoneWorkers.wait()
    }
}

private enum MicrophoneAdmission {
    case success(GatewayMicrophoneSession)
    case failure(String)
}

/// At most one accept operation is submitted by a peer. Close is serialized after
/// it, while the atomic cancellation flag prevents queued work from becoming audio.
private final class GatewayMicrophoneSession {
    private var sink: MicrophoneSink? // Created, used and released on the microphone work queue.
    private let work: DispatchQueue
    private let callbacks: DispatchQueue
    private let lock = NSLock()
    private var ending = false
    private var finished = false
    private var completions: [() -> Void] = [] // Owned only by the TLS callback queue.
    private var didStop: (() -> Void)?
    init(sink: MicrophoneSink, work: DispatchQueue, callbacks: DispatchQueue, didStop: @escaping () -> Void) {
        self.sink = sink; self.work = work; self.callbacks = callbacks; self.didStop = didStop
    }
    func accept(_ pcm: Data, frames: Int, sequence: UInt32, completion: @escaping (Bool) -> Void) {
        work.async { [self] in
            lock.lock(); let cancelled = ending; lock.unlock()
            var accepted = false
            if !cancelled, let sink { do { try sink.accept(pcm, frames: frames, sequence: sequence); accepted = true } catch {} }
            let result = accepted
            callbacks.async { completion(result) }
        }
    }
    func close(completion: @escaping () -> Void = {}) {
        if finished { completion(); return }
        completions.append(completion)
        lock.lock()
        guard !ending else { lock.unlock(); return }
        ending = true; lock.unlock()
        work.async { [self] in
            sink?.stop(); sink = nil
            callbacks.async { [self] in
                finished = true
                didStop?(); didStop = nil
                let waiting = completions; completions.removeAll()
                for completion in waiting { completion() }
            }
        }
    }
}

private final class WiFiPeer {
    let connection: NWConnection
    let token: String
    let queue: DispatchQueue
    let upstreamPort: UInt16
    var onAuthenticated: (() -> Void)?
    var onClose: (() -> Void)?
    var onMicrophone: ((@escaping (MicrophoneAdmission) -> Void) -> Void)?
    var onMicrophoneStarted: (() -> Void)?
    private var microphone: GatewayMicrophoneSession?
    private var microphonePending = false
    private var microphoneReadPending = false
    private(set) var isMicrophone = false
    private var upstream: NWConnection?
    private var prefix = Data()
    private var timer: DispatchSourceTimer?
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var closed = false
    private(set) var authenticated = false
    init(connection: NWConnection, token: String, queue: DispatchQueue, upstreamPort: UInt16) {
        self.connection = connection; self.token = token; self.queue = queue; self.upstreamPort = upstreamPort
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.readAuthentication()
            case .failed, .cancelled: self.stop()
            default: break
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if ProcessInfo.processInfo.systemUptime - self.lastActivity > (self.microphonePending ? 4 : self.isMicrophone ? 2 : self.authenticated ? 8 : 4) { self.stop() }
        }
        self.timer = timer; timer.resume()
        connection.start(queue: queue)
    }
    private func readAuthentication() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data { self.prefix.append(data) }
            guard error == nil, !complete, self.prefix.count <= 4096 else { self.stop(); return }
            if let newline = self.prefix.firstIndex(of: 10) {
                let line = self.prefix.prefix(upTo: newline)
                let suffix = Data(" MIC1".utf8)
                let mic = line.suffix(suffix.count) == suffix
                let supplied = mic ? line.dropLast(suffix.count) : line
                let expected = Data(self.token.utf8)
                var difference = UInt8(supplied.count == expected.count ? 0 : 1)
                if supplied.count == expected.count { for (a, b) in zip(supplied, expected) { difference |= a ^ b } }
                guard difference == 0 else { self.stop(); return }
                self.prefix.removeSubrange(...newline)
                self.authenticated = true; self.lastActivity = ProcessInfo.processInfo.systemUptime
                if mic {
                    guard self.prefix.isEmpty else { self.stop(); return }
                    self.isMicrophone = true; self.microphonePending = true
                    // Keep an EOF watcher while CoreAudio opens. No client PCM is
                    // permitted before ACK; after ACK this same read becomes the first frame read.
                    self.readMicrophone(maximum: 1)
                    self.timer?.schedule(deadline: .now() + 4, repeating: 1)
                    guard let admit = self.onMicrophone else { self.stop(); return }
                    admit { [weak self] admission in
                        switch admission {
                        case .success(let session):
                            guard let self, !self.closed else { session.close(); return }
                            self.microphone = session; self.microphonePending = false
                            self.lastActivity = ProcessInfo.processInfo.systemUptime
                            self.timer?.schedule(deadline: .now() + 1, repeating: 1)
                            self.onMicrophoneStarted?()
                            self.connection.send(content: Data("OK MIC1 48000\n".utf8), completion: .contentProcessed { [weak self] error in
                                guard let self, !self.closed else { return }
                                if error != nil { self.stop() } else { self.readMicrophone() }
                            })
                        case .failure(let reason):
                            guard let self, !self.closed else { return }
                            self.microphonePending = false; self.isMicrophone = false
                            self.connection.send(content: Data("ERR \(reason)\n".utf8), completion: .contentProcessed { [weak self] _ in self?.stop() })
                        }
                    }
                } else { self.onAuthenticated?() }
            } else { self.readAuthentication() }
        }
    }
    private func readMicrophone(maximum: Int = 16) {
        guard !closed, !microphoneReadPending else { return }
        microphoneReadPending = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            self.microphoneReadPending = false
            if self.microphonePending { self.stop(); return }
            if let data { self.prefix.append(data) }
            guard error == nil, !complete, self.prefix.count <= 1936 else { self.stop(); return }
            self.processMicrophone()
        }
    }
    private func processMicrophone() {
        guard !closed, let microphone else { return }
        guard prefix.count >= 16 else { readMicrophone(maximum: 16 - prefix.count); return }
        let header: (UInt32, UInt32, UInt32, UInt32) = prefix.withUnsafeBytes { raw in
            (UInt32(littleEndian: raw.loadUnaligned(as: UInt32.self)),
             UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)),
             UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self)),
             UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self)))
        }
        guard header.0 == 0x314d5342, header.2 == 48000, header.3 <= 960 else { stop(); return }
        let length = 16 + Int(header.3) * 2
        guard prefix.count >= length else { readMicrophone(maximum: length - prefix.count); return }
        lastActivity = ProcessInfo.processInfo.systemUptime
        if header.3 == 0 {
            prefix.removeAll()
            microphone.close { [weak self] in
                guard let self, !self.closed else { return }
                self.microphone = nil; self.isMicrophone = false
                self.connection.send(content: Data("STOPPED\n".utf8), completion: .contentProcessed { [weak self] _ in self?.stop() })
            }
            return
        }
        let pcm = Data(prefix.dropFirst(16).prefix(Int(header.3) * 2))
        prefix.removeFirst(length)
        // Do not read or enqueue another packet until the sink operation completes.
        // A slow endpoint applies TCP backpressure; it cannot grow an async work queue.
        microphone.accept(pcm, frames: Int(header.3), sequence: header.1) { [weak self] accepted in
            guard let self, !self.closed else { return }
            if accepted { self.processMicrophone() } else { self.stop() }
        }
    }
    func connectUpstream() {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let upstream = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: upstreamPort)!, using: NWParameters(tls: nil, tcp: tcp))
        self.upstream = upstream
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if !self.prefix.isEmpty {
                    upstream.send(content: self.prefix, completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        if error != nil { self.stop() } else { self.pipe(self.connection, to: upstream, control: true) }
                    })
                    self.prefix.removeAll()
                } else { self.pipe(self.connection, to: upstream, control: true) }
                self.pipe(upstream, to: self.connection, control: false)
            case .failed, .cancelled: self.stop()
            default: break
            }
        }
        upstream.start(queue: queue)
    }
    private func pipe(_ source: NWConnection, to destination: NWConnection, control: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: control ? 4096 : 16384) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            guard error == nil, !complete, let data, !data.isEmpty else { self.stop(); return }
            if control { self.lastActivity = ProcessInfo.processInfo.systemUptime }
            // One outstanding send per direction: network backpressure is bounded.
            destination.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { self.stop() } else { self.pipe(source, to: destination, control: control) }
            })
        }
    }
    func stop() {
        guard !closed else { return }; closed = true
        timer?.cancel(); timer = nil
        microphone?.close(); microphone = nil
        isMicrophone = false
        connection.cancel(); upstream?.cancel(); upstream = nil
        onClose?(); onClose = nil; onAuthenticated = nil; onMicrophone = nil; onMicrophoneStarted = nil
    }
}
