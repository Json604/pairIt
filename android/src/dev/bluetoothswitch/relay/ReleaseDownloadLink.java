package dev.bluetoothswitch.relay;

/** Shared by cached and freshly fetched update notices before exposing a link. */
final class ReleaseDownloadLink {
    static boolean trusted(String value) {
        // Validate the whole unescaped URL. Browsers normalize dot segments,
        // backslashes and percent-encoded separators after a simple prefix check.
        return value != null && !value.contains("..") && value.matches(
                "https://github\\.com/Json604/pairIt-download/releases/"
                + "(?:tag/v[0-9][A-Za-z0-9._-]*|download/v[0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*)");
    }
}
