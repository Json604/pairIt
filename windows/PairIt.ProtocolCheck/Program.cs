using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using PairIt.Core;
using PairIt.Windows;
using PairIt.Windows.Storage;

// This is a real loopback-TLS integration executable using synthetic PCM and
// fake audio endpoints. It never calls Windows audio or records any input.
await Integration.RunAsync();

internal static class Integration
{
    public static async Task RunAsync()
    {
        await InstallerChecks.RunAsync();
        UpdatePromptChecks.Run();
        CheckReleaseDestinations();
        DiscoveryChecks.Run();
        using var rsa = RSA.Create(2048);
        var request = new CertificateRequest("CN=PairIt synthetic integration", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var generated = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
        var syntheticPfx = generated.Export(X509ContentType.Pfx);
        using var windowsCertificate = OperatingSystem.IsWindows()
            ? X509CertificateLoader.LoadPkcs12(syntheticPfx, null, X509KeyStorageFlags.UserKeySet)
            : null;
        var certificate = windowsCertificate ?? generated;
        CryptographicOperations.ZeroMemory(syntheticPfx);
        var token = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));
        await OutputSwitchIntegration.RunAsync(certificate, token);
        await RoutedPauseIntegration.RunAsync(certificate, token);
        await PresentationIntegration.RunAsync(certificate, token);
        await ExtensionIntegration.RunAsync(certificate, token);
        var audio = new SyntheticEndpoints();
        var sessions = new DesktopSessions(audio);
        await using var server = new RelayServer(certificate, token, sessions);
        server.Start(IPAddress.Loopback, 0);
        var connector = new Connector(server.Port, certificate, token);
        using (var occupancy = await connector.ConnectAsync()) {
            await occupancy.WriteLineAsync("STATUS1");
            Require((await occupancy.ReadLineAsync()).StartsWith("OK STATUS1 0 "), "Occupancy before authentication must not start capture.");
            Require(sessions.Status.Receivers == 0 && !sessions.Status.Capturing, "Occupancy is read-only.");
        }
        var wrongRequest = new CertificateRequest("CN=Different synthetic identity", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var wrongCertificate = wrongRequest.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
        var pinRejected = false;
        try { using var unexpected = await new Connector(server.Port, wrongCertificate, token).ConnectAsync(); }
        catch (AuthenticationException) { pinRejected = true; }
        Require(pinRejected, "Certificate pin mismatch was accepted.");
        await sessions.ConfigureAsync(new(SourceEndpointId: "synthetic", SharingEnabled: true));

        // Slow unauthenticated sockets cannot occupy receiver slots.
        var pendingHandshakes = new List<TcpClient>();
        for (var index = 0; index < 4; index++)
        {
            var socket = new TcpClient();
            await socket.ConnectAsync(IPAddress.Loopback, server.Port);
            pendingHandshakes.Add(socket);
        }
        var listeners = new List<Receiver>();
        for (var index = 0; index < 4; index++)
            listeners.Add(await connector.ReceiverAsync(index == 0 ? token + " PRO1 retired-preview" : token));
        await UntilAsync(() => sessions.Status.Receivers == 4 && audio.SourceStarts == 1, "four receivers with one capture");
        foreach (var socket in pendingHandshakes) socket.Dispose();

        var capturedAt = MonotonicClock.Nanoseconds;
        audio.Emit(480, capturedAt);
        foreach (var peer in listeners) await UntilAsync(() => peer.Frames.Any(frame => frame.CapturedAt == capturedAt), "shared source packet");
        var signatures = listeners.Select(peer => peer.Frames.Single(frame => frame.CapturedAt == capturedAt)).ToArray();
        Require(signatures.All(frame => frame == signatures[0]), "All four peers must receive identical source sequence/timestamp/payload.");
        await listeners[0].SendAsync("PING 123456\nSYNC 123.5\nACTIVE 1\nSTATS harmless-diagnostic\n");
        await UntilAsync(() => listeners[0].Clocks.Contains(123456), "serialized PING response");

        await using (var excess = await connector.ReceiverAsync()) {
            await UntilAsync(() => excess.Closed, "fifth receiver rejected");
            Require(excess.Rejection == 1, "Fifth authenticated receiver needs a group-full explanation.");
        }
        Require(sessions.Status.Receivers == 4, "Fifth peer evicted a healthy receiver.");
        await listeners[0].SendAsync("NAME1 " + Convert.ToBase64String(Encoding.UTF8.GetBytes("Moto G85")) + "\n");
        await UntilAsync(() => sessions.Status.PhoneNames.Contains("Moto G85"), "authenticated device name");
        await listeners[0].SendAsync("NAME1 " + Convert.ToBase64String(Encoding.UTF8.GetBytes("Injected\nlabel")) + "\nPING 424242\n");
        await UntilAsync(() => listeners[0].Clocks.Contains(424242), "invalid name processed");
        Require(!sessions.Status.PhoneNames.Contains("Injected"), "Control characters in names must be rejected.");
        using (var occupancy = await connector.ConnectAsync()) {
            await occupancy.WriteLineAsync("STATUS1");
            var status = (await occupancy.ReadLineAsync()).Split(' ',4);
            Require(status[2] == "4" && Encoding.UTF8.GetString(Convert.FromBase64String(status[3])).Contains("Moto G85"), "Occupied computer reports real phone labels.");
        }
        await using (var invalid = await connector.ReceiverAsync(new string('0', 64))) {
            await UntilAsync(() => invalid.Closed, "wrong authentication rejected");
            Require(invalid.Rejection == 0, "Unauthenticated peer must not receive group status.");
        }
        await using (var invalidLegacy = await connector.ReceiverAsync(new string('0', 64) + " PRO1 retired-preview"))
            await UntilAsync(() => invalidLegacy.Closed, "retired suffix cannot bypass authentication");
        await using (var unknownRole = await connector.ReceiverAsync(token + " MIC2"))
            await UntilAsync(() => unknownRole.Closed, "unknown microphone protocol rejected without capture");
        using (var busy = await connector.ConnectAsync())
        {
            await busy.WriteLineAsync(token + " MIC1");
            Require(await busy.ReadLineAsync() == "ERR BUSY", "Microphone must be refused while sharing.");
        }
        Console.WriteLine("PASS: pinned TLS, independent handshake slots, legacy four-peer fanout, fifth-peer rejection, PING and sharing/mic exclusion.");

        await listeners[3].DisposeAsync();
        listeners.RemoveAt(3);
        await UntilAsync(() => sessions.Status.Receivers == 3, "receiver disconnect");
        await using (var slow = await connector.ReceiverAsync(readFrames: false))
        {
            await UntilAsync(() => sessions.Status.Receivers == 4, "slow receiver admission");
            var deadline = DateTime.UtcNow.AddSeconds(5);
            while (sessions.Status.Receivers == 4 && DateTime.UtcNow < deadline)
            {
                audio.Emit(8192, MonotonicClock.Nanoseconds);
                await Task.Delay(20);
            }
            Require(sessions.Status.Receivers == 3, "A non-reading peer was not removed by bounded backpressure.");
            Require(listeners.All(peer => !peer.Closed), "A slow peer disrupted healthy peers.");
        }
        await using (var malformed = await connector.ReceiverAsync())
        {
            await UntilAsync(() => sessions.Status.Receivers == 4, "malformed peer admission");
            await malformed.SendAsync("SYNC NaN\n");
            await UntilAsync(() => malformed.Closed, "invalid control rejection");
        }
        await UntilAsync(() => sessions.Status.Receivers == 3, "malformed receiver removed");
        await using (var overlong = await connector.ReceiverAsync())
        {
            await UntilAsync(() => sessions.Status.Receivers == 4, "overlong control peer admission");
            await overlong.SendAsync(new string('x', 4097) + "\n");
            await UntilAsync(() => overlong.Closed, "bounded control line rejection");
        }
        foreach (var peer in listeners) await peer.SendAsync("ACTIVE 0\n");
        await UntilAsync(() => !sessions.Status.Capturing, "last active receiver stops capture");
        await listeners[0].SendAsync("ACTIVE 1\n");
        await UntilAsync(() => sessions.Status.Capturing, "explicit receiver reactivation");
        foreach (var peer in listeners) await peer.DisposeAsync();
        await UntilAsync(() => sessions.Status.Receivers == 0 && !sessions.Status.Capturing, "last receiver cleanup");
        Require(audio.MaximumSources == 1 && audio.SourceStarts == audio.SourceStops, "Source lifetime leaked or overlapped.");
        Console.WriteLine("PASS: slow-peer isolation, malformed-control isolation, ACTIVE transitions and last-receiver cleanup.");

        // Sleep drops active sessions but preserves sharing eligibility for wake.
        await using (var sleeping = await connector.ReceiverAsync())
        {
            await UntilAsync(() => sessions.Status.Capturing, "capture before sleep cleanup");
            await sessions.ConfigureAsync(sessions.CurrentSettings with { MicrophoneEnabled = false });
            await UntilAsync(() => sleeping.Closed && !sessions.Status.Capturing, "sleep releases capture and socket");
            Require(sessions.CurrentSettings.SharingEnabled, "Sleep erased sharing intent.");
        }
        await using (var waking = await connector.ReceiverAsync())
            await UntilAsync(() => sessions.Status.Capturing, "fresh authenticated receiver after wake");
        await UntilAsync(() => sessions.Status.Receivers == 0 && !sessions.Status.Capturing, "wake receiver cleanup");
        Console.WriteLine("PASS: sleep cleanup preserves sharing, and a fresh authenticated receiver can reconnect.");

        audio.FailSourceStartup = true;
        await sessions.ConfigureAsync(new(SourceEndpointId: "synthetic", SharingEnabled: true));
        await using (var failedSource = await connector.ReceiverAsync())
            await UntilAsync(() => failedSource.Closed, "source startup failure closes peer");
        Require(sessions.CurrentSettings.SharingEnabled && sessions.Status.Message.Contains("synthetic format", StringComparison.Ordinal),
            "Startup failure must retain sharing intent and actionable error.");
        var failedAttempts = audio.SourceAttempts;
        await using (var retry = await connector.ReceiverAsync())
            await UntilAsync(() => retry.Closed, "automatic retry blocked after source failure");
        Require(audio.SourceAttempts == failedAttempts, "Automatic reconnect reopened a failed source.");
        audio.FailSourceStartup = false;
        await Task.Delay(2100);
        await using (var restarted = await connector.ReceiverAsync())
            await UntilAsync(() => sessions.Status.Capturing, "explicit restart after source failure");
        await UntilAsync(() => !sessions.Status.Capturing && sessions.Status.Receivers == 0, "restart cleanup");
        for (var cycle = 0; cycle < 3; cycle++) {
            await using var live = await connector.ReceiverAsync();
            await UntilAsync(() => sessions.Status.Capturing, "capture for runtime failure cycle");
            audio.SourceFailure!("Synthetic endpoint temporarily unavailable.");
            await UntilAsync(() => live.Closed && !sessions.Status.Capturing, "runtime failure releases source and peer");
            Require(sessions.CurrentSettings.SharingEnabled, "Runtime failure erased sharing intent.");
            await Task.Delay(2100);
        }
        await using (var recovered = await connector.ReceiverAsync())
            await UntilAsync(() => sessions.Status.Capturing, "recovery after repeated runtime failures");
        await UntilAsync(() => sessions.Status.Receivers == 0 && !sessions.Status.Capturing, "runtime retry cleanup");
        Require(audio.MaximumSources == 1, "Retry overlapped capture lifetimes.");
        Console.WriteLine("PASS: startup and repeated runtime failures recover without app restart, preserve sharing and never overlap captures.");

        await sessions.ConfigureAsync(new(SourceEndpointId: "synthetic", SharingEnabled: true));
        await using (var stopping = await connector.ReceiverAsync())
        {
            await UntilAsync(() => sessions.Status.Capturing, "capture before unavailable-settings stop");
            var saved = await SettingsApplication.ApplyAsync(sessions, new(), _ => throw new IOException("Synthetic read-only profile."));
            Require(!saved && !sessions.CurrentSettings.SharingEnabled && !sessions.Status.Capturing && sessions.Status.Receivers == 0,
                "A settings write failure prevented Stop from closing capture and receivers.");
            await UntilAsync(() => stopping.Closed, "stop closes listener despite settings write failure");
        }
        Console.WriteLine("PASS: Stop closes capture and receivers even when saving preferences fails.");

        await sessions.ConfigureAsync(new());
        using (var disabled = await connector.ConnectAsync())
        {
            await disabled.WriteLineAsync(token + " MIC1");
            Require(await disabled.ReadLineAsync() == "ERR DISABLED", "Disabled microphone was accepted.");
        }
        await sessions.ConfigureAsync(new(MicrophoneEndpointId: "missing", VirtualEndpointConfirmed: true, MicrophoneEnabled: true));
        using (var missing = await connector.ConnectAsync())
        {
            await missing.WriteLineAsync(token + " MIC1");
            Require(await missing.ReadLineAsync() == "ERR OUTPUT", "Missing sink was accepted.");
        }
        await EnableMicrophone(sessions);
        using (var microphone = await connector.ConnectAsync())
        {
            await microphone.WriteLineAsync(token + " MIC1");
            Require(await microphone.ReadLineAsync() == "OK MIC1 48000", "Microphone negotiation failed.");
            using (var second = await connector.ConnectAsync())
            {
                await second.WriteLineAsync(token + " MIC1");
                Require(await second.ReadLineAsync() == "ERR BUSY", "Second microphone was accepted.");
            }
            await using (var receiver = await connector.ReceiverAsync())
                await UntilAsync(() => receiver.Closed, "source cannot start during mic lease");
            await microphone.WriteAsync(MicPacket(0, 480));
            await UntilAsync(() => audio.LastSink?.Packets == 1, "synthetic microphone delivery");
            await microphone.WriteAsync(MicPacket(2, 480));
            await UntilAsync(() => audio.LastSink?.Packets == 2 && audio.LastSink.Flushes == 1, "discontinuity flush");
            await microphone.WriteAsync(MicPacket(3, 0));
            Require(await microphone.ReadLineAsync() == "STOPPED", "Stop acknowledgement missing.");
            Require(audio.LastSink!.Disposed && !sessions.Status.MicrophoneActive, "Stop did not dispose sink and release lease before ACK.");
        }
        Console.WriteLine("PASS: MIC1 disabled/output errors, exclusive admission, bounded packet parsing, discontinuity flush and Stop/STOPPED lifetime.");

        // Bad framing, stalled partial payload, EOF, and desktop revoke all
        // release the same sink/lease; no real microphone is ever opened.
        using (var wrongRate = await AcceptedMicrophone(connector, token))
        {
            var packet = MicPacket(0, 480);
            BinaryPrimitives.WriteInt32LittleEndian(packet.AsSpan(8), 44100);
            await wrongRate.WriteAsync(packet);
            await UntilAsync(() => !sessions.Status.MicrophoneActive && audio.LastSink!.Disposed, "wrong mic sample rate rejected");
        }
        using (var oversized = await AcceptedMicrophone(connector, token))
        {
            await oversized.WriteAsync(MicPacket(0, 961));
            await UntilAsync(() => !sessions.Status.MicrophoneActive, "oversized mic frame rejected");
        }
        using (var stalled = await AcceptedMicrophone(connector, token))
        {
            await stalled.WriteAsync(MicPacket(0, 480).AsMemory(0, 17));
            await UntilAsync(() => !sessions.Status.MicrophoneActive && audio.LastSink!.Disposed, "partial microphone timeout", 3500);
        }
        using (var eof = await AcceptedMicrophone(connector, token)) { }
        await UntilAsync(() => !sessions.Status.MicrophoneActive && audio.LastSink!.Disposed, "mic EOF cleanup");
        using (var revoked = await AcceptedMicrophone(connector, token))
        {
            await sessions.ConfigureAsync(new());
            Require(!sessions.Status.MicrophoneActive && audio.LastSink!.Disposed, "Desktop revoke leaked sink.");
        }
        await EnableMicrophone(sessions);
        using (var failedSink = await AcceptedMicrophone(connector, token))
        {
            audio.LastSink!.RejectWrites = true;
            await failedSink.WriteAsync(MicPacket(0, 480));
            await UntilAsync(() => !sessions.Status.MicrophoneActive && audio.LastSink!.Disposed, "sink failure cleanup");
        }
        Console.WriteLine("PASS: wrong-rate/oversize/partial frames, idle timeout, EOF, desktop revoke and sink failure cleanup.");
        await HandoffIntegration.RunAsync(certificate, token);
        Console.WriteLine("Synthetic protocol integration passed. No hardware audio, microphone, Windows UI or acoustic checks were performed.");
    }

    private static void CheckReleaseDestinations()
    {
        const string prefix = "https://github.com/Json604/pairIt-download/releases/";
        foreach (var suffix in new[] { "tag/v1.1.0-preview.7", "download/v1.1.0-preview.7/PairIt-Windows-x64.zip" })
            Require(ReleaseDestination.IsTrusted(prefix + suffix), "Official versioned release was rejected.");
        foreach (var suffix in new[] { "latest", "tag/latest", "tag/v1?redirect=elsewhere", "tag/v1#fragment", "tag/v1/extra",
            "tag/v1..2", "../../../attacker/repo/releases/tag/v1", "%2e%2e/%2e%2e/%2e%2e/attacker/repo/releases/tag/v1",
            "%2e%2e%2fattacker", "%252e%252e/%252e%252e", "tag/v1\\..\\latest", "tag/v1\n" })
            Require(!ReleaseDestination.IsTrusted(prefix + suffix), "Unsafe or mutable release URL was accepted: " + suffix);
        foreach (var url in new[] { null, "https://github.com/Json604/pairIt/releases/tag/v1",
            "https://github.com/Json604/pairIt-download-evil/releases/tag/v1", "http://github.com/Json604/pairIt-download/releases/tag/v1",
            "https://github.com.attacker.invalid/Json604/pairIt-download/releases/tag/v1",
            "https://user@github.com/Json604/pairIt-download/releases/tag/v1", "https://github.com:443/Json604/pairIt-download/releases/tag/v1",
            "https://github.com/attacker/repo/releases/tag/v1" })
            Require(!ReleaseDestination.IsTrusted(url), "Unofficial or ambiguous release URL was accepted.");
        Console.WriteLine("PASS: update destinations allow only versioned official GitHub release pages/assets; escaped paths and ambiguous/mutable URLs are rejected.");
    }

    private static Task EnableMicrophone(DesktopSessions sessions) => sessions.ConfigureAsync(new(MicrophoneEndpointId: "virtual-synthetic", VirtualEndpointConfirmed: true, MicrophoneEnabled: true));
    private static async Task<Connection> AcceptedMicrophone(Connector connector, string token)
    {
        var connection = await connector.ConnectAsync();
        await connection.WriteLineAsync(token + " MIC1");
        Require(await connection.ReadLineAsync() == "OK MIC1 48000", "Expected microphone acceptance.");
        return connection;
    }
    private static byte[] MicPacket(uint sequence, int frames)
    {
        var packet = new byte[16 + frames * 2];
        BinaryPrimitives.WriteUInt32LittleEndian(packet, Protocol.MicMagic);
        BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(4), sequence);
        BinaryPrimitives.WriteInt32LittleEndian(packet.AsSpan(8), 48000);
        BinaryPrimitives.WriteInt32LittleEndian(packet.AsSpan(12), frames);
        return packet;
    }
    internal static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    internal static async Task UntilAsync(Func<bool> condition, string description, int timeout = 3000)
    {
        using var deadline = new CancellationTokenSource(timeout);
        while (!condition())
        {
            if (deadline.IsCancellationRequested) throw new TimeoutException(description);
            await Task.Delay(10);
        }
    }
}

internal sealed class Connector(int port, X509Certificate2 expected, string token)
{
    public async Task<Connection> ConnectAsync()
    {
        var socket = new TcpClient { ReceiveBufferSize = 4096, NoDelay = true };
        await socket.ConnectAsync(IPAddress.Loopback, port);
        var stream = new SslStream(socket.GetStream(), false, (_, certificate, _, _) =>
            certificate != null && CryptographicOperations.FixedTimeEquals(SHA256.HashData(certificate.GetRawCertData()), SHA256.HashData(expected.RawData)));
        using var deadline = new CancellationTokenSource(3000);
        try
        {
            await stream.AuthenticateAsClientAsync(new SslClientAuthenticationOptions { TargetHost = "localhost", EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13 }, deadline.Token);
            return new(socket, stream);
        }
        catch { socket.Dispose(); stream.Dispose(); throw; }
    }
    public async Task<Receiver> ReceiverAsync(string? credential = null, bool readFrames = true)
    {
        var connection = await ConnectAsync();
        await connection.WriteLineAsync(credential ?? token);
        return new(connection, readFrames);
    }
}

internal sealed class Connection(TcpClient socket, SslStream stream) : IDisposable
{
    public SslStream Stream { get; } = stream;
    private readonly ProtocolReader reader = new(stream);
    public Task WriteLineAsync(string line) => WriteAsync(Encoding.ASCII.GetBytes(line + "\n"));
    public async Task WriteAsync(ReadOnlyMemory<byte> bytes)
    {
        using var timeout = new CancellationTokenSource(2500);
        await Stream.WriteAsync(bytes, timeout.Token);
    }
    public async Task<string> ReadLineAsync()
    {
        using var timeout = new CancellationTokenSource(3000);
        return await reader.ReadLineAsync(timeout.Token);
    }
    public void Dispose() { socket.Dispose(); Stream.Dispose(); }
}

internal sealed record FrameSignature(uint Sequence, int Rate, int Frames, long CapturedAt, string Hash);
internal sealed class Receiver : IAsyncDisposable
{
    private readonly Connection connection;
    private readonly Task reader;
    private readonly CancellationTokenSource lifetime = new();
    private readonly SemaphoreSlim writes = new(1);
    public ConcurrentQueue<FrameSignature> Frames { get; } = new();
    public ConcurrentBag<long> Clocks { get; } = [];
    private readonly ConcurrentDictionary<long, uint> clockFlags = new();
    private long nextClock;
    public bool Closed { get; private set; }
    public uint Rejection { get; private set; }
    public int Heartbeats;
    public volatile uint DesktopRequest;
    public volatile uint PresentationTarget, PresentationListeners, PresentationCapable;
    public int AlignmentReplies;
    // Negotiated extension frames; a receiver that never advertised one must see none.
    public ConcurrentQueue<uint> PlayerStates { get; } = new();
    public ConcurrentQueue<uint> VolumeRequests { get; } = new();
    public volatile uint ComputerVolume;
    public int ComputerVolumeFrames;

    public Receiver(Connection connection, bool readFrames)
    {
        this.connection = connection;
        reader = readFrames ? ReadAsync() : Task.CompletedTask;
    }
    public async Task SendAsync(string line)
    {
        await writes.WaitAsync();
        try { await connection.WriteAsync(Encoding.ASCII.GetBytes(line)); }
        finally { writes.Release(); }
    }
    public async Task<uint> ProbeAsync()
    {
        var echo = Interlocked.Increment(ref nextClock);
        await SendAsync($"PING {echo}\n");
        await Integration.UntilAsync(() => clockFlags.ContainsKey(echo), "handoff clock reply");
        clockFlags.TryRemove(echo, out var flags);
        return flags;
    }
    private async Task ReadAsync()
    {
        try
        {
            while (!lifetime.IsCancellationRequested)
            {
                var header = new byte[24];
                await connection.Stream.ReadExactlyAsync(header, lifetime.Token);
                var magic = BinaryPrimitives.ReadUInt32LittleEndian(header);
                if(magic==0x31455342){Rejection=BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4));Closed=true;return;}
                if (magic == 0x34435342) {
                    PresentationTarget = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4));
                    PresentationListeners = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(8));
                    PresentationCapable = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(12));
                    Interlocked.Increment(ref AlignmentReplies); continue;
                }
                if(magic==0x32435342){DesktopRequest=BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4));continue;}
                if (magic == Protocol.ComputerVolumeMagic) {
                    ComputerVolume = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4));
                    Interlocked.Increment(ref ComputerVolumeFrames); continue;
                }
                if (magic == Protocol.VolumeRequestMagic) { VolumeRequests.Enqueue(BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4))); continue; }
                if (magic == Protocol.PlayerStateMagic) { PlayerStates.Enqueue(BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4))); continue; }
                if (magic == Protocol.ClockMagic)
                {
                    var echo = BinaryPrimitives.ReadInt64LittleEndian(header.AsSpan(8));
                    Clocks.Add(echo);
                    clockFlags[echo] = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4));
                    continue;
                }
                Integration.Require(magic == Protocol.PcmMagic, "Unexpected/overlapped server frame.");
                var frames = BinaryPrimitives.ReadInt32LittleEndian(header.AsSpan(12));
                Integration.Require(frames is >= 0 and <= 8192, "Invalid source frame bound.");
                var pcm = new byte[frames * 4];
                await connection.Stream.ReadExactlyAsync(pcm, lifetime.Token);
                if (frames == 0) { Interlocked.Increment(ref Heartbeats); continue; }
                Frames.Enqueue(new(BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4)), BinaryPrimitives.ReadInt32LittleEndian(header.AsSpan(8)), frames,
                    BinaryPrimitives.ReadInt64LittleEndian(header.AsSpan(16)), Convert.ToHexStringLower(SHA256.HashData(pcm))));
                while (Frames.Count > 64) Frames.TryDequeue(out _);
            }
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or ObjectDisposedException) { Closed = true; }
    }
    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel();
        connection.Dispose();
        await reader;
        lifetime.Dispose();
        writes.Dispose();
    }
}

internal sealed class SyntheticEndpoints : IAudioEndpoints
{
    private SyntheticSource? current;
    private int activeSources;
    public int SourceStarts, SourceStops, MaximumSources, SourceAttempts;
    public bool FailSourceStartup;
    public Action<string>? SourceFailure;
    public bool KeepCaptureWhilePaused { get; init; }
    // Synthetic computer volume wire value (-1: unavailable) and whether PCM precedes it.
    public volatile int VolumeWire = -1;
    public volatile bool VolumeIndependent;
    public SyntheticSink? LastSink;
    public ISystemAudioSource CreateSource(string endpointId) => new SyntheticSource(this);
    public Task<IMicrophoneSink> OpenMicrophoneSinkAsync(string endpointId, CancellationToken cancellation)
    {
        if (endpointId != "virtual-synthetic") throw new IOException("Synthetic endpoint absent.");
        LastSink = new();
        return Task.FromResult<IMicrophoneSink>(LastSink);
    }
    public void Emit(int frames, long capturedAt, bool silent = false)
    {
        var bytes = new byte[frames * 4];
        if (!silent) for (var index = 0; index < bytes.Length; index++) bytes[index] = (byte)(index % 251);
        current?.Received?.Invoke(new(48000, frames, capturedAt, bytes));
    }
    private sealed class SyntheticSource(SyntheticEndpoints owner) : ISystemAudioSource
    {
        public Action<SourcePacket>? Received;
        private bool disposed, started;
        public uint? ComputerVolume => owner.VolumeWire is var value && value >= 0 ? (uint)value : null;
        public bool VolumeIndependentCapture => owner.VolumeIndependent;
        public Task StartAsync(Action<SourcePacket> received, Action<string> failed, CancellationToken cancellation)
        {
            owner.SourceAttempts++;
            if (owner.FailSourceStartup) throw new NotSupportedException("Choose a supported synthetic format and start again.");
            started = true;
            owner.current = this;
            Received = received;
            owner.SourceFailure = failed;
            owner.SourceStarts++;
            owner.MaximumSources = Math.Max(owner.MaximumSources, ++owner.activeSources);
            return Task.CompletedTask;
        }
        public ValueTask DisposeAsync()
        {
            if (!disposed)
            {
                disposed = true;
                Received = null;
                if (started) { owner.SourceStops++; owner.activeSources--; }
            }
            return ValueTask.CompletedTask;
        }
    }
}

internal sealed class SyntheticSink : IMicrophoneSink
{
    public volatile int Packets, Flushes;
    public volatile bool Disposed, RejectWrites;
    public void Write(ReadOnlySpan<byte> pcm)
    {
        if (Disposed || RejectWrites) throw new IOException("Synthetic output unavailable.");
        Interlocked.Increment(ref Packets);
    }
    public Task FlushAsync(CancellationToken cancellation) { Interlocked.Increment(ref Flushes); return Task.CompletedTask; }
    public ValueTask DisposeAsync() { Disposed = true; return ValueTask.CompletedTask; }
}
