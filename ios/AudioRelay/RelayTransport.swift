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
    private let useBluetooth: Bool
    private var bluetoothLink: BluetoothRelayLink?
    private var rejectedBluetoothPeripherals = Set<UUID>()
    private var currentBluetoothPeripheral: UUID?
    private var connection: NWConnection?
    private var browser: NWBrowser?
    private var pathMonitor: NWPathMonitor?
    private var discovered: NWEndpoint?
    private var timer: DispatchSourceTimer?
    private var healthTimer: DispatchSourceTimer?
    private var lastTrafficAt = RelayClock.nanoseconds
    var onUnavailable: (() -> Void)?
    var onGroupFull: (() -> Void)?
    private func watchConnection() {
        healthTimer?.cancel()
        lastTrafficAt = RelayClock.nanoseconds
        let health = DispatchSource.makeTimerSource(queue: queue)
        health.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        health.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            if self.intent != "RESUME" || self.controlStatus & 192 == 192 { self.lastTrafficAt = RelayClock.nanoseconds; return }
            if RelayClock.nanoseconds - self.lastTrafficAt >= 15_000_000_000 {
                self.lastTrafficAt = RelayClock.nanoseconds
                self.reconnect()
            }
        }
        healthTimer = health; health.resume()
    }
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
    private var alignmentReport = "STATS ALIGN1 320 -1\n"
    var onPresentationTarget: ((Int, Int, Int) -> Void)?
    func setOutputTiming(minimum: Int, output: Int?) {
        guard (1...320).contains(minimum), output == nil || (0...1000).contains(output!) else { return }
        let report = "STATS ALIGN1 \(minimum) \(output ?? -1)\n"
        guard report != alignmentReport else { return }
        alignmentReport = report; send(report)
    }
    private var intent = "RESUME", intentToken: UInt32 = 1, sentToken: UInt32 = 0
    private var controlStatus: UInt32 = 0
    private var acknowledgedConnection = 0
    /// Called only after authenticated audio has actually started, on the transport queue.
    func claimConnectionFeedback() -> Bool {
        guard connections > 0, acknowledgedConnection != connections else { return false }
        acknowledgedConnection = connections; return true
    }
    private var capabilitiesKnown = false
    private var requestedComputerOutput: Bool?
    private var outputRequestPing: Int64?
    var pendingComputerOutput: Bool? { requestedComputerOutput }
    private var offeredToken: UInt32 = 0
    var onComputerVolume: ((ComputerVolume) -> Void)?
    var onDesktopPlayback: ((Bool) -> Void)?
    /// The computer ended this phone's session (bit 64, only after STATS CONTROLS2).
    var onDesktopDisconnect: (() -> Void)?
    /// A computer volume key or slider asks for this phone's own media volume, 0...1000.
    var onPhoneVolumeRequest: ((Int) -> Void)?
    private var desktopStatus: UInt32 = 0
    private var consumedDesktopRequest: UInt32 = 0
    enum DesktopRequest: Equatable { case pause, resume, disconnect }
    /// Each request is consumed once per intent token, like the Android receiver.
    func claimDesktopCommand(_ status: UInt32) -> DesktopRequest? {
        guard intent != "RELEASE", status >> 8 == intentToken, status & 2 != 0 else { return nil }
        let key = status & 0xFFFFFF52
        guard key != consumedDesktopRequest else { return nil }
        desktopStatus = status
        consumedDesktopRequest = key
        return status & 64 != 0 ? .disconnect : status & 16 != 0 ? .resume : .pause
    }
    func claimDesktopRequest(_ status: UInt32) -> Bool? {
        switch claimDesktopCommand(status) { case .resume: return true; case .pause: return false; default: return nil }
    }
    /// Every authenticated control status (bit 2: the computer may control its media player).
    var onControlStatus: ((UInt32) -> Void)?
    /// Earphone next/previous. Updated Macs skip tracks; Windows/Linux ignore STATS lines.
    func sendMediaKey(next: Bool) { sendMediaCommand(next ? "NEXT" : "PREVIOUS") }
    /// NEXT, PREVIOUS or PLAY (start the computer's paused player while this phone listens).
    func sendMediaCommand(_ name: String) {
        guard ["NEXT", "PREVIOUS", "PLAY"].contains(name), connection?.state == .ready, capabilitiesKnown else { return }
        send("STATS MEDIA1 " + name + "\n")
    }
    /// Computer player state after STATS PLAYER1: true while the computer produces sound.
    var onPlayerState: ((Bool) -> Void)?
    private var phoneVolume: Int?, sentPhoneVolume: Int?
    /// Reports this phone's media volume (0...1000) so the computer's controls stay in step.
    func setPhoneVolume(_ level: Int) {
        phoneVolume = max(0, min(1000, level)); sendPhoneVolume()
    }
    private func sendPhoneVolume() {
        guard let level = phoneVolume, level != sentPhoneVolume, connection?.state == .ready else { return }
        sentPhoneVolume = level; send("STATS PVOL1 \(level)\n")
    }
    /// Updated Macs offer a resume (bit 16) after real silence then new sound, for a phone
    /// interruption or a user pause. OUTPUT parks never accept offers.
    func claimResumeOffer(_ status: UInt32) -> Bool {
        guard intent == "PHONE" || intent == "PAUSE", status >> 8 == intentToken, status & 20 == 20, offeredToken != intentToken else { return false }
        offeredToken = intentToken; return true
    }
    var onHandoff: ((UInt32) -> Void)?
    var onOutput: ((_ supported: Bool, _ computer: Bool) -> Void)?
    var onPacket: ((RelayPacket, Int64) -> Void)?
    var onState: ((String) -> Void)?
    var onReset: (() -> Void)?
    var diagnostics: () -> String = { "" }
    var roundTripMs: Double { bestRTT == .max ? 0 : Double(bestRTT) / 1e6 }

    init(mac: PairedMac, queue: DispatchQueue, hostOverride: String? = nil, port: UInt16 = 5002, useBluetooth: Bool = false) {
        self.mac = mac; self.queue = queue; self.hostOverride = hostOverride
        self.useBluetooth = useBluetooth
        self.port = NWEndpoint.Port(rawValue: port) ?? 5002
    }
    func start() {
        if running && connection != nil { return }
        running = true
        browser?.cancel(); pathMonitor?.cancel()
        if useBluetooth { watchConnection(); connect(); return }
        let monitor = NWPathMonitor()
        var receivedInitialPath = false
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            guard let self, let monitor, self.pathMonitor === monitor, self.running, ["RESUME", "PHONE"].contains(self.intent),
                  UserDefaults.standard.object(forKey: "trustedAutoReconnect") as? Bool != false else { return }
            // NWPathMonitor first reports the existing path immediately. Treat it
            // as a baseline, not a network change that cancels the initial TLS attempt.
            guard receivedInitialPath else { receivedInitialPath = true; return }
            if path.status == .satisfied, self.connection?.state != .ready {
                self.retryTicket += 1
                let old = self.connection; self.connection = nil; old?.cancel()
                self.connect()
            }
        }
        pathMonitor = monitor; monitor.start(queue: queue)
        watchConnection()
        let browser = NWBrowser(for: .bonjour(type: "_audiorelay._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, self.browser === browser, self.running else { return }
            self.discovered = results.first(where: { result in
                if case .service(let name, _, _, _) = result.endpoint {
                    let expected = "AudioRelay-" + self.mac.pin.prefix(8)
                    // Bonjour adds a numeric suffix after a name collision. The full
                    // certificate pin still authenticates the resolved endpoint.
                    return name == expected || name.range(of: "^" + NSRegularExpression.escapedPattern(for: expected) + " [(][2-9][0-9]?[)]$", options: .regularExpression) != nil
                }
                return false
            })?.endpoint
        }
        if hostOverride == nil { self.browser = browser; browser.start(queue: queue) }
        connect()
    }
    private var stopCompletion: (() -> Void)?
    func stop(completion: (() -> Void)? = nil) {
        stopCompletion = completion
        requestedComputerOutput = nil; outputRequestPing = nil
        guard connection != nil else { suspend(); return }
        setIntent("RELEASE")
        // Keep this transport alive for its correlated release ACK. A lost
        // connection restores the desktop output when its last live listener leaves.
        let ticket = intentToken
        queue.asyncAfter(deadline: .now() + 2) { [self] in
            if intent == "RELEASE", intentToken == ticket { suspend() }
        }
    }
    func suspend() {
        running = false; retryTicket += 1
        healthTimer?.cancel(); healthTimer = nil
        timer?.cancel(); timer = nil; browser?.cancel(); browser = nil
        pathMonitor?.cancel(); pathMonitor = nil
        bluetoothLink?.stop(); bluetoothLink = nil
        let old = connection; connection = nil; old?.cancel(); bytes.removeAll()
        let completed = stopCompletion; stopCompletion = nil; completed?()
    }
    func park(_ reason: String) { setIntent(reason) }
    func resume() {
        watchConnection()
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
    func requestOutputIfConnected(computer: Bool) -> Bool {
        guard capabilitiesKnown, connection?.state == .ready, controlStatus & 128 != 0 else { return false }
        requestOutput(computer: computer)
        return true
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
        guard next != intent || desktopStatus != 0 else { return }
        desktopStatus = 0
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
        onControlStatus?(status)
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
        onPresentationTarget?(0, 0, 0)
        capabilitiesKnown = false; controlStatus = 0; intentToken = 1; sentToken = 0; offeredToken = 0; consumedDesktopRequest = 0; desktopStatus = 0
        sentPhoneVolume = nil
        outputRequestPing = nil // Retry an unacknowledged user choice on the new socket.
        if useBluetooth {
            let savedIdentifier = UserDefaults.standard.string(forKey: "bluetoothPeripheral:" + mac.pin).flatMap(UUID.init(uuidString:))
            let link = BluetoothRelayLink(pin: mac.pin, callbackQueue: queue, preferredIdentifier: savedIdentifier,
                                          excludedIdentifiers: rejectedBluetoothPeripherals)
            bluetoothLink?.stop(); bluetoothLink = link
            link.onReady = { [weak self, weak link] endpoint, identifier in
                guard let self, let link, self.bluetoothLink === link, self.running else { return }
                self.currentBluetoothPeripheral = identifier
                self.connectTLS(to: endpoint)
            }
            link.onFailure = { [weak self, weak link] _ in
                guard let self, let link, self.bluetoothLink === link, self.running else { return }
                self.reconnectBluetooth()
            }
            link.start(); return
        }
        let endpoint = hostOverride.map { NWEndpoint.hostPort(host: .init($0), port: port) } ?? discovered ?? .hostPort(host: .init(mac.host), port: port)
        connectTLS(to: endpoint)
    }
    private func connectTLS(to endpoint: NWEndpoint) {
        guard running else { return }
        var identityRejected = false
        let parameters = RelaySecurity.parameters(pin: mac.pin, queue: queue) { identityRejected = true }
        let current = NWConnection(to: endpoint, using: parameters); connection = current
        current.stateUpdateHandler = { [weak self, weak current] state in
            guard let self, let current, self.connection === current, self.running else { return }
            switch state {
            case .ready:
                self.retry = 0; self.connections += 1; self.lastReceived = RelayClock.nanoseconds
                if self.useBluetooth, let identifier = self.currentBluetoothPeripheral {
                    self.rejectedBluetoothPeripherals.removeAll()
                    UserDefaults.standard.set(identifier.uuidString, forKey: "bluetoothPeripheral:" + self.mac.pin)
                }
                self.send(self.mac.token + "\nHELLO " + RelayInstallation.identifier + "\nNAME1 " + NearbyDevices.encodedName + "\nSTATS CONTROLS1\nSTATS VOLUME1\nSTATS VOLUME2\nSTATS CONTROLS2\nSTATS PLAYER1\n" + (self.useBluetooth ? "STATS IMA1\n" : ""))
                self.send(self.alignmentReport); self.sendPhoneVolume()
                if let value = self.compensation { self.send("SYNC \(value)\n") }
                self.onState?("Getting audio ready"); self.startTimer(); self.receive(current)
            case .failed:
                if identityRejected, self.useBluetooth, let identifier = self.currentBluetoothPeripheral {
                    // TLS rejected this candidate before .ready, so no pairing token was sent.
                    // Rotate to another advertising Mac instead of retrying the strongest one.
                    self.rejectedBluetoothPeripherals.insert(identifier)
                    UserDefaults.standard.removeObject(forKey: "bluetoothPeripheral:" + self.mac.pin)
                    let old = self.connection; self.connection = nil; old?.cancel()
                    self.bluetoothLink?.stop(); self.bluetoothLink = nil
                    self.retryTicket += 1; self.connect()
                }
                else if identityRejected { self.suspend(); self.onUnavailable?() }
                else { self.reconnect() }
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
        if !["RESUME", "PHONE"].contains(intent) || UserDefaults.standard.object(forKey: "trustedAutoReconnect") as? Bool == false {
            suspend(); onUnavailable?(); return
        }
        let old = connection; connection = nil; old?.cancel(); timer?.cancel(); timer = nil
        if useBluetooth { bluetoothLink?.stop(); bluetoothLink = nil }
        bytes.removeAll(); onReset?(); onState?("Reconnecting to your computer")
        retry += 1; retryTicket += 1; let ticket = retryTicket
        queue.asyncAfter(deadline: .now() + min(4, 0.5 * Double(retry))) { [weak self] in
            guard let self, self.running, self.retryTicket == ticket else { return }; self.connect()
        }
    }
    private func reconnectBluetooth() {
        guard running else { return }
        if !["RESUME", "PHONE"].contains(intent) || UserDefaults.standard.object(forKey: "trustedAutoReconnect") as? Bool == false {
            suspend(); onUnavailable?(); return
        }
        let old = connection; connection = nil; old?.cancel()
        timer?.cancel(); timer = nil
        bluetoothLink?.stop(); bluetoothLink = nil; bytes.removeAll(); onReset?()
        onState?("Reconnecting to your computer over Bluetooth")
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
            if magic == 0x34435342 {
                let target: UInt32 = integer(at: 4)
                let listeners: UInt32 = integer(at: 8), capable: UInt32 = integer(at: 12)
                guard target <= 2000, listeners <= 4, capable <= listeners else { return false }
                bytes.removeFirst(24); onPresentationTarget?(Int(target), Int(listeners), Int(capable)); continue
            }
            if magic == 0x31455342 {
                let code: UInt32 = integer(at: 4)
                guard code == 1 else { return false }
                suspend(); onGroupFull?(); return true
            }
            if magic == 0x33435342 {
                let value: UInt32 = integer(at: 4)
                guard let volume = ComputerVolume(wireValue: value) else { return false }
                onComputerVolume?(volume); bytes.removeFirst(24); continue
            }
            if magic == 0x32435342 {
                let command: UInt32 = integer(at: 4)
                let request = claimDesktopCommand(command)
                bytes.removeFirst(24)
                switch request {
                case .disconnect: onDesktopDisconnect?()
                case .resume: onDesktopPlayback?(true)
                case .pause: onDesktopPlayback?(false)
                case nil: break
                }
                continue
            }
            if magic == 0x36435342 {
                // Sent only after STATS PLAYER1: bit 0 means the computer is producing sound.
                let state: UInt32 = integer(at: 4)
                guard state <= 1 else { return false }
                bytes.removeFirst(24); onPlayerState?(state == 1); continue
            }
            if magic == 0x35435342 {
                // Sent only after STATS VOLUME2: set this phone's own media volume.
                let level: UInt32 = integer(at: 4)
                guard level <= 1000 else { return false }
                bytes.removeFirst(24); onPhoneVolumeRequest?(Int(level)); continue
            }
            if magic == 0x314D4441 {
                let sequence: UInt32 = integer(at: 4), rate: UInt32 = integer(at: 8), frames: UInt32 = integer(at: 12)
                let captured: UInt64 = integer(at: 16)
                guard useBluetooth, (rate == 48000 || rate == 44100), frames > 0, frames <= 8192,
                      captured <= UInt64(Int64.max) else { return false }
                let length = 24 + Int(frames) + 5
                guard bytes.count >= length else { return true }
                guard let pcm = ImaStereo.decode(Data(bytes.dropFirst(24).prefix(Int(frames) + 5)), frames: Int(frames)) else { return false }
                bytes.removeFirst(length)
                if clockSamples >= 3, intent == "RESUME", capabilitiesKnown, requestedComputerOutput != true, controlStatus & 192 != 192,
                   controlStatus & 1 == 0 || (controlStatus >> 8 == intentToken && controlStatus & 4 == 0) {
                    lastTrafficAt = RelayClock.nanoseconds
                    onPacket?(RelayPacket(sequence: sequence, rate: rate, frames: frames, capturedAt: Int64(captured), pcm: pcm), clockOffset)
                }
                continue
            }
            if magic == 0x31435342 {
                let status: UInt32 = integer(at: 4)
                let sent: UInt64 = integer(at: 8), server: UInt64 = integer(at: 16)
                let now = RelayClock.nanoseconds, roundTrip = now - Int64(clamping: sent)
                if roundTrip >= 0 && roundTrip <= 1_000_000_000 {
                    if now - clockWindow > 30_000_000_000 { bestRTT = .max; clockWindow = now }
                    if roundTrip < bestRTT { bestRTT = roundTrip; clockOffset = Int64(clamping: sent) + roundTrip / 2 - Int64(clamping: server) }
                    clockSamples += 1
                }
                lastTrafficAt = RelayClock.nanoseconds
                bytes.removeFirst(24); acceptControl(status, echoedPing: sent); continue
            }
            guard magic == 0x31415342 else { return false }
            let sequence: UInt32 = integer(at: 4), rate: UInt32 = integer(at: 8), frames: UInt32 = integer(at: 12)
            let captured: UInt64 = integer(at: 16)
            if frames == 0 && captured == 0 && rate == 48000 { lastTrafficAt = RelayClock.nanoseconds; bytes.removeFirst(24); continue }
            guard (rate == 48000 || rate == 44100), frames > 0, frames <= 8192, captured <= UInt64(Int64.max) else { return false }
            let length = 24 + Int(frames) * 4
            guard bytes.count >= length else { return true }
            let pcm = Data(bytes.dropFirst(24).prefix(Int(frames) * 4)); bytes.removeFirst(length)
            if clockSamples >= 3, intent == "RESUME", capabilitiesKnown, requestedComputerOutput != true, controlStatus & 192 != 192,
               controlStatus & 1 == 0 || (controlStatus >> 8 == intentToken && controlStatus & 4 == 0) {
                lastTrafficAt = RelayClock.nanoseconds
                onPacket?(RelayPacket(sequence: sequence, rate: rate, frames: frames, capturedAt: Int64(captured), pcm: pcm), clockOffset)
            }
        }
        return true
    }
    private func integer<T: FixedWidthInteger>(at offset: Int) -> T {
        bytes.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
}
