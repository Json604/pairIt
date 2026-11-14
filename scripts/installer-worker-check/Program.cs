using System.Diagnostics;
using System.Text.Json;

// Run only inside the owned Linux test environment under Xvfb. Inputs are a
// bootstrap app directory, a locally-built next-build ZIP, and a signed manifest.
// No feeds are changed and no real user profile is used.
if (!OperatingSystem.IsLinux() || args.Length != 3) throw new ArgumentException("Use on Linux: baseline-directory next.zip signed-manifest.json");
var baseline = Path.GetFullPath(args[0]);
var nextPackage = Path.GetFullPath(args[1]);
var nextManifest = Path.GetFullPath(args[2]);
var currentBuild = FileVersionInfo.GetVersionInfo(Path.Combine(baseline, "PairIt.dll")).FilePrivatePart;
using var envelope = JsonDocument.Parse(File.ReadAllBytes(nextManifest));
var payload = Convert.FromBase64String(envelope.RootElement.GetProperty("payload").GetString()!);
using var manifest = JsonDocument.Parse(payload);
var nextBuild = manifest.RootElement.GetProperty("releases")[0].GetProperty("build").GetInt32();
await RunCaseAsync(tamper: true);
await RunCaseAsync(tamper: false);
Console.WriteLine("PASS: real Linux worker rejects a tampered package, installs/relaunches a valid newer build, and preserves isolated user data.");

async Task RunCaseAsync(bool tamper)
{
    var root = Path.Combine(Path.GetTempPath(), "pairit-worker-check-" + Guid.NewGuid().ToString("N"));
    var target = Path.Combine(root, "PairIt");
    var data = Path.Combine(root, "profile");
    var work = Path.Combine(data, "PairIt", "updates", Guid.NewGuid().ToString("N"));
    var helper = Path.Combine(work, "helper");
    var targetExe = Path.Combine(target, "PairIt");
    Directory.CreateDirectory(work);
    CopyTree(baseline, target); CopyTree(baseline, helper);
    File.Copy(nextManifest, Path.Combine(work, "manifest.json"));
    var package = Path.Combine(work, "package.zip"); File.Copy(nextPackage, package);
    if (tamper) { using var stream = new FileStream(package, FileMode.Open, FileAccess.Write); stream.WriteByte(0); }
    var sentinel = Path.Combine(data, "PairIt", "owner-settings-sentinel.txt"); File.WriteAllText(sentinel, "preserve me");
    Process? parent = null; Process? worker = null;
    try {
        parent = Start(targetExe, target, data, "--smoke-test");
        var job = new { ParentId = parent.Id, ParentStart = parent.StartTime.ToUniversalTime().Ticks, Target = target,
            Platform = "linux", Architecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant(), Kind = "zip", CurrentBuild = currentBuild, OfferedBuild = nextBuild };
        var jobFile = Path.Combine(work, "job.json"); File.WriteAllText(jobFile, JsonSerializer.Serialize(job));
        worker = Start(Path.Combine(helper, "PairIt"), helper, data, "--apply-update", jobFile);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(75));
        await worker.WaitForExitAsync(timeout.Token);
        if (tamper) {
            if (worker.ExitCode == 0 || File.Exists(Path.Combine(work, "ready"))) throw new Exception("Tampered installer reached installation.");
            if (FileVersionInfo.GetVersionInfo(Path.Combine(target, "PairIt.dll")).FilePrivatePart != currentBuild) throw new Exception("Tampered installer changed current app.");
            await parent.WaitForExitAsync(timeout.Token);
        } else {
            if (worker.ExitCode != 0 || !File.Exists(Path.Combine(work, "ready")) || !parent.HasExited) throw new Exception("Worker did not complete a clean installation.");
            if (FileVersionInfo.GetVersionInfo(Path.Combine(target, "PairIt.dll")).FilePrivatePart != nextBuild) throw new Exception("Wrong installed build.");
            var restarted = false;
            for (var attempt = 0; attempt < 30; attempt++) {
                if (FindTargetProcesses(targetExe).Count > 0) { restarted = true; break; }
                await Task.Delay(100);
            }
            if (!restarted) throw new Exception("Updated application was not relaunched.");
            if (Directory.GetDirectories(root, "PairIt.previous-*").Length != 1) throw new Exception("Recovery copy missing.");
        }
        if (File.ReadAllText(sentinel) != "preserve me") throw new Exception("User data changed.");
        Console.WriteLine(tamper ? "PASS: tampered real worker request rejected before ready; original build and data intact." : "PASS: signed real worker install and relaunch completed; prior directory retained; data intact.");
    } finally {
        foreach (var process in FindTargetProcesses(targetExe)) { try { process.Kill(); process.WaitForExit(5000); } catch { } process.Dispose(); }
        try { if (parent != null && !parent.HasExited) { parent.Kill(); parent.WaitForExit(5000); } } catch { }
        try { if (worker != null && !worker.HasExited) { worker.Kill(); worker.WaitForExit(5000); } } catch { }
        parent?.Dispose(); worker?.Dispose();
        Directory.Delete(root, true);
    }
}
static Process Start(string executable, string directory, string data, params string[] arguments) {
    var start = new ProcessStartInfo(executable) { UseShellExecute = false, WorkingDirectory = directory };
    start.Environment["XDG_DATA_HOME"] = data;
    foreach (var argument in arguments) start.ArgumentList.Add(argument);
    return Process.Start(start) ?? throw new IOException("Could not start test child.");
}
static List<Process> FindTargetProcesses(string executable) {
    var found = new List<Process>();
    foreach (var process in Process.GetProcesses()) {
        try { if (process.MainModule?.FileName == executable) { found.Add(process); continue; } } catch { }
        process.Dispose();
    }
    return found;
}
static void CopyTree(string source, string target) {
    Directory.CreateDirectory(target);
    foreach (var file in Directory.GetFiles(source, "*", SearchOption.AllDirectories)) {
        var destination = Path.Combine(target, Path.GetRelativePath(source, file)); Directory.CreateDirectory(Path.GetDirectoryName(destination)!); File.Copy(file, destination);
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(destination, File.GetUnixFileMode(file));
    }
}
