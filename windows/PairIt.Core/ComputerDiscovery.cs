using System.Buffers.Binary;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;

namespace PairIt.Core;

/// <summary>Local discovery metadata only. Pairing still requires a private QR/link and pinned TLS.</summary>
public sealed class ComputerDiscovery : IDisposable
{
    public const string Service = "_audiorelay._tcp.local";
    private static readonly IPAddress Group = IPAddress.Parse("224.0.0.251");
    private readonly CancellationTokenSource stop = new();
    private readonly List<UdpClient> sockets = [];
    private readonly string pin, platform, displayName;
    private readonly int port;
    private readonly Task loop;
    private int disposed;
    private readonly SemaphoreSlim networkChanged = new(0, 1);

    public ComputerDiscovery(string pin, string platform, string displayName, int port = 5002)
    {
        if (pin.Length != 64 || pin.Any(c => !"0123456789abcdef".Contains(c))) throw new ArgumentException("Invalid pin.");
        if (platform is not ("windows" or "linux")) throw new ArgumentException("Invalid platform.");
        if (port is < 1 or > 65535) throw new ArgumentOutOfRangeException(nameof(port));
        this.pin = pin; this.platform = platform; this.port = port;
        this.displayName = new string(displayName.Where(c => !char.IsControl(c)).Take(60).ToArray());
        NetworkChange.NetworkAddressChanged += OnNetworkChanged;
        loop = Task.Run(RunAsync);
    }

    private void OnNetworkChanged(object? sender, EventArgs args)
    {
        // Serialize disposal with callbacks already dispatched by the OS.
        lock (networkChanged)
        {
            if (disposed != 0) return;
            if (networkChanged.CurrentCount == 0) networkChanged.Release();
        }
    }

    private async Task RunAsync()
    {
        // Recreate memberships periodically so reconnecting Wi-Fi does not need an app restart.
        while (!stop.IsCancellationRequested)
        {
            var workers = new List<Task>();
            try
            {
                foreach (var address in NetworkInterface.GetAllNetworkInterfaces()
                    .Where(n => n.OperationalStatus == OperationalStatus.Up && n.SupportsMulticast && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
                    .SelectMany(n => n.GetIPProperties().UnicastAddresses)
                    .Select(a => a.Address).Where(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a)).Distinct())
                {
                    UdpClient? socket = null;
                    try
                    {
                        socket = new UdpClient(AddressFamily.InterNetwork);
                        socket.Client.ExclusiveAddressUse = false;
                        socket.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                        socket.Client.Bind(new IPEndPoint(IPAddress.Any, 5353));
                        socket.JoinMulticastGroup(Group, address);
                        socket.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface, address.GetAddressBytes());
                        socket.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastTimeToLive, 255);
                        lock (sockets) sockets.Add(socket);
                        workers.Add(ServeAsync(socket, address));
                    }
                    catch (SocketException) { socket?.Dispose(); }
                }
                await networkChanged.WaitAsync(TimeSpan.FromSeconds(60), stop.Token);
            }
            catch (NetworkInformationException) { try { await Task.Delay(5000, stop.Token); } catch (OperationCanceledException) { } }
            catch (OperationCanceledException) { }
            finally
            {
                lock (sockets) { foreach (var socket in sockets) socket.Dispose(); sockets.Clear(); }
                await Task.WhenAll(workers);
            }
        }
    }

    private async Task ServeAsync(UdpClient socket, IPAddress address)
    {
        var packet = CreateAnnouncement(pin, platform, displayName, address, port);
        var target = new IPEndPoint(Group, 5353);
        try
        {
            await socket.SendAsync(packet, target, stop.Token);
            long lastReply = 0;
            while (!stop.IsCancellationRequested)
            {
                var request = await socket.ReceiveAsync(stop.Token);
                // Only normal mDNS queries. Never reflect traffic to arbitrary source ports/addresses.
                if (request.RemoteEndPoint.Port != 5353 || !IsQuery(request.Buffer, pin)) continue;
                var now = Environment.TickCount64;
                if (now - lastReply < 1000) continue;
                lastReply = now;
                await socket.SendAsync(packet, target, stop.Token);
            }
        }
        catch (Exception error) when (error is SocketException or ObjectDisposedException or OperationCanceledException) { }
    }

    public static bool IsQuery(ReadOnlySpan<byte> packet, string pin)
    {
        if (packet.Length is < 12 or > 9000 || (packet[2] & 0xF8) != 0) return false;
        int count = BinaryPrimitives.ReadUInt16BigEndian(packet[4..]), offset = 12;
        if (count is < 1 or > 32) return false;
        for (int i = 0; i < count; i++)
        {
            var name = ReadName(packet, ref offset);
            if (name == null || offset + 4 > packet.Length) return false;
            var type = BinaryPrimitives.ReadUInt16BigEndian(packet[offset..]);
            var klass = BinaryPrimitives.ReadUInt16BigEndian(packet[(offset + 2)..]) & 0x7fff;
            offset += 4;
            if (klass == 1 && type is 1 or 12 or 16 or 33 or 255 &&
                (name.Equals(Service, StringComparison.OrdinalIgnoreCase) ||
                 name.Equals($"AudioRelay-{pin[..8]}.{Service}", StringComparison.OrdinalIgnoreCase) ||
                 name.Equals($"pairit-{pin[..16]}.local", StringComparison.OrdinalIgnoreCase))) return true;
        }
        return false;
    }

    private static string? ReadName(ReadOnlySpan<byte> packet, ref int offset)
    {
        int cursor = offset, end = -1, steps = 0, length = 0;
        var labels = new List<string>();
        while (cursor < packet.Length && steps++ < 128)
        {
            int size = packet[cursor++];
            if (size == 0) { offset = end < 0 ? cursor : end; return string.Join('.', labels); }
            if ((size & 0xC0) == 0xC0)
            {
                if (cursor >= packet.Length) return null;
                if (end < 0) end = cursor + 1;
                cursor = ((size & 63) << 8) | packet[cursor];
                continue;
            }
            if (size > 63 || cursor + size > packet.Length || (length += size + 1) > 254) return null;
            labels.Add(Encoding.ASCII.GetString(packet.Slice(cursor, size))); cursor += size;
        }
        return null;
    }

    public static byte[] CreateAnnouncement(string pin, string platform, string name, IPAddress address, int port)
    {
        var instance = $"AudioRelay-{pin[..8]}.{Service}";
        var host = $"pairit-{pin[..16]}.local";
        using var stream = new MemoryStream();
        void U16(int value) { stream.WriteByte((byte)(value >> 8)); stream.WriteByte((byte)value); }
        void Name(string value) { foreach (var label in value.Split('.')) { var bytes = Encoding.UTF8.GetBytes(label); stream.WriteByte((byte)bytes.Length); stream.Write(bytes); } stream.WriteByte(0); }
        void Record(string owner, int type, Action data)
        {
            Name(owner); U16(type); U16(type == 12 ? 1 : 0x8001); stream.Write([0, 0, 0, 120]);
            long sizeAt = stream.Position; U16(0); long start = stream.Position; data();
            long end = stream.Position; stream.Position = sizeAt; U16((int)(end - start)); stream.Position = end;
        }
        U16(0); U16(0x8400); U16(0); U16(4); U16(0); U16(0);
        Record(Service, 12, () => Name(instance));
        Record(instance, 33, () => { U16(0); U16(0); U16(port); Name(host); });
        Record(instance, 16, () => {
            foreach (var text in new[] { "role=computer", "v=1", "platform=" + platform, "name=" + name, "pin=" + pin })
            { var bytes = Encoding.UTF8.GetBytes(text); if (bytes.Length > 255) throw new ArgumentException("Discovery text too long."); stream.WriteByte((byte)bytes.Length); stream.Write(bytes); }
        });
        Record(host, 1, () => stream.Write(address.GetAddressBytes()));
        return stream.ToArray();
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        NetworkChange.NetworkAddressChanged -= OnNetworkChanged;
        stop.Cancel();
        lock (sockets) foreach (var socket in sockets) socket.Dispose();
        loop.GetAwaiter().GetResult(); stop.Dispose();
        lock (networkChanged) networkChanged.Dispose();
    }
}
