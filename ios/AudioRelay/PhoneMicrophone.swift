import Foundation
import AVFAudio
import Network
import Combine

/// Foreground-only, explicitly started sender. Audio never leaves the paired local connection.
@MainActor final class PhoneMicrophone: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var message = "Microphone is off"
    private var engine: AVAudioEngine?
    private var connection: NWConnection?
    private var generation = 0
    private var pending = 0
    private var timeout: Task<Void, Never>?
    private let network = DispatchQueue(label: "pairit.phone.microphone")
    private var observer: NSObjectProtocol?
    func start(computer: PairedMac?, host: String?) {
        guard !running else { return }
        guard let computer else { message = "Pair a computer in Connect first."; return }
        generation += 1; let ticket = generation
        AVAudioApplication.requestRecordPermission { [weak self] allowed in
            Task { @MainActor in
                guard let self, self.generation == ticket else { return }
                guard allowed else { self.message = "Microphone access was denied. You can still listen normally."; return }
                self.connect(computer: computer, host: host, ticket: ticket)
            }
        }
    }
    private func connect(computer: PairedMac, host: String?, ticket: Int) {
        running = true; message = "Connecting to your computer…"
        let current = NWConnection(host: NWEndpoint.Host(host ?? computer.host), port: 5002, using: RelaySecurity.parameters(pin: computer.pin, queue: network))
        connection = current
        current.stateUpdateHandler = { [weak self, weak current] state in
            Task { @MainActor in
                guard let self, let current, self.generation == ticket else { return }
                switch state {
                case .ready:
                    current.send(content: Data((computer.token + " MIC1\n").utf8), completion: .contentProcessed { [weak self] error in
                        Task { @MainActor in
                            guard let self, self.generation == ticket else { return }
                            if error != nil { self.stop("Could not connect. Try again.") }
                            else { self.readReply(current, ticket: ticket, bytes: Data()) }
                        }
                    })
                case .failed: self.stop("Connection lost. Start microphone again when ready.")
                default: break
                }
            }
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.generation == ticket else { return }
            self.stop("Computer did not respond. Check Phone microphone in its Settings.")
        }
        current.start(queue: network)
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop("Microphone interrupted. Start again when ready.") }
        }
    }
    private func readReply(_ current: NWConnection, ticket: Int, bytes: Data) {
        current.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.generation == ticket else { return }
                var reply = bytes; if let data { reply.append(data) }
                guard error == nil, !complete, reply.count <= 80 else { self.stop("Computer closed the connection."); return }
                if reply.last == 10 {
                    guard reply == Data("OK MIC1 48000\n".utf8) else {
                        self.stop(String(data: reply, encoding: .utf8)?.contains("BUSY") == true ? "Stop computer sharing and other microphone sessions first." : "Enable Phone microphone and select a virtual cable in computer Settings."); return
                    }
                    do { try self.capture(current, ticket: ticket) }
                    catch { self.stop("Microphone unavailable. Close other recording apps and retry.") }
                } else { self.readReply(current, ticket: ticket, bytes: reply) }
            }
        }
    }
    private func capture(_ current: NWConnection, ticket: Int) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setPreferredSampleRate(48000); try session.setActive(true)
        let audio = AVAudioEngine(); engine = audio
        let source = audio.inputNode.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target) else { throw NSError(domain: "PairItMicrophone", code: 1) }
        var sequence: UInt32 = 0
        audio.inputNode.installTap(onBus: 0, bufferSize: 960, format: source) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 48000 / source.sampleRate) + 16)
            guard capacity <= 8192, let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var provided = false, error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if provided { status.pointee = .noDataNow; return nil }
                provided = true; status.pointee = .haveData; return buffer
            }
            guard error == nil, let samples = converted.int16ChannelData?[0] else { return }
            var offset = 0
            while offset < Int(converted.frameLength) {
                let count = min(960, Int(converted.frameLength) - offset)
                var packet = Data()
                for var value in [UInt32(0x314d5342).littleEndian, sequence.littleEndian, UInt32(48000).littleEndian, UInt32(count).littleEndian] {
                    withUnsafeBytes(of: &value) { packet.append(contentsOf: $0) }
                }
                packet.append(Data(bytes: samples.advanced(by: offset), count: count * 2)); sequence &+= 1; offset += count
                Task { @MainActor in self?.send(packet, on: current, ticket: ticket) }
            }
        }
        audio.prepare(); try audio.start(); timeout?.cancel(); timeout = nil
        message = "Microphone live · " + (session.currentRoute.inputs.first?.portName ?? "iPhone microphone")
    }
    private func send(_ packet: Data, on current: NWConnection, ticket: Int) {
        guard generation == ticket, running else { return }
        guard pending < 4 else { stop("Network is too slow for microphone audio. Check Wi-Fi and try again."); return }
        pending += 1
        current.send(content: packet, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self, self.generation == ticket else { return }
                self.pending -= 1
                if error != nil { self.stop("Connection lost. Start microphone again when ready.") }
            }
        })
    }
    func stop(_ reason: String = "Microphone is off") {
        generation += 1; running = false; timeout?.cancel(); timeout = nil
        connection?.cancel(); connection = nil; pending = 0
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }; engine = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        message = reason
    }
}
