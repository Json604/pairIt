using System.Buffers.Binary;
using NAudio.Wave;

namespace PairIt.Windows.Audio;

internal sealed class CaptureFormat
{
    private readonly bool floating;
    private readonly int channels, bits;
    public int Rate { get; }
    public int FrameBytes { get; }

    public CaptureFormat(WaveFormat mix)
    {
        var format = mix is WaveFormatExtensible extensible ? extensible.ToStandardWaveFormat() : mix;
        Rate = format.SampleRate;
        channels = format.Channels;
        bits = format.BitsPerSample;
        floating = format.Encoding == WaveFormatEncoding.IeeeFloat;
        FrameBytes = format.BlockAlign;
        if (Rate is not (44100 or 48000) || channels is not (1 or 2) ||
            (floating ? bits != 32 : format.Encoding != WaveFormatEncoding.Pcm || bits is not (16 or 24 or 32)) ||
            FrameBytes != channels * (bits / 8))
            throw new NotSupportedException("Choose 44.1 or 48 kHz mono/stereo PCM in Windows sound settings, then enable sharing again.");
    }

    public byte[] ToStereo16(ReadOnlySpan<byte> input, int frames, bool silent)
    {
        var output = new byte[frames * 4];
        if (silent) return output;
        for (var frame = 0; frame < frames; frame++)
        {
            var sample = input.Slice(frame * FrameBytes, FrameBytes);
            var left = ReadSample(sample);
            var right = channels == 1 ? left : ReadSample(sample[(bits / 8)..]);
            BinaryPrimitives.WriteInt16LittleEndian(output.AsSpan(frame * 4), left);
            BinaryPrimitives.WriteInt16LittleEndian(output.AsSpan(frame * 4 + 2), right);
        }
        return output;
    }

    private short ReadSample(ReadOnlySpan<byte> value)
    {
        if (!floating)
        {
            if (bits == 16) return BinaryPrimitives.ReadInt16LittleEndian(value);
            if (bits == 32) return (short)(BinaryPrimitives.ReadInt32LittleEndian(value) >> 16);
            // 24-bit signed PCM is little endian; retain its most significant 16 bits.
            return unchecked((short)(value[1] | value[2] << 8));
        }
        var sample = BinaryPrimitives.ReadSingleLittleEndian(value);
        if (!float.IsFinite(sample)) return 0;
        return (short)Math.Clamp(Math.Round(sample * 32768d), short.MinValue, short.MaxValue);
    }
}
