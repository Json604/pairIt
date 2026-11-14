using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace PairIt.Core;

public sealed record InstallerRelease(string Platform, string Architecture, string Kind, int Build, string Version, string Url, long Size, string Sha256);
public sealed record SignedInstallerManifest(string Payload, string Signature);

public static class InstallerReleases
{
    public const string FeedUrl = "https://raw.githubusercontent.com/Json604/pairIt-download/main/release/installers.json";
    private sealed record Manifest(int Schema, InstallerRelease[] Releases);
    private static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };

    public static InstallerRelease Select(byte[] envelope, string platform, string architecture, string kind, int currentBuild, int offeredBuild, string? publicKey = null)
    {
        if (envelope.Length > 65536) throw new InvalidDataException("Installer metadata exceeds its limit.");
        var signed = JsonSerializer.Deserialize<SignedInstallerManifest>(envelope, Json) ?? throw new InvalidDataException("Missing installer metadata.");
        var payload = Convert.FromBase64String(signed.Payload);
        var signature = Convert.FromBase64String(signed.Signature);
        using var verifier = ECDsa.Create();
        verifier.ImportSubjectPublicKeyInfo(Convert.FromBase64String(publicKey ?? UpdateTrust.PublicKey), out _);
        if (!verifier.VerifyData(payload, signature, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence))
            throw new CryptographicException("Installer signature is invalid.");
        var manifest = JsonSerializer.Deserialize<Manifest>(payload, Json);
        if (manifest?.Schema != 1 || manifest.Releases == null || manifest.Releases.Length > 30) throw new InvalidDataException("Unsupported installer metadata.");
        var matches = manifest.Releases.Where(r => r.Platform == platform && r.Architecture == architecture && r.Kind == kind && r.Build == offeredBuild && r.Build > currentBuild).ToArray();
        if (matches.Length != 1) throw new InvalidDataException("A matching signed installer is not published yet. Try again later.");
        var entry = matches[0];
        if (entry.Size <= 0 || entry.Size > 512L * 1024 * 1024 || !Regex.IsMatch(entry.Sha256, "\\A[0-9a-f]{64}\\z") ||
            !Regex.IsMatch(entry.Version, "\\A[0-9]+\\.[0-9]+\\.[0-9]+([.-][A-Za-z0-9.]+)?\\z") || !TrustedAsset(entry.Url))
            throw new InvalidDataException("Invalid signed installer details.");
        return entry;
    }

    public static bool TrustedAsset(string value) => value != null && !value.Contains("..", StringComparison.Ordinal) &&
        Regex.IsMatch(value, @"\Ahttps://github\.com/Json604/pairIt-download/releases/download/v[0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*\z");

    public static async Task<byte[]> FetchManifestAsync(CancellationToken cancellation)
    {
        using var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(20), MaxResponseContentBufferSize = 65536 };
        return await client.GetByteArrayAsync(FeedUrl, cancellation);
    }

    public static async Task DownloadAsync(InstallerRelease release, string destination, Action<int> progress, CancellationToken cancellation, HttpMessageHandler? handler = null)
    {
        using var client = new HttpClient(handler ?? new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = Timeout.InfiniteTimeSpan };
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        deadline.CancelAfter(TimeSpan.FromMinutes(10));
        var url = new Uri(release.Url);
        for (var redirects = 0; redirects < 4; redirects++) {
            using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
            if ((int)response.StatusCode is >= 300 and < 400) {
                var location = response.Headers.Location ?? throw new InvalidDataException("Missing download redirect.");
                url = location.IsAbsoluteUri ? location : new Uri(url, location);
                if (url.Scheme != "https" || !url.IsDefaultPort || url.UserInfo.Length != 0 || url.Fragment.Length != 0 ||
                    !(url.Host == "release-assets.githubusercontent.com" || TrustedAsset(url.AbsoluteUri)))
                    throw new InvalidDataException("Untrusted download redirect.");
                continue;
            }
            response.EnsureSuccessStatusCode();
            if (response.Content.Headers.ContentLength is long length && length != release.Size) throw new InvalidDataException("Installer size does not match.");
            await using var input = await response.Content.ReadAsStreamAsync(deadline.Token);
            await using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true);
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[65536]; long received = 0; var lastPercent = -1;
            while (true) {
                var count = await input.ReadAsync(buffer, deadline.Token);
                if (count == 0) break;
                received += count;
                if (received > release.Size) throw new InvalidDataException("Installer exceeds its signed size.");
                hash.AppendData(buffer, 0, count);
                await output.WriteAsync(buffer.AsMemory(0, count), deadline.Token);
                var percent = (int)(received * 100 / release.Size);
                if (percent != lastPercent) { lastPercent = percent; progress(percent); }
            }
            if (received != release.Size || !CryptographicOperations.FixedTimeEquals(hash.GetHashAndReset(), Convert.FromHexString(release.Sha256)))
                throw new CryptographicException("Downloaded installer failed verification.");
            await output.FlushAsync(deadline.Token);
            return;
        }
        throw new InvalidDataException("Too many download redirects.");
    }

    public static void VerifyFile(string file, InstallerRelease release)
    {
        using var input = File.OpenRead(file);
        if (input.Length != release.Size || !CryptographicOperations.FixedTimeEquals(SHA256.HashData(input), Convert.FromHexString(release.Sha256)))
            throw new CryptographicException("Installer changed after download.");
    }
}
