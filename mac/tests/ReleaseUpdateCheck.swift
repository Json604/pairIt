import Foundation

@main struct ReleaseUpdateCheck {
    @MainActor static func main() {
        for url in ["https://github.com/Json604/pairIt/releases/tag/v1.1.0-preview.7",
                    "https://github.com/Json604/pairIt/releases/download/v1.1.0-preview.7/PairIt-mac.zip"] {
            precondition(ReleaseUpdates.trustedURL(url, platform: "mac"))
        }
        for url in ["https://apps.apple.com/app/id6833655052", "https://apps.apple.com/us/app/pairit/id6833655052"] {
            precondition(ReleaseUpdates.trustedURL(url, platform: "ios"))
        }
        for url in ["https://github.com/Json604/pairIt/releases/../../../attacker/repo/releases/tag/v1",
                    "https://github.com/Json604/pairIt/releases/tag/%2e%2e/%2e%2e/other",
                    "https://github.com/Json604/pairIt/releases/tag/v1?redirect=elsewhere",
                    "https://github.com/Json604/pairIt/releases/tag/v1#fragment",
                    "https://github.com/Json604/pairIt/releases/",
                    "https://github.com/Json604/pairIt/releases/tag/v1\n",
                    "https://github.com:443/Json604/pairIt/releases/tag/v1"] {
            precondition(!ReleaseUpdates.trustedURL(url, platform: "mac"), "Unsafe Mac update URL accepted: " + url)
        }
        for url in ["https://apps.apple.com/elsewhere/id6833655052", "https://apps.apple.com/app/id6833655052?redirect=elsewhere",
                    "https://apps.apple.com/app/id0000000000", "https://attacker.example/app/id6833655052"] {
            precondition(!ReleaseUpdates.trustedURL(url, platform: "ios"), "Unsafe iOS update URL accepted")
        }
        print("PASS: Apple update links stay on exact official versioned release and App Store routes")
    }
}
