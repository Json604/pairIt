using PairIt.Core;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace PairIt.Linux;

internal sealed class ReleaseUpdates : IDisposable
{
    internal sealed record Entry(int Build, string Version, string Url);
    private static readonly Uri Endpoint = new("https://raw.githubusercontent.com/Json604/pairIt-download/main/release/updates.json");
    private readonly HttpClient client;
    private readonly int currentBuild;
    private readonly string architecture;
    private DateTimeOffset lastAttempt = DateTimeOffset.MinValue;
    private bool disposed;
    internal Entry? Available { get; private set; }
    internal bool Checking { get; private set; }
    internal string Status { get; private set; } = "Check for updates";
    internal event Action? Changed;

    internal ReleaseUpdates(HttpMessageHandler? handler = null, int? build = null, string? arch = null)
    {
        client = new HttpClient(handler ?? new HttpClientHandler { AllowAutoRedirect = false })
            { Timeout = TimeSpan.FromSeconds(12), MaxResponseContentBufferSize = 65536 };
        var version = typeof(ReleaseUpdates).Assembly.GetCustomAttribute<AssemblyFileVersionAttribute>()?.Version;
        currentBuild = build ?? (Version.TryParse(version, out var parsed) ? parsed.Revision : int.MaxValue);
        architecture = arch ?? RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant();
    }
    internal async Task CheckAsync(bool force = false)
    {
        if (disposed || Checking || !force && DateTimeOffset.UtcNow - lastAttempt < TimeSpan.FromHours(6)) return;
        Checking = true; lastAttempt = DateTimeOffset.UtcNow; Status = "Checking for updates…"; Changed?.Invoke();
        try {
            var bytes = await client.GetByteArrayAsync(Endpoint);
            var entry = Parse(bytes, currentBuild, architecture);
            if (disposed) return;
            Available = entry;
            Status = entry == null ? "No newer release available" : "Update available · " + entry.Version;
        } catch (Exception error) {
            if (disposed) return;
            Status = UpdateCheckFailure.Describe(error);
            lastAttempt = DateTimeOffset.UtcNow - TimeSpan.FromHours(6) + TimeSpan.FromMinutes(5);
        } finally {
            Checking = false;
            if (!disposed) Changed?.Invoke();
        }
    }
    internal static Entry? Parse(byte[] bytes, int currentBuild, string architecture)
    {
        if (bytes.Length > 65536) throw new InvalidDataException("Update feed exceeds its size limit.");
        using var feed = JsonDocument.Parse(bytes);
        if (feed.RootElement.GetProperty("schema").GetInt32() != 1) throw new InvalidDataException("Unknown update feed.");
        var releases = feed.RootElement.GetProperty("releases");
        if (releases.ValueKind != JsonValueKind.Array || releases.GetArrayLength() > 100) throw new InvalidDataException("Invalid releases.");
        Entry? newest = null;
        foreach (var item in releases.EnumerateArray()) {
            if (item.GetProperty("platform").GetString() != "linux" || item.GetProperty("bundleID").GetString() != "dev.bluetoothswitch.linuxrelay") continue;
            var build = item.GetProperty("build").GetInt32();
            if (build <= currentBuild || newest != null && build <= newest.Build) continue;
            if (!item.GetProperty("architectures").EnumerateArray().Any(a => a.GetString() == architecture)) continue;
            var version = item.GetProperty("version").GetString();
            var url = item.GetProperty("url").GetString();
            if (version == null || !Regex.IsMatch(version, @"\A\d+\.\d+\.\d+([.-][A-Za-z0-9.]+)?\z") || !TrustedUrl(url)) continue;
            newest = new(build, version, url!);
        }
        return newest;
    }
    private static bool TrustedUrl(string? url) => url != null && !url.Contains("..", StringComparison.Ordinal)
        && Regex.IsMatch(url, @"\Ahttps://github\.com/Json604/pairIt-download/releases/tag/v[0-9][A-Za-z0-9._-]*\z", RegexOptions.CultureInvariant);
    public void Dispose() { disposed = true; client.Dispose(); }
}
