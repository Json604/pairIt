import Foundation

struct RelayPhone: Equatable, Identifiable {
    enum State: Equatable { case listening, paused, connected }
    let id: UUID
    let name: String
    let state: State
    let level: Int?
    let canDisconnect: Bool
    var installation: String? = nil
}

@main
struct NearbyPhonesCheck {
    static func main() {
        let id1 = String(repeating: "a", count: 32)
        let id2 = String(repeating: "b", count: 32)
        let id3 = String(repeating: "c", count: 32)
        let id4 = String(repeating: "d", count: 32)

        // Three offline duplicates of the same phone collapse into one row carrying all IDs.
        let collapsed = NearbyPhones.deduplicated([
            .init(id: id3, name: "moto g85 5G", available: false),
            .init(id: id2, name: "moto g85 5G", available: false),
            .init(id: id1, name: "moto g85 5G", available: false),
            .init(id: id4, name: "Pixel 9", available: false),
        ])
        precondition(collapsed.count == 2, "Expected 2 rows after deduplication, got \(collapsed.count)")
        precondition(collapsed[0].id == id3 && collapsed[0].name == "moto g85 5G")
        precondition(Set(collapsed[0].allIDs) == Set([id1, id2, id3]))
        precondition(collapsed[1].id == id4 && collapsed[1].allIDs == [id4])

        // If an older installation ID is actually open nearby, promote it and fold offline duplicates into it.
        let promoted = NearbyPhones.deduplicated([
            .init(id: id3, name: "moto g85 5G", available: false),
            .init(id: id2, name: "moto g85 5G", available: true),
            .init(id: id1, name: "moto g85 5G", available: false),
        ])
        precondition(promoted.count == 1)
        precondition(promoted[0].id == id2 && promoted[0].available)
        precondition(Set(promoted[0].allIDs) == Set([id1, id2, id3]))

        // Two distinct phones with the same name that are BOTH open nearby are both shown.
        let bothOnline = NearbyPhones.deduplicated([
            .init(id: id2, name: "iPhone", available: true),
            .init(id: id1, name: "iPhone", available: true),
            .init(id: id3, name: "iPhone", available: false),
        ])
        precondition(bothOnline.count == 2)
        precondition(bothOnline.allSatisfy(\.available))

        // Connected phone hides both its own ID and offline stale duplicates with the same name,
        // while keeping a genuinely open second phone of the same name.
        let connected = [RelayPhone(id: UUID(), name: "moto g85 5G", state: .listening, level: nil, canDisconnect: true, installation: id3)]
        let reconnectable = NearbyPhones.reconnectable(remembered: [
            .init(id: id2, name: "moto g85 5G", available: false),
            .init(id: id1, name: "moto g85 5G", available: true),
            .init(id: id4, name: "Pixel 9", available: false),
        ], connected: connected)
        precondition(reconnectable.map(\.id) == [id1, id4])

        // Persistence + remember + 1-click forget of all collapsed duplicate IDs.
        let suite = "pairit.test.nearby.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([
            ["id": id3, "name": "moto g85 5G"],
            ["id": id2, "name": "moto g85 5G"],
            ["id": id1, "name": "moto g85 5G"],
            ["id": id4, "name": "Pixel 9"],
        ], forKey: "rememberedPhones")

        let nearby = NearbyPhones(defaults: defaults)
        var latest: [NearbyPhones.Phone] = []
        var callbacks = 0
        nearby.onChange = { phones in latest = phones; callbacks += 1 }
        func waitForCallback(_ target: Int) -> Bool {
            let deadline = Date().addingTimeInterval(3)
            while callbacks < target && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return callbacks >= target
        }
        nearby.remember([RelayPhone(id: UUID(), name: "Pixel 9", state: .listening, level: nil, canDisconnect: true, installation: id4)])
        precondition(waitForCallback(1), "Timed out waiting for remember callback")
        precondition(latest.map(\.name) == ["Pixel 9", "moto g85 5G"])
        precondition(Set(latest[1].allIDs) == Set([id1, id2, id3]))

        nearby.forget(latest[1].allIDs)
        precondition(waitForCallback(2), "Timed out waiting for forget callback")
        precondition(latest.map(\.name) == ["Pixel 9"])
        let remaining = defaults.array(forKey: "rememberedPhones") as? [[String: String]] ?? []
        precondition(remaining.count == 1 && remaining[0]["id"] == id4)

        print("PASS: Mac NearbyPhones deduplication, promotion, reconnect filtering, and 1-click forget verified.")
    }
}
