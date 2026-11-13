using System.Buffers.Binary;
using System.Net;
using System.Text;
using PairIt.Core;

internal static class DiscoveryChecks
{
    public static void Run()
    {
        var pin = new string('a', 64);
        var packet = ComputerDiscovery.CreateAnnouncement(pin, "windows", "Living room PC", IPAddress.Parse("192.168.1.5"), 5002);
        Require(packet.Length < 1200, "Discovery must fit one ordinary DNS datagram.");
        Require(BinaryPrimitives.ReadUInt16BigEndian(packet.AsSpan(6)) == 4, "Expected PTR, SRV, TXT and A records.");
        var offset = 12;
        string ReadName()
        {
            var labels = new List<string>();
            while (packet[offset] != 0) { int size = packet[offset++]; labels.Add(Encoding.UTF8.GetString(packet, offset, size)); offset += size; }
            offset++; return string.Join('.', labels);
        }
        var records = new Dictionary<int, (string Owner, byte[] Data)>();
        for (var i = 0; i < 4; i++)
        {
            var owner = ReadName();
            int type = BinaryPrimitives.ReadUInt16BigEndian(packet.AsSpan(offset));
            int length = BinaryPrimitives.ReadUInt16BigEndian(packet.AsSpan(offset + 8)); offset += 10;
            records.Add(type, (owner, packet.AsSpan(offset, length).ToArray())); offset += length;
        }
        Require(offset == packet.Length, "Trailing DNS data.");
        Require(records[12].Owner == "_audiorelay._tcp.local", "Wrong computer service type.");
        Require(records[33].Owner == "AudioRelay-aaaaaaaa._audiorelay._tcp.local", "Wrong service instance.");
        Require(BinaryPrimitives.ReadUInt16BigEndian(records[33].Data.AsSpan(4)) == 5002, "Wrong relay port.");
        Require(records[1].Data.SequenceEqual(new byte[] { 192, 168, 1, 5 }), "Wrong address record.");
        var txt = new List<string>();
        for (int p = 0; p < records[16].Data.Length;)
        { int length = records[16].Data[p++]; txt.Add(Encoding.UTF8.GetString(records[16].Data, p, length)); p += length; }
        Require(txt.Order().SequenceEqual(new[] { "role=computer", "v=1", "platform=windows", "name=Living room PC", "pin=" + pin }.Order()), "Discovery metadata changed or includes credentials.");
        Require(ComputerDiscovery.IsQuery(Query("_audiorelay._tcp.local"), pin), "Computer browse query ignored.");
        Require(!ComputerDiscovery.IsQuery(Query("_pairit-phone._tcp.local"), pin), "Phone query was answered by computer.");
        Require(!ComputerDiscovery.IsQuery(packet, pin), "Announcement mistaken for query.");
        var cycle = new byte[18]; cycle[5] = 1; cycle[12] = 0xc0; cycle[13] = 12;
        Require(!ComputerDiscovery.IsQuery(cycle, pin), "Pointer cycle accepted.");
        var valid = Query("_audiorelay._tcp.local");
        for (int i = 0; i < valid.Length; i++) Require(!ComputerDiscovery.IsQuery(valid.AsSpan(0, i), pin), "Truncated query accepted.");
        var random = new Random(42);
        for (int i = 0; i < 2000; i++) { var data = new byte[random.Next(512)]; random.NextBytes(data); _ = ComputerDiscovery.IsQuery(data, pin); }
        Console.WriteLine("PASS: computer-only discovery records, secret exclusion and malformed query bounds.");
    }
    private static byte[] Query(string name)
    {
        using var stream = new MemoryStream(); stream.Write(new byte[] { 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 });
        foreach (var label in name.Split('.')) { stream.WriteByte((byte)label.Length); stream.Write(Encoding.ASCII.GetBytes(label)); }
        stream.Write(new byte[] { 0, 0, 12, 0, 1 }); return stream.ToArray();
    }
    private static void Require(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
