import CoreAudio
import Foundation

// Publish downstream latency through a real output device. An aggregate's
// safety offset is not the presentation latency consumed by video players.
final class SyncOutput {
    static let deviceUID = "dev.bluetoothswitch.output"
    private var original: AudioObjectID = 0
    private var output: AudioObjectID = 0

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private static func devices() -> [AudioObjectID] {
        var a = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &result) == noErr else { return [] }
        return result
    }
    private static func uid(_ device: AudioObjectID) -> String? {
        var a = address(kAudioDevicePropertyDeviceUID), value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    private static func selectedOutput() -> AudioObjectID {
        var a = address(kAudioHardwarePropertyDefaultOutputDevice), value: AudioObjectID = 0, size: UInt32 = 4
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &value)
        return value
    }
    private static func select(_ device: AudioObjectID) -> OSStatus {
        var a = address(kAudioHardwarePropertyDefaultOutputDevice), value = device
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, 4, &value)
    }
    private static func owned(_ device: AudioObjectID) -> Bool {
        let value = uid(device) ?? ""
        return value == deviceUID || value.hasPrefix("dev.bluetoothswitch.sync.")
    }
    static var installed: Bool { devices().contains { uid($0) == deviceUID } }

    static func recoverAfterCrash() {
        let all = devices()
        let previousUID = UserDefaults.standard.string(forKey: "originalOutputUID")
        if owned(selectedOutput()) {
            guard let previous = all.first(where: { uid($0) == previousUID && !owned($0) }) else {
                log("RECOVERY original output unavailable; choose an output in Sound settings")
                return
            }
            _ = select(previous)
        }
        // Clean up only temporary aggregate outputs made by earlier app builds.
        for device in all where uid(device)?.hasPrefix("dev.bluetoothswitch.sync.") == true {
            _ = AudioHardwareDestroyAggregateDevice(device)
        }
        UserDefaults.standard.removeObject(forKey: "originalOutputUID")
    }

    func start(milliseconds: Double) throws {
        guard let device = Self.devices().first(where: { Self.uid($0) == Self.deviceUID }) else {
            throw AudioFailure(description: "Install Audio Relay Output from the Mac menu, then reconnect")
        }
        original = Self.selectedOutput()
        guard !Self.owned(original), let uid = Self.uid(original) else {
            throw AudioFailure(description: "Choose your normal output in Sound settings, then reconnect")
        }
        UserDefaults.standard.set(uid, forKey: "originalOutputUID")
        UserDefaults.standard.synchronize()
        output = device
        do {
            try setLatency(milliseconds)
            try check(Self.select(output), "Select Audio Relay output")
        } catch { stop(); throw error }
        log("SYNC driver output=\(output) original=\(original) presentationMs=\(milliseconds)")
    }

    func adjust(milliseconds: Double) throws {
        guard output != 0, Self.selectedOutput() == output else { return }
        try setLatency(milliseconds)
        // Some clients (including Chromium's AUHAL stream) cache hardware latency
        // when opening a stream. Reopen once after a stable route measurement.
        // The process tap continues muting local output throughout this transition.
        try check(Self.select(original), "Refresh media timing")
        Thread.sleep(forTimeInterval: 0.15)
        guard Self.selectedOutput() == original else { return }
        try check(Self.select(output), "Restore Audio Relay output")
        log("SYNC refreshed presentationMs=\(milliseconds)")
    }

    private func setLatency(_ milliseconds: Double) throws {
        guard milliseconds.isFinite, (0...2000).contains(milliseconds) else {
            throw AudioFailure(description: "Invalid video timing")
        }
        var a = Self.address(0x61726c79) // 'arly', CFNumber milliseconds
        let number: CFNumber = NSNumber(value: milliseconds)
        var value = Unmanaged.passUnretained(number)
        let result = withExtendedLifetime(number) {
            AudioObjectSetPropertyData(output, &a, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value)
        }
        try check(result, "Set output presentation latency")
        // Verify the standard property, not merely our custom configuration value.
        a.mSelector = kAudioDevicePropertyLatency; a.mScope = kAudioObjectPropertyScopeOutput
        var frames: UInt32 = 0, size: UInt32 = 4
        try check(AudioObjectGetPropertyData(output, &a, 0, nil, &size, &frames), "Read output presentation latency")
        var rate = 48000.0
        a = Self.address(kAudioDevicePropertyNominalSampleRate); size = 8
        try check(AudioObjectGetPropertyData(output, &a, 0, nil, &size, &rate), "Read output rate")
        guard abs(Double(frames) / rate * 1000 - milliseconds) < 1 else {
            throw AudioFailure(description: "Audio output did not apply video timing")
        }
        log("SYNC confirmed deviceLatencyFrames=\(frames) rate=\(rate)")
    }

    func stop() {
        guard output != 0 else { return }
        if Self.selectedOutput() == output { log("SYNC restore status=\(Self.select(original))") }
        output = 0
        UserDefaults.standard.removeObject(forKey: "originalOutputUID")
    }
    deinit { stop() }
}
