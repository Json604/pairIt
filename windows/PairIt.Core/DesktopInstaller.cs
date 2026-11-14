using System.Diagnostics;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace PairIt.Core;

public static class DesktopInstaller
{
    private sealed record Job(int ParentId, long ParentStart, string Target, string Platform, string Architecture, string Kind, int CurrentBuild, int OfferedBuild);
    private const string Inventory = "pairit-files.json";
    public static string Platform => OperatingSystem.IsWindows() ? "windows" : "linux";
    public static string Architecture => RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant();
    public static int CurrentBuild => Version.TryParse(Assembly.GetEntryAssembly()?.GetCustomAttribute<AssemblyFileVersionAttribute>()?.Version, out var version) ? version.Revision : int.MaxValue;
    public static string ExecutableName => OperatingSystem.IsWindows() ? "PairIt.exe" : "PairIt";
    private static string Cache => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PairIt", "updates");
    private static string InstallKind(string target) => OperatingSystem.IsLinux() && target == "/opt/pairit" ? "deb" : "zip";

    public static string? TakeResult()
    {
        try {
            var file = Path.Combine(Cache, "result.txt");
            if (!File.Exists(file)) return null;
            var message = File.ReadAllText(file); File.Delete(file);
            return message.Length <= 300 ? message : null;
        } catch { return null; }
    }

    public static async Task PrepareAsync(int offeredBuild, Action<string> status, CancellationToken cancellation)
    {
        var target = Path.TrimEndingDirectorySeparator(Path.GetFullPath(AppContext.BaseDirectory));
        var kind = InstallKind(target);
        ValidateInstallation(target);
        if (kind == "zip") {
            var probe = Path.Combine(Path.GetDirectoryName(target)!, ".pairit-write-" + Guid.NewGuid().ToString("N"));
            try { Directory.CreateDirectory(probe); Directory.Delete(probe); }
            catch { throw new InvalidOperationException("This app folder is not writable. Move PairIt to a folder you own before updating."); }
        } else if (!File.Exists("/usr/bin/pkexec")) {
            throw new InvalidOperationException("The system authorization tool is unavailable. Install this update with your software installer.");
        }
        Directory.CreateDirectory(Cache);
        var work = Path.Combine(Cache, Guid.NewGuid().ToString("N")); Directory.CreateDirectory(work);
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(work, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        try {
            status("Verifying update information…");
            var envelope = await InstallerReleases.FetchManifestAsync(cancellation);
            var release = InstallerReleases.Select(envelope, Platform, Architecture, kind, CurrentBuild, offeredBuild);
            await File.WriteAllBytesAsync(Path.Combine(work, "manifest.json"), envelope, cancellation);
            await InstallerReleases.DownloadAsync(release, Path.Combine(work, "package." + kind), p => status($"Downloading {p}% · click to cancel"), cancellation);
            cancellation.ThrowIfCancellationRequested();
            status("Preparing installation…");
            var helper = Path.Combine(work, "helper"); Directory.CreateDirectory(helper);
            await Task.Run(() => { foreach (var relative in ReadInventory(target)) {
                cancellation.ThrowIfCancellationRequested();
                var destination = Path.Combine(helper, relative); Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                File.Copy(Path.Combine(target, relative), destination);
                if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(destination, File.GetUnixFileMode(Path.Combine(target, relative)));
            }
            }, cancellation);
            var job = new Job(Environment.ProcessId, ProcessIdentity(Process.GetCurrentProcess()), target, Platform, Architecture, kind, CurrentBuild, offeredBuild);
            var file = Path.Combine(work, "job.json"); await File.WriteAllTextAsync(file, JsonSerializer.Serialize(job), cancellation);
            cancellation.ThrowIfCancellationRequested();
            var start = new ProcessStartInfo(Path.Combine(helper, ExecutableName)) { UseShellExecute = false, WorkingDirectory = helper };
            start.ArgumentList.Add("--apply-update"); start.ArgumentList.Add(file);
            using var worker = Process.Start(start) ?? throw new IOException("Could not start update installer.");
            for (var i = 0; i < 100; i++) {
                if (File.Exists(Path.Combine(work, "ready"))) { status("Restarting to install…"); return; }
                if (worker.HasExited) throw new IOException("The installer could not start. Your current app is unchanged.");
                await Task.Delay(100, CancellationToken.None);
            }
            try { worker.Kill(); } catch { }
            throw new IOException("Installer did not become ready. Your current app is unchanged.");
        } catch { try { Directory.Delete(work, true); } catch { } throw; }
    }

    public static long ProcessIdentity(Process process)
    {
        if (!OperatingSystem.IsLinux()) return process.StartTime.ToUniversalTime().Ticks;
        // Linux StartTime converts boot-relative ticks using a newly sampled wall
        // clock in each process. Compare the kernel start tick itself, not that
        // slightly different conversion, while still rejecting PID reuse.
        return ParseLinuxProcessIdentity(File.ReadAllText($"/proc/{process.Id}/stat"));
    }

    public static long ParseLinuxProcessIdentity(string stat)
    {
        var endName = stat.LastIndexOf(')');
        if (endName < 0) throw new InvalidDataException("Invalid process identity.");
        var fields = stat[(endName + 1)..].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (fields.Length < 20 || !long.TryParse(fields[19], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var start)) throw new InvalidDataException("Invalid process identity.");
        return start;
    }

    public static bool IsWorker(string[] args) => args.Length == 2 && args[0] == "--apply-update";

    public static async Task<int> RunWorkerAsync(string file)
    {
        string? target = null; string? backup = null; string? stage = null; bool parentExited = false;
        try {
            var full = Path.GetFullPath(file); var work = Path.GetDirectoryName(full)!;
            if (Path.GetFileName(full) != "job.json" || Directory.GetParent(work)?.FullName != Cache || new FileInfo(full).Length > 4096)
                throw new InvalidDataException("Invalid update job.");
            if (!string.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(AppContext.BaseDirectory)), Path.Combine(work, "helper"), OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal)) throw new InvalidDataException("Unexpected installer location.");
            var job = JsonSerializer.Deserialize<Job>(await File.ReadAllTextAsync(full)) ?? throw new InvalidDataException();
            target = job.Target;
            if (job.Platform != Platform || job.Architecture != Architecture || job.Kind != InstallKind(target) || job.CurrentBuild != CurrentBuild) throw new InvalidDataException();
            ValidateInstallation(target);
            if (FileVersionInfo.GetVersionInfo(Path.Combine(target, "PairIt.dll")).FilePrivatePart != job.CurrentBuild) throw new InvalidDataException("Installed build changed.");
            var manifest = await File.ReadAllBytesAsync(Path.Combine(work, "manifest.json"));
            var release = InstallerReleases.Select(manifest, Platform, Architecture, job.Kind, job.CurrentBuild, job.OfferedBuild);
            var package = Path.Combine(work, "package." + job.Kind); InstallerReleases.VerifyFile(package, release);
            using var parent = Process.GetProcessById(job.ParentId);
            var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
            if (ProcessIdentity(parent) != job.ParentStart || !string.Equals(parent.MainModule?.FileName, Path.Combine(target, ExecutableName), comparison)) throw new InvalidDataException("Unexpected parent application.");
            await File.WriteAllTextAsync(Path.Combine(work, "ready"), "ready");
            using (var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(60))) await parent.WaitForExitAsync(timeout.Token);
            parentExited = true;
            InstallerReleases.VerifyFile(package, release);
            if (job.Kind == "deb") {
                var install = new ProcessStartInfo("/usr/bin/pkexec") { UseShellExecute = false };
                install.ArgumentList.Add("/usr/bin/dpkg"); install.ArgumentList.Add("--install"); install.ArgumentList.Add(package);
                using var process = Process.Start(install) ?? throw new IOException();
                await process.WaitForExitAsync();
                if (process.ExitCode != 0) throw new IOException("System installer declined or failed.");
                ValidateInstallation(target);
                if (FileVersionInfo.GetVersionInfo(Path.Combine(target, "PairIt.dll")).FilePrivatePart != release.Build) throw new InvalidDataException("System installer did not install the expected build.");
            } else {
                stage = Path.Combine(Path.GetDirectoryName(target)!, ".pairit-new-" + Guid.NewGuid().ToString("N"));
                ExtractPackage(package, stage);
                ValidateInstallation(stage);
                if (FileVersionInfo.GetVersionInfo(Path.Combine(stage, "PairIt.dll")).FilePrivatePart != release.Build) throw new InvalidDataException("Installer contains the wrong build.");
                backup = target + ".previous-" + Guid.NewGuid().ToString("N");
                Directory.Move(target, backup);
                Directory.Move(stage, target); stage = null;
            }
            Result("Updated to " + release.Version + ".");
            Launch(target);
            // Keep the previous directory for recovery; never touch user settings.
            return 0;
        } catch {
            if (target != null && backup != null && Directory.Exists(backup)) {
                try { if (Directory.Exists(target)) Directory.Move(target, target + ".failed-" + Guid.NewGuid().ToString("N")); Directory.Move(backup, target); } catch { }
            }
            Result("Update installation was cancelled or failed. Your pairing/settings are preserved. Please retry or use the installer download.");
            if (target != null && parentExited) { try { Launch(target); } catch { } }
            return 1;
        } finally { if (stage != null) { try { Directory.Delete(stage, true); } catch { } } }
    }

    private static void Launch(string target) {
        using var process = Process.Start(new ProcessStartInfo(Path.Combine(target, ExecutableName)) { UseShellExecute = true, WorkingDirectory = target }) ?? throw new IOException("Could not restart PairIt.");
    }
    private static void Result(string message) { try { Directory.CreateDirectory(Cache); File.WriteAllText(Path.Combine(Cache, "result.txt"), message); } catch { } }

    private static string[] ReadInventory(string target)
    {
        var path = Path.Combine(target, Inventory);
        if (!File.Exists(path) || new FileInfo(path).Length > 1024 * 1024) throw new InvalidDataException("This installation needs a manual upgrade first.");
        var files = JsonSerializer.Deserialize<string[]>(File.ReadAllText(path)) ?? throw new InvalidDataException();
        if (files.Length is < 3 or > 10000 || files.Distinct(StringComparer.OrdinalIgnoreCase).Count() != files.Length) throw new InvalidDataException();
        foreach (var relative in files) {
            if (!SafeRelative(relative)) throw new InvalidDataException();
            var file = new FileInfo(Path.Combine(target, relative));
            if (!file.Exists || (file.Attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException();
        }
        return files;
    }
    private static bool ReservedPart(string part) {
        var stem = part.Split('.')[0].ToUpperInvariant();
        return part.EndsWith('.') || part.EndsWith(' ') || stem is "CON" or "PRN" or "AUX" or "NUL" ||
            stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal)) && char.IsAsciiDigit(stem[3]);
    }
    public static bool SafeRelative(string name) => !string.IsNullOrWhiteSpace(name) && !Path.IsPathRooted(name) && !name.Contains('\\') && !name.Contains(':') && !name.Split('/').Any(p => p is "" or "." or ".." || ReservedPart(p)) && !name.Any(char.IsControl);
    private static void ValidateInstallation(string target)
    {
        if (target != Path.TrimEndingDirectorySeparator(Path.GetFullPath(target)) || Path.GetDirectoryName(target) is null ||
            (File.GetAttributes(target) & FileAttributes.ReparsePoint) != 0 || !File.Exists(Path.Combine(target, ExecutableName)) || !File.Exists(Path.Combine(target, "PairIt.dll"))) throw new InvalidDataException("Not a PairIt installation folder.");
        var actualFiles = EnumeratePlainFiles(target).ToArray();
        var files = ReadInventory(target).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (!files.Contains(ExecutableName) || !files.Contains("PairIt.dll") || !files.Contains(Inventory)) throw new InvalidDataException();
        foreach (var file in actualFiles) {
            var relative = Path.GetRelativePath(target, file).Replace('\\', '/');
            if (!files.Contains(relative) && Path.GetFileName(relative) != ".DS_Store") throw new InvalidDataException("Keep PairIt in its own folder before using in-app installation.");
        }
    }
    private static IEnumerable<string> EnumeratePlainFiles(string root)
    {
        foreach (var entry in Directory.EnumerateFileSystemEntries(root)) {
            var attributes = File.GetAttributes(entry);
            if ((attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Linked app files cannot be updated in place.");
            if ((attributes & FileAttributes.Directory) != 0) {
                foreach (var file in EnumeratePlainFiles(entry)) yield return file;
            } else yield return entry;
        }
    }
    public static void ExtractPackage(string package, string destination)
    {
        Directory.CreateDirectory(destination);
        using var archive = ZipFile.OpenRead(package);
        if (archive.Entries.Count is < 3 or > 10000) throw new InvalidDataException();
        long total = 0; var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in archive.Entries) {
            if (!entry.FullName.StartsWith("PairIt/", StringComparison.Ordinal)) throw new InvalidDataException("Invalid archive root.");
            var relative = entry.FullName[7..];
            if (relative.Length == 0 || relative.EndsWith('/')) continue;
            if (!SafeRelative(relative) || !names.Add(relative) || ((entry.ExternalAttributes >> 16) & 0xF000) == 0xA000 || entry.Length < 0 || (total += entry.Length) > 1024L * 1024 * 1024) throw new InvalidDataException("Unsafe archive entry.");
            var output = Path.Combine(destination, relative); Directory.CreateDirectory(Path.GetDirectoryName(output)!);
            entry.ExtractToFile(output, false);
            if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(output, relative == "PairIt" || relative.EndsWith(".sh", StringComparison.Ordinal) ? UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute | UnixFileMode.GroupRead | UnixFileMode.GroupExecute | UnixFileMode.OtherRead | UnixFileMode.OtherExecute : UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.GroupRead | UnixFileMode.OtherRead);
        }
    }
}
