using System.Diagnostics;
using System.Net;
using System.Text.Json;

namespace PairIt.Windows;

internal sealed class ReleaseUpdates : IDisposable
{
    internal sealed record Entry(string Platform, string BundleID, int Build, string Version, string MinimumOS, string Url);
    private sealed record Feed(int Schema, Entry[] Releases);
    private static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };
    private static readonly Uri Endpoint = new("https://raw.githubusercontent.com/Json604/pairIt-download/main/release/updates.json");
    private readonly HttpClient client = new(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(12), MaxResponseContentBufferSize = 65536 };
    private readonly string cache = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PairIt", "release-update.json");
    private DateTimeOffset lastAttempt = DateTimeOffset.MinValue;
    private bool checking, disposed;
    internal Entry? Available { get; private set; }
    internal string Status { get; private set; } = "Check for updates";
    internal event Action? Changed;
    internal ReleaseUpdates()
    {
        try {
            if (new FileInfo(cache).Length <= 65536) {
                var entry = JsonSerializer.Deserialize<Entry>(File.ReadAllText(cache), Json);
                if (entry != null && Eligible(entry)) Available = entry;
            }
        } catch { /* First launch or invalid cache; no effect on listening. */ }
    }
    internal async Task CheckAsync(bool force = false)
    {
        if (disposed || checking || !force && DateTimeOffset.UtcNow - lastAttempt < TimeSpan.FromHours(6)) return;
        checking = true; lastAttempt = DateTimeOffset.UtcNow; Status = "Checking for updates…";
        try {
            using var response = await client.GetAsync(Endpoint);
            if (response.StatusCode != HttpStatusCode.OK) throw new HttpRequestException("Update feed unavailable.");
            var feed = JsonSerializer.Deserialize<Feed>(await response.Content.ReadAsStringAsync(), Json);
            if (feed?.Schema != 1 || feed.Releases == null || feed.Releases.Length > 100) throw new InvalidDataException("Invalid update feed.");
            if (disposed) return;
            Available = feed.Releases.Where(Eligible).OrderByDescending(e => e.Build).FirstOrDefault();
            try {
                Directory.CreateDirectory(Path.GetDirectoryName(cache)!);
                if (Available == null) File.Delete(cache);
                else File.WriteAllText(cache, JsonSerializer.Serialize(Available, Json));
            } catch { /* A read-only profile must not prevent an update notice. */ }
            Status = Available == null ? "No newer release available" : "Update available · " + Available.Version;
        } catch {
            Status = "Couldn’t check. Try again when online.";
            lastAttempt = DateTimeOffset.UtcNow - TimeSpan.FromHours(6) + TimeSpan.FromMinutes(5);
        } finally { checking = false; if (!disposed) Changed?.Invoke(); }
    }
    private static bool Eligible(Entry entry)
    {
        var current = FileVersionInfo.GetVersionInfo(Application.ExecutablePath).FilePrivatePart;
        return entry.Platform == "windows" && entry.BundleID == "dev.bluetoothswitch.windowsrelay" && entry.Build > current
            && entry.Version != null && System.Text.RegularExpressions.Regex.IsMatch(entry.Version, @"^\d+\.\d+\.\d+([.-][A-Za-z0-9.]+)?$")
            && Version.TryParse(entry.MinimumOS, out var os) && Environment.OSVersion.Version >= os
            && ReleaseDestination.IsTrusted(entry.Url);
    }
    internal bool Open()
    {
        if (Available == null || !Eligible(Available)) return false;
        try { Process.Start(new ProcessStartInfo(Available.Url) { UseShellExecute = true }); return true; }
        catch { return false; }
    }
    public void Dispose() { disposed = true; client.Dispose(); }
}
