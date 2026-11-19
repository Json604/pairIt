// Synthetic integration fixture: never imports or creates the real audio capture.
import Foundation
import CoreAudio
import Darwin

struct AudioFailure: Error { let description: String }
func check(_ value: OSStatus, _ message: String) throws { if value != noErr { throw AudioFailure(description: message) } }
func log(_ message: String) { }

final class Capture: RelayCaptureSource {
    static let lock = NSLock()
    static var starts = 0, stops = 0
    static var starting = 0, stopping = 0
    static var startDelay: TimeInterval = 0
    static var failNextStart = false
    static var audible = false
    static var adjustments: [Double] = []
    static var volumeLevel = 0.25
    static var volumeWrites: [Double] = []
    var computerVolume: ComputerVolume? { Self.lock.lock(); defer { Self.lock.unlock() }; return ComputerVolume(level: Self.volumeLevel, muted: false) }
    func setComputerVolume(_ level: Double) { Self.lock.lock(); Self.volumeLevel = level; Self.volumeWrites.append(level); Self.lock.unlock() }
    private var nextTime: UInt64 = 0
    private var sequence: UInt32 = 0
    func start() throws {
        Self.lock.lock(); Self.starts += 1; Self.starting += 1; let delay = Self.startDelay; Self.lock.unlock()
        Thread.sleep(forTimeInterval: delay)
        Self.lock.lock(); Self.starting -= 1; let fail = Self.failNextStart; Self.failNextStart = false; Self.lock.unlock()
        if fail { throw AudioFailure(description: "Synthetic capture startup failure") }
    }
    func stop() {
        Self.lock.lock(); Self.stopping += 1; Self.lock.unlock()
        Thread.sleep(forTimeInterval: 0.15) // A microphone cannot enter during HAL teardown.
        Self.lock.lock(); Self.stops += 1; Self.stopping -= 1; Self.lock.unlock()
    }
    func adjustSync(_ value: Double) throws {
        Self.lock.lock(); Self.adjustments.append(value); Self.lock.unlock()
        Thread.sleep(forTimeInterval: 0.15) // Exercise real HAL-refresh blocking budget.
    }
    func nextPacket() -> Data? {
        let now = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
        guard now >= nextTime else { return nil }
        nextTime = now + 5_333_333
        Self.lock.lock(); let audible = Self.audible; Self.lock.unlock()
        var result = Data(count: 1048)
        result.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(0x31415342).littleEndian, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: sequence.littleEndian, toByteOffset: 4, as: UInt32.self)
            raw.storeBytes(of: UInt32(48000).littleEndian, toByteOffset: 8, as: UInt32.self)
            raw.storeBytes(of: UInt32(256).littleEndian, toByteOffset: 12, as: UInt32.self)
            raw.storeBytes(of: now.littleEndian, toByteOffset: 16, as: UInt64.self)
            if audible { raw.storeBytes(of: Int16(1000).littleEndian, toByteOffset: 24, as: Int16.self) }
        }
        sequence &+= 1; return result
    }
}

final class FakeMedia: RelayMediaControl {
    static let shared = FakeMedia()
    let lock = NSLock()
    var presses = 0
    var available: Bool { true }
    func togglePlayPause() { lock.lock(); presses += 1; lock.unlock() }
    var skips: [Bool] = []
    func skip(forward: Bool) { lock.lock(); skips.append(forward); lock.unlock() }
}

@main struct Harness {
    static func main() throws {
        #if GATEWAY
        try runGateway(); return
        #else
        let port = UInt16(CommandLine.arguments[1])!
        let suite = "dev.bluetoothswitch.integration." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let server = RelayServer(port: port, preferences: preferences)
        server.mediaControl = FakeMedia.shared
        try server.start()
        print("READY " + server.gatewayToken); fflush(stdout)
        while let line = readLine() {
            if line == "phone-resume" || line == "phone-pause" { server.requestPhonePlayback(line == "phone-resume"); print("OK"); fflush(stdout) }
            if line == "audio-on" || line == "audio-off" { Capture.lock.lock(); Capture.audible = line == "audio-on"; Capture.lock.unlock(); print("OK"); fflush(stdout) }
            if line.hasPrefix("volume ") { Capture.lock.lock(); Capture.volumeLevel = Double(line.dropFirst(7))!; Capture.lock.unlock(); print("OK"); fflush(stdout) }
            if line.hasPrefix("disconnect ") {
                let name = String(line.dropFirst(11))
                let phone = server.phones.first { $0.name == name }
                if let phone { server.disconnectPhone(phone.id); print("OK") } else { print("MISSING") }; fflush(stdout)
            }
            if line == "phones" {
                let rows = server.phones.map { ["name": $0.name, "level": $0.level ?? -1, "state": "\($0.state)", "disconnect": $0.canDisconnect] as [String: Any] }
                print(String(data: try JSONSerialization.data(withJSONObject: rows), encoding: .utf8)!); fflush(stdout)
            }
            if line == "computer-output" { server.setComputerOutput(true); print("OK"); fflush(stdout) }
            if line == "phone-output" { server.setComputerOutput(false); print("OK"); fflush(stdout) }
            if line == "reserve" { print(server.reserveMicrophone() ? "RESERVED" : "BUSY"); fflush(stdout) }
            if line == "release" { server.releaseMicrophone(); print("RELEASED"); fflush(stdout) }
            if line == "slow-start" { Capture.lock.lock(); Capture.startDelay = 0.3; Capture.lock.unlock(); print("OK"); fflush(stdout) }
            if line == "fail-next-start" { Capture.lock.lock(); Capture.failNextStart = true; Capture.lock.unlock(); print("OK"); fflush(stdout) }
            if line == "stats" {
                Capture.lock.lock()
                var result: [String: Any] = ["starts": Capture.starts, "stops": Capture.stops, "starting": Capture.starting, "stopping": Capture.stopping, "adjustments": Capture.adjustments, "volumeWrites": Capture.volumeWrites]
                Capture.lock.unlock()
                FakeMedia.shared.lock.lock(); result["presses"] = FakeMedia.shared.presses; result["skips"] = FakeMedia.shared.skips; FakeMedia.shared.lock.unlock()
                print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!); fflush(stdout)
            }
            if line == "stop" { break }
        }
        server.stop()
        print("STOPPED"); fflush(stdout)
        #endif
    }
}
