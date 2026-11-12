// Live experiment: expose downstream latency through a temporary aggregate output.
// Always restore the prior output on normal exit, SIGINT, SIGTERM, or timeout.
import Foundation
import CoreAudio
import Darwin

setbuf(stdout, nil)
let system = AudioObjectID(kAudioObjectSystemObject)
func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
func defaultOutput() -> AudioObjectID {
    var a = property(kAudioHardwarePropertyDefaultOutputDevice), value: AudioObjectID = 0, size: UInt32 = 4
    AudioObjectGetPropertyData(system, &a, 0, nil, &size, &value)
    return value
}
func select(_ id: AudioObjectID) -> OSStatus {
    var a = property(kAudioHardwarePropertyDefaultOutputDevice), value = id
    return AudioObjectSetPropertyData(system, &a, 0, nil, 4, &value)
}
let original = defaultOutput()
var uid: Unmanaged<CFString>?
var uidAddress = property(kAudioDevicePropertyDeviceUID)
var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
guard AudioObjectGetPropertyData(original, &uidAddress, 0, nil, &uidSize, &uid) == 0,
      let uidValue = uid?.takeRetainedValue() else { fatalError("Cannot read original output UID") }
var sampleRate = 48000.0, rateSize: UInt32 = 8
var rateAddress = property(kAudioDevicePropertyNominalSampleRate)
AudioObjectGetPropertyData(original, &rateAddress, 0, nil, &rateSize, &sampleRate)
let milliseconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 250 : 250
guard milliseconds >= 0 && milliseconds <= 1000 else { fatalError("Delay must be 0…1000 ms") }
let composition: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Audio Relay Video Sync Experiment",
    kAudioAggregateDeviceUIDKey: "dev.bluetoothswitch.sync.\(UUID().uuidString)",
    kAudioAggregateDeviceIsPrivateKey: false,
    kAudioAggregateDeviceMainSubDeviceKey: uidValue,
    kAudioAggregateDeviceSubDeviceListKey: [[
        kAudioSubDeviceUIDKey: uidValue,
        kAudioSubDeviceExtraOutputLatencyKey: sampleRate * milliseconds / 1000
    ]]
]
var aggregate: AudioObjectID = 0
let created = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
guard created == 0 else { fatalError("Cannot create experiment output: \(created)") }
let selection = select(aggregate)
guard selection == 0 else {
    AudioHardwareDestroyAggregateDevice(aggregate)
    fatalError("Cannot select experiment output: \(selection)")
}
print("SYNC EXPERIMENT selected output=\(aggregate) extra=\(milliseconds)ms original=\(original); auto-restores in 180s")
func restore() {
    if defaultOutput() == aggregate { print("Restore output status=\(select(original))") }
    print("Destroy experiment status=\(AudioHardwareDestroyAggregateDevice(aggregate))")
    exit(0)
}
signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
interrupt.setEventHandler { restore() }; terminate.setEventHandler { restore() }
interrupt.resume(); terminate.resume()
DispatchQueue.main.asyncAfter(deadline: .now() + 180) { restore() }
RunLoop.main.run()
