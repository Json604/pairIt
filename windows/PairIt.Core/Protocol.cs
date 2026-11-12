using System.Buffers.Binary;
using System.Diagnostics;
using System.Text;

namespace PairIt.Core;

public static class MonotonicClock
{
    // On Windows Stopwatch is QueryPerformanceCounter. WASAPI gives the same
    // absolute QPC domain already scaled to 100 ns; neither clock is wall time.
    public static long Nanoseconds => (long)((Int128)Stopwatch.GetTimestamp() * 1_000_000_000 / Stopwatch.Frequency);
}

public static class Protocol
{
    public const uint PcmMagic = 0x31415342, ClockMagic = 0x31435342, MicMagic = 0x314d5342;
    public const int Port = 5002, MaximumReceivers = 4;
    public const uint ParkSupported = 1, PlayerControl = 2, ParkAccepted = 4,
        PlayerPaused = 8, ResumeOffer = 16, ReleaseAccepted = 32, MaximumIntentToken = 0x00ff_ffff;

    public static byte[] Pcm(uint sequence, SourcePacket packet)
    {
        if (packet.Rate is not (44100 or 48000) || packet.Frames is < 1 or > 8192 ||
            packet.FirstFrameNanoseconds <= 0 || packet.StereoPcm16.Length != packet.Frames * 4)
            throw new InvalidDataException("Unsupported source packet.");
        var result = Header(sequence, packet.Rate, packet.Frames, packet.FirstFrameNanoseconds, packet.StereoPcm16.Length);
        packet.StereoPcm16.CopyTo(result, 24);
        return result;
    }

    public static byte[] Heartbeat(uint sequence) => Header(sequence, 48000, 0, 0, 0);

    private static byte[] Header(uint sequence, int rate, int frames, long capturedAt, int payloadLength)
    {
        var bytes = new byte[24 + payloadLength];
        BinaryPrimitives.WriteUInt32LittleEndian(bytes, PcmMagic);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(4), sequence);
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(8), rate);
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(12), frames);
        BinaryPrimitives.WriteInt64LittleEndian(bytes.AsSpan(16), capturedAt);
        return bytes;
    }

    public static byte[] ClockReply(long echoed, uint handoff = 0)
    {
        var bytes = new byte[24];
        BinaryPrimitives.WriteUInt32LittleEndian(bytes, ClockMagic);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(4), handoff);
        BinaryPrimitives.WriteInt64LittleEndian(bytes.AsSpan(8), echoed);
        BinaryPrimitives.WriteInt64LittleEndian(bytes.AsSpan(16), MonotonicClock.Nanoseconds);
        return bytes;
    }

    public static (uint Sequence, int Frames) ReadMicrophoneHeader(ReadOnlySpan<byte> header)
    {
        if (header.Length != 16 || BinaryPrimitives.ReadUInt32LittleEndian(header) != MicMagic ||
            BinaryPrimitives.ReadInt32LittleEndian(header[8..]) != 48000)
            throw new InvalidDataException("Unsupported microphone packet.");
        var frames = BinaryPrimitives.ReadInt32LittleEndian(header[12..]);
        if (frames is < 0 or > 960) throw new InvalidDataException("Invalid microphone packet length.");
        return (BinaryPrimitives.ReadUInt32LittleEndian(header[4..]), frames);
    }
}

// Bounded incremental reader preserves data already read after authentication.
// It cannot allocate an unbounded string or swallow binary MIC1 bytes.
public sealed class ProtocolReader(Stream stream)
{
    private readonly byte[] buffer = new byte[4096];
    private int offset, count;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    public async Task<string> ReadLineAsync(CancellationToken cancellation)
    {
        var line = new byte[4096];
        var used = 0;
        while (true)
        {
            if (offset == count) await FillAsync(cancellation).ConfigureAwait(false);
            var next = buffer[offset++];
            if (next == 10) return StrictUtf8.GetString(line, 0, used);
            if (used == line.Length) throw new InvalidDataException("Control line is too long.");
            line[used++] = next;
        }
    }

    public async Task ReadExactlyAsync(Memory<byte> destination, CancellationToken cancellation)
    {
        var written = 0;
        while (written < destination.Length)
        {
            if (offset == count) await FillAsync(cancellation).ConfigureAwait(false);
            var length = Math.Min(count - offset, destination.Length - written);
            buffer.AsMemory(offset, length).CopyTo(destination[written..]);
            offset += length;
            written += length;
        }
    }

    private async Task FillAsync(CancellationToken cancellation)
    {
        count = await stream.ReadAsync(buffer, cancellation).ConfigureAwait(false);
        offset = 0;
        if (count == 0) throw new EndOfStreamException();
    }
}
