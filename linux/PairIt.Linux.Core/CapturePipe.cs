using System.IO.Pipes;
using System.Runtime.InteropServices;

namespace PairIt.Linux;

internal static class CapturePipe
{
    // Linux FIONREAD reports bytes queued in this pipe without consuming them.
    private const nuint BytesAvailable = 0x541B;
    [DllImport("libc", EntryPoint = "ioctl", SetLastError = true)]
    private static extern int Ioctl(int fd, nuint request, out int value);

    internal static int PendingBytes(Stream stream)
    {
        if (stream is not PipeStream pipe) throw new IOException("Capture pipe does not expose its queued audio.");
        if (Ioctl(pipe.SafePipeHandle.DangerousGetHandle().ToInt32(), BytesAvailable, out var count) != 0 || count < 0)
            throw new IOException("Could not inspect capture buffering.");
        return count;
    }
}
