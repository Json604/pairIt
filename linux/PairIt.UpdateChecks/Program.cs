using System.Net;
using System.Text;
using PairIt.Linux;

static void Require(bool value, string message) { if (!value) throw new Exception(message); }
static byte[] Feed(string url = "https://github.com/Json604/pairIt-download/releases/tag/v1.1.0-preview.17", string arch = "arm64") => Encoding.UTF8.GetBytes("""
{"schema":1,"releases":[{"platform":"linux","bundleID":"dev.bluetoothswitch.linuxrelay","build":17,"version":"1.1.0-preview.17","architectures":["ARCH"],"url":"URL"}]}
""".Replace("ARCH", arch).Replace("URL", url));
Require(ReleaseUpdates.Parse(Feed(), 16, "arm64")?.Build == 17, "New supported release missing.");
Require(ReleaseUpdates.Parse(Feed(), 17, "arm64") == null, "Current build offered.");
Require(ReleaseUpdates.Parse(Feed(), 16, "x64") == null, "Wrong architecture offered.");
foreach (var url in new[] { "http://github.com/Json604/pairIt-download/releases/tag/v17", "https://evil.example/releases/tag/v17", "https://github.com/Json604/pairIt-download/releases/tag/v17?x=1", "https://github.com/Json604/pairIt-download/releases/tag/../../elsewhere" })
    Require(ReleaseUpdates.Parse(Feed(url), 16, "arm64") == null, "Unsafe update destination offered.");
var handler = new FakeHandler();
using var updates = new ReleaseUpdates(handler, 16, "arm64");
handler.Body = Feed();
await updates.CheckAsync();
Require(updates.Available?.Build == 17, "Available update must be exposed to the notice.");
await updates.CheckAsync();
Require(handler.Requests == 1, "Automatic checks must be throttled.");
handler.Fail = true;
await updates.CheckAsync(force: true);
Require(handler.Requests == 2 && updates.Status.Contains("Couldn’t check") && updates.Available?.Build == 17, "Manual failed check must run, report failure, and retain known update.");
handler.Fail = false; handler.Body = Encoding.UTF8.GetBytes("{\"schema\":2,\"releases\":[]}");
await updates.CheckAsync(force: true);
Require(updates.Status.Contains("Couldn’t check"), "Unsupported feed must not report up to date.");
Console.WriteLine("PASS: trusted Linux feed, architecture/build filter, manual refresh, failure status.");

sealed class FakeHandler : HttpMessageHandler
{
    internal byte[] Body = []; internal bool Fail; internal int Requests;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation)
    {
        Requests++;
        if (Fail) throw new HttpRequestException("offline");
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Body) });
    }
}
