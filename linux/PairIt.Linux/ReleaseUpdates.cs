using System.Text.Json;
using System.Text.RegularExpressions;

namespace PairIt.Linux;
internal static class ReleaseUpdates
{
    internal static async Task<string?> CheckAsync()
    {
        using var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(12), MaxResponseContentBufferSize = 65536 };
        var bytes = await client.GetByteArrayAsync("https://raw.githubusercontent.com/Json604/pairIt/main/release/updates.json");
        using var feed = JsonDocument.Parse(bytes);
        if (feed.RootElement.GetProperty("schema").GetInt32() != 1) return null;
        foreach (var entry in feed.RootElement.GetProperty("releases").EnumerateArray())
        {
            if (entry.GetProperty("platform").GetString() != "linux" || entry.GetProperty("bundleID").GetString() != "dev.bluetoothswitch.linuxrelay" || entry.GetProperty("build").GetInt32() <= 10) continue;
            var url = entry.GetProperty("url").GetString() ?? "";
            if (Regex.IsMatch(url, @"\Ahttps://github\.com/Json604/pairIt/releases/tag/v[0-9][A-Za-z0-9._-]*\z") && !url.Contains("..")) return url;
        }
        return null;
    }
}
