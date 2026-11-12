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
    static var adjustments: [Double] = []
    private var nextTime: UInt64 = 0
    private var sequence: UInt32 = 0
    func start() throws {
        Self.lock.lock(); Self.starts += 1; Self.starting += 1; let delay = Self.startDelay; Self.lock.unlock()
        Thread.sleep(forTimeInterval: delay)
        Self.lock.lock(); Self.starting -= 1; Self.lock.unlock()
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
        var result = Data(count: 1048)
        result.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(0x31415342).littleEndian, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: sequence.littleEndian, toByteOffset: 4, as: UInt32.self)
            raw.storeBytes(of: UInt32(48000).littleEndian, toByteOffset: 8, as: UInt32.self)
            raw.storeBytes(of: UInt32(256).littleEndian, toByteOffset: 12, as: UInt32.self)
            raw.storeBytes(of: now.littleEndian, toByteOffset: 16, as: UInt64.self)
        }
        sequence &+= 1; return result
    }
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
        try server.start()
        print("READY"); fflush(stdout)
        while let line = readLine() {
            if line == "reserve" { print(server.reserveMicrophone() ? "RESERVED" : "BUSY"); fflush(stdout) }
            if line == "release" { server.releaseMicrophone(); print("RELEASED"); fflush(stdout) }
            if line == "slow-start" { Capture.lock.lock(); Capture.startDelay = 0.3; Capture.lock.unlock(); print("OK"); fflush(stdout) }
            if line == "stats" {
                Capture.lock.lock()
                let result: [String: Any] = ["starts": Capture.starts, "stops": Capture.stops, "starting": Capture.starting, "stopping": Capture.stopping, "adjustments": Capture.adjustments]
                Capture.lock.unlock()
                print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!); fflush(stdout)
            }
            if line == "stop" { break }
        }
        server.stop()
        print("STOPPED"); fflush(stdout)
        #endif
    }
}
