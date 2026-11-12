using PairIt.Linux;
using System.Text.Json;

static void Require(bool value, string message) { if (!value) throw new Exception(message); }
var sinks = PulseAudio.ParseSinks("""[{"name":"alsa_output.test","description":"Test speakers","monitor_source":"alsa_output.test.monitor"}]""");
Require(sinks.Count == 1 && sinks[0].Monitor == "alsa_output.test.monitor", "Must select a sink monitor, never a microphone.");
Require(PulseAudio.ParseSinks("""[{"name":"bad","monitor_source":"--help"}]""").Count == 0, "Unsafe endpoint accepted.");
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
}
