using System.IO.Compression;
using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using PairIt.Core;

internal static class InstallerChecks
{
    public static async Task RunAsync()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var publicKey = Convert.ToBase64String(key.ExportSubjectPublicKeyInfo());
        var release = new InstallerRelease("linux", "arm64", "zip", 23, "1.1.0-preview.23", "https://github.com/Json604/pairIt-download/releases/download/v1.1.0-preview.23/PairIt-linux-arm64.zip", 3, Convert.ToHexStringLower(SHA256.HashData(new byte[] { 1, 2, 3 })));
        byte[] Signed(params InstallerRelease[] entries) {
            var payload = JsonSerializer.SerializeToUtf8Bytes(new { schema = 1, releases = entries });
            return JsonSerializer.SerializeToUtf8Bytes(new SignedInstallerManifest(Convert.ToBase64String(payload), Convert.ToBase64String(key.SignData(payload, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence))));
        }
        var envelope = Signed(release);
        if (InstallerReleases.Select(envelope, "linux", "arm64", "zip", 22, 23, publicKey) != release) throw new Exception("Signed installer selection failed.");
        Reject(() => InstallerReleases.Select(envelope, "linux", "x64", "zip", 22, 23, publicKey));
        Reject(() => InstallerReleases.Select(envelope, "linux", "arm64", "deb", 22, 23, publicKey));
        Reject(() => InstallerReleases.Select(envelope, "linux", "arm64", "zip", 23, 23, publicKey));
        Reject(() => InstallerReleases.Select(Signed(release, release), "linux", "arm64", "zip", 22, 23, publicKey));
        using var wrong = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        Reject(() => InstallerReleases.Select(envelope, "linux", "arm64", "zip", 22, 23, Convert.ToBase64String(wrong.ExportSubjectPublicKeyInfo())));
        Reject(() => InstallerReleases.Select(Signed(release with { Url = "https://evil.example/update.zip" }), "linux", "arm64", "zip", 22, 23, publicKey));
        var root = Path.Combine(Path.GetTempPath(), "pairit-installer-check-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        try {
            var package = Path.Combine(root, "file"); File.WriteAllBytes(package, [1, 2, 3]); InstallerReleases.VerifyFile(package, release);
            File.WriteAllBytes(package, [1, 2, 4]); Reject(() => InstallerReleases.VerifyFile(package, release));
            foreach (var unsafeName in new[] { "../outside", "folder/../../outside", "/absolute", "folder\\file", "C:/bad", "CON", "folder/name.", "folder/name " })
                if (DesktopInstaller.SafeRelative(unsafeName)) throw new Exception("Unsafe path accepted: " + unsafeName);
            await InstallerReleases.DownloadAsync(release, Path.Combine(root, "download-good"), _ => {}, CancellationToken.None, new ResponseHandler(() => new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([1, 2, 3]) }));
            await RejectAsync(() => InstallerReleases.DownloadAsync(release, Path.Combine(root, "download-bad"), _ => {}, CancellationToken.None, new ResponseHandler(() => new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([1, 2, 4]) })));
            await RejectAsync(() => InstallerReleases.DownloadAsync(release, Path.Combine(root, "download-size"), _ => {}, CancellationToken.None, new ResponseHandler(() => new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([1, 2]) })));
            await RejectAsync(() => InstallerReleases.DownloadAsync(release, Path.Combine(root, "download-redirect"), _ => {}, CancellationToken.None, new ResponseHandler(() => { var response = new HttpResponseMessage(HttpStatusCode.Redirect); response.Headers.Location = new Uri("https://evil.example/package.zip"); return response; })));
            var install = Path.Combine(root, "install"); Directory.CreateDirectory(install);
            File.WriteAllText(Path.Combine(install, DesktopInstaller.ExecutableName), "test"); File.WriteAllText(Path.Combine(install, "PairIt.dll"), "test");
            File.WriteAllText(Path.Combine(install, "pairit-files.json"), JsonSerializer.Serialize(new[] { DesktopInstaller.ExecutableName, "PairIt.dll", "pairit-files.json" }));
            ValidateInstallation(install);
            File.WriteAllText(Path.Combine(install, "owner-document.txt"), "preserve"); Reject(() => ValidateInstallation(install)); File.Delete(Path.Combine(install, "owner-document.txt"));
            if (!OperatingSystem.IsWindows()) {
                var other = Path.Combine(root, "other"); Directory.CreateDirectory(other); File.WriteAllText(Path.Combine(other, "file"), "outside");
                Directory.CreateSymbolicLink(Path.Combine(install, "linked"), other);
                File.WriteAllText(Path.Combine(install, "pairit-files.json"), JsonSerializer.Serialize(new[] { DesktopInstaller.ExecutableName, "PairIt.dll", "pairit-files.json", "linked/file" }));
                Reject(() => ValidateInstallation(install));
            }
            var archive = Path.Combine(root, "bad.zip");
            using (var zip = ZipFile.Open(archive, ZipArchiveMode.Create)) {
                zip.CreateEntry("PairIt/ok"); zip.CreateEntry("PairIt/another"); zip.CreateEntry("PairIt/../../escaped");
            }
            Reject(() => DesktopInstaller.ExtractPackage(archive, Path.Combine(root, "extract")));
            if (File.Exists(Path.Combine(root, "escaped"))) throw new Exception("Archive escaped destination.");
        } finally { Directory.Delete(root, true); }
        Console.WriteLine("Signed installer selection, integrity and extraction checks passed.");
    }
    private static void ValidateInstallation(string path) {
        try { typeof(DesktopInstaller).GetMethod("ValidateInstallation", BindingFlags.NonPublic | BindingFlags.Static)!.Invoke(null, [path]); }
        catch (TargetInvocationException error) when (error.InnerException != null) { System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(error.InnerException).Throw(); }
    }
    private sealed class ResponseHandler(Func<HttpResponseMessage> response) : HttpMessageHandler {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => Task.FromResult(response());
    }
    private static async Task RejectAsync(Func<Task> action) {
        try { await action(); } catch (Exception error) when (error is InvalidDataException or CryptographicException or FormatException) { return; }
        throw new Exception("Unsafe installer download was accepted.");
    }
    private static void Reject(Action action) {
        try { action(); } catch (Exception error) when (error is InvalidDataException or CryptographicException or FormatException) { return; }
        throw new Exception("Unsafe installer input was accepted.");
    }
}
