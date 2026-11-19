import Foundation
import Combine
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

/// Discovery is display metadata only. Pairing still requires a private QR code and pinned TLS.
final class NearbyDevices: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static var localName: String {
        #if canImport(UIKit)
        let raw = UIDevice.current.name
        #else
        let raw = "iPhone"
        #endif
        var clean = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format }.map(String.init).joined().prefix(64)).trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.utf8.count > 256 { clean.removeLast() }
        return clean.isEmpty ? "iPhone" : clean
    }
    static var encodedName: String { Data(localName.utf8).base64EncodedString() }
    struct Device: Identifiable {
        let id: String
        let name: String
        let platform: String
        let pin: String?
        let host: String?
        var invitationPort: Int = 0
    }
    @Published private(set) var computers: [Device] = []
    @Published private(set) var phones: [Device] = []
    private var browsers: [NetServiceBrowser] = []
    private var services: [String: NetService] = [:]
    private var found: [String: Device] = [:]
    private var advertisement: NetService?
    private var sessionName = ""
    private let presenceID = UUID().uuidString
    private var running = false
    var invitationPort = 0
    /// Comma-separated daily tags, one per saved computer (TXT "c"). See `tag`.
    var computerTags = "" {
        didSet { if computerTags != oldValue, let advertisement { advertisement.setTXTRecord(txtRecord()) } }
    }
    /// One daily-rotating tag per saved computer: SHA-256("token:installation:day"), first 6 bytes
    /// as hex. Only a computer holding that pairing token can recognise (and offer to connect) this phone.
    static func tag(token: String, installation: String, day: Int) -> String {
        SHA256.hash(data: Data("\(token):\(installation):\(day)".utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
    static func tags(tokens: [String], installation: String, now: Date = Date()) -> String {
        let day = Int(now.timeIntervalSince1970 / 86400)
        return tokens.prefix(8).map { tag(token: $0, installation: installation, day: day) }.joined(separator: ",")
    }
    private func txtRecord() -> Data {
        var fields = ["invite": Data((invitationPort > 0 ? "1" : "0").utf8), "id": Data(presenceID.utf8), "role": Data("phone".utf8), "v": Data("1".utf8), "platform": Data("ios".utf8), "name": Data(Self.localName.utf8)]
        if !computerTags.isEmpty { fields["c"] = Data(computerTags.utf8) }
        return NetService.data(fromTXTRecord: fields)
    }

    func start() {
        guard !running else { return }; running = true
        for type in ["_audiorelay._tcp.", "_pairit-phone._tcp."] {
            let browser = NetServiceBrowser(); browser.delegate = self
            browsers.append(browser); browser.searchForServices(ofType: type, inDomain: "local.")
        }
    }
    func showTogether(_ active: Bool) {
        guard active else { advertisement?.stop(); advertisement = nil; return }
        guard advertisement == nil else { return }
        sessionName = UUID().uuidString
        let service = NetService(domain: "local.", type: "_pairit-phone._tcp.", name: sessionName, port: Int32(invitationPort > 0 ? invitationPort : 9))
        service.setTXTRecord(txtRecord())
        advertisement = service; service.publish()
    }
    func stop() {
        showTogether(false); browsers.forEach { $0.stop() }; browsers.removeAll()
        services.values.forEach { $0.stop() }; services.removeAll(); found.removeAll()
        computers = []; phones = []; running = false
    }
    private func key(_ service: NetService) -> String { service.type + service.name }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard running, browsers.contains(where: { $0 === browser }), service.name != sessionName, services.count < 64 else { return }
        services[key(service)]?.stop()
        services[key(service)] = service; service.delegate = self; service.resolve(withTimeout: 5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard running, browsers.contains(where: { $0 === browser }) else { return }
        let id = key(service); services.removeValue(forKey: id)?.stop(); found.removeValue(forKey: id); publish()
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard running, services[key(sender)] === sender else { return }
        guard let data = sender.txtRecordData(), data.count <= 2048 else { discard(sender); return }
        guard NetService.dictionary(fromTXTRecord: data)["id"] != Data(presenceID.utf8) else { discard(sender); return }
        if var device = Self.decode(type: sender.type, id: key(sender), data: data, host: sender.hostName) {
            guard device.pin == nil || sender.port == 5002 else { discard(sender); return }
            if device.pin == nil, NetService.dictionary(fromTXTRecord: data)["invite"] == Data("1".utf8), sender.port > 0, sender.port <= 65535 { device.invitationPort = sender.port }
            found[key(sender)] = device; publish()
        } else { discard(sender) }
    }
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) { discard(sender) }
    private func discard(_ service: NetService) {
        let id = key(service)
        guard services[id] === service else { return }
        services.removeValue(forKey: id)?.stop(); found.removeValue(forKey: id); publish()
    }
    static func decode(type: String, id: String, data: Data, host: String? = nil) -> Device? {
        guard data.count <= 2048 else { return nil }
        let record = NetService.dictionary(fromTXTRecord: data)
        func value(_ field: String) -> String { record[field].flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        let platform = value("platform"), role = value("role")
        guard value("v") == "1" else { return nil }
        let phone = type == "_pairit-phone._tcp." && role == "phone" && ["android", "ios"].contains(platform)
        let computer = type == "_audiorelay._tcp." && role == "computer" && ["macos", "windows", "linux"].contains(platform)
        guard phone || computer else { return nil }
        let pin = value("pin")
        guard !computer || (pin.utf8.count == 64 && pin.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil) else { return nil }
        let name = String(value("name").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(60).map(String.init).joined())
        return Device(id: id, name: name.isEmpty ? (phone ? "Phone" : "Computer") : name, platform: platform, pin: computer ? pin : nil, host: host)
    }
    private func publish() {
        computers = found.values.filter { $0.pin != nil }.sorted { $0.name < $1.name }
        phones = found.values.filter { $0.pin == nil }.sorted { $0.name < $1.name }
    }
}
