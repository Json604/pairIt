import Foundation
import CoreAudio
import Darwin

protocol RelayCaptureSource: AnyObject {
    func start() throws
    func stop()
    func adjustSync(_ milliseconds: Double) throws
    func nextPacket() -> Data?
    var computerVolume: ComputerVolume? { get }
    /// Moves the Mac's output volume (the value its volume keys and HUD use).
    func setComputerVolume(_ level: Double)
}
extension RelayCaptureSource {
    var computerVolume: ComputerVolume? { nil }
    func setComputerVolume(_ level: Double) { }
}

/// Play/pause for whatever player owns the Mac's media keys. The app supplies system
/// media keys; headless tests use the unavailable default and never send key events.
protocol RelayMediaControl: AnyObject {
    var available: Bool { get }
    func togglePlayPause()
    /// Next/previous track keys (earphone double/triple tap).
    func skip(forward: Bool)
}
extension RelayMediaControl { func skip(forward: Bool) { } }
final class UnavailableMediaControl: RelayMediaControl {
    var available: Bool { false }
    func togglePlayPause() { }
}

/// One connected phone, as shown and controlled from the Mac.
struct RelayPhone: Equatable, Identifiable {
    enum State: Equatable { case listening, paused, connected }
    let id: UUID
    let name: String
    let state: State
    /// Phone media volume 0...1000 when the phone accepts volume control (STATS VOLUME2).
    let level: Int?
    let canDisconnect: Bool
    /// The phone's random installation ID (HELLO), used to remember it for "Connect".
    var installation: String? = nil
}

/// One capture owner and one ring consumer. Each receiver owns its socket writer.
/// The lifecycle queue can refresh HAL latency without stopping packet dispatch.
final class RelayServer {
    // The loopback listener is an implementation detail, not another pairing
    // endpoint. Give only this process's TLS gateway a fresh capability.
    let gatewayToken = UUID().uuidString + UUID().uuidString
    private let lock = NSLock()
    private let lifecycle = DispatchQueue(label: "pairit.capture.lifecycle", qos: .userInitiated)
    private let workers = DispatchGroup()
    private let makeCapture: () -> RelayCaptureSource
    private let port: UInt16
    private let preferences: UserDefaults
    private var listener: Int32 = -1
    private var peers: [UUID: RelayPeer] = [:]
    private var order: [UUID] = []
    private var capture: RelayCaptureSource?
    private var startingCapture = false
    private var stoppingCapture = false
    private var stopped = false
    private var micLease = false
    private var computerOutput = false
    private var primary: UUID?
    private var appliedCompensation: Double?
    private var captureFailure: String?
    private var lastStatus = ""
    private var lastAudibleAt: TimeInterval = 0
    private var onsetAt: TimeInterval?
    private var onsetArmed = false
    private var reconciliationScheduled = false
    private var lastReceiverCount = -1
    private var lastReceiverDetail = ""
    private var lastPhones: [RelayPhone]?
    // Media handoff: a phone pause also pauses the Mac player, then resumes it only if
    // that pause demonstrably silenced the Mac and nothing else has restarted it.
    private var mediaPausedBy: UUID?
    private var mediaPausedAt: TimeInterval = 0
    private var audibleRunStart: TimeInterval?
    private var lastSkipAt: TimeInterval = -.infinity
    // Mac player state for STATS PLAYER1 phones: sound in the last 1.5 s means playing.
    private var macPlaying = false
    private var pausedOfferArmed = false
    // Volume keys: the observed Mac volume, and the value this server wrote itself.
    private var observedVolume: ComputerVolume?
    private var selfWrittenLevel: Double?
    private var selfWrittenAt: TimeInterval = 0
    var mediaControl: RelayMediaControl = UnavailableMediaControl()
    /// The latest published phone list, readable from any thread.
    var phones: [RelayPhone] { lock.lock(); defer { lock.unlock() }; return lastPhones ?? [] }
    var onPhones: (([RelayPhone]) -> Void)?
    /// A phone used earphone controls but the Mac may not send media keys yet.
    var onMediaControlNeeded: (() -> Void)?
    var onStatus: ((String) -> Void)?
    var phoneNames: String {
        lock.lock(); defer { lock.unlock() }; return peers.values.filter { $0.authenticated && !$0.closed && !$0.released }.map { $0.displayName }.sorted().joined(separator: ", ")
    }
    var onPhoneNames: ((String) -> Void)?
    var onReceivers: ((Int, Int, String) -> Void)?
    var onOutputChanged: ((Bool) -> Void)?

    init(port: UInt16 = 5001, preferences: UserDefaults = .standard, makeCapture: @escaping () -> RelayCaptureSource = { Capture() }) {
        self.port = port; self.preferences = preferences; self.makeCapture = makeCapture
    }
    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AudioFailure(description: "Couldn’t create local audio server") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 && listen(fd, 8) == 0 else {
            close(fd); throw AudioFailure(description: "Local audio port is busy. Quit the other PairIt copy and try again.")
        }
        lock.lock(); listener = fd; stopped = false; lock.unlock()
        workers.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { workers.leave() }; acceptLoop(fd)
        }
        workers.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { workers.leave() }; dispatchPackets()
        }
        update("Ready for your phones")
    }
    private func acceptLoop(_ fd: Int32) {
        while true {
            let socket = accept(fd, nil, nil)
            guard socket >= 0 else { return }
            let id = UUID(), peer = RelayPeer(socket: socket)
            lock.lock()
            guard !stopped, !micLease, peers.count < 12 else {
                let ending = stopped; lock.unlock(); close(socket)
                if ending { return }; continue
            }
            peers[id] = peer; order.append(id)
            lock.unlock()
            peer.onControl = { [weak self] line in self?.control(line, from: id) }
            workers.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self, peer] in
                defer { workers.leave() }
                peer.run(); remove(id)
            }
            reconcile()
        }
    }
    private func control(_ line: String, from id: UUID) {
        lock.lock()
        guard let peer = peers[id], !stopped else { lock.unlock(); return }
        if !peer.authenticated {
            let supplied = Array(line.utf8), expected = Array(("AUTH " + gatewayToken).utf8)
            var difference: UInt8 = supplied.count == expected.count ? 0 : 1
            if supplied.count == expected.count { for (a, b) in zip(supplied, expected) { difference |= a ^ b } }
            guard difference == 0, !micLease else { lock.unlock(); peer.stop(); return }
            guard peers.values.filter({ $0.authenticated && !$0.closed }).count < 4 else {
                lock.unlock(); peer.rejectFull(); return
            }
            peer.authenticated = true; peer.active = true
            lock.unlock(); reconcile(); return
        }
        if line.hasPrefix("PING "), let sent = UInt64(line.dropFirst(5)), sent <= UInt64(Int64.max) {
            var reply = Data(count: 24)
            reply.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: UInt32(0x31435342).littleEndian, toByteOffset: 0, as: UInt32.self)
                let held = peer.parked && (computerOutput || capture != nil) && !startingCapture && !stoppingCapture
                let playerPaused = held && mediaPausedBy != nil
                let status = UInt32(1 | 128) | (computerOutput ? 64 : 0) | (held ? 4 : 0) | (peer.released ? 32 : 0) | (peer.resumeOffered ? 16 : 0)
                    | (mediaControl.available ? 2 : 0) | (playerPaused ? 8 : 0) | (peer.intentToken << 8)
                raw.storeBytes(of: status.littleEndian, toByteOffset: 4, as: UInt32.self)
                raw.storeBytes(of: sent.littleEndian, toByteOffset: 8, as: UInt64.self)
                raw.storeBytes(of: AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()).littleEndian, toByteOffset: 16, as: UInt64.self)
            }
            var alignment: Data?
            if peer.presentationAlignment {
                let active = peers.values.filter { $0.authenticated && $0.active && !$0.closed }
                let ready = active.count >= 2 && active.allSatisfy { $0.presentationAlignment && $0.outputDelay != nil }
                let maximum = ready ? active.map { $0.minimumRender + ($0.outputDelay ?? 0) }.max() ?? 0 : 0
                let target = UInt32((maximum + 9) / 10 * 10)
                alignment = Data(count: 24)
                alignment!.withUnsafeMutableBytes { raw in
                    raw.storeBytes(of: UInt32(0x34435342).littleEndian, toByteOffset: 0, as: UInt32.self)
                    raw.storeBytes(of: target.littleEndian, toByteOffset: 4, as: UInt32.self)
                    raw.storeBytes(of: UInt32(active.count).littleEndian, toByteOffset: 8, as: UInt32.self)
                    raw.storeBytes(of: UInt32(active.filter { $0.presentationAlignment }.count).littleEndian, toByteOffset: 12, as: UInt32.self)
                }
            }
            var volume: Data?
            if peer.volumeControls, let value = capture?.computerVolume {
                volume = Data(count: 24)
                volume!.withUnsafeMutableBytes { raw in
                    raw.storeBytes(of: UInt32(0x33435342).littleEndian, toByteOffset: 0, as: UInt32.self)
                    // 0x20000 tells a VOLUME2 phone its PCM is not attenuated: Mac keys move its own volume.
                    raw.storeBytes(of: (value.wireValue | (peer.volume2 ? 0x20000 : 0)).littleEndian, toByteOffset: 4, as: UInt32.self)
                }
            }
            var command: Data?
            if peer.desktopControls, peer.desktopRelease || peer.desktopRequest != nil {
                let bits: UInt32 = peer.desktopRelease ? 64 : peer.desktopRequest == true ? 16 : 0
                command=Data(count:24)
                command!.withUnsafeMutableBytes { raw in
                    raw.storeBytes(of: UInt32(0x32435342).littleEndian,toByteOffset:0,as:UInt32.self)
                    raw.storeBytes(of: (UInt32(2) | bits | peer.intentToken << 8).littleEndian,toByteOffset:4,as:UInt32.self)
                }
            }
            let player = peer.player1 ? Self.playerState(macPlaying) : nil
            lock.unlock(); peer.enqueue(reply); if let command { peer.enqueue(command) }; if let volume { peer.enqueue(volume) }; if let alignment { peer.enqueue(alignment) }; if let player { peer.enqueue(player) }; return
        }
        if line == "STATS VOLUME1" { peer.volumeControls = true; lock.unlock(); return }
        if line == "STATS CONTROLS1" { peer.desktopControls=true;lock.unlock();return }
        if line == "STATS VOLUME2" { peer.volume2 = true; lock.unlock(); publishPhones(); return }
        if line == "STATS CONTROLS2" { peer.controls2 = true; lock.unlock(); publishPhones(); return }
        if line == "STATS PLAYER1" { peer.player1 = true; peer.enqueue(Self.playerState(macPlaying)); lock.unlock(); return }
        if line == "STATS MEDIA1 PLAY" {
            // The phone shows "Paused on computer"; its earphone Play starts the Mac player.
            let quiet = ProcessInfo.processInfo.systemUptime - lastAudibleAt >= 1.5
            let ok = peer.authenticated && !computerOutput && quiet
            lock.unlock()
            guard ok else { log("MEDIA play skipped: Mac already playing or speakers selected"); return }
            if mediaControl.available { log("MEDIA play from \(peer.displayName)"); mediaControl.togglePlayPause() }
            else { log("MEDIA play ignored: headphone controls not allowed (Accessibility)"); DispatchQueue.main.async { [weak self] in self?.onMediaControlNeeded?() } }
            return
        }
        if line == "STATS MEDIA1 NEXT" || line == "STATS MEDIA1 PREVIOUS" {
            let ok = peer.authenticated && !computerOutput
            lock.unlock()
            guard ok else { return }
            // A skip changes the player's state itself (Spotify starts playing): forget our
            // pause, and let the phone's following resume pass without pressing Play.
            lock.lock(); lastSkipAt = ProcessInfo.processInfo.systemUptime; mediaPausedBy = nil; lock.unlock()
            if mediaControl.available { log("MEDIA \(line.hasSuffix("NEXT") ? "next" : "previous") track from \(peer.displayName)"); mediaControl.skip(forward: line.hasSuffix("NEXT")) }
            else { log("MEDIA skip ignored: headphone controls not allowed (Accessibility)"); DispatchQueue.main.async { [weak self] in self?.onMediaControlNeeded?() } }
            return
        }
        if line.hasPrefix("STATS PVOL1 ") {
            guard let level = Int(line.dropFirst(12)), (0...1000).contains(level) else { lock.unlock(); return }
            peer.phoneLevel = level
            // With one volume-controlled phone, the Mac's volume follows that phone,
            // so the volume HUD and the next key press start from what the listener hears.
            // Never with an older phone connected: the Mac volume still attenuates its audio.
            let listeners = peers.values.filter { $0.authenticated && !$0.closed && !$0.released }
            let sole = listeners.count == 1 && listeners.first === peer
            lock.unlock()
            if sole && peer.volume2 { lifecycle.async { [weak self] in self?.adoptPhoneVolume(level, from: id) } }
            publishPhones(); return
        }
        if line.hasPrefix("STATS ALIGN1 ") {
            let values = line.split(separator: " ")
            guard values.count == 4, let minimum = Int(values[2]), (1...320).contains(minimum),
                  let output = Int(values[3]), (-1...1000).contains(output) else { lock.unlock(); peer.stop(); return }
            peer.presentationAlignment = true; peer.minimumRender = minimum; peer.outputDelay = output < 0 ? nil : output
            lock.unlock(); return
        }
        let words = line.split(separator: " ")
        if line == "OUTPUT COMPUTER" || line == "OUTPUT PHONE" {
            lock.unlock(); setComputerOutput(line == "OUTPUT COMPUTER"); return
        }
        if let command = words.first, ["PARK", "RESUME", "RELEASE"].contains(String(command)) {
            guard words.count == (command == "PARK" ? 3 : 2),
                  let token = UInt32(words[1]), token > 0, token <= 0xFFFFFF,
                  token > peer.intentToken else { lock.unlock(); return }
            if command == "PARK" && !["PHONE", "PAUSE", "OUTPUT"].contains(String(words[2])) { lock.unlock(); return }
            let wasActive = peer.active
            // Only a resume from an earphone/app pause (or a call) may start the Mac player;
            // a first connection or reconnection never presses Play.
            let resumingFromPause = command == "RESUME" && peer.parked && peer.parkReason != "OUTPUT"
            if command == "PARK" { peer.parkReason = String(words[2]) }
            peer.intentToken = token; peer.released = command == "RELEASE"
            peer.parked = command == "PARK"; peer.active = command == "RESUME"
            peer.phoneInterrupted = command == "PARK" && words[2] == "PHONE"
            peer.resumeOffered = false; peer.desktopRequest = nil; peer.desktopRelease = false
            peer.clear()
            let pauseMedia = command == "PARK" && words[2] != "OUTPUT" && wasActive
            let resumeMedia = resumingFromPause && ProcessInfo.processInfo.systemUptime - lastSkipAt > 2
            if command == "RELEASE" && mediaPausedBy == id { mediaPausedBy = nil }
            lock.unlock(); reconcile()
            if pauseMedia { pauseMediaIfLastListener(parkedBy: id) }
            if resumeMedia { resumeMediaIfPaused() }
            return
        }
        else if line == "ACTIVE 0" && peer.intentToken == 0 { peer.active = false; peer.clear() }
        else if line == "ACTIVE 1" {
            if micLease { lock.unlock(); peer.stop(); return }
            if peer.intentToken == 0 { peer.active = true }
        } else if line.hasPrefix("SYNC "), let value = Double(line.dropFirst(5)), value.isFinite, (0...2000).contains(value) {
            peer.compensation = value
        } else if line.hasPrefix("NAME1 ") {
            let encoded = String(line.dropFirst(6))
            if encoded.utf8.count <= 344, let data = Data(base64Encoded: encoded), let name = String(data: data, encoding: .utf8),
               !name.isEmpty, name.count <= 64, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }) { peer.displayName = name }
        } else if line.hasPrefix("HELLO ") {
            let identity = String(line.dropFirst(6))
            if identity.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil {
                peer.identity = identity
                // A reconnect may replace only the same installation's stale session.
                for (otherID, other) in peers where otherID != id && other.identity == identity {
                    // Replace the stale connection for this installation.
                    other.parked = false; other.released = true
                    other.stop()
                }
            }
        } else { lock.unlock(); return } // Ignore legacy telemetry and unknown extensions.
        lock.unlock(); reconcile()
    }
    private func remove(_ id: UUID) {
        lock.lock()
        peers.removeValue(forKey: id); order.removeAll { $0 == id }; lock.unlock()
        reconcile()
    }
    private func reconcile() {
        lock.lock()
        guard !reconciliationScheduled else { lock.unlock(); return }
        reconciliationScheduled = true; lock.unlock()
        lifecycle.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.reconciliationScheduled = false; self.lock.unlock()
            self.updateCapture()
        }
    }
    var playbackRequestPending: Bool { lock.lock();defer { lock.unlock() };return peers.values.contains { !$0.closed && $0.desktopRequest != nil } }
    func cancelPlaybackRequest(){lock.lock();for peer in peers.values {peer.desktopRequest=nil};lock.unlock()}
    /// Pause or resume every phone, or only `phone` when given.
    func requestPhonePlayback(_ playing: Bool, phone: UUID? = nil) {
        if playing { setComputerOutput(false) }
        lock.lock()
        for (id, peer) in peers where peer.authenticated && peer.desktopControls && !peer.closed && !peer.released && (phone == nil || phone == id) {
            peer.desktopRequest = playing
            peer.resumeOffered = false
        }
        lock.unlock()
    }
    /// Sets one phone's own media volume (0...1000). Only phones that sent STATS VOLUME2.
    func setPhoneVolume(_ phone: UUID, level: Int) {
        let target = min(1000, max(0, level))
        lock.lock()
        guard let peer = peers[phone], peer.authenticated, peer.volume2, !peer.closed, !peer.released else { lock.unlock(); return }
        peer.phoneLevel = target; peer.enqueue(Self.volumeRequest(target))
        lock.unlock(); publishPhones()
    }
    /// Ends one phone's session. An updated phone stops instead of reconnecting;
    /// an older phone is closed and may reconnect if its auto-reconnect is on.
    func disconnectPhone(_ phone: UUID) {
        lock.lock()
        guard let peer = peers[phone], !peer.closed else { lock.unlock(); return }
        if peer.authenticated && peer.controls2 && peer.desktopControls && !peer.released {
            peer.desktopRelease = true; peer.desktopRequest = nil
            lock.unlock()
            lifecycle.asyncAfter(deadline: .now() + 5) { [weak self, weak peer] in
                guard let self, let peer else { return }
                self.lock.lock(); let waiting = peer.desktopRelease && !peer.released; self.lock.unlock()
                if waiting { peer.stop() }
            }
            return
        }
        lock.unlock(); peer.stop()
    }
    /// 0x36435342: bit 0 set while the Mac is producing sound (only to STATS PLAYER1 phones).
    private static func playerState(_ playing: Bool) -> Data {
        var frame = Data(count: 24)
        frame.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(0x36435342).littleEndian, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: UInt32(playing ? 1 : 0).littleEndian, toByteOffset: 4, as: UInt32.self)
        }
        return frame
    }
    private static func volumeRequest(_ level: Int) -> Data {
        var frame = Data(count: 24)
        frame.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(0x35435342).littleEndian, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: UInt32(level).littleEndian, toByteOffset: 4, as: UInt32.self)
        }
        return frame
    }
    // Lifecycle queue. The write is recorded first so the volume observer does not
    // mistake it for a key press and send it back to the phone.
    private func adoptPhoneVolume(_ level: Int, from phone: UUID) {
        lock.lock()
        let target = Double(level) / 1000
        guard !stopped, !computerOutput, let source = capture, peers[phone]?.phoneLevel == level,
              abs((observedVolume?.level ?? -1) - target) >= 0.002 else { lock.unlock(); return }
        selfWrittenLevel = target; selfWrittenAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        source.setComputerVolume(target)
    }
    /// Called with `lock` held from packet dispatch. A Mac volume-key change moves each
    /// volume-controlled phone by the same amount, keeping their own relative levels.
    private func observeVolume(_ volume: ComputerVolume) {
        guard let previous = observedVolume else { observedVolume = volume; return }
        observedVolume = volume
        guard abs(volume.level - previous.level) >= 0.0005 else { return }
        if let written = selfWrittenLevel {
            selfWrittenLevel = nil
            if abs(volume.level - written) < 0.002 && ProcessInfo.processInfo.systemUptime - selfWrittenAt < 1 { return }
        }
        let delta = Int(((volume.level - previous.level) * 1000).rounded())
        var changed = false
        for peer in peers.values where peer.authenticated && peer.volume2 && !peer.closed && !peer.released {
            guard let current = peer.phoneLevel else { continue }
            let target = min(1000, max(0, current + delta))
            guard target != current else { continue }
            peer.phoneLevel = target; peer.enqueue(Self.volumeRequest(target)); changed = true
        }
        if changed { DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.publishPhones() } }
    }
    private func pauseMediaIfLastListener(parkedBy phone: UUID) {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let othersListening = peers.values.contains { $0.authenticated && $0.active && !$0.closed }
        let skip: String? = stopped ? "sharing stopped" : computerOutput ? "Mac speakers selected" : capture == nil ? "capture not running"
            : mediaPausedBy != nil ? "already paused by PairIt" : othersListening ? "another phone is still listening"
            : now - lastAudibleAt >= 3 ? "Mac was silent for 3 s (nothing playing)" : nil
        let available = mediaControl.available
        lock.unlock()
        if let skip { log("MEDIA pause skipped: \(skip)"); return }
        guard available else {
            log("MEDIA pause skipped: headphone controls not allowed (Accessibility)")
            DispatchQueue.main.async { [weak self] in self?.onMediaControlNeeded?() }
            return
        }
        lock.lock(); mediaPausedBy = phone; mediaPausedAt = now; lock.unlock()
        log("MEDIA pausing Mac player for earphone/phone pause")
        mediaControl.togglePlayPause()
        // A real pause leaves a silent gap. Only unbroken sound right through the check
        // window means the key reached no pausable player: then press once more to undo.
        lifecycle.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let continuous = (self.audibleRunStart.map { $0 <= now + 0.5 } ?? false) && self.lastAudibleAt > now + 1.4
            let undo = self.mediaPausedAt == now && self.mediaPausedBy != nil && continuous
            if undo { self.mediaPausedBy = nil }
            self.lock.unlock()
            if undo { log("MEDIA sound never stopped; undoing the key press"); self.mediaControl.togglePlayPause() }
        }
    }
    private func resumeMediaIfPaused() {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let ours = mediaPausedBy != nil
        mediaPausedBy = nil
        // Pressing Play/Pause while sound is playing would stop it. After PairIt's own pause a
        // short silence suffices; otherwise require 2 s of silence (nothing is playing), and
        // the key then starts the Mac's last Now Playing app, like the Mac's own Play key.
        let quiet = now - lastAudibleAt > (ours ? 0.5 : 2)
        let available = mediaControl.available
        lock.unlock()
        guard quiet else { log("MEDIA resume skipped: Mac audio already playing"); return }
        guard available else { log("MEDIA resume skipped: headphone controls not allowed (Accessibility)"); return }
        log(ours ? "MEDIA resuming Mac player" : "MEDIA starting the Mac's last player")
        mediaControl.togglePlayPause()
    }
    func setComputerOutput(_ enabled: Bool) {
        lock.lock()
        guard !stopped, !micLease, computerOutput != enabled else { lock.unlock(); return }
        computerOutput = enabled
        mediaPausedBy = nil
        if enabled {
            // Preserve each connected phone’s playback/paused intent.

            for peer in peers.values { peer.discardAudio() }
        }
        lock.unlock(); reconcile()
    }
    private func updateCapture() {
        lock.lock()
        let active = order.filter { peers[$0]?.active == true && peers[$0]?.closed == false }
        if let current = primary, !active.contains(current) { primary = nil }
        if primary == nil { primary = active.first { peers[$0]?.compensation != nil } }
        let desired = primary.flatMap { peers[$0]?.compensation }
        let count = active.count
        let parkedCount = peers.values.filter { $0.parked && !$0.closed }.count
        let held = peers.values.contains { $0.parked && !$0.closed }
        let microphoneActive = micLease
        let speakers = computerOutput
        let shouldCapture = !stopped && !micLease && !speakers && (count > 0 || held)
        let current = capture
        if !shouldCapture {
            capture = nil; startingCapture = false; stoppingCapture = current != nil
            primary = nil; appliedCompensation = nil; observedVolume = nil; selfWrittenLevel = nil
        }
        else if current == nil { startingCapture = true }
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onOutputChanged?(speakers) }
        if !shouldCapture {
            current?.stop()
            lock.lock(); stoppingCapture = false; lock.unlock()
            update(microphoneActive ? "Phone microphone is active" : captureFailure ?? (speakers ? "Playing on Mac speakers" : "Ready for your phones"))
            publishReceivers(count, parkedCount, speakers ? "Mac speakers selected. Your phones stay connected." : "No active listeners")
            return
        }
        if current == nil {
            captureFailure = nil
            let next = makeCapture()
            do {
                try next.start()
                lock.lock()
                if stopped || micLease || computerOutput || !(peers.values.contains(where: { $0.closed == false && ($0.parked || $0.active) })) {
                    // The newly opened tap is still live until its cancellation teardown returns.
                    stoppingCapture = true; lock.unlock(); next.stop()
                    lock.lock(); startingCapture = false; stoppingCapture = false; lock.unlock(); return
                }
                capture = next; startingCapture = false; observedVolume = nil; selfWrittenLevel = nil
                appliedCompensation = preferences.object(forKey: "videoCompensationMs") as? Double ?? 0
                lock.unlock()
            } catch {
                next.stop()
                lock.lock()
                startingCapture = false
                guard !stopped else { lock.unlock(); return }
                // Keep the control channel and listening intent so a permission
                // or device failure can be retried without pairing/reconnecting.
                computerOutput = true

                for peer in peers.values { peer.discardAudio() }
                lock.unlock()
                captureFailure = "Capture failed: \(error)"
                DispatchQueue.main.async { [weak self] in self?.onOutputChanged?(true) }
                update(captureFailure!)
                publishReceivers(count, parkedCount, "Mac audio could not start. Your phones stay connected; choose Phone headphones to retry.")
                return
            }
        }
        if let desired, desired != appliedCompensation {
            lock.lock(); let source = capture; lock.unlock()
            do {
                try source?.adjustSync(desired)
                appliedCompensation = desired
                preferences.set(desired, forKey: "videoCompensationMs")
            } catch { update("Video timing could not update. Reconnect the primary phone.") }
        }
        update(count == 0 && held ? "Mac output held for your phone" : "Relaying Mac audio → \(count) \(count == 1 ? "phone" : "phones")")
        publishReceivers(count, parkedCount, count == 0 && held ? "\(parkedCount) paused · Resume in PairIt on your phone. Media may still be playing silently." : parkedCount > 0 ? "\(count) listening · \(parkedCount) paused. Each phone returns independently." : count > 1 ? "One primary phone controls video sync. Other outputs may differ." : "Automatic timing for the active phone")
    }
    private func dispatchPackets() {
        var lastPacket = ProcessInfo.processInfo.systemUptime
        var lastVolumeCheck: TimeInterval = 0
        while true {
            lock.lock(); let ending = stopped, source = computerOutput ? nil : capture; lock.unlock()
            if ending { return }
            var packet = source?.nextPacket()
            let now = ProcessInfo.processInfo.systemUptime
            if packet == nil && now - lastPacket >= 1 {
                var heartbeat = Data(count: 24)
                heartbeat.withUnsafeMutableBytes { raw in
                    raw.storeBytes(of: UInt32(0x31415342).littleEndian, toByteOffset: 0, as: UInt32.self)
                    raw.storeBytes(of: UInt32(48000).littleEndian, toByteOffset: 8, as: UInt32.self)
                }
                packet = heartbeat
            }
            guard let packet else { usleep(1000); continue }
            lastPacket = now
            lock.lock()
            let valid = source == nil || (!computerOutput && capture === source)
            // Serialize selection + bounded enqueue against PARK/clear. The socket
            // writer never runs under this lock; parked packets cannot be queued late.
            if valid {
                // Only a fresh silence-to-audio edge can reclaim an interrupted phone.
                // Existing audio, explicit pauses and output changes never offer resume.
                let audible = packet.count > 24 && packet.withUnsafeBytes { raw in
                    stride(from: 24, to: packet.count - 1, by: 2).contains {
                        abs(Int(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: Int16.self)))) > 160
                    }
                }
                if !audible {
                    if now - lastAudibleAt >= 0.75 { onsetArmed = true }
                    // A real stop (not a gap between songs) before new sound may resume a paused phone.
                    if now - lastAudibleAt >= 2 { pausedOfferArmed = true }
                    if macPlaying, now - lastAudibleAt >= 1.5 {
                        macPlaying = false
                        for peer in peers.values where peer.authenticated && peer.player1 { peer.enqueue(Self.playerState(false)) }
                    }
                    if now - lastAudibleAt >= 0.3 { audibleRunStart = nil }
                    onsetAt = nil
                } else {
                    // Sustained sound after our media pause means the user resumed the
                    // player on the Mac; a later phone resume must not toggle it off.
                    if audibleRunStart == nil { audibleRunStart = now }
                    if mediaPausedBy != nil, now - mediaPausedAt > 2, now - (audibleRunStart ?? now) >= 0.6 { mediaPausedBy = nil }
                    if !macPlaying {
                        macPlaying = true
                        for peer in peers.values where peer.authenticated && peer.player1 { peer.enqueue(Self.playerState(true)) }
                    }
                    // Sustained new sound (play/next/previous on the Mac itself) resumes a phone
                    // the listener paused. Short sounds such as notification dings do not.
                    if pausedOfferArmed, now - (audibleRunStart ?? now) >= 0.5 {
                        for peer in peers.values where peer.authenticated && peer.player1 && peer.parked && peer.parkReason == "PAUSE" {
                            peer.resumeOffered = true; log("MEDIA Mac started playing; offering resume to \(peer.displayName)")
                        }
                        pausedOfferArmed = false
                    }
                    if onsetArmed {
                        if onsetAt == nil { onsetAt = now }
                        if now - (onsetAt ?? now) >= 0.08 {
                            for peer in peers.values where peer.authenticated && peer.parked && peer.phoneInterrupted {
                                peer.resumeOffered = true
                            }
                            onsetArmed = false; onsetAt = nil
                        }
                    }
                    lastAudibleAt = now
                }
            }
            if valid, let source, now - lastVolumeCheck >= 0.05, let volume = source.computerVolume {
                lastVolumeCheck = now; observeVolume(volume)
            }
            if valid {
                // Volume-controlled phones receive full-scale PCM (mute still applies);
                // older phones keep the Mac volume applied to their audio.
                let volume = packet.count > 24 ? source?.computerVolume : nil
                var attenuated: Data?, muteOnly: Data?
                for peer in peers.values where peer.authenticated && (peer.active || source == nil) {
                    guard let volume else { peer.enqueue(packet); continue }
                    if peer.volume2 {
                        if muteOnly == nil { var copy = packet; ComputerVolume(level: 1, muted: volume.muted).apply(to: &copy); muteOnly = copy }
                        peer.enqueue(muteOnly!)
                    } else {
                        if attenuated == nil { var copy = packet; volume.apply(to: &copy); attenuated = copy }
                        peer.enqueue(attenuated!)
                    }
                }
            }
            lock.unlock()
        }
    }
    /// Reservation excludes both existing and in-flight capture startup.
    func reserveMicrophone() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, !micLease, capture == nil, !startingCapture, !stoppingCapture,
              !peers.values.contains(where: { $0.active && !$0.closed }) else { return false }
        micLease = true; return true
    }
    func releaseMicrophone() { lock.lock(); micLease = false; lock.unlock(); reconcile() }
    private func update(_ text: String) {
        // Capture lifecycle owns this deduplication except the initial ready state.
        lock.lock(); let changed = text != lastStatus; lastStatus = text; lock.unlock()
        if changed { DispatchQueue.main.async { [weak self] in self?.onStatus?(text) } }
    }
    private func publishPhones() {
        lock.lock()
        let rows = order.compactMap { id -> RelayPhone? in
            guard let peer = peers[id], peer.authenticated, !peer.closed, !peer.released else { return nil }
            return RelayPhone(id: id, name: peer.displayName, state: peer.active ? .listening : peer.parked ? .paused : .connected,
                              level: peer.volume2 ? peer.phoneLevel : nil, canDisconnect: peer.controls2 && peer.desktopControls,
                              installation: peer.identity)
        }
        let changed = rows != lastPhones
        if changed { lastPhones = rows }
        lock.unlock()
        if changed { DispatchQueue.main.async { [weak self] in self?.onPhones?(rows) } }
    }
    private func publishReceivers(_ count: Int, _ parked: Int, _ detail: String) {
        publishPhones()
        lock.lock(); let names = peers.values.filter { !$0.released }.map { $0.displayName }.sorted().joined(separator: ", "); lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onPhoneNames?(names) }
        guard count != lastReceiverCount || detail != lastReceiverDetail else { return }
        lastReceiverCount = count; lastReceiverDetail = detail
        DispatchQueue.main.async { [weak self] in self?.onReceivers?(count, parked, detail) }
    }
    func disconnect() {
        lock.lock(); let current = Array(peers.values); lock.unlock()
        current.forEach { $0.stop() }
    }
    func stop() {
        lock.lock(); stopped = true;
        if listener >= 0 { shutdown(listener, SHUT_RDWR); close(listener); listener = -1 }
        let current = Array(peers.values); lock.unlock()
        current.forEach { $0.stop() }
        lifecycle.sync { updateCapture() }
        _ = workers.wait(timeout: .now() + 4)
    }
}

/// No shared writer: a blocked receiver cannot stop another receiver's PCM/PING.
private final class RelayPeer {
    private struct Pending { let data: Data; let queued: TimeInterval }
    private let socket: Int32
    private let queueLock = NSLock()
    private var pending: [Pending] = []
    private var bytes = 0
    private var ending = false
    var closed: Bool { queueLock.lock(); defer { queueLock.unlock() }; return ending }
    var authenticated = false
    var active = false
    var parked = false
    var phoneInterrupted = false
    var volumeControls = false
    var desktopControls=false
    var desktopRequest: Bool?
    var desktopRelease = false
    var parkReason: String?
    var player1 = false
    var volume2 = false
    var controls2 = false
    var phoneLevel: Int?
    var resumeOffered = false
    var released = false
    var intentToken: UInt32 = 0
    var displayName = "Phone"
    var identity: String?
    var compensation: Double?
    var presentationAlignment = false
    var minimumRender = 320
    var outputDelay: Int?
    var onControl: ((String) -> Void)?
    init(socket: Int32) { self.socket = socket }
    func enqueue(_ data: Data) {
        queueLock.lock()
        guard !ending else { queueLock.unlock(); return }
        let now = ProcessInfo.processInfo.systemUptime
        if bytes + data.count > 262144 || pending.first.map({ now - $0.queued > 0.250 }) == true {
            queueLock.unlock(); stop(); return
        }
        pending.append(Pending(data: data, queued: now)); bytes += data.count
        queueLock.unlock()
    }
    func clear() { queueLock.lock(); pending.removeAll(keepingCapacity: true); bytes = 0; queueLock.unlock() }
    func discardAudio() {
        queueLock.lock()
        pending.removeAll { $0.data.count > 24 }
        bytes = pending.reduce(0) { $0 + $1.data.count }
        queueLock.unlock()
    }
    private func next() -> Data? {
        queueLock.lock(); defer { queueLock.unlock() }
        guard !pending.isEmpty else { return nil }
        let item = pending.removeFirst(); bytes -= item.data.count
        if ProcessInfo.processInfo.systemUptime - item.queued > 0.250 {
            ending = true; shutdown(socket, SHUT_RDWR); return nil
        }
        return item.data
    }
    // Called on this peer's run thread, before it is authenticated; no concurrent writer.
    func rejectFull() {
        var frame = Data(count: 24)
        frame.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(0x31455342).littleEndian, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: UInt32(1).littleEndian, toByteOffset: 4, as: UInt32.self)
        }
        frame.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = send(socket, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                if written <= 0 { break }; offset += written
            }
        }
        stop()
    }
    func stop() {
        queueLock.lock()
        if !ending { ending = true; shutdown(socket, SHUT_RDWR) }
        queueLock.unlock()
    }
    func run() {
        defer { queueLock.lock(); ending = true; close(socket); pending.removeAll(); bytes = 0; queueLock.unlock() }
        var yes: Int32 = 1, sendBuffer: Int32 = 8192
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socket, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socket, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 200000)
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let acceptedAt = ProcessInfo.processInfo.systemUptime
        var commands = Data(), lastControl = acceptedAt
        while true {
            queueLock.lock(); let done = ending; queueLock.unlock()
            let now = ProcessInfo.processInfo.systemUptime
            if done || now - lastControl > 8 || (!authenticated && now - acceptedAt > 4) { return }
            var probe = pollfd(fd: socket, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            if poll(&probe, 1, 0) > 0 {
                if probe.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return }
                if probe.revents & Int16(POLLIN) != 0 {
                    var input = [UInt8](repeating: 0, count: 4096)
                    let count = recv(socket, &input, input.count, MSG_DONTWAIT)
                    if count <= 0 { return }; lastControl = ProcessInfo.processInfo.systemUptime
                    commands.append(contentsOf: input.prefix(count))
                    if commands.count > 16384 { return }
                    while let newline = commands.firstIndex(of: 10) {
                        guard newline - commands.startIndex <= 4096 else { return }
                        let line = String(decoding: commands.prefix(upTo: newline), as: UTF8.self)
                        commands.removeSubrange(...newline); onControl?(line)
                    }
                    if commands.count > 4096 { return }
                }
            }
            guard let data = next() else { usleep(1000); continue }
            let success = data.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let count = send(socket, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                    if count <= 0 { return false }; offset += count
                }
                return true
            }
            if !success { return }
        }
    }
}
