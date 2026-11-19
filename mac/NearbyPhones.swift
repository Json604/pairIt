import Foundation
import Network
import CryptoKit

/// Phones that have connected to this Mac before, and which of them have PairIt open
/// nearby. Phones advertise only daily-rotating tags derived from this Mac's pairing
/// token, so nobody else on the network can recognise or track them. "Connect" sends a
/// hint; the phone verifies it with this Mac over the pinned connection before acting.
final class NearbyPhones {
    struct Phone: Identifiable, Equatable {
        let id: String          // installation ID
        let name: String
        var available: Bool
    }
    private struct Seen { let tags: Set<String>; let name: String; let endpoint: NWEndpoint; var seenAt: TimeInterval }
    private let queue = DispatchQueue(label: "pairit.nearby-phones")
    private let defaults: UserDefaults
    private var browser: NWBrowser?
    private var results: [NWEndpoint: Seen] = [:]
    private var token = "", pin = ""
    var onChange: (([Phone]) -> Void)?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var remembered: [[String: String]] {
        get { defaults.array(forKey: "rememberedPhones") as? [[String: String]] ?? [] }
        set { defaults.set(Array(newValue.prefix(12)), forKey: "rememberedPhones") }
    }
    /// Called with the currently connected phones: remember (or rename) each one.
    func remember(_ phones: [RelayPhone]) {
        var list = remembered, changed = false
        for phone in phones {
            guard let id = phone.installation else { continue }
            let entry = ["id": id, "name": phone.name]
            if let index = list.firstIndex(where: { $0["id"] == id }) {
                if list[index] != entry { list.remove(at: index); list.insert(entry, at: 0); changed = true }
            } else { list.insert(entry, at: 0); changed = true }
        }
        if changed { remembered = list; queue.async { self.publish() } }
    }
    func forget(_ id: String) { remembered = remembered.filter { $0["id"] != id }; queue.async { self.publish() } }

    func start(token: String, pin: String) {
        queue.async {
            self.token = token; self.pin = pin
            self.browser?.cancel(); self.results = [:]
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_pairit-phone._tcp", domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self else { return }
                // Keep a phone that just vanished for a few seconds: an app re-registering its
                // advertisement must not make the Connect button flicker.
                let now = ProcessInfo.processInfo.systemUptime
                var seen = self.results.filter { now - $0.value.seenAt < 10 }
                for result in results {
                    guard case .bonjour(let txt) = result.metadata else { continue }
                    let tags = Set((txt["c"] ?? "").split(separator: ",").map(String.init))
                    guard !tags.isEmpty, txt["invite"] == "1" else { continue }
                    for (endpoint, old) in seen where !old.tags.isDisjoint(with: tags) { seen.removeValue(forKey: endpoint) }
                    seen[result.endpoint] = Seen(tags: tags, name: txt["name"] ?? "Phone", endpoint: result.endpoint, seenAt: now)
                }
                self.results = seen; self.publish()
                self.queue.asyncAfter(deadline: .now() + 10.5) { [weak self] in self?.expire() }
            }
            browser.stateUpdateHandler = { [weak self, weak browser] state in
                if case .failed = state, let self, let browser, self.browser === browser {
                    browser.cancel(); self.queue.asyncAfter(deadline: .now() + 3) { self.start(token: self.token, pin: self.pin) }
                }
            }
            self.browser = browser; browser.start(queue: self.queue)
        }
    }
    private func expire() {
        let now = ProcessInfo.processInfo.systemUptime
        let kept = results.filter { now - $0.value.seenAt < 10 }
        if kept.count != results.count { results = kept; publish() }
    }
    func stop() { queue.async { self.browser?.cancel(); self.browser = nil; self.results = [:]; self.publish() } }

    static func tag(token: String, installation: String, day: Int) -> String {
        SHA256.hash(data: Data("\(token):\(installation):\(day)".utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
    private func endpoint(for installation: String) -> Seen? {
        guard !token.isEmpty else { return nil }
        let day = Int(Date().timeIntervalSince1970 / 86_400)
        let tags = [day, day - 1, day + 1].map { Self.tag(token: token, installation: installation, day: $0) }
        return results.values.first { !$0.tags.isDisjoint(with: tags) }
    }
    private func publish() {
        let phones = remembered.compactMap { entry -> Phone? in
            guard let id = entry["id"] else { return nil }
            return Phone(id: id, name: entry["name"] ?? "Phone", available: endpoint(for: id) != nil)
        }
        DispatchQueue.main.async { [weak self] in self?.onChange?(phones) }
    }
    /// Sends the connect hint. Returns false when the phone is not currently reachable.
    func requestConnection(_ installation: String, completion: @escaping (Bool) -> Void) {
        queue.async {
            guard let seen = self.endpoint(for: installation), !self.pin.isEmpty else { DispatchQueue.main.async { completion(false) }; return }
            let connection = NWConnection(to: seen.endpoint, using: .tcp)
            var finished = false
            let finish: (Bool) -> Void = { ok in
                guard !finished else { return }; finished = true; connection.cancel()
                DispatchQueue.main.async { completion(ok) }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Data("CONNECT1 \(self.pin)\n".utf8), completion: .contentProcessed { error in finish(error == nil) })
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + 5) { finish(false) }
        }
    }
}
