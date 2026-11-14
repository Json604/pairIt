import Foundation

@main struct ReleaseUpdateCheck {
    @MainActor static func main() {
        for url in ["https://github.com/Json604/pairIt-download/releases/tag/v1.1.0-preview.7",
                    "https://github.com/Json604/pairIt-download/releases/download/v1.1.0-preview.7/PairIt-mac.zip"] {
            precondition(ReleaseUpdates.trustedURL(url, platform: "mac"))
        }
        for url in ["https://apps.apple.com/app/id6833655052", "https://apps.apple.com/us/app/pairit/id6833655052"] {
            precondition(ReleaseUpdates.trustedURL(url, platform: "ios"))
        }
        for url in ["https://github.com/Json604/pairIt/releases/tag/v1",
                    "https://github.com/Json604/pairIt-download-evil/releases/tag/v1",
                    "https://github.com/Json604/pairIt-download/releases/../../../attacker/repo/releases/tag/v1",
                    "https://github.com/Json604/pairIt-download/releases/tag/%2e%2e/%2e%2e/other",
                    "https://github.com/Json604/pairIt-download/releases/tag/v1?redirect=elsewhere",
                    "https://github.com/Json604/pairIt-download/releases/tag/v1#fragment",
                    "https://github.com/Json604/pairIt-download/releases/",
                    "https://github.com/Json604/pairIt-download/releases/tag/v1\n",
                    "https://github.com:443/Json604/pairIt-download/releases/tag/v1"] {
            precondition(!ReleaseUpdates.trustedURL(url, platform: "mac"), "Unsafe Mac update URL accepted: " + url)
        }
        for url in ["https://apps.apple.com/elsewhere/id6833655052", "https://apps.apple.com/app/id6833655052?redirect=elsewhere",
                    "https://apps.apple.com/app/id0000000000", "https://attacker.example/app/id6833655052"] {
            precondition(!ReleaseUpdates.trustedURL(url, platform: "ios"), "Unsafe iOS update URL accepted")
        }
        let source = try! Data(contentsOf: URL(fileURLWithPath: "release/updates.json"))
        let mixed = try! ReleaseUpdates.decodeFeed(source)
        precondition(mixed.contains { $0.platform == "mac" })
        var json = try! JSONSerialization.jsonObject(with: source) as! [String: Any]
        var entries = json["releases"] as! [[String: Any]]
        for index in entries.indices where ["android", "linux"].contains(entries[index]["platform"] as? String ?? "") { entries[index].removeValue(forKey: "minimumOS") }
        json["releases"] = entries
        precondition((try! ReleaseUpdates.decodeFeed(JSONSerialization.data(withJSONObject: json))).count == mixed.count)
        json["schema"] = 2
        do { _ = try ReleaseUpdates.decodeFeed(JSONSerialization.data(withJSONObject: json)); preconditionFailure("Unknown schema accepted") } catch { }
        precondition(ReleaseUpdates.failureMessage(URLError(.notConnectedToInternet)).contains("connection"))
        precondition(ReleaseUpdates.failureMessage(URLError(.cannotParseResponse)).contains("invalid"))
        print("PASS: mixed-platform feed accepts Android/Linux without Apple-only fields; invalid schema rejected")
        print("PASS: Apple update links stay on exact official versioned release and App Store routes")
    }
}
