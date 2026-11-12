import Foundation

final class SyntheticMicrophone: MicrophoneSink {
    static let lock = NSLock()
    static var frames = 0, sessions = 0, stopped = 0
    static var opening = 0, closing = 0, accepting = 0, maxAccepting = 0
    private var active = false
    private var stopDelay: TimeInterval = 0
    private var acceptDelay: TimeInterval = 0
    func start(uid: String) throws {
        if uid == "fail" { throw AudioFailure(description: "Synthetic unavailable endpoint") }
        let startDelay: TimeInterval = uid == "slow-open" ? 0.65 : uid == "timeout-open" ? 4.3 : 0
        stopDelay = uid == "slow-stop" || uid == "slow-open" ? 0.45 : 0
        acceptDelay = uid == "slow-accept" ? 0.65 : 0
        Self.lock.lock(); Self.sessions += 1; Self.opening += 1; Self.lock.unlock()
        Thread.sleep(forTimeInterval: startDelay)
        Self.lock.lock(); Self.opening -= 1; Self.lock.unlock(); active = true
    }
    func accept(_ pcm: Data, frames: Int, sequence: UInt32) throws {
        guard active, pcm.count == frames * 2 else { throw AudioFailure(description: "Invalid synthetic frame") }
        Self.lock.lock(); Self.accepting += 1; Self.maxAccepting = max(Self.maxAccepting, Self.accepting); Self.lock.unlock()
        Thread.sleep(forTimeInterval: acceptDelay)
        Self.lock.lock(); Self.frames += frames; Self.accepting -= 1; Self.lock.unlock()
    }
    func stop() {
        guard active else { return }; active = false
        Self.lock.lock(); Self.closing += 1; Self.lock.unlock()
        Thread.sleep(forTimeInterval: stopDelay)
        Self.lock.lock(); Self.stopped += 1; Self.closing -= 1; Self.lock.unlock()
    }
}

func runGateway() throws {
    let directory = URL(fileURLWithPath: CommandLine.arguments[3])
    let config = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: directory.appendingPathComponent("identity.json")))
    let suite = "dev.bluetoothswitch.integration." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let source = RelayServer(port: UInt16(CommandLine.arguments[2])!, preferences: preferences)
    let gateway = WiFiServer(port: UInt16(CommandLine.arguments[1])!, upstreamPort: UInt16(CommandLine.arguments[2])!,
                            upstreamToken: source.gatewayToken,
                            identityProvider: { LocalIdentity(directory: directory, config: config) },
                            makeMicrophone: { SyntheticMicrophone() })
    gateway.reserveMicrophone = { source.reserveMicrophone() }
    gateway.releaseMicrophone = { source.releaseMicrophone() }
    let pairingLock = NSLock()
    var pairings = 0
    gateway.onPairingConfirmed = { pairingLock.lock(); pairings += 1; pairingLock.unlock() }
    try source.start(); try gateway.start()
    print("READY"); fflush(stdout)
    while let line = readLine() {
        if line == "enable" { gateway.configureMicrophone(enabled: true, uid: "synthetic") }
        if line == "disable" { gateway.configureMicrophone(enabled: false, uid: "synthetic") }
        if line == "bad-output" { gateway.configureMicrophone(enabled: true, uid: "fail") }
        if ["slow-open", "slow-stop", "slow-accept", "timeout-open"].contains(line) { gateway.configureMicrophone(enabled: true, uid: line) }
        if line == "stats" {
            SyntheticMicrophone.lock.lock()
            var result: [String: Any] = ["micFrames": SyntheticMicrophone.frames, "micStarts": SyntheticMicrophone.sessions, "micStops": SyntheticMicrophone.stopped,
                                       "micOpening": SyntheticMicrophone.opening, "micClosing": SyntheticMicrophone.closing,
                                       "micAccepting": SyntheticMicrophone.accepting, "maxMicAccepting": SyntheticMicrophone.maxAccepting]
            SyntheticMicrophone.lock.unlock()
            Capture.lock.lock(); result["sourceStarts"] = Capture.starts; result["sourceStops"] = Capture.stops; Capture.lock.unlock()
            pairingLock.lock(); result["pairings"] = pairings; pairingLock.unlock()
            print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!); fflush(stdout)
        } else if line == "stop" { break }
        else { print("OK"); fflush(stdout) }
    }
    gateway.stop(); source.stop(); print("STOPPED"); fflush(stdout)
}
