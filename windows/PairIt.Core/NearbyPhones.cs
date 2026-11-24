using System.Buffers.Binary;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace PairIt.Core;

public sealed record RememberedPhone(string Id, string Name);

public sealed record NearbyPhone(string Id, string Name, bool Available, IReadOnlyList<string> AllIds);

public sealed record PhoneAdvertisement(IReadOnlySet<string> Tags, string Name, IPAddress Address, int Port);

/// <summary>Remembers phones that connected to this computer before, detects when they
/// have PairIt open nearby over mDNS (_pairit-phone._tcp.local) using daily-rotating
/// SHA-256 tags, and sends CONNECT1 hints verified by the phone over pinned TLS (WANT1).</summary>
public sealed class NearbyPhones : IDisposable
{
    public const string Service = "_pairit-phone._tcp.local";
    private const int MaximumRemembered = 12;
    private const long SeenLifetimeNanoseconds = 15_000_000_000L;
    private static readonly IPAddress MulticastGroup = IPAddress.Parse("224.0.0.251");
    private static readonly byte[] PhoneQueryPacket = CreatePhoneQuery();

    private sealed record SeenPhone(HashSet<string> Tags, string Name, IPAddress Address, int Port, long SeenAt);

    private readonly object gate = new();
    private readonly string storagePath, token, pin;
    private readonly List<RememberedPhone> remembered = [];
    private readonly Dictionary<string, SeenPhone> seen = [];
    private readonly CancellationTokenSource stop = new();
    private readonly SemaphoreSlim networkChanged = new(0, 1);
    private readonly List<UdpClient> sockets = [];
    private readonly Task? loop;
    private IReadOnlyList<NearbyPhone> published = [];
    private int disposed;

    public event Action<IReadOnlyList<NearbyPhone>>? Changed;

    public NearbyPhones(string storagePath, string token, string pin, bool startDiscovery = true)
    {
        this.storagePath = storagePath;
        this.token = token;
        this.pin = pin;
        LoadRemembered();
        published = BuildListLocked();
        if (startDiscovery)
        {
            NetworkChange.NetworkAddressChanged += OnNetworkChanged;
            loop = Task.Run(RunAsync);
        }
    }

    public IReadOnlyList<NearbyPhone> Current
    {
        get { lock (gate) return published; }
    }

    public static string NormalizeName(string name) => name.Trim().ToLowerInvariant();

    public static string Tag(string token, string installation, long day)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes($"{token}:{installation}:{day}"));
        return Convert.ToHexStringLower(hash.AsSpan(0, 6));
    }

    /// <summary>Collapse duplicate offline entries with the same display name (for example,
    /// after reinstalling PairIt or switching between Play and Preview builds on the same
    /// phone). Online phones are never hidden.</summary>
    public static IReadOnlyList<NearbyPhone> Deduplicate(IReadOnlyList<(string Id, string Name, bool Available)> raw)
    {
        var result = new List<NearbyPhone>(raw.Count);
        var idsByIndex = new List<List<string>>(raw.Count);
        var representativeByName = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var phone in raw)
        {
            if (!phone.Available) continue;
            var key = NormalizeName(phone.Name);
            if (!representativeByName.ContainsKey(key)) representativeByName[key] = result.Count;
            var ids = new List<string> { phone.Id };
            idsByIndex.Add(ids);
            result.Add(new(phone.Id, phone.Name, true, ids));
        }
        foreach (var phone in raw)
        {
            if (phone.Available) continue;
            var key = NormalizeName(phone.Name);
            if (representativeByName.TryGetValue(key, out var index))
            {
                idsByIndex[index].Add(phone.Id);
            }
            else
            {
                representativeByName[key] = result.Count;
                var ids = new List<string> { phone.Id };
                idsByIndex.Add(ids);
                result.Add(new(phone.Id, phone.Name, false, ids));
            }
        }
        return result.Select((p, i) => p with { AllIds = idsByIndex[i].ToArray() }).ToArray();
    }

    /// <summary>Phones that connected before and are not connected now. Offline stale
    /// duplicates sharing a connected phone's name are hidden unless actively open nearby.</summary>
    public static IReadOnlyList<NearbyPhone> FilterReconnectable(IReadOnlyList<NearbyPhone> remembered, IReadOnlyList<DesktopPhone> connected)
    {
        var connectedIds = new HashSet<string>(connected.Where(p => p.InstallationId != null).Select(p => p.InstallationId!), StringComparer.Ordinal);
        var connectedNames = new HashSet<string>(connected.Select(p => NormalizeName(p.Name)), StringComparer.Ordinal);
        return remembered.Where(phone =>
        {
            if (connectedIds.Contains(phone.Id)) return false;
            if (!phone.Available && connectedNames.Contains(NormalizeName(phone.Name))) return false;
            return true;
        }).ToArray();
    }

    public void Remember(IReadOnlyList<DesktopPhone> phones)
    {
        IReadOnlyList<NearbyPhone>? next = null;
        lock (gate)
        {
            var changed = false;
            foreach (var phone in phones)
            {
                if (!ValidInstallationId(phone.InstallationId)) continue;
                var id = phone.InstallationId!;
                var name = string.IsNullOrWhiteSpace(phone.Name) ? "Phone" : phone.Name;
                var entry = new RememberedPhone(id, name);
                var existing = remembered.FindIndex(item => item.Id == id);
                if (existing >= 0)
                {
                    if (existing != 0 || remembered[existing] != entry)
                    {
                        remembered.RemoveAt(existing);
                        remembered.Insert(0, entry);
                        changed = true;
                    }
                }
                else
                {
                    remembered.Insert(0, entry);
                    if (remembered.Count > MaximumRemembered) remembered.RemoveRange(MaximumRemembered, remembered.Count - MaximumRemembered);
                    changed = true;
                }
            }
            if (!changed) return;
            SaveRememberedLocked();
            next = PublishLocked();
        }
        if (next != null) Changed?.Invoke(next);
    }

    public void Forget(IEnumerable<string> ids)
    {
        var doomed = new HashSet<string>(ids, StringComparer.Ordinal);
        if (doomed.Count == 0) return;
        IReadOnlyList<NearbyPhone>? next = null;
        lock (gate)
        {
            var removed = remembered.RemoveAll(entry => doomed.Contains(entry.Id));
            if (removed == 0) return;
            SaveRememberedLocked();
            next = PublishLocked();
        }
        if (next != null) Changed?.Invoke(next);
    }

    public void ObservePacket(ReadOnlySpan<byte> packet, IPAddress source) => ObservePacket(packet, source, MonotonicClock.Nanoseconds);

    internal void ObservePacket(ReadOnlySpan<byte> packet, IPAddress source, long nowNanoseconds)
    {
        var parsed = ParseAnnouncement(packet, source);
        if (parsed.Count == 0) return;
        IReadOnlyList<NearbyPhone>? next;
        lock (gate)
        {
            PruneSeenLocked(nowNanoseconds);
            foreach (var item in parsed)
            {
                var key = $"{item.Address}:{item.Port}";
                foreach (var old in seen.Where(kv => kv.Key != key && kv.Value.Tags.Overlaps(item.Tags)).Select(kv => kv.Key).ToArray())
                    seen.Remove(old);
                seen[key] = new SeenPhone([.. item.Tags], item.Name, item.Address, item.Port, nowNanoseconds);
            }
            next = PublishLocked();
        }
        if (next != null) Changed?.Invoke(next);
    }

    public async Task<bool> RequestConnectionAsync(string installationId, CancellationToken cancellation = default)
    {
        SeenPhone? target;
        lock (gate)
        {
            PruneSeenLocked(MonotonicClock.Nanoseconds);
            target = FindEndpointLocked(installationId);
        }
        if (target == null || string.IsNullOrEmpty(pin)) return false;
        try
        {
            using var client = new TcpClient(AddressFamily.InterNetwork);
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(stop.Token, cancellation);
            deadline.CancelAfter(TimeSpan.FromSeconds(5));
            await client.ConnectAsync(target.Address, target.Port, deadline.Token).ConfigureAwait(false);
            var message = Encoding.ASCII.GetBytes($"CONNECT1 {pin}\n");
            await client.GetStream().WriteAsync(message, deadline.Token).ConfigureAwait(false);
            await client.GetStream().FlushAsync(deadline.Token).ConfigureAwait(false);
            return true;
        }
        catch (Exception error) when (error is SocketException or IOException or OperationCanceledException or ObjectDisposedException)
        {
            return false;
        }
    }

    private void OnNetworkChanged(object? sender, EventArgs args)
    {
        lock (networkChanged)
        {
            if (disposed != 0) return;
            if (networkChanged.CurrentCount == 0) networkChanged.Release();
        }
    }

    private async Task RunAsync()
    {
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
                        socket.JoinMulticastGroup(MulticastGroup, address);
                        socket.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface, address.GetAddressBytes());
                        socket.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastTimeToLive, 255);
                        lock (sockets) sockets.Add(socket);
                        workers.Add(BrowseAsync(socket));
                    }
                    catch (SocketException) { socket?.Dispose(); }
                }
                using var cycle = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
                var expiryTask = ExpireLoopAsync(cycle.Token);
                await networkChanged.WaitAsync(TimeSpan.FromSeconds(60), stop.Token).ConfigureAwait(false);
                cycle.Cancel();
                await expiryTask.ConfigureAwait(false);
            }
            catch (NetworkInformationException) { try { await Task.Delay(5000, stop.Token).ConfigureAwait(false); } catch (OperationCanceledException) { } }
            catch (OperationCanceledException) { }
            finally
            {
                lock (sockets) { foreach (var socket in sockets) socket.Dispose(); sockets.Clear(); }
                await Task.WhenAll(workers).ConfigureAwait(false);
            }
        }
    }

    private async Task BrowseAsync(UdpClient socket)
    {
        var target = new IPEndPoint(MulticastGroup, 5353);
        try
        {
            await socket.SendAsync(PhoneQueryPacket, target, stop.Token).ConfigureAwait(false);
            var lastQuery = MonotonicClock.Nanoseconds;
            while (!stop.IsCancellationRequested)
            {
                using var wait = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
                wait.CancelAfter(TimeSpan.FromSeconds(8));
                try
                {
                    var result = await socket.ReceiveAsync(wait.Token).ConfigureAwait(false);
                    ObservePacket(result.Buffer, result.RemoteEndPoint.Address);
                }
                catch (OperationCanceledException) when (!stop.IsCancellationRequested) { }
                var now = MonotonicClock.Nanoseconds;
                if (now - lastQuery >= 8_000_000_000L)
                {
                    lastQuery = now;
                    await socket.SendAsync(PhoneQueryPacket, target, stop.Token).ConfigureAwait(false);
                }
            }
        }
        catch (Exception error) when (error is SocketException or ObjectDisposedException or OperationCanceledException) { }
    }

    private async Task ExpireLoopAsync(CancellationToken cancellation)
    {
        try
        {
            using var timer = new PeriodicTimer(TimeSpan.FromSeconds(4));
            while (await timer.WaitForNextTickAsync(cancellation).ConfigureAwait(false))
            {
                IReadOnlyList<NearbyPhone>? next = null;
                lock (gate)
                {
                    if (PruneSeenLocked(MonotonicClock.Nanoseconds)) next = PublishLocked();
                }
                if (next != null) Changed?.Invoke(next);
            }
        }
        catch (OperationCanceledException) { }
    }

    private bool PruneSeenLocked(long now)
    {
        var removed = false;
        foreach (var key in seen.Where(kv => now - kv.Value.SeenAt >= SeenLifetimeNanoseconds).Select(kv => kv.Key).ToArray())
        {
            seen.Remove(key);
            removed = true;
        }
        return removed;
    }

    private SeenPhone? FindEndpointLocked(string installation)
    {
        if (string.IsNullOrEmpty(token) || seen.Count == 0) return null;
        var day = DateTimeOffset.UtcNow.ToUnixTimeSeconds() / 86_400;
        var t0 = Tag(token, installation, day);
        var t1 = Tag(token, installation, day - 1);
        var t2 = Tag(token, installation, day + 1);
        foreach (var entry in seen.Values)
            if (entry.Tags.Contains(t0) || entry.Tags.Contains(t1) || entry.Tags.Contains(t2)) return entry;
        return null;
    }

    private IReadOnlyList<NearbyPhone> BuildListLocked()
    {
        var raw = remembered.Select(entry => (entry.Id, entry.Name, FindEndpointLocked(entry.Id) != null)).ToArray();
        return Deduplicate(raw);
    }

    private IReadOnlyList<NearbyPhone>? PublishLocked()
    {
        var next = BuildListLocked();
        if (ListsEqual(published, next)) return null;
        published = next;
        return next;
    }

    private static bool ListsEqual(IReadOnlyList<NearbyPhone> a, IReadOnlyList<NearbyPhone> b)
    {
        if (a.Count != b.Count) return false;
        for (int i = 0; i < a.Count; i++)
        {
            if (a[i].Id != b[i].Id || a[i].Name != b[i].Name || a[i].Available != b[i].Available ||
                !a[i].AllIds.SequenceEqual(b[i].AllIds, StringComparer.Ordinal)) return false;
        }
        return true;
    }

    private static bool ValidInstallationId(string? id) =>
        id != null && id.Length == 32 && !id.AsSpan().ContainsAnyExcept("0123456789abcdef".AsSpan());

    private void LoadRemembered()
    {
        try
        {
            if (!File.Exists(storagePath) || new FileInfo(storagePath).LinkTarget != null || new FileInfo(storagePath).Length > 16384) return;
            var loaded = JsonSerializer.Deserialize<List<RememberedPhone>>(File.ReadAllText(storagePath));
            if (loaded == null) return;
            var seenIds = new HashSet<string>(StringComparer.Ordinal);
            foreach (var entry in loaded)
            {
                if (remembered.Count >= MaximumRemembered) break;
                if (!ValidInstallationId(entry.Id) || string.IsNullOrWhiteSpace(entry.Name) || !seenIds.Add(entry.Id)) continue;
                remembered.Add(new(entry.Id, entry.Name.Length > 64 ? entry.Name[..64] : entry.Name));
            }
        }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { }
    }

    private void SaveRememberedLocked()
    {
        try
        {
            var directory = Path.GetDirectoryName(storagePath);
            if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
            var temporary = storagePath + ".new";
            var data = JsonSerializer.SerializeToUtf8Bytes(remembered);
            if (!OperatingSystem.IsWindows())
            {
                using var file = new FileStream(temporary, new FileStreamOptions
                {
                    Mode = FileMode.Create,
                    Access = FileAccess.Write,
                    Share = FileShare.None,
                    UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite
                });
                file.Write(data);
                file.Flush(true);
            }
            else
            {
                File.WriteAllBytes(temporary, data);
            }
            File.Move(temporary, storagePath, true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    public static byte[] CreatePhoneQuery()
    {
        using var stream = new MemoryStream();
        void U16(int value) { stream.WriteByte((byte)(value >> 8)); stream.WriteByte((byte)value); }
        U16(0); U16(0); U16(1); U16(0); U16(0); U16(0);
        foreach (var label in Service.Split('.'))
        {
            var bytes = Encoding.UTF8.GetBytes(label);
            stream.WriteByte((byte)bytes.Length);
            stream.Write(bytes);
        }
        stream.WriteByte(0);
        U16(12); // PTR
        U16(1);  // IN
        return stream.ToArray();
    }

    public static IReadOnlyList<PhoneAdvertisement> ParseAnnouncement(ReadOnlySpan<byte> packet, IPAddress source)
    {
        if (packet.Length is < 12 or > 9000 || (packet[2] & 0x80) == 0) return [];
        int qd = BinaryPrimitives.ReadUInt16BigEndian(packet[4..]);
        int an = BinaryPrimitives.ReadUInt16BigEndian(packet[6..]);
        int ns = BinaryPrimitives.ReadUInt16BigEndian(packet[8..]);
        int ar = BinaryPrimitives.ReadUInt16BigEndian(packet[10..]);
        if (qd > 32 || an + ns + ar > 64) return [];
        int offset = 12;
        for (int i = 0; i < qd; i++)
        {
            if (ReadName(packet, ref offset) == null || offset + 4 > packet.Length) return [];
            offset += 4;
        }
        var phoneInstances = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var srvRecords = new Dictionary<string, (int Port, string Target)>(StringComparer.OrdinalIgnoreCase);
        var txtRecords = new Dictionary<string, Dictionary<string, string>>(StringComparer.OrdinalIgnoreCase);
        var aRecords = new Dictionary<string, IPAddress>(StringComparer.OrdinalIgnoreCase);

        int total = an + ns + ar;
        for (int i = 0; i < total; i++)
        {
            var owner = ReadName(packet, ref offset);
            if (owner == null || offset + 10 > packet.Length) break;
            var type = BinaryPrimitives.ReadUInt16BigEndian(packet[offset..]);
            var rdLength = BinaryPrimitives.ReadUInt16BigEndian(packet[(offset + 8)..]);
            offset += 10;
            if (offset + rdLength > packet.Length) break;
            var rdEnd = offset + rdLength;
            if (type == 12 && owner.Equals(Service, StringComparison.OrdinalIgnoreCase))
            {
                int cursor = offset;
                var target = ReadName(packet, ref cursor);
                if (!string.IsNullOrEmpty(target)) phoneInstances.Add(target);
            }
            else if (type == 33 && rdLength >= 6)
            {
                var port = BinaryPrimitives.ReadUInt16BigEndian(packet[(offset + 4)..]);
                int cursor = offset + 6;
                var target = ReadName(packet, ref cursor);
                if (port is >= 1 and <= 65535 && !string.IsNullOrEmpty(target))
                {
                    srvRecords[owner] = (port, target);
                    if (owner.EndsWith("." + Service, StringComparison.OrdinalIgnoreCase)) phoneInstances.Add(owner);
                }
            }
            else if (type == 16)
            {
                var map = new Dictionary<string, string>(StringComparer.Ordinal);
                int cursor = offset;
                while (cursor < rdEnd)
                {
                    int len = packet[cursor++];
                    if (cursor + len > rdEnd) break;
                    var entry = Encoding.UTF8.GetString(packet.Slice(cursor, len));
                    cursor += len;
                    var eq = entry.IndexOf('=');
                    if (eq > 0) map[entry[..eq]] = entry[(eq + 1)..];
                }
                txtRecords[owner] = map;
                if (owner.EndsWith("." + Service, StringComparison.OrdinalIgnoreCase)) phoneInstances.Add(owner);
            }
            else if (type == 1 && rdLength == 4)
            {
                aRecords[owner] = new IPAddress(packet.Slice(offset, 4));
            }
            offset = rdEnd;
        }

        if (phoneInstances.Count == 0) return [];
        var results = new List<PhoneAdvertisement>();
        foreach (var instance in phoneInstances)
        {
            if (!txtRecords.TryGetValue(instance, out var txt)) continue;
            if (!txt.TryGetValue("invite", out var invite) || invite != "1") continue;
            if (!txt.TryGetValue("c", out var rawTags) || string.IsNullOrEmpty(rawTags)) continue;
            var tags = new HashSet<string>(rawTags.Split(',', StringSplitOptions.RemoveEmptyEntries), StringComparer.Ordinal);
            if (tags.Count == 0) continue;
            if (!srvRecords.TryGetValue(instance, out var srv)) continue;
            if (!aRecords.TryGetValue(srv.Target, out var address))
            {
                if (source.AddressFamily != AddressFamily.InterNetwork || IPAddress.IsLoopback(source)) continue;
                address = source;
            }
            var name = txt.TryGetValue("name", out var label) && !string.IsNullOrWhiteSpace(label) ? label : "Phone";
            results.Add(new PhoneAdvertisement(tags, name, address, srv.Port));
        }
        return results;
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
            labels.Add(Encoding.UTF8.GetString(packet.Slice(cursor, size)));
            cursor += size;
        }
        return null;
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        NetworkChange.NetworkAddressChanged -= OnNetworkChanged;
        stop.Cancel();
        lock (sockets) foreach (var socket in sockets) socket.Dispose();
        loop?.GetAwaiter().GetResult();
        stop.Dispose();
        lock (networkChanged) networkChanged.Dispose();
    }
}
