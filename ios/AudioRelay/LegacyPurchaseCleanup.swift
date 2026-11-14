import Security

/// Remove only the retired purchase-preview items, never pairing credentials or ad consent.
enum LegacyPurchaseCleanup {
    static func run() {
        for account in ["purchase", "checkout"] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "dev.bluetoothswitch.pro",
                kSecAttrAccount as String: account
            ]
            // A temporarily locked Keychain is retried at the next launch.
            SecItemDelete(query as CFDictionary)
        }
    }
}
