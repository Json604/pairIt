package dev.bluetoothswitch.relay;

public final class ReleaseDownloadLinkCheck {
    public static void main(String[] args) {
        String root = "https://github.com/Json604/pairIt/releases/";
        String[] accepted = {root + "tag/v1.1.0", root + "tag/v1.1.0-preview.15",
                root + "download/v1.1.0/PairIt-1.1.0.apk"};
        String[] rejected = {root + "../../../attacker/repo/releases/tag/v1.1.0",
                root + "%2e%2e/%2e%2e/%2e%2e/attacker/repo/releases/tag/v1.1.0",
                root + "download/v1.1.0/%2e%2e%2ffile.apk", root + "tag/v1.1.0?redirect=evil",
                root + "tag/v1.1.0#other", root + "latest", root + "tag/v1.1.0\\evil",
                root.replace("github.com", "github.com.evil.test") + "tag/v1.1.0",
                root.replace("https://", "http://") + "tag/v1.1.0",
                root.replace("github.com", "user@github.com") + "tag/v1.1.0",
                root.replace("github.com", "github.com:443") + "tag/v1.1.0"};
        for (String value : accepted) {
            if (!ReleaseDownloadLink.trusted(value)) throw new AssertionError("Rejected official release: " + value);
        }
        for (String value : rejected) {
            if (ReleaseDownloadLink.trusted(value)) throw new AssertionError("Accepted untrusted release: " + value);
        }
        System.out.println("PASS: official release links accepted; repository escapes and ambiguous URLs rejected");
    }
}
