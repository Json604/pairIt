// Real Core Audio capability probe. Does not change the selected output device.
import Foundation
import CoreAudio

func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func uint(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32 {
    var a = address(selector, scope), v: UInt32 = 0, size: UInt32 = 4
    let status = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v)
    if status != 0 { print("read \(selector) failed \(status)") }
    return v
}
func describe(_ id: AudioObjectID) {
    let scope = kAudioObjectPropertyScopeOutput
    print("device=\(id) latencyFrames=\(uint(id, kAudioDevicePropertyLatency, scope)) safetyFrames=\(uint(id, kAudioDevicePropertySafetyOffset, scope))")
    var a = address(kAudioDevicePropertyStreams, scope), size: UInt32 = 0
    AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size)
    var streams = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    if size > 0 {
        streams.withUnsafeMutableBytes { _ = AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0.baseAddress!) }
        for stream in streams { print("  stream=\(stream) latencyFrames=\(uint(stream, kAudioStreamPropertyLatency))") }
    }
}
let original = uint(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
var uidReference: Unmanaged<CFString>?
var a = address(kAudioDevicePropertyDeviceUID), size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
let result = AudioObjectGetPropertyData(original, &a, 0, nil, &size, &uidReference)
guard result == 0, let uid = uidReference?.takeRetainedValue() else { fatalError("Cannot read current output") }
print("CURRENT OUTPUT")
describe(original)
for frames in [0, 12000] {
    let composition: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Audio Relay Latency Probe",
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceMainSubDeviceKey: uid,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid, kAudioSubDeviceExtraOutputLatencyKey: frames]]
    ]
    var aggregate: AudioObjectID = 0
    let status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
    print("PROBE extraFrames=\(frames) createStatus=\(status)")
    if status == 0 { describe(aggregate); AudioHardwareDestroyAggregateDevice(aggregate) }
}
