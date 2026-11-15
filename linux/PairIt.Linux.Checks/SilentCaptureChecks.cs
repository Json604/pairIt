using PairIt.Linux;

internal static class SilentCaptureChecks
{
    public static async Task RunAsync()
    {
        if (!OperatingSystem.IsLinux()) { Console.WriteLine("SKIP: silent capture integration requires Linux pipe ioctl; run in Linux CI/container."); return; }
        var folder = Path.Combine(Path.GetTempPath(), "pairit-silent-" + Guid.NewGuid());
        Directory.CreateDirectory(folder);
        var path = Environment.GetEnvironmentVariable("PATH");
        var previous = Environment.GetEnvironmentVariable("PAIRIT_CAPTURE_FIXTURE");
        try {
            var fixture = """
#!/usr/bin/env python3
import os,sys,json,time,pathlib
root=pathlib.Path(os.environ['PAIRIT_CAPTURE_FIXTURE'])
if pathlib.Path(sys.argv[0]).name=='pactl':
 if sys.argv[-1]=='sinks': print(json.dumps([{'name':'silent','monitor_source':'silent.monitor'}]))
 elif sys.argv[-1]=='source-outputs':
  p=root/'pid'
  print(json.dumps([{'properties':{'application.process.id':p.read_text()}}] if p.exists() and not (root/'unregistered').exists() else []))
else:
 if (root/'failed').exists(): sys.exit(1)
 (root/'pid').write_text(str(os.getpid()))
 while not (root/'play').exists(): time.sleep(.01)
 while True:
  sys.stdout.buffer.write(b'\x01\x00'*960);sys.stdout.buffer.flush();time.sleep(.01)
""";
            foreach (var command in new[] { "parec", "pactl" }) {
                var name = Path.Combine(folder, command); File.WriteAllText(name, fixture);
                File.SetUnixFileMode(name, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            }
            Environment.SetEnvironmentVariable("PAIRIT_CAPTURE_FIXTURE", folder);
            Environment.SetEnvironmentVariable("PATH", folder + Path.PathSeparator + path);
            var packet = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            string? failure = null;
            await using (var source = new PulseSource("silent.monitor")) {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
                await source.StartAsync(_ => packet.TrySetResult(), message => failure = message, timeout.Token);
                if (packet.Task.IsCompleted) throw new Exception("Idle fixture unexpectedly emitted PCM.");
                var pid = File.ReadAllText(Path.Combine(folder, "pid"));
                await Task.Delay(6500); // Outlast the previous PCM-dependent startup deadline.
                if (failure != null || packet.Task.IsCompleted) throw new Exception("Silent capture failed or invented audio.");
                File.WriteAllText(Path.Combine(folder, "play"), "go");
                await packet.Task.WaitAsync(TimeSpan.FromSeconds(2));
                if (File.ReadAllText(Path.Combine(folder, "pid")) != pid) throw new Exception("Playback required capture restart.");
            }
            File.Delete(Path.Combine(folder, "play"));
            foreach (var scenario in new[] { "unregistered", "failed" }) {
                File.WriteAllText(Path.Combine(folder, scenario), "yes");
                var rejected = false;
                await using (var source = new PulseSource("silent.monitor")) {
                    try { await source.StartAsync(_ => throw new Exception("Unexpected PCM"), _ => { }, CancellationToken.None); }
                    catch (Exception error) when (error is IOException or OperationCanceledException) { rejected = true; }
                }
                if (!rejected) throw new Exception("Unregistered/failed capture reported success.");
                File.Delete(Path.Combine(folder, scenario));
            }
            Console.WriteLine("PASS: failed/unregistered capture rejected; registered silent capture starts within2s, survives6.5s without PCM, and delivers later audio without restart.");
        } finally {
            Environment.SetEnvironmentVariable("PATH", path);
            Environment.SetEnvironmentVariable("PAIRIT_CAPTURE_FIXTURE", previous);
            Directory.Delete(folder, true);
        }
    }
}
