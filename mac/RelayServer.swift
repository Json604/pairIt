import Foundation
import CoreAudio
import Darwin

protocol RelayCaptureSource: AnyObject {
    func start() throws
    func stop()
    func adjustSync(_ milliseconds: Double) throws
    func nextPacket() -> Data?
    var computerVolume: ComputerVolume? { get }
}
extension RelayCaptureSource { var computerVolume: ComputerVolume? { nil } }

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
                let status = UInt32(1 | 128) | (computerOutput ? 64 : 0) | (held ? 4 : 0) | (peer.released ? 32 : 0) | (peer.resumeOffered ? 16 : 0) | (peer.intentToken << 8)
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
                    raw.storeBytes(of: value.wireValue.littleEndian, toByteOffset: 4, as: UInt32.self)
                }
            }
            var command: Data?
            if peer.desktopControls, let playing = peer.desktopRequest {
                command=Data(count:24)
                command!.withUnsafeMutableBytes { raw in
                    raw.storeBytes(of: UInt32(0x32435342).littleEndian,toByteOffset:0,as:UInt32.self)
                    raw.storeBytes(of: (UInt32(2 | (playing ? 16 : 0)) | peer.intentToken << 8).littleEndian,toByteOffset:4,as:UInt32.self)
                }
            }
            lock.unlock(); peer.enqueue(reply); if let command { peer.enqueue(command) }; if let volume { peer.enqueue(volume) }; if let alignment { peer.enqueue(alignment) }; return
        }
        if line == "STATS VOLUME1" { peer.volumeControls = true; lock.unlock(); return }
        if line == "STATS CONTROLS1" { peer.desktopControls=true;lock.unlock();return }
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
            peer.intentToken = token; peer.released = command == "RELEASE"
            peer.parked = command == "PARK"; peer.active = command == "RESUME"
            peer.phoneInterrupted = command == "PARK" && words[2] == "PHONE"
            peer.resumeOffered = false; peer.desktopRequest = nil
            peer.clear()
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
    func requestPhonePlayback(_ playing: Bool) {
        if playing { setComputerOutput(false) }
        lock.lock()
        for peer in peers.values where peer.authenticated && peer.desktopControls && !peer.closed && !peer.released {
            peer.desktopRequest = playing
            peer.resumeOffered = false
        }
        lock.unlock()
    }
    func setComputerOutput(_ enabled: Bool) {
        lock.lock()
        guard !stopped, !micLease, computerOutput != enabled else { lock.unlock(); return }
        computerOutput = enabled
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
            primary = nil; appliedCompensation = nil
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
                capture = next; startingCapture = false
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
                    onsetAt = nil
                } else {
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
            if valid { for peer in peers.values where peer.authenticated && (peer.active || source == nil) { peer.enqueue(packet) } }
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
    private func publishReceivers(_ count: Int, _ parked: Int, _ detail: String) {
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
