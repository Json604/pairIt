using System.Text.RegularExpressions;

namespace PairIt.Windows;

internal static class ReleaseDestination
{
    // Validate the original spelling before any browser or URI normalization.
    // Escapes, dot segments, credentials, ports, queries and fragments are excluded.
    private static readonly Regex OfficialRelease = new(
        @"\Ahttps://github\.com/Json604/pairIt-download/releases/(?:tag/v[0-9][A-Za-z0-9._-]*|download/v[0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*)\z",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    internal static bool IsTrusted(string? value) => value != null
        && !value.Contains("..", StringComparison.Ordinal) && OfficialRelease.IsMatch(value);
}
