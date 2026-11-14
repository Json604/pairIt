using System.Collections.Concurrent;
using System.Globalization;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace PairIt.Core;

public sealed class RelayServer(X509Certificate2 certificate, string pairingToken, DesktopSessions sessions) : IAsyncDisposable
{
    private readonly CancellationTokenSource lifetime = new();
    private readonly SemaphoreSlim handshakes = new(8, 8);
    private readonly SemaphoreSlim authenticatedSessions = new(5, 5);
    private readonly ConcurrentDictionary<Guid, TcpClient> sockets = new();
    private readonly ConcurrentDictionary<Guid, Task> connections = new();
    private TcpListener? listener;
    private Task? acceptLoop, heartbeatLoop;
    public int Port => ((IPEndPoint?)listener?.LocalEndpoint)?.Port ?? Protocol.Port;

    public void Start(IPAddress? address = null, int port = Protocol.Port)
    {
        if (listener != null) throw new InvalidOperationException("Server already started.");
        listener = new TcpListener(address ?? IPAddress.Any, port);
        listener.Start(16);
        acceptLoop = AcceptAsync();
        heartbeatLoop = HeartbeatAsync();
    }

    private async Task AcceptAsync()
    {
        try
        {
            while (!lifetime.IsCancellationRequested)
            {
                TcpClient socket;
                try { socket = await listener!.AcceptTcpClientAsync(lifetime.Token).ConfigureAwait(false); }
                catch (SocketException) when (!lifetime.IsCancellationRequested)
                {
                    // A transient interface failure must not terminate the accept loop.
                    await Task.Delay(1000, lifetime.Token).ConfigureAwait(false);
                    continue;
                }
                if (!handshakes.Wait(0)) { socket.Dispose(); continue; }
                socket.NoDelay = true;
                socket.SendBufferSize = 32 * 1024;
                var id = Guid.NewGuid();
                sockets[id] = socket;
                var task = RunConnectionAsync(socket);
                connections[id] = task;
                _ = ObserveConnectionAsync(id, task);
            }
        }
        catch (Exception error) when (error is OperationCanceledException or ObjectDisposedException or SocketException)
        {
            if (!lifetime.IsCancellationRequested) throw;
        }
    }

    private async Task ObserveConnectionAsync(Guid id, Task task)
    {
        try { await task.ConfigureAwait(false); }
        finally
        {
            connections.TryRemove(id, out _);
            if (sockets.TryRemove(id, out var socket)) socket.Dispose();
        }
    }

    private async Task RunConnectionAsync(TcpClient socket)
    {
        var handshakeHeld = true;
        var authenticatedSlot = false;
        try
        {
            using var stream = new SslStream(socket.GetStream(), false);
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            deadline.CancelAfter(TimeSpan.FromSeconds(4));
            await stream.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
            {
                ServerCertificate = certificate,
                EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
                ClientCertificateRequired = false,
                CertificateRevocationCheckMode = X509RevocationMode.NoCheck
            }, deadline.Token).ConfigureAwait(false);
            var reader = new ProtocolReader(stream);
            var line = await reader.ReadLineAsync(deadline.Token).ConfigureAwait(false);
            var proIndex = line.IndexOf(" PRO1 ", StringComparison.Ordinal);
            // Retired preview suffix is ignored; it never bypasses pairing-token validation.
            if (proIndex >= 0) line = line[..proIndex];
            var microphone = line.EndsWith(" MIC1", StringComparison.Ordinal);
            var pairing = line.EndsWith(" PAIR1", StringComparison.Ordinal);
            var supplied = pairing ? line[..^6] : microphone ? line[..^5] : line;
            if (!ValidToken(supplied)) return;
            if (pairing)
            {
                await stream.WriteAsync("OK PAIR1\n"u8.ToArray(), deadline.Token).ConfigureAwait(false);
                sessions.AcknowledgePairing();
                return;
            }
            if (!authenticatedSessions.Wait(0))
            {
                if (microphone) await stream.WriteAsync("ERR BUSY\n"u8.ToArray(), deadline.Token).ConfigureAwait(false);
                else await RejectFullAsync(stream, deadline.Token).ConfigureAwait(false);
                return;
            }
            authenticatedSlot = true;
            handshakes.Release();
            handshakeHeld = false;
            if (microphone) await RunMicrophoneAsync(stream, reader, deadline.Token).ConfigureAwait(false);
            else await RunReceiverAsync(socket, stream, reader, deadline.Token).ConfigureAwait(false);
        }
        catch (Exception error) when (error is IOException or SocketException or AuthenticationException or
            OperationCanceledException or ObjectDisposedException or InvalidDataException or FormatException or DecoderFallbackException)
        {
            // Never log peer-supplied text, tokens or audio. Closing is the error
            // response for legacy receiver/authentication failures.
        }
        finally
        {
            if (handshakeHeld) handshakes.Release();
            if (authenticatedSlot) authenticatedSessions.Release();
            socket.Dispose();
        }
    }

    private bool ValidToken(string supplied)
    {
        if (supplied.Length != 64 || pairingToken.Length != 64) return false;
        return CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(supplied), Encoding.ASCII.GetBytes(pairingToken));
    }

    private static async Task RejectFullAsync(SslStream stream, CancellationToken cancellation)
    {
        var rejected = new byte[24];
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(rejected, 0x31455342);
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(rejected.AsSpan(4), 1);
        await stream.WriteAsync(rejected, cancellation).ConfigureAwait(false);
    }

    private async Task RunReceiverAsync(TcpClient socket, SslStream stream, ProtocolReader reader, CancellationToken admissionDeadline)
    {
        using var peer = new ReceiverSession(socket, stream);
        if (!await sessions.AddReceiverAsync(peer, admissionDeadline).ConfigureAwait(false)) {
            if (peer.GroupFull) await RejectFullAsync(stream, admissionDeadline).ConfigureAwait(false);
            return;
        }
        var writer = peer.WriteFramesAsync();
        try
        {
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token, peer.Cancellation);
            while (!linked.IsCancellationRequested)
            {
                using var idle = CancellationTokenSource.CreateLinkedTokenSource(linked.Token);
                idle.CancelAfter(TimeSpan.FromSeconds(8));
                var line = await reader.ReadLineAsync(idle.Token).ConfigureAwait(false);
                peer.LastControlAt = MonotonicClock.Nanoseconds;
                await HandleControlAsync(peer, line).ConfigureAwait(false);
            }
        }
        finally
        {
            peer.Close();
            await writer.ConfigureAwait(false);
            await sessions.RemoveReceiverAsync(peer).ConfigureAwait(false);
        }
    }

    private async Task HandleControlAsync(ReceiverSession peer, string line)
    {
        if (line == "OUTPUT COMPUTER" || line == "OUTPUT PHONE")
        {
            await sessions.SetComputerOutputAsync(line == "OUTPUT COMPUTER").ConfigureAwait(false);
            return;
        }
        if (line == "ACTIVE 0" || line == "ACTIVE 1")
        {
            await sessions.SetActiveAsync(peer, line[^1] == '1').ConfigureAwait(false);
            return;
        }
        if (line.StartsWith("PING ", StringComparison.Ordinal) &&
            long.TryParse(line.AsSpan(5), NumberStyles.None, CultureInfo.InvariantCulture, out var echoed) && echoed >= 0)
        {
            if (!peer.TryEnqueue(Protocol.ClockReply(echoed, sessions.ClockStatus(peer)))) peer.Close();
            if (sessions.PresentationTarget(peer) is { } alignment) {
                var frame = Protocol.ClockReply(echoed, alignment.Target);
                System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(frame, 0x34435342);
                System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(frame.AsSpan(8), alignment.Listeners);
                System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(frame.AsSpan(12), alignment.Capable);
                if (!peer.TryEnqueue(frame)) peer.Close();
            }
            if (peer.VolumeControls && sessions.ComputerVolume is uint volume) {
                var frame=Protocol.ClockReply(echoed,volume);
                System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(frame,0x33435342);
                if(!peer.TryEnqueue(frame))peer.Close();
            }
            if(sessions.DesktopPlaybackRequest(peer) is uint request){
                var frame=Protocol.ClockReply(echoed,request);
                System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(frame,0x32435342);
                if(!peer.TryEnqueue(frame))peer.Close();
            }
            return;
        }
        if (line.StartsWith("PARK ", StringComparison.Ordinal) || line.StartsWith("RESUME ", StringComparison.Ordinal) || line.StartsWith("RELEASE ", StringComparison.Ordinal))
        {
            var parts = line.Split(' ');
            if (parts.Length is < 2 or > 3 || !uint.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var token) ||
                token is 0 or > Protocol.MaximumIntentToken) throw new InvalidDataException("Invalid handoff token.");
            var intent = parts[0] switch
            {
                "PARK" when parts.Length == 3 => ReceiverIntent.Park,
                "RESUME" when parts.Length == 2 => ReceiverIntent.Resume,
                "RELEASE" when parts.Length == 2 => ReceiverIntent.Release,
                _ => throw new InvalidDataException("Invalid handoff command.")
            };
            var reason = intent == ReceiverIntent.Park ? parts[2] switch
            {
                "PHONE" => ParkReason.Phone,
                "PAUSE" => ParkReason.Pause,
                "OUTPUT" => ParkReason.Output,
                _ => throw new InvalidDataException("Invalid park reason.")
            } : ParkReason.Output;
            await sessions.ApplyIntentAsync(peer, intent, token, reason).ConfigureAwait(false);
            return;
        }
        if (line.StartsWith("SYNC ", StringComparison.Ordinal) &&
            double.TryParse(line.AsSpan(5), NumberStyles.Float, CultureInfo.InvariantCulture, out var delay) &&
            double.IsFinite(delay) && delay is >= 0 and <= 2000)
        {
            peer.SyncMilliseconds = delay; // Diagnostic only; Windows has no HAL compensation.
            return;
        }
        if (line.StartsWith("HELLO ", StringComparison.Ordinal) && line.Length == 38 &&
            line.AsSpan(6).ContainsAnyExcept("0123456789abcdef".AsSpan()) == false)
        {
            sessions.SetHello(peer, line[6..]);
            return;
        }
        if (line.StartsWith("STATS ALIGN1 ", StringComparison.Ordinal)) {
            var parts = line.Split(' ');
            if (parts.Length != 4 || !int.TryParse(parts[2], NumberStyles.None, CultureInfo.InvariantCulture, out int minimum) ||
                !int.TryParse(parts[3], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out int output) ||
                minimum is < 1 or > 320 || output is < -1 or > 1000) throw new InvalidDataException("Invalid presentation timing.");
            sessions.SetPresentationTiming(peer, minimum, output < 0 ? null : output);
            return;
        }
        if(line=="STATS VOLUME1"){peer.VolumeControls=true;return;}
        if(line=="STATS CONTROLS1"){peer.DesktopControls=true;return;}
        if (line.StartsWith("STATS ", StringComparison.Ordinal)) return;
        throw new InvalidDataException("Unsupported control line.");
    }

    private async Task RunMicrophoneAsync(SslStream stream, ProtocolReader reader, CancellationToken negotiationDeadline)
    {
        var (lease, response) = await sessions.AcquireMicrophoneAsync(negotiationDeadline).ConfigureAwait(false);
        try
        {
            await stream.WriteAsync(Encoding.ASCII.GetBytes(response), negotiationDeadline).ConfigureAwait(false);
            if (lease == null) return;
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token, lease.Lifetime.Token);
            var header = new byte[16];
            var pcm = new byte[960 * 2];
            uint? expectedSequence = null;
            while (!linked.IsCancellationRequested)
            {
                using var idle = CancellationTokenSource.CreateLinkedTokenSource(linked.Token);
                idle.CancelAfter(TimeSpan.FromSeconds(2));
                await reader.ReadExactlyAsync(header, idle.Token).ConfigureAwait(false);
                var packet = Protocol.ReadMicrophoneHeader(header);
                if (packet.Frames == 0)
                {
                    // Dispose/reset the sink before acknowledging Stop. The phone
                    // already stopped capture and does not wait for this ACK.
                    await sessions.ReleaseMicrophoneAsync(lease).ConfigureAwait(false);
                    using var stopDeadline = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                    stopDeadline.CancelAfter(TimeSpan.FromMilliseconds(400));
                    await stream.WriteAsync("STOPPED\n"u8.ToArray(), stopDeadline.Token).ConfigureAwait(false);
                    return;
                }
                await reader.ReadExactlyAsync(pcm.AsMemory(0, packet.Frames * 2), idle.Token).ConfigureAwait(false);
                if (expectedSequence.HasValue && packet.Sequence != expectedSequence.Value)
                    await lease.Sink.FlushAsync(idle.Token).ConfigureAwait(false);
                expectedSequence = unchecked(packet.Sequence + 1);
                lease.Sink.Write(pcm.AsSpan(0, packet.Frames * 2));
            }
        }
        finally
        {
            if (lease != null)
            {
                await sessions.ReleaseMicrophoneAsync(lease).ConfigureAwait(false);
                lease.Lifetime.Dispose();
            }
        }
    }

    private async Task HeartbeatAsync()
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));
        try { while (await timer.WaitForNextTickAsync(lifetime.Token).ConfigureAwait(false)) sessions.SendHeartbeat(); }
        catch (OperationCanceledException) { }
    }

    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel();
        listener?.Stop();
        if (acceptLoop != null) await acceptLoop.ConfigureAwait(false);
        foreach (var socket in sockets.Values) socket.Dispose();
        await sessions.DisposeAsync().ConfigureAwait(false);
        await Task.WhenAll(connections.Values).ConfigureAwait(false);
        if (heartbeatLoop != null) await heartbeatLoop.ConfigureAwait(false);
        lifetime.Dispose();
        handshakes.Dispose();
        authenticatedSessions.Dispose();
    }
}
