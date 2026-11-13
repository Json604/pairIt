import Foundation

@main struct NearbyDevicesCheck {
    static func main() {
        let pin = String(repeating: "a", count: 64)
        func decode(_ type: String, _ fields: [String: String]) -> NearbyDevices.Device? {
            NearbyDevices.decode(type: type, id: "test", data: NetService.data(fromTXTRecord: fields.mapValues { Data($0.utf8) }))
        }
        let computer = ["role": "computer", "platform": "macos", "v": "1", "pin": pin, "name": "Mac"]
        precondition(decode("_audiorelay._tcp.", computer)?.pin == pin)
        var invalid = computer; invalid["platform"] = "ios"
        precondition(decode("_audiorelay._tcp.", invalid) == nil, "Phones must never appear as computers")
        invalid = computer; invalid["pin"] = "untrusted"
        precondition(decode("_audiorelay._tcp.", invalid) == nil)
        invalid = computer; invalid.removeValue(forKey: "role")
        precondition(decode("_audiorelay._tcp.", invalid) == nil)
        invalid = computer; invalid["pin"] = pin + "\n"
        precondition(decode("_audiorelay._tcp.", invalid) == nil)
        invalid = computer; invalid["v"] = "2"
        precondition(decode("_audiorelay._tcp.", invalid) == nil)
        precondition(NearbyDevices.decode(type: "_audiorelay._tcp.", id: "test", data: Data(repeating: 0, count: 2049)) == nil)
        precondition(decode("_pairit-phone._tcp.", computer) == nil)
        let phone = ["role": "phone", "platform": "android", "v": "1", "name": "Moto\nPhone"]
        precondition(decode("_pairit-phone._tcp.", phone)?.name == "MotoPhone")
        precondition(decode("_audiorelay._tcp.", phone) == nil)
        precondition(decode("_pairit-phone._tcp.", phone)?.pin == nil)
        print("Nearby role, platform, version and pin checks passed")
    }
}
