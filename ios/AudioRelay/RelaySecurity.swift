import Foundation
import Network
import Security
import CryptoKit

enum RelaySecurity {
    static func parameters(pin: String, queue: DispatchQueue) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let value = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(value) as? [SecCertificate], let certificate = chain.first else { complete(false); return }
            let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
            guard fingerprint == pin else { complete(false); return }
            SecTrustSetAnchorCertificates(value, [certificate] as CFArray)
            SecTrustSetAnchorCertificatesOnly(value, true)
            SecTrustSetPolicies(value, SecPolicyCreateBasicX509())
            complete(SecTrustEvaluateWithError(value, nil))
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true; tcp.enableKeepalive = true; tcp.connectionTimeout = 5
        return NWParameters(tls: tls, tcp: tcp)
    }
}
