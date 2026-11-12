import Foundation
import SwiftUI

/// Public release metadata only. No pairing, audio, or device identifiers leave the app.
@MainActor final class ReleaseUpdates: ObservableObject {
    struct Entry: Codable {
        let platform: String
        let bundleID: String
        let build: Int
        let version: String
        let minimumOS: String
        let url: String
    }
    private struct Feed: Decodable { let schema: Int; let releases: [Entry] }
    @Published private(set) var available: Entry?
    @Published private(set) var checking = false
    @Published private(set) var status = "Check for updates"
    private var lastAttempt = Date.distantPast
    private var task: Task<Void, Never>?
    private let cacheKey = "pairit.release-update.v1"
    private let endpoint = URL(string: "https://raw.githubusercontent.com/Json604/pairIt/main/release/updates.json")!
    #if os(macOS)
    private let platform = "mac"
    #else
    private let platform = "ios"
    #endif

    init() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let entry = try? JSONDecoder().decode(Entry.self, from: data), eligible(entry) { available = entry }
    }
    func check(force: Bool = false) {
        guard !checking, force || Date().timeIntervalSince(lastAttempt) >= 6 * 3600 else { return }
        lastAttempt = Date(); checking = true; status = "Checking for updates…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { checking = false }
            do {
                var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 65536,
                      http.url?.host == endpoint.host else { throw URLError(.badServerResponse) }
                let feed = try JSONDecoder().decode(Feed.self, from: data)
                guard feed.schema == 1, feed.releases.count <= 100 else { throw URLError(.cannotParseResponse) }
                available = feed.releases.filter(eligible).max { $0.build < $1.build }
                if let entry = available { UserDefaults.standard.set(try JSONEncoder().encode(entry), forKey: cacheKey) }
                else { UserDefaults.standard.removeObject(forKey: cacheKey) }
                status = available == nil ? "No newer release available" : "Update available"
            } catch {
                // Keep a previously verified update visible through offline launches.
                status = "Couldn’t check. Try again when online."
                lastAttempt = Date().addingTimeInterval(-6 * 3600 + 300)
            }
        }
    }
    private func eligible(_ entry: Entry) -> Bool {
        guard entry.platform == platform, entry.bundleID == Bundle.main.bundleIdentifier,
              entry.build > (Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? Int.max),
              entry.version.range(of: #"^\d+\.\d+\.\d+([.-][A-Za-z0-9.]+)?$"#, options: .regularExpression) != nil,
              entry.minimumOS.range(of: #"^\d+\.\d+(\.\d+)?$"#, options: .regularExpression) != nil,
              let url = URL(string: entry.url), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil else { return false }
        let current = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(current.majorVersion).\(current.minorVersion).\(current.patchVersion)"
        guard os.compare(entry.minimumOS, options: .numeric) != .orderedAscending else { return false }
        #if os(macOS)
        return url.host == "github.com" && url.path.hasPrefix("/Json604/pairIt/releases/")
        #else
        return url.host == "apps.apple.com" && url.path.hasSuffix("/id6833655052")
        #endif
    }
}

struct ReleaseUpdateNotice: View {
    @ObservedObject var updates: ReleaseUpdates
    @Environment(\.openURL) private var openURL
    @State private var openFailed = false
    var body: some View {
        if let entry = updates.available, let url = URL(string: entry.url) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Update available · \(entry.version)").font(.system(size: 13, weight: .semibold))
                #if os(macOS)
                Text("Download the new version, then quit PairIt to replace it.").font(.system(size: 12))
                #else
                Text("Get the latest PairIt from the App Store.").font(.system(size: 12))
                #endif
                Button("Get update") { openURL(url) { accepted in openFailed = !accepted } }
                    .buttonStyle(RelayControlButtonStyle()).frame(minHeight: 44)
                if openFailed { Text("Couldn’t open the download. Try again.").font(.caption) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14).frost(14)
        }
    }
}
