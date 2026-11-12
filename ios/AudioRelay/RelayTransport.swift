import Foundation
import Network
import Security
import CryptoKit
import AVFAudio

enum RelayClock {
    static var nanoseconds: Int64 { Int64(AVAudioTime.seconds(forHostTime: mach_absolute_time()) * 1e9) }
}

struct RelayPacket {
    let sequence: UInt32
    let rate: UInt32
    let frames: UInt32
    let capturedAt: Int64
    let pcm: Data
    let receivedAt = RelayClock.nanoseconds
    func localCaptureSeconds(clockOffset: Int64) -> Double {
        // A pinned but faulty peer can still supply extreme timestamps. Convert
        // before adding so playback's age check can reject them without a trap.
        (Double(capturedAt) + Double(clockOffset)) / 1e9
    }
}

/// All mutable transport and playback scheduling state runs on the supplied queue.
/// The TLS peer is the paired computer; there is no Internet audio service.
final class RelayTransport {
    private let queue: DispatchQueue
    private let mac: PairedMac
    private let hostOverride: String?
    private let port: NWEndpoint.Port
    private var connection: NWConnection?
    private var browser: NWBrowser?
    private var discovered: NWEndpoint?
    private var timer: DispatchSourceTimer?
    private var bytes = Data()
    private var running = false
    private var retry = 0, pingCount = 0
    private var retryTicket = 0
    private var lastReceived = RelayClock.nanoseconds
    private var bestRTT = Int64.max, clockWindow: Int64 = 0
    private(set) var clockOffset: Int64 = 0
    private(set) var clockSamples = 0
    private(set) var connections = 0
    private var compensation: Int?
    private var intent = "RESUME", intentToken: UInt32 = 1, sentToken: UInt32 = 0
    private var controlStatus: UInt32 = 0
    private var capabilitiesKnown = false
    private var requestedComputerOutput: Bool?
    private var outputRequestPing: Int64?
    var pendingComputerOutput: Bool? { requestedComputerOutput }
    var onHandoff: ((UInt32) -> Void)?
    var onOutput: ((_ supported: Bool, _ computer: Bool) -> Void)?
    var onPacket: ((RelayPacket, Int64) -> Void)?
    var onState: ((String) -> Void)?
    var onReset: (() -> Void)?
    var diagnostics: () -> String = { "" }
    var roundTripMs: Double { bestRTT == .max ? 0 : Double(bestRTT) / 1e6 }

    init(mac: PairedMac, queue: DispatchQueue, hostOverride: String? = nil, port: UInt16 = 5002) {
        self.mac = mac; self.queue = queue; self.hostOverride = hostOverride
        self.port = NWEndpoint.Port(rawValue: port) ?? 5002
    }
    func start() {
        if running && connection != nil { return }
        running = true
        let browser = NWBrowser(for: .bonjour(type: "_audiorelay._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.discovered = results.first(where: { result in
                if case .service(let name, _, _, _) = result.endpoint { return name == "AudioRelay-" + self.mac.pin.prefix(8) }
                return false
            })?.endpoint
        }
        if hostOverride == nil { self.browser = browser; browser.start(queue: queue) }
        connect()
    }
    func stop() {
        requestedComputerOutput = nil; outputRequestPing = nil
        guard connection != nil else { suspend(); return }
        setIntent("RELEASE")
        // Keep this transport alive for its correlated release ACK. A lost
        // connection deliberately leaves a desktop hold, never a speaker burst.
        let ticket = intentToken
        queue.asyncAfter(deadline: .now() + 2) { [self] in
            if intent == "RELEASE", intentToken == ticket { suspend() }
        }
    }
    func suspend() {
        running = false; retryTicket += 1
        timer?.cancel(); timer = nil; browser?.cancel(); browser = nil
        let old = connection; connection = nil; old?.cancel(); bytes.removeAll()
    }
    func park(_ reason: String) { setIntent(reason) }
    func resume() {
        setIntent("RESUME")
        // Playback may have been rebuilt while this control socket remained
        // connected. Reapply the current destination even when its bits did not change.
        if capabilitiesKnown, connection?.state == .ready {
            onOutput?(controlStatus & 128 != 0, controlStatus & 192 == 192)
        }
        if connection == nil { start() }
    }
    func requestOutput(computer: Bool) {
        requestedComputerOutput = computer; outputRequestPing = nil
        sendOutputRequest()
    }
    private func sendOutputRequest() {
        guard capabilitiesKnown, connection?.state == .ready, outputRequestPing == nil, let computer = requestedComputerOutput else { return }
        guard controlStatus & 128 != 0 else {
            // Legacy companions already stream to phones. An unfulfilled
            // Computer choice must continue suppressing local playback.
            if !computer { requestedComputerOutput = nil }
            return
        }
        let ping = RelayClock.nanoseconds; outputRequestPing = ping
        send("OUTPUT " + (computer ? "COMPUTER" : "PHONE") + "\n")
        send("PING \(ping)\n")
    }
    private func setIntent(_ next: String) {
        guard next != intent else { return }
        intent = next; intentToken += 1
        sendIntent()
    }
    private func sendIntent() {
        guard capabilitiesKnown, sentToken != intentToken else { return }
        sentToken = intentToken
        if controlStatus & 1 == 0 { send(intent == "RELEASE" ? "ACTIVE 0\n" : "ACTIVE 1\n") }
        else {
            let command = ["RESUME", "RELEASE"].contains(intent) ? "\(intent) \(intentToken)" : "PARK \(intentToken) \(intent)"
            send(command + "\n")
        }
        send("PING \(RelayClock.nanoseconds)\n")
    }
    private func acceptControl(_ status: UInt32, echoedPing: UInt64) {
        let outputChanged = !capabilitiesKnown || (status & 192) != (controlStatus & 192)
        var outputAcknowledged = false
        if let requested = requestedComputerOutput, let ping = outputRequestPing,
           echoedPing == UInt64(ping), status & 128 != 0, (status & 64 != 0) == requested {
            requestedComputerOutput = nil; outputRequestPing = nil; outputAcknowledged = true
        }
        controlStatus = status; capabilitiesKnown = true; sendIntent(); sendOutputRequest()
        if outputChanged || outputAcknowledged { onOutput?(status & 128 != 0, status & 192 == 192) }
        if status >> 8 == intentToken {
            onHandoff?(status)
            if intent == "RELEASE", status & 32 != 0 { suspend() }
        }
    }
    func setCompensation(_ value: Int?) {
        guard value != compensation else { return }; compensation = value
        if let value { send("SYNC \(max(0, min(2000, value)))\n") }
    }
    private func connect() {
        guard running else { return }
        onState?(connections == 0 ? "Connecting to your computer" : "Reconnecting to your computer")
        clockSamples = 0; bestRTT = .max; clockWindow = 0; pingCount = 0; bytes.removeAll()
        capabilitiesKnown = false; controlStatus = 0; intentToken = 1; sentToken = 0
        outputRequestPing = nil // Retry an unacknowledged user choice on the new socket.
        let parameters = RelaySecurity.parameters(pin: mac.pin, queue: queue)
        let endpoint = hostOverride.map { NWEndpoint.hostPort(host: .init($0), port: port) } ?? discovered ?? .hostPort(host: .init(mac.host), port: port)
        let current = NWConnection(to: endpoint, using: parameters); connection = current
        current.stateUpdateHandler = { [weak self, weak current] state in
            guard let self, let current, self.connection === current, self.running else { return }
            switch state {
            case .ready:
                self.retry = 0; self.connections += 1; self.lastReceived = RelayClock.nanoseconds
                self.send(self.mac.token + "\nHELLO " + RelayInstallation.identifier + "\n")
                if let value = self.compensation { self.send("SYNC \(value)\n") }
                self.onState?("Getting audio ready"); self.startTimer(); self.receive(current)
            case .failed: self.reconnect()
            case .waiting: self.onState?("Waiting for your computer and local network")
            default: break
            }
        }
        current.start(queue: queue)
        let ticket = retryTicket
        queue.asyncAfter(deadline: .now() + 8) { [weak self, weak current] in
            guard let self, let current, self.running, self.retryTicket == ticket, self.connection === current else { return }
            if current.state != .ready { self.reconnect() }
        }
    }
    private func reconnect() {
        guard running, connection != nil else { return }
        if intent != "RESUME" {
            suspend(); onState?("Control connection ended. Resume in PairIt to reconnect."); return
        }
        let old = connection; connection = nil; old?.cancel(); timer?.cancel(); timer = nil
        bytes.removeAll(); onReset?(); onState?("Reconnecting to your computer")
        retry += 1; retryTicket += 1; let ticket = retryTicket
        queue.asyncAfter(deadline: .now() + min(4, 0.5 * Double(retry))) { [weak self] in
            guard let self, self.running, self.retryTicket == ticket else { return }; self.connect()
        }
    }
    private func startTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = RelayClock.nanoseconds
            if now - self.lastReceived > 8_000_000_000 { self.reconnect(); return }
            self.pingCount += 1
            if self.pingCount < 10 || self.pingCount % 4 == 0 {
                self.send("PING \(now)\n")
                if self.pingCount % 4 == 0 { self.send("STATS iPhone " + self.diagnostics().replacingOccurrences(of: "\n", with: " ") + "\n") }
            }
        }
        self.timer = timer; timer.resume()
    }
    private func send(_ text: String) {
        guard let current = connection else { return }
        current.send(content: Data(text.utf8), completion: .contentProcessed({ [weak self, weak current] error in
            guard let self, let current, self.connection === current else { return }
            if error != nil { self.reconnect() }
        }))
    }
    private func receive(_ current: NWConnection) {
        current.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak current] data, _, finished, error in
            guard let self, let current, self.connection === current, self.running else { return }
            if let data, !data.isEmpty {
                self.lastReceived = RelayClock.nanoseconds; self.bytes.append(data)
                guard self.parse() else { self.reconnect(); return }
            }
            if finished || error != nil { self.reconnect(); return }
            self.receive(current)
        }
    }
    private func parse() -> Bool {
        guard bytes.count <= 262144 else { return false }
        while bytes.count >= 24 {
            let magic: UInt32 = integer(at: 0)
            if magic == 0x31435342 {
                let status: UInt32 = integer(at: 4)
                let sent: UInt64 = integer(at: 8), server: UInt64 = integer(at: 16)
                let now = RelayClock.nanoseconds, roundTrip = now - Int64(clamping: sent)
                if roundTrip >= 0 && roundTrip <= 1_000_000_000 {
                    if now - clockWindow > 30_000_000_000 { bestRTT = .max; clockWindow = now }
                    if roundTrip < bestRTT { bestRTT = roundTrip; clockOffset = Int64(clamping: sent) + roundTrip / 2 - Int64(clamping: server) }
                    clockSamples += 1
                }
                bytes.removeFirst(24); acceptControl(status, echoedPing: sent); continue
            }
            guard magic == 0x31415342 else { return false }
            let sequence: UInt32 = integer(at: 4), rate: UInt32 = integer(at: 8), frames: UInt32 = integer(at: 12)
            let captured: UInt64 = integer(at: 16)
            if frames == 0 && captured == 0 && rate == 48000 { bytes.removeFirst(24); continue }
            guard (rate == 48000 || rate == 44100), frames > 0, frames <= 8192, captured <= UInt64(Int64.max) else { return false }
            let length = 24 + Int(frames) * 4
            guard bytes.count >= length else { return true }
            let pcm = Data(bytes.dropFirst(24).prefix(Int(frames) * 4)); bytes.removeFirst(length)
            if clockSamples >= 3, intent == "RESUME", capabilitiesKnown, requestedComputerOutput != true, controlStatus & 192 != 192,
               controlStatus & 1 == 0 || (controlStatus >> 8 == intentToken && controlStatus & 4 == 0) {
                onPacket?(RelayPacket(sequence: sequence, rate: rate, frames: frames, capturedAt: Int64(captured), pcm: pcm), clockOffset)
            }
        }
        return true
    }
    private func integer<T: FixedWidthInteger>(at offset: Int) -> T {
        bytes.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
}
