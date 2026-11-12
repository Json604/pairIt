using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;

namespace PairIt.Windows.Storage;

internal sealed class LocalIdentity : IDisposable
{
    private sealed record StoredIdentity(string Token, string Pfx);
    public X509Certificate2 Certificate { get; }
    public string Token { get; }
    public string Pin { get; }
    public static string DirectoryPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PairIt");

    private LocalIdentity(string token, byte[] pfx)
    {
        Token = token;
        // Windows Schannel cannot reliably use an EphemeralKeySet certificate.
        // Import into the current-user key set without PersistKeySet: Schannel
        // can open the OS-protected key container and normal certificate disposal
        // releases the temporary import. The DPAPI PFX remains the stable identity.
        Certificate = X509CertificateLoader.LoadPkcs12(pfx, null, X509KeyStorageFlags.UserKeySet);
        Pin = Convert.ToHexStringLower(SHA256.HashData(Certificate.RawData));
        if (!Certificate.HasPrivateKey || token.Length != 64 || token.Any(character => !"0123456789abcdef".Contains(character)))
            throw new CryptographicException("Invalid local pairing identity.");
    }

    public static LocalIdentity LoadOrCreate()
    {
        Directory.CreateDirectory(DirectoryPath);
        var path = Path.Combine(DirectoryPath, "identity.dpapi");
        if (!File.Exists(path)) Create(path);
        var plaintext = WindowsDpapi.Unprotect(File.ReadAllBytes(path));
        try
        {
            var stored = JsonSerializer.Deserialize<StoredIdentity>(plaintext) ?? throw new CryptographicException("Pairing identity is unreadable.");
            var pfx = Convert.FromBase64String(stored.Pfx);
            try { return new(stored.Token, pfx); }
            finally { CryptographicOperations.ZeroMemory(pfx); }
        }
        finally { CryptographicOperations.ZeroMemory(plaintext); }
    }

    private static void Create(string path)
    {
        using var key = RSA.Create(3072);
        var request = new CertificateRequest("CN=PairIt Local Companion", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new OidCollection { new("1.3.6.1.5.5.7.3.1") }, false));
        using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(20));
        var pfx = certificate.Export(X509ContentType.Pfx);
        var plaintext = JsonSerializer.SerializeToUtf8Bytes(new StoredIdentity(Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32)), Convert.ToBase64String(pfx)));
        try
        {
            var temporary = path + ".new";
            File.WriteAllBytes(temporary, WindowsDpapi.Protect(plaintext));
            File.Move(temporary, path, false);
        }
        finally { CryptographicOperations.ZeroMemory(pfx); CryptographicOperations.ZeroMemory(plaintext); }
    }

    public string PairingCode(string host)
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(new
        {
            host, pin = Pin, token = Token, name = Environment.MachineName, platform = "windows", protocol = "2"
        });
        return "audiorelay://pair/" + Convert.ToBase64String(payload).Replace('+', '-').Replace('/', '_');
    }

    public void Dispose() => Certificate.Dispose();
}

// Current-user DPAPI. No plaintext private key/token file and no external tool
// arguments, log output or machine-wide key store are involved.
internal static class WindowsDpapi
{
    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob { public int Length; public IntPtr Pointer; }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref DataBlob input, string? description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out DataBlob output);
    [DllImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref DataBlob input, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out DataBlob output);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr pointer);

    public static byte[] Protect(byte[] value) => Transform(value, true);
    public static byte[] Unprotect(byte[] value) => Transform(value, false);
    private static byte[] Transform(byte[] value, bool protect)
    {
        var input = new DataBlob { Length = value.Length, Pointer = Marshal.AllocHGlobal(value.Length) };
        DataBlob output = default;
        try
        {
            Marshal.Copy(value, 0, input.Pointer, value.Length);
            var success = protect
                ? CryptProtectData(ref input, "PairIt local identity", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output)
                : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output);
            if (!success) throw new Win32Exception(Marshal.GetLastWin32Error(), "Windows could not unlock PairIt's local identity. Keep the existing identity file; use the Windows account that created it.");
            var result = new byte[output.Length];
            Marshal.Copy(output.Pointer, result, 0, output.Length);
            return result;
        }
        finally
        {
            Marshal.Copy(new byte[value.Length], 0, input.Pointer, value.Length);
            Marshal.FreeHGlobal(input.Pointer);
            if (output.Pointer != IntPtr.Zero)
            {
                Marshal.Copy(new byte[output.Length], 0, output.Pointer, output.Length);
                LocalFree(output.Pointer);
            }
        }
    }
}
