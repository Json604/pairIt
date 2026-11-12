import Foundation

struct AudioFailure: Error { let description: String }

@main struct LocalIdentityCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pairit-identity-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fresh = root.appendingPathComponent("fresh")
        let first = try LocalIdentity.load(directory: fresh)
        let second = try LocalIdentity.load(directory: fresh)
        precondition(first.config == second.config, "Loading must preserve an existing identity")
        for name in ["identity.json", "identity.p12", "server.key"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: fresh.appendingPathComponent(name).path)
            precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        for (name, contents) in ["identity.json": Data("not JSON".utf8), "identity.p12": Data([1, 2, 3]), "server.key": Data("existing private key".utf8)] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(name)
            try contents.write(to: file)
            do {
                _ = try LocalIdentity.load(directory: directory)
                fatalError("Partial or unreadable identity must fail without replacement: " + name)
            } catch is AudioFailure { }
            let retained = try Data(contentsOf: file)
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            precondition(retained == contents)
            precondition(files == [name])
        }
        let config = fresh.appendingPathComponent("identity.json")
        let invalid = try JSONEncoder().encode(["token": String(repeating: "z", count: 64), "pin": first.config["pin"]!])
        try invalid.write(to: config)
        do { _ = try LocalIdentity.load(directory: fresh); fatalError("Non-hex credentials must fail") }
        catch is AudioFailure { }
        let retained = try Data(contentsOf: config)
        precondition(retained == invalid)
        print("PASS: identity persists, permissions are private, damaged identities remain untouched")
    }
}
