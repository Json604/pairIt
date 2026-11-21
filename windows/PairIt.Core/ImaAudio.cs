using System.Buffers.Binary;

namespace PairIt.Core;

internal static class ImaAudio
{
    private static readonly int[] Steps = [
        7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,
        73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,
        449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,
        2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,
        7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767];
    private static readonly int[] Adjust = [-1,-1,-1,-1,2,4,6,8];

    private struct Channel(int first, int next)
    {
        private int predictor = first;
        public int Index = InitialIndex(Math.Abs(next - first));

        private static int InitialIndex(int slope)
        {
            int i = Array.BinarySearch(Steps, slope);
            return i >= 0 ? i : Math.Min(~i, Steps.Length - 1);
        }

        public int Encode(int sample)
        {
            int difference = sample - predictor, step = Steps[Index];
            int remaining = Math.Abs(difference), delta = step >> 3, magnitude = 0;
            for (int bit = 0; bit < 3; bit++)
            {
                int threshold = step >> bit;
                if (remaining < threshold) continue;
                magnitude |= 4 >> bit;
                remaining -= threshold;
                delta += threshold;
            }
            predictor = Math.Clamp(predictor + (difference < 0 ? -delta : delta), short.MinValue, short.MaxValue);
            Index = Math.Clamp(Index + Adjust[magnitude], 0, Steps.Length - 1);
            return magnitude | (difference < 0 ? 8 : 0);
        }
    }

    // Input is a validated Protocol.Pcm packet. Each encoded packet starts independently.
    public static byte[] Encode(byte[] pcm)
    {
        int frames = (pcm.Length - 24) / 4;
        var result = new byte[29 + frames];
        Array.Copy(pcm, result, 28);
        BinaryPrimitives.WriteUInt32LittleEndian(result, 0x314D4441);
        int Sample(int offset) => BinaryPrimitives.ReadInt16LittleEndian(pcm.AsSpan(offset));
        int next = frames > 1 ? 28 : 24;
        var left = new Channel(Sample(24), Sample(next));
        var right = new Channel(Sample(26), Sample(next + 2));
        result[28] = (byte)left.Index;
        result[29] = (byte)right.Index;
        for (int i = 1; i < frames; i++)
        {
            int offset = 24 + i * 4;
            result[29 + i] = (byte)(left.Encode(Sample(offset)) | right.Encode(Sample(offset + 2)) << 4);
        }
        return result;
    }
}
