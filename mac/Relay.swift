import AppKit
import CoreAudio
import AudioToolbox
import Foundation
import CoreImage
import Darwin

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

struct AudioFailure: Error, CustomStringConvertible {
    let description: String
}
func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw AudioFailure(description: "\(operation): OSStatus \(status)") }
}

// Single producer/single consumer. Callback never allocates packets or takes a mutex.
final class PacketQueue {
    private let ring = ARCreate()!
    var drops: UInt64 { ARDrops(ring) }
    func write(size: Int, fill: (UnsafeMutableRawPointer) -> Void) {
        guard let slot = ARWriteSlot(ring) else { return }
        fill(UnsafeMutableRawPointer(slot))
        ARCommit(ring, UInt32(size))
    }
    func pop() -> Data? {
        var size: UInt32 = 0
        guard let slot = ARReadSlot(ring, &size) else { return nil }
        let packet = Data(bytes: slot, count: Int(size))
        ARConsume(ring)
        return packet
    }
    deinit { ARDestroy(ring) }
}

final class Capture {
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private var format = AudioStreamBasicDescription()
    private var sequence: UInt32 = 0
    private var callbacks = 0
    private let syncOutput = SyncOutput()
    let queue = PacketQueue()

    func start() throws {
        // The phone sends its saved route calibration after connecting.
        let saved = UserDefaults.standard.object(forKey: "videoCompensationMs") as? Double
        let compensation = saved.flatMap { $0.isFinite && (0...2000).contains($0) ? $0 : nil } ?? 0
        try syncOutput.start(milliseconds: compensation)
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Audio Relay Lab"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tap), "Create audio tap")
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "Read tap format")
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32,
              [44100.0, 48000.0].contains(format.mSampleRate) else {
            throw AudioFailure(description: "Unsupported tap format: \(format)")
        }
        log("FORMAT rate=\(format.mSampleRate) channels=\(format.mChannelsPerFrame) bytesPerFrame=\(format.mBytesPerFrame) flags=\(format.mFormatFlags)")
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Audio Relay Lab Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "Create capture device")
        var requestedFrames: UInt32 = 256
        var bufferAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let bufferResult = AudioObjectSetPropertyData(device, &bufferAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &requestedFrames)
        log("Requested 256-frame capture buffer; status=\(bufferResult)")
        try check(AudioDeviceCreateIOProcIDWithBlock(&io, device, nil) { [weak self] _, input, inputTime, _, _ in
            self?.capture(input, inputTime.pointee.mHostTime)
        }, "Register audio callback")
        try check(AudioDeviceStart(device, io), "Start capture (allow System Audio Recording)")
        log("CAPTURE started; Mac output is muted while relaying")
    }

    func adjustSync(_ milliseconds: Double) throws { try syncOutput.adjust(milliseconds: milliseconds) }

    private func capture(_ input: UnsafePointer<AudioBufferList>, _ hostTime: UInt64) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mData != nil, first.mNumberChannels > 0 else { return }
        let frames = Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels))
        guard frames > 0 && frames <= 8192 else { return }
        queue.write(size: 24 + frames * 4) { raw in
            raw.storeBytes(of: UInt32(0x31415342).littleEndian, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: sequence.littleEndian, toByteOffset: 4, as: UInt32.self)
            raw.storeBytes(of: UInt32(format.mSampleRate).littleEndian, toByteOffset: 8, as: UInt32.self)
            raw.storeBytes(of: UInt32(frames).littleEndian, toByteOffset: 12, as: UInt32.self)
            raw.storeBytes(of: AudioConvertHostTimeToNanos(hostTime).littleEndian, toByteOffset: 16, as: UInt64.self)
            for frame in 0..<frames {
                for channel in 0..<2 {
                    let buffer = buffers.count > 1 ? buffers[min(channel, buffers.count - 1)] : first
                    let channels = Int(buffer.mNumberChannels)
                    guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self), channels > 0 else { continue }
                    let offset = frame * channels + (buffers.count > 1 ? 0 : min(channel, channels - 1))
                    guard (offset + 1) * 4 <= Int(buffer.mDataByteSize) else { continue }
                    let value = samples[offset].isFinite ? min(1, max(-1, samples[offset])) : 0
                    raw.storeBytes(of: Int16(value * 32767).littleEndian, toByteOffset: 24 + (frame * 2 + channel) * 2, as: Int16.self)
                }
            }
        }
        sequence &+= 1
        callbacks += 1
    }

    func stop() {
        guard tap != 0 || device != 0 else { syncOutput.stop(); return }
        if let io { AudioDeviceStop(device, io); AudioDeviceDestroyIOProcID(device, io) }
        io = nil
        if device != 0 { AudioHardwareDestroyAggregateDevice(device); device = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        syncOutput.stop()
        log("CAPTURE stopped; callbacks=\(callbacks) queueDrops=\(queue.drops); Mac output restored")
    }
    deinit { stop() }
}

extension Capture: RelayCaptureSource {
    func nextPacket() -> Data? { queue.pop() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
