import Foundation

@main struct NearbyPairingCheck {
    static func main() {
        let token = String(repeating: "a", count: 64)
        precondition(NearbyPairingRequest.approvedToken(Data(("OK REQUEST1 " + token + "\n").utf8)) == token)
        for reply in ["NO\n", "OK REQUEST1 short\n", "OK REQUEST1 " + token + "\nextra", "OK REQUEST1 " + token.uppercased() + "\n"] {
            precondition(NearbyPairingRequest.approvedToken(Data(reply.utf8)) == nil)
        }
        let request = try! NearbyPairingRequest(pin: token)
        precondition(request.comparison.count == 19)
        precondition(request.comparison.filter { $0 == " " }.count == 3)
        print("Nearby pairing reply bounds, token validation and comparison format passed")
    }
}
