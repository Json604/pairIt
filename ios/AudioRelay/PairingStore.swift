import Foundation
import Security
import Combine

struct PairedMac: Codable {
    let host: String
    let pin: String
    let token: String
    var name: String?
    var platform: String?
    var protocolVersion: String?
    enum CodingKeys: String, CodingKey { case host, pin, token, name, platform; case protocolVersion = "protocol" }
    var displayName: String {
        let clean = name?.filter { !$0.isNewline && !$0.isASCIIControl }.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clean.isEmpty ? (platform == "windows" ? "Your Windows PC" : "Your computer") : String(clean.prefix(80))
    }
    /// Older pairing archives may not carry a platform. The pinned TLS identity
    /// remains authoritative, so keep the Mac preview available for those entries.
    var supportsBluetoothReceiver: Bool {
        guard let platform = platform?.lowercased(), !platform.isEmpty else { return true }
        return platform == "macos" || platform == "mac"
    }
    static func validHost(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 253 && host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil && !host.contains("/")
    }

    static func parse(_ code: String) throws -> PairedMac {
        var raw = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("audiorelay://pair/") { raw = String(raw.dropFirst("audiorelay://pair/".count)) }
        guard raw.count < 4096 else { throw PairingError.invalidCode }
        raw = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        raw += String(repeating: "=", count: (4 - raw.count % 4) % 4)
        guard let data = Data(base64Encoded: raw), let value = try? JSONDecoder().decode(PairedMac.self, from: data),
              validHost(value.host),
              value.pin.utf8.count == 64, value.token.utf8.count == 64,
              value.pin.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              value.token.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw PairingError.invalidCode }
        return value
    }
}

enum PairingError: LocalizedError {
    case invalidCode, storage(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalidCode: return "That code doesn’t look right. Copy the complete code from PairIt on your computer."
        case .storage: return "Your computer couldn’t be saved securely. Unlock your iPhone and try again."
        }
    }
}

final class PairingStore: ObservableObject {
    @Published private(set) var mac: PairedMac?
    @Published private(set) var computers: [PairedMac] = []
    private let service: String
    private struct Archive: Codable { var computers: [PairedMac]; var selectedPin: String? }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "mac"]
    }
    var hostOverride: String? {
        guard let mac else { return nil }
        let value = UserDefaults.standard.string(forKey: "hostOverride:" + mac.pin) ?? ""
        return value.isEmpty ? nil : value
    }
    var bluetoothEnabled: Bool {
        guard let mac else { return false }
        return mac.supportsBluetoothReceiver && UserDefaults.standard.bool(forKey: "bluetoothReceiver:" + mac.pin)
    }
    func setBluetoothEnabled(_ enabled: Bool) {
        guard let mac, mac.supportsBluetoothReceiver else { return }
        UserDefaults.standard.set(enabled, forKey: "bluetoothReceiver:" + mac.pin)
        objectWillChange.send()
    }
    func setHostOverride(_ value: String) throws {
        guard let mac else { return }
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard host.isEmpty || PairedMac.validHost(host) else { throw PairingError.invalidCode }
        UserDefaults.standard.set(host, forKey: "hostOverride:" + mac.pin)
        objectWillChange.send()
    }
    init(service: String = "dev.bluetoothswitch.iosrelay.pairing") {
        self.service = service
        var read = query
        read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(read as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return }
        if let archive = try? JSONDecoder().decode(Archive.self, from: data) {
            computers = archive.computers
            mac = computers.first { $0.pin == archive.selectedPin }
        } else if let legacy = try? JSONDecoder().decode(PairedMac.self, from: data) {
            computers = [legacy]; mac = legacy
        }
    }
    func savedComputer(pin: String) -> PairedMac? { computers.first { $0.pin == pin } }
    func save(_ value: PairedMac) throws {
        var saved = computers.filter { $0.pin != value.pin }; saved.append(value)
        try persist(saved, selectedPin: value.pin)
    }
    private func persist(_ saved: [PairedMac], selectedPin: String?) throws {
        let data = try JSONEncoder().encode(Archive(computers: saved, selectedPin: selectedPin))
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(addition as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PairingError.storage(status) }
        computers = saved; mac = saved.first { $0.pin == selectedPin }
    }
    func forget(pin: String? = nil) throws {
        guard let pin = pin ?? mac?.pin else { return }
        try persist(computers.filter { $0.pin != pin }, selectedPin: mac?.pin == pin ? nil : mac?.pin)
        UserDefaults.standard.removeObject(forKey: "hostOverride:" + pin)
        UserDefaults.standard.removeObject(forKey: "bluetoothReceiver:" + pin)
        UserDefaults.standard.removeObject(forKey: "bluetoothPeripheral:" + pin)
    }

}

struct RouteTiming {
    let key: String
    init(pin: String, route: String, mode: RelayPlaybackMode = .reliable, hostOverride: String? = nil, bluetooth: Bool = false) {
        // The original Reliable key is deliberately retained for existing routes.
        key = "timing:\(pin):\(route)" + (mode == .reliable ? "" : ":interactive") + (hostOverride.map { ":manual:\($0)" } ?? "") + (bluetooth ? ":bluetooth" : "")
    }
    var estimate: Int? { UserDefaults.standard.object(forKey: key + ":estimate") as? Int }
    var correction: Int { UserDefaults.standard.integer(forKey: key + ":correction") }
    var effective: Int? { estimate.map { max(0, min(2000, $0 + correction)) } }
    func saveEstimate(_ value: Int) { UserDefaults.standard.set(value, forKey: key + ":estimate") }
    func setCorrection(_ value: Int) { UserDefaults.standard.set(max(-500, min(500, value)), forKey: key + ":correction") }
}

private extension Character {
    var isASCIIControl: Bool { unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
}
