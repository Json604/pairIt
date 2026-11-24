using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using PairIt.Core;

internal static class NearbyPhonesChecks
{
    public static async Task RunAsync(X509Certificate2 certificate, string token)
    {
        var id1 = new string('a', 32);
        var id2 = new string('b', 32);
        var id3 = new string('c', 32);
        var id4 = new string('d', 32);

        // Cross-platform daily tag vector: first 6 bytes of SHA-256("token:installation:day").
        var tag = NearbyPhones.Tag("test-token", id1, 20000);
        Require(tag.Length == 12 && !tag.AsSpan().ContainsAnyExcept("0123456789abcdef".AsSpan()), "Unexpected tag format.");

        // Duplicate offline same-name entries collapse into one row carrying all IDs.
        var collapsed = NearbyPhones.Deduplicate([
            (id3, "moto g85 5G", false),
            (id2, "moto g85 5G", false),
            (id1, "moto g85 5G", false),
            (id4, "Pixel 9", false)
        ]);
        Require(collapsed.Count == 2, "Expected 2 rows after deduplication.");
        Require(collapsed[0].Id == id3 && collapsed[0].AllIds.Count == 3 && collapsed[0].AllIds.Contains(id1) && collapsed[0].AllIds.Contains(id2),
            "Collapsed row must carry all duplicate offline IDs.");
        Require(collapsed[1].Id == id4 && collapsed[1].AllIds.Count == 1, "Distinct phone must remain untouched.");

        // Online older ID is promoted and absorbs offline duplicates of the same name.
        var promoted = NearbyPhones.Deduplicate([
            (id3, "moto g85 5G", false),
            (id2, "moto g85 5G", true),
            (id1, "moto g85 5G", false)
        ]);
        Require(promoted.Count == 1 && promoted[0].Id == id2 && promoted[0].Available && promoted[0].AllIds.Count == 3,
            "Online duplicate should be promoted and absorb offline copies.");

        // Two simultaneous online phones with the same name are both kept.
        var bothOnline = NearbyPhones.Deduplicate([
            (id2, "iPhone", true),
            (id1, "iPhone", true),
            (id3, "iPhone", false)
        ]);
        Require(bothOnline.Count == 2 && bothOnline.All(p => p.Available), "Two online phones with the same name must both be visible.");

        // FilterReconnectable hides connected ID and offline stale duplicates of connected name, but keeps online duplicates.
        var connected = new[] { new DesktopPhone(Guid.NewGuid(), "moto g85 5G", DesktopPhoneState.Listening, null, true, id3) };
        var filtered = NearbyPhones.FilterReconnectable([
            new NearbyPhone(id2, "moto g85 5G", false, [id2]),
            new NearbyPhone(id1, "moto g85 5G", true, [id1]),
            new NearbyPhone(id4, "Pixel 9", false, [id4])
        ], connected);
        Require(filtered.Select(p => p.Id).SequenceEqual([id1, id4]), "Offline stale duplicate of connected phone must be hidden.");

        // Persistence, mDNS parsing, CONNECT1 delivery, and 1-click forget.
        var tempFile = Path.Combine(Path.GetTempPath(), $"pairit-nearby-{Guid.NewGuid():N}.json");
        try
        {
            var pin = new string('1', 64);
            using var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            var phonePort = ((IPEndPoint)listener.LocalEndpoint).Port;

            using (var nearby = new NearbyPhones(tempFile, token, pin, startDiscovery: false))
            {
                nearby.Remember([
                    new DesktopPhone(Guid.NewGuid(), "moto g85 5G", DesktopPhoneState.Listening, null, true, id1),
                    new DesktopPhone(Guid.NewGuid(), "moto g85 5G", DesktopPhoneState.Listening, null, true, id2),
                    new DesktopPhone(Guid.NewGuid(), "Pixel 9", DesktopPhoneState.Listening, null, true, id4)
                ]);
                Require(nearby.Current.Count == 2, "Three remembered entries (two duplicates) must display as two.");

                var day = DateTimeOffset.UtcNow.ToUnixTimeSeconds() / 86_400;
                var liveTag = NearbyPhones.Tag(token, id1, day);
                var query = NearbyPhones.CreatePhoneQuery();
                Require(query.Length > 12 && (query[2] & 0x80) == 0, "Phone query packet must be a DNS query.");

                var announcement = CreatePhoneAnnouncement("MotoInstance", "moto-host.local", IPAddress.Loopback, phonePort, liveTag, "moto g85 5G");
                nearby.ObservePacket(announcement, IPAddress.Loopback);
                var moto = nearby.Current.Single(p => p.Name == "moto g85 5G");
                Require(moto.Available && moto.Id == id1 && moto.AllIds.Count == 2, "mDNS announcement must mark matching phone available.");

                // Malformed packet must be ignored without throwing.
                nearby.ObservePacket([0x00, 0x00, 0x84, 0x00, 0xff, 0xff], IPAddress.Loopback);

                var acceptTask = listener.AcceptTcpClientAsync();
                var sent = await nearby.RequestConnectionAsync(id1);
                Require(sent, "RequestConnectionAsync should deliver CONNECT1.");
                using var accepted = await acceptTask.WaitAsync(TimeSpan.FromSeconds(3));
                using var reader = new StreamReader(accepted.GetStream(), Encoding.ASCII);
                var receivedLine = await reader.ReadLineAsync();
                Require(receivedLine == $"CONNECT1 {pin}", $"Expected CONNECT1 line, got '{receivedLine}'.");

                // 1-click forget removes all collapsed duplicate IDs and persists to disk.
                nearby.Forget(moto.AllIds);
                Require(nearby.Current.Count == 1 && nearby.Current[0].Id == id4, "Forget must remove all collapsed IDs.");
            }

            // Reload from disk verifies persistence.
            using (var reloaded = new NearbyPhones(tempFile, token, pin, startDiscovery: false))
            {
                Require(reloaded.Current.Count == 1 && reloaded.Current[0].Id == id4, "Forgotten duplicates must stay gone after reload.");
            }
        }
        finally
        {
            if (File.Exists(tempFile)) File.Delete(tempFile);
        }

        // Loopback TLS verification for WANT1 <installation>.
        var sessions = new DesktopSessions(new SyntheticEndpoints());
        await using var server = new RelayServer(certificate, token, sessions);
        server.Start(IPAddress.Loopback, 0);
        var connector = new Connector(server.Port, certificate, token);

        using (var unrequested = await connector.ConnectAsync())
        {
            await unrequested.WriteLineAsync($"{token} WANT1 {id1}");
            Require(await unrequested.ReadLineAsync() == "NO WANT1", "Unrequested WANT1 must return NO WANT1.");
        }

        server.ExpectConnection(id1);
        using (var requested = await connector.ConnectAsync())
        {
            await requested.WriteLineAsync($"{token} WANT1 {id1}");
            Require(await requested.ReadLineAsync() == "OK WANT1", "Expected WANT1 must return OK WANT1.");
        }
        using (var replay = await connector.ConnectAsync())
        {
            await replay.WriteLineAsync($"{token} WANT1 {id1}");
            Require(await replay.ReadLineAsync() == "NO WANT1", "WANT1 claim must be single-use.");
        }

        Console.WriteLine("PASS: NearbyPhones deduplication, mDNS parsing, Forget persistence, CONNECT1, and WANT1 verified.");
    }

    private static byte[] CreatePhoneAnnouncement(string instanceLabel, string host, IPAddress address, int port, string tag, string name)
    {
        var instance = $"{instanceLabel}.{NearbyPhones.Service}";
        using var stream = new MemoryStream();
        void U16(int value) { stream.WriteByte((byte)(value >> 8)); stream.WriteByte((byte)value); }
        void WriteName(string value)
        {
            foreach (var label in value.Split('.'))
            {
                var bytes = Encoding.UTF8.GetBytes(label);
                stream.WriteByte((byte)bytes.Length);
                stream.Write(bytes);
            }
            stream.WriteByte(0);
        }
        void Record(string owner, int type, Action body)
        {
            WriteName(owner); U16(type); U16(1); stream.Write([0, 0, 0, 120]);
            var lenPos = stream.Position; U16(0); var start = stream.Position; body();
            var end = stream.Position; stream.Position = lenPos; U16((int)(end - start)); stream.Position = end;
        }
        U16(0); U16(0x8400); U16(0); U16(4); U16(0); U16(0);
        Record(NearbyPhones.Service, 12, () => WriteName(instance));
        Record(instance, 33, () => { U16(0); U16(0); U16(port); WriteName(host); });
        Record(instance, 16, () =>
        {
            foreach (var kv in new[] { "role=phone", "invite=1", $"c={tag}", $"name={name}" })
            {
                var bytes = Encoding.UTF8.GetBytes(kv);
                stream.WriteByte((byte)bytes.Length);
                stream.Write(bytes);
            }
        });
        Record(host, 1, () => stream.Write(address.GetAddressBytes()));
        return stream.ToArray();
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
