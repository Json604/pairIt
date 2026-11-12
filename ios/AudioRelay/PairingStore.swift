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
    private let service = "dev.bluetoothswitch.iosrelay.pairing"
    var hostOverride: String? {
        guard let mac else { return nil }
        let value = UserDefaults.standard.string(forKey: "hostOverride:" + mac.pin) ?? ""
        return value.isEmpty ? nil : value
    }
    func setHostOverride(_ value: String) throws {
        guard let mac else { return }
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard host.isEmpty || PairedMac.validHost(host) else { throw PairingError.invalidCode }
        UserDefaults.standard.set(host, forKey: "hostOverride:" + mac.pin)
        objectWillChange.send()
    }
    init() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "mac", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            mac = try? JSONDecoder().decode(PairedMac.self, from: data)
        }
    }
    func save(_ value: PairedMac) throws {
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "mac"]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(addition as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PairingError.storage(status) }
        mac = value
    }
    func forget() {
        if let mac { UserDefaults.standard.removeObject(forKey: "hostOverride:" + mac.pin) }
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "mac"] as CFDictionary)
        mac = nil
    }
}

struct RouteTiming {
    let key: String
    init(pin: String, route: String, mode: RelayPlaybackMode = .reliable, hostOverride: String? = nil) {
        // The original Reliable key is deliberately retained for existing routes.
        key = "timing:\(pin):\(route)" + (mode == .reliable ? "" : ":interactive") + (hostOverride.map { ":manual:\($0)" } ?? "")
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
