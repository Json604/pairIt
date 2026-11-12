using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;

namespace PairIt.Linux;

public sealed class LocalIdentity : IDisposable
{
    private sealed record Stored(string Token, string Pfx);
    public X509Certificate2 Certificate { get; }
    public string Token { get; }
    public string Pin { get; }
    public static string DirectoryPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PairIt");

    private LocalIdentity(Stored stored)
    {
        if (stored.Token.Length != 64 || stored.Token.Any(c => !"0123456789abcdef".Contains(c)))
            throw new CryptographicException("Invalid pairing identity.");
        Token = stored.Token;
        var bytes = Convert.FromBase64String(stored.Pfx);
        try { Certificate = X509CertificateLoader.LoadPkcs12(bytes, null, OperatingSystem.IsMacOS() ? X509KeyStorageFlags.DefaultKeySet : X509KeyStorageFlags.EphemeralKeySet); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
        if (!Certificate.HasPrivateKey) { Certificate.Dispose(); throw new CryptographicException("Missing pairing key."); }
        Pin = Convert.ToHexStringLower(SHA256.HashData(Certificate.RawData));
    }

    public static LocalIdentity LoadOrCreate(string? directory = null)
    {
        if (OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        directory ??= DirectoryPath;
        if (new DirectoryInfo(directory).LinkTarget != null) throw new IOException("PairIt data directory must not be a symlink.");
        Directory.CreateDirectory(directory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        var mode = File.GetUnixFileMode(directory);
        if ((mode & (UnixFileMode.GroupWrite | UnixFileMode.OtherWrite | UnixFileMode.GroupRead | UnixFileMode.OtherRead | UnixFileMode.GroupExecute | UnixFileMode.OtherExecute)) != 0)
            throw new IOException("PairIt data directory must be private (chmod 700).");
        var path = Path.Combine(directory, "identity.json");
        if (new FileInfo(path).LinkTarget != null) throw new IOException("Pairing identity must not be a symlink.");
        if (!File.Exists(path)) Create(path);
        if ((File.GetUnixFileMode(path) & (UnixFileMode.GroupRead | UnixFileMode.GroupWrite | UnixFileMode.OtherRead | UnixFileMode.OtherWrite)) != 0)
            throw new IOException("Pairing identity must be private (chmod 600).");
        if (new FileInfo(path).Length > 32768) throw new IOException("Invalid pairing identity size.");
        var bytes = File.ReadAllBytes(path);
        try { return new(JsonSerializer.Deserialize<Stored>(bytes) ?? throw new CryptographicException("Invalid pairing identity.")); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    private static void Create(string path)
    {
        if (OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        using var key = RSA.Create(3072);
        var request = new CertificateRequest("CN=PairIt Linux Companion", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new OidCollection { new("1.3.6.1.5.5.7.3.1") }, false));
        using var cert = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(20));
        var pfx = cert.Export(X509ContentType.Pfx);
        var data = JsonSerializer.SerializeToUtf8Bytes(new Stored(Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32)), Convert.ToBase64String(pfx)));
        var temporary = path + "." + Guid.NewGuid().ToString("N");
        try
        {
            using (var file = new FileStream(temporary, new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write,
                Share = FileShare.None, UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite }))
            { file.Write(data); file.Flush(true); }
            File.Move(temporary, path, false);
        }
        finally { File.Delete(temporary); CryptographicOperations.ZeroMemory(data); CryptographicOperations.ZeroMemory(pfx); }
    }

    public string PairingCode(string host)
    {
        if (!System.Net.IPAddress.TryParse(host, out var address) || address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork)
            throw new ArgumentException("Choose a local IPv4 address.");
        var payload = JsonSerializer.SerializeToUtf8Bytes(new { host, pin = Pin, token = Token, name = Environment.MachineName, platform = "linux", protocol = "2" });
        return "audiorelay://pair/" + Convert.ToBase64String(payload).Replace('+', '-').Replace('/', '_');
    }
    public void Dispose() => Certificate.Dispose();
}
