import AVFAudio
import CoreAudio
import AudioToolbox
import Foundation

struct MicrophoneDestination: Identifiable, Equatable {
    let id: String
    let name: String
    let device: AudioObjectID
}

protocol MicrophoneSink: AnyObject {
    func start(uid: String) throws
    func accept(_ pcm: Data, frames: Int, sequence: UInt32) throws
    func stop()
}

/// Feeds an explicitly selected virtual cable. Never selects the system default.
final class MicrophoneOutput: MicrophoneSink {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "pairit.microphone.output", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var pendingFrames = 0
    private var generation = 0
    private var previousSequence: UInt32?
    private var destination: String?
    private var observer: NSObjectProtocol?
    private var failed = false
    private var started = false
    private var finished = false
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!

    init() { queue.setSpecific(key: queueKey, value: 1) }
    private func onQueue<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try operation() }
        return try queue.sync(execute: operation)
    }

    static func destinations() -> [MicrophoneDestination] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.compactMap { device in
            var transport: UInt32 = 0, bytes: UInt32 = 4
            address.mSelector = kAudioDevicePropertyTransportType
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeVirtual,
                  let uid = string(device, kAudioDevicePropertyDeviceUID),
                  uid != SyncOutput.deviceUID, !uid.hasPrefix("dev.bluetoothswitch.sync."),
                  hasChannels(device, scope: kAudioObjectPropertyScopeInput),
                  hasChannels(device, scope: kAudioObjectPropertyScopeOutput) else { return nil }
            return MicrophoneDestination(id: uid, name: string(device, kAudioObjectPropertyName) ?? "Virtual audio device", device: device)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private static func string(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    private static func hasChannels(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size >= MemoryLayout<AudioBufferList>.size else { return false }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory) == noErr else { return false }
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).contains { $0.mNumberChannels > 0 }
    }
    func start(uid: String) throws {
        try onQueue { try open(uid: uid) }
    }
    private func open(uid: String) throws {
        guard let output = Self.destinations().first(where: { $0.id == uid }),
              let unit = engine.outputNode.audioUnit else {
            throw AudioFailure(description: "Choose an installed virtual audio cable in Mac Settings.")
        }
        var device = output.device
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout.size(ofValue: device))), "Select microphone destination")
        var selected: AudioObjectID = 0, size: UInt32 = 4
        try check(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selected, &size), "Check microphone destination")
        guard selected == device else { throw AudioFailure(description: "The virtual microphone destination changed.") }
        destination = uid
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            // Never let an engine configuration change redirect this stream.
            self?.queue.async { [weak self] in self?.invalidate() }
        }
        engine.prepare(); try engine.start()
    }
    private func invalidate() {
        guard !finished else { return }
        lock.lock(); failed = true; lock.unlock()
        player.stop(); engine.stop()
    }
    func accept(_ pcm: Data, frames: Int, sequence: UInt32) throws {
        try onQueue { try schedule(pcm, frames: frames, sequence: sequence) }
    }
    private func schedule(_ pcm: Data, frames: Int, sequence: UInt32) throws {
        guard frames > 0, frames <= 960, pcm.count == frames * 2 else { throw AudioFailure(description: "Invalid microphone frame") }
        lock.lock(); let unavailable = failed; lock.unlock()
        guard !unavailable, engine.isRunning, destination != nil else { throw AudioFailure(description: "Microphone destination is unavailable") }
        if let previousSequence, sequence != previousSequence &+ 1 {
            player.stop(); lock.lock(); generation += 1; pendingFrames = 0; lock.unlock(); started = false
        }
        previousSequence = sequence
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)), let samples = buffer.floatChannelData?[0] else { throw AudioFailure(description: "Microphone buffer unavailable") }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            for frame in 0..<frames { samples[frame] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: frame * 2, as: Int16.self))) / 32768 }
        }
        lock.lock()
        guard pendingFrames + frames <= 4800 else { lock.unlock(); throw AudioFailure(description: "Microphone output stalled") }
        pendingFrames += frames; let epoch = generation; let ready = pendingFrames >= 1920
        lock.unlock()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            if self.generation == epoch { self.pendingFrames = max(0, self.pendingFrames - frames) }
            self.lock.unlock()
        }
        if !started && ready { player.play(); started = true }
    }
    func stop() {
        onQueue { finish() }
    }
    private func finish() {
        guard !finished else { return }
        finished = true
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        player.stop(); engine.stop(); engine.reset()
        lock.lock(); generation += 1; pendingFrames = 0; failed = true; lock.unlock()
        destination = nil; previousSequence = nil; started = false
    }
    deinit { if !finished { stop() } }
}
