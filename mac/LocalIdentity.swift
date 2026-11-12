import Foundation
import CryptoKit
import Security
import Darwin

/// Each installation owns its identity. No credentials ship in either app.
struct LocalIdentity {
    let directory: URL
    let config: [String: String]

    static func load() throws -> LocalIdentity {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AudioRelay", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let configURL = directory.appendingPathComponent("identity.json")
        if let data = try? Data(contentsOf: configURL),
           let config = try? JSONDecoder().decode([String: String].self, from: data),
           config["token"]?.count == 64, config["pin"]?.count == 64,
           FileManager.default.fileExists(atPath: directory.appendingPathComponent("identity.p12").path) {
            return LocalIdentity(directory: directory, config: config)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AudioFailure(description: "Could not create pairing identity") }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let key = directory.appendingPathComponent("server.key").path
        let cert = directory.appendingPathComponent("server.pem").path
        try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650", "-subj", "/CN=Audio Relay", "-keyout", key, "-out", cert])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key)
        try openssl(["x509", "-in", cert, "-outform", "DER", "-out", directory.appendingPathComponent("server.der").path])
        let certificate = try Data(contentsOf: directory.appendingPathComponent("server.der"))
        let pin = SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
        try openssl(["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", directory.appendingPathComponent("identity.p12").path,
                     "-passout", "stdin", "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"], password: token)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("identity.p12").path)
        let config = ["pin": pin, "token": token]
        try JSONEncoder().encode(config).write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        return LocalIdentity(directory: directory, config: config)
    }

    private static func openssl(_ arguments: [String], password: String? = nil) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl"); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let input = Pipe(); process.standardInput = input
        try process.run()
        if let password { input.fileHandleForWriting.write(Data((password + "\n").utf8)) }
        try input.fileHandleForWriting.close(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AudioFailure(description: "Could not prepare local identity (\(process.terminationStatus))") }
    }

    static func currentHost() -> String {
        addresses().first?.host ?? Host.current().name ?? "localhost"
    }
    struct Address: Identifiable, Equatable {
        let interface: String
        let host: String
        var id: String { interface + ":" + host }
    }
    static func addresses() -> [Address] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }
        var next = interfaces, result: [Address] = []
        while let current = next {
            let entry = current.pointee; next = entry.ifa_next
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge"), let address = entry.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET), entry.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(Address(interface: name, host: String(cString: host)))
            }
        }
        return result
    }
}
