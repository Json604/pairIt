import Foundation
import CryptoKit

/// Matches Android's ephemeral P-256/AES-GCM invitation protocol.
struct InvitationCrypto {
    private let privateKey = P256.KeyAgreement.PrivateKey()
    private var key: SymmetricKey?
    private static let context = Data("PairIt invitation v1".utf8)
    var publicKey: Data { privateKey.publicKey.x963Representation }
    mutating func agree(_ remote: Data, sender: Bool) throws {
        let other = try P256.KeyAgreement.PublicKey(x963Representation: remote)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: other)
        var transcript = shared.withUnsafeBytes { Data($0) }
        transcript.append(sender ? publicKey : remote)
        transcript.append(sender ? remote : publicKey)
        transcript.append(Self.context)
        key = SymmetricKey(data: SHA256.hash(data: transcript))
    }
    var comparison: String {
        guard let key else { return "" }
        var data = key.withUnsafeBytes { Data($0) }; data.append(Data("compare".utf8))
        let hex = Self.hex(Data(SHA256.hash(data: data))).prefix(16).uppercased()
        return stride(from: 0, to: 16, by: 4).map { String(hex.dropFirst($0).prefix(4)) }.joined(separator: " ")
    }
    func seal(_ plain: Data) throws -> Data {
        guard let key else { throw InvitationError.invalid }
        return try AES.GCM.seal(plain, using: key, authenticating: Self.context).combined!
    }
    func open(_ sealed: Data) throws -> Data {
        guard let key, (28...8192).contains(sealed.count) else { throw InvitationError.invalid }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: Self.context)
    }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func unhex(_ text: String) throws -> Data {
        guard !text.isEmpty, text.count <= 16384, text.count % 2 == 0, text.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw InvitationError.invalid }
        let chars = Array(text); return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0+1)]), radix: 16)! })
    }
}
enum InvitationError: Error { case invalid }
