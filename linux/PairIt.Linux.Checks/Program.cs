using PairIt.Linux;
using System.Text.Json;

static void Require(bool value, string message) { if (!value) throw new Exception(message); }
if (args.Contains("--route-crash-helper")) {
    await using var crashRoute = new PulseRoute(new PulseCommands());
    await crashRoute.StartAsync("pairit_route_test.monitor", CancellationToken.None);
    Console.WriteLine(crashRoute.SinkName); Console.Out.Flush();
    await Task.Delay(Timeout.Infinite); return;
}
CaptureTimingChecks.Run();
await RoutingChecks.RunAsync();
if (args.Contains("--routing")) await LiveRoutingChecks.RunAsync();
if (args.Contains("--timing")) await LiveCaptureTimingChecks.RunAsync();
var sinks = PulseAudio.ParseSinks("""[{"name":"alsa_output.test","description":"Test speakers","monitor_source":"alsa_output.test.monitor"}]""");
Require(sinks.Count == 1 && sinks[0].Monitor == "alsa_output.test.monitor", "Must select a sink monitor, never a microphone.");
Require(PulseAudio.ParseSinks("""[{"name":"bad","monitor_source":"--help"}]""").Count == 0, "Unsafe endpoint accepted.");
var muted = PulseAudio.ParseSinks("""[{"name":"sink","monitor_source":"sink.monitor","mute":true,"volume":{"left":{"value":16384},"right":{"value":16384}}}]""");
Require(muted[0].Volume == (0x10000u | 250u), "Mute and 25 percent volume must be reflected independently.");
var virtualSink = PulseAudio.ParseSinks("""[{"name":"pairit_mic","monitor_source":"pairit_mic.monitor","driver":"module-null-sink.c"}]""");
Require(virtualSink[0].Virtual && !sinks[0].Virtual, "Phone microphone may target virtual sinks only.");
var home = Path.Combine(Path.GetTempPath(), "pairit-check-" + Guid.NewGuid());
try {
    using var first = LocalIdentity.LoadOrCreate(home);
    using var second = LocalIdentity.LoadOrCreate(home);
    Require(first.Pin == second.Pin && first.Token == second.Token, "Pairing changed on restart.");
    var encoded = first.PairingCode("192.168.1.2").Split('/')[3].Replace('-', '+').Replace('_', '/');
    using var payload = JsonDocument.Parse(Convert.FromBase64String(encoded));
    Require(payload.RootElement.GetProperty("platform").GetString() == "linux", "Wrong pairing platform.");
    if (!OperatingSystem.IsWindows()) {
        Require((File.GetUnixFileMode(Path.Combine(home, "identity.json")) & (UnixFileMode.GroupRead | UnixFileMode.OtherRead)) == 0, "Identity is readable by other users.");
    }
} finally { Directory.Delete(home, true); }
Console.WriteLine("PASS: monitor selection, endpoint validation, persistent Linux identity and private permissions.");
if (args.Contains("--audio")) {
    await using (var invalid = new PulseSource("pairit_nonexistent.monitor")) {
        var rejected = false;
        try { await invalid.StartAsync(_ => throw new Exception("Captured an unintended source."), _ => { }, CancellationToken.None); }
        catch (IOException) { rejected = true; }
        Require(rejected, "Missing sink must not fall back to a microphone.");
    }
    var available = await PulseAudio.ListAsync();
    Require(available.Count > 0, "No test sink found.");
    await using var source = new PulseSource(available.Single(o => o.Name == "pairit_test").Monitor);
    var received = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
    await source.StartAsync(packet => {
        if (packet.Rate == 48000 && packet.Frames == 480 && packet.StereoPcm16.Any(b => b != 0)) received.TrySetResult(true);
    }, message => received.TrySetException(new Exception(message)), CancellationToken.None);
    await received.Task.WaitAsync(TimeSpan.FromSeconds(15));
    Console.WriteLine("PASS: real PulseAudio monitor delivers non-silent stereo PCM.");
    var endpoints = new LinuxAudioEndpoints();
    bool denied = false;
    try { await endpoints.OpenMicrophoneSinkAsync("nonexistent", CancellationToken.None); }
    catch (IOException) { denied = true; }
    Require(denied, "Missing microphone sink must not fall back to speakers.");
    await using var microphone = await endpoints.OpenMicrophoneSinkAsync("pairit_mic_test", CancellationToken.None);
    await using var micMonitor = new PulseSource("pairit_mic_test.monitor");
    var heard = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    await micMonitor.StartAsync(packet => {
        if (packet.StereoPcm16.Any(b => b != 0)) heard.TrySetResult();
    }, message => heard.TrySetException(new IOException(message)), CancellationToken.None);
    var pcm = new byte[1920];
    for (int i = 0; i < 960; i++)
        System.Buffers.Binary.BinaryPrimitives.WriteInt16LittleEndian(pcm.AsSpan(i * 2), (short)(8000 * Math.Sin(i * Math.Tau * 440 / 48000)));
    for (int i = 0; i < 30; i++) { microphone.Write(pcm); await Task.Delay(20); }
    await heard.Task.WaitAsync(TimeSpan.FromSeconds(5));
    await microphone.FlushAsync(CancellationToken.None);
    Console.WriteLine("PASS: phone microphone PCM reaches only the selected virtual sink; discontinuity flush and disposal complete.");

}
