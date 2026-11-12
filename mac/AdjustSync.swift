// Real-device calibration helper. Only changes this app's selected sync aggregate.
// Usage: xcrun swift mac/AdjustSync.swift [milliseconds] [--save]
// Without a delay, reads the current setting. --save keeps it for future sessions.
import Foundation
import CoreAudio

func property(_ selector: AudioObjectPropertySelector,
              _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func require(_ status: OSStatus, _ operation: String) throws {
    if status != noErr {
        throw NSError(domain: operation, code: Int(status))
    }
}
func read<T>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
             _ initial: T, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
    var address = property(selector, scope), result = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &result) {
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
    }
    try require(status, "Read property \(selector) on \(device)")
    return result
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let save = arguments.contains("--save")
    let requested = arguments.filter { $0 != "--save" }
    guard requested.count <= 1 else { throw NSError(domain: "Use at most one delay argument", code: 1) }
    var milliseconds: Double?
    if let argument = requested.first {
        guard let value = Double(argument), value.isFinite, (0...1000).contains(value) else {
            throw NSError(domain: "Delay must be between 0 and 1000 ms", code: 1)
        }
        milliseconds = value
    }
    let output = try read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
    var uidAddress = property(kAudioDevicePropertyDeviceUID)
    var reference: Unmanaged<CFString>?
    var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try require(AudioObjectGetPropertyData(output, &uidAddress, 0, nil, &uidSize, &reference), "Read output identity")
    guard let uid = reference?.takeRetainedValue(), (uid as String).hasPrefix("dev.bluetoothswitch.sync.") else {
        throw NSError(domain: "Start the relay first; selected output is not its sync aggregate", code: 1)
    }
    var listAddress = property(kAudioObjectPropertyOwnedObjects)
    var subdeviceClass = kAudioSubDeviceClassID
    let qualifierSize = UInt32(MemoryLayout<AudioClassID>.size)
    var listSize: UInt32 = 0
    try require(AudioObjectGetPropertyDataSize(output, &listAddress, qualifierSize, &subdeviceClass, &listSize), "Read subdevice size")
    guard listSize == UInt32(MemoryLayout<AudioObjectID>.size) else {
        throw NSError(domain: "Expected exactly one relay output subdevice", code: 1)
    }
    var subdevice: AudioObjectID = 0
    try require(AudioObjectGetPropertyData(output, &listAddress, qualifierSize, &subdeviceClass, &listSize, &subdevice), "Read owned subdevice")
    let rate = try read(output, kAudioDevicePropertyNominalSampleRate, Double(0))
    guard rate > 0 else { throw NSError(domain: "Invalid output sample rate", code: 1) }
    let before = try read(subdevice, kAudioSubDevicePropertyExtraLatency, Double(0), kAudioObjectPropertyScopeOutput)
    print("output=\(output) compensationBeforeMs=\(before * 1000 / rate)")
    if let milliseconds {
        var address = property(kAudioSubDevicePropertyExtraLatency, kAudioObjectPropertyScopeOutput)
        var writable = DarwinBoolean(false)
        try require(AudioObjectIsPropertySettable(subdevice, &address, &writable), "Check adjustable latency")
        guard writable.boolValue else { throw NSError(domain: "Output latency is not adjustable", code: 1) }
        var frames = rate * milliseconds / 1000
        try require(AudioObjectSetPropertyData(subdevice, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &frames), "Set output compensation")
    }
    let after = try read(subdevice, kAudioSubDevicePropertyExtraLatency, Double(0), kAudioObjectPropertyScopeOutput)
    print("compensationAfterMs=\(after * 1000 / rate)")
    // Derived aggregate properties can remain cached in the writer process.
    // Re-run without a delay to inspect the effective safety offset independently.
    if milliseconds == nil {
        let safety = try read(output, kAudioDevicePropertySafetyOffset, UInt32(0), kAudioObjectPropertyScopeOutput)
        print("effectiveSafetyFrames=\(safety)")
    }
    if let milliseconds, abs(after * 1000 / rate - milliseconds) > 0.1 {
        throw NSError(domain: "Output did not accept requested compensation", code: 1)
    }
    if save {
        let calibratedMs = after * 1000 / rate
        guard calibratedMs.isFinite, (0...1000).contains(calibratedMs) else {
            throw NSError(domain: "Refusing to save invalid compensation", code: 1)
        }
        let domain = "dev.bluetoothswitch.macrelay" as CFString
        CFPreferencesSetAppValue("videoCompensationMs" as CFString, calibratedMs as CFNumber, domain)
        guard CFPreferencesAppSynchronize(domain) else {
            throw NSError(domain: "Could not save calibration", code: 1)
        }
        print("savedForFutureSessionsMs=\(calibratedMs)")
    }
} catch {
    fputs("Calibration failed: \(error)\n", stderr)
    exit(1)
}
