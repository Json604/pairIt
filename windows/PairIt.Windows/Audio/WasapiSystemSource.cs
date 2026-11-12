using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using PairIt.Core;

namespace PairIt.Windows.Audio;

internal sealed class WasapiSystemSource(string endpointId) : ISystemAudioSource
{
    private readonly CancellationTokenSource lifetime = new();
    private readonly TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource finished = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private Thread? worker;
    private bool disposed;

    public async Task StartAsync(Action<SourcePacket> received, Action<string> failed, CancellationToken cancellation)
    {
        if (worker != null) throw new InvalidOperationException("Source already started.");
        worker = new Thread(() => Capture(received, failed)) { IsBackground = true, Name = "PairIt WASAPI loopback" };
        worker.SetApartmentState(ApartmentState.MTA);
        worker.Start();
        await ready.Task.WaitAsync(cancellation).ConfigureAwait(false);
    }

    private void Capture(Action<SourcePacket> received, Action<string> failed)
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = enumerator.GetDevice(endpointId);
            if (device.DataFlow != DataFlow.Render || device.State != DeviceState.Active)
                throw new IOException("The selected output is unavailable. Choose it again after reconnecting.");
            using var client = device.AudioClient;
            var mix = client.MixFormat;
            var format = new CaptureFormat(mix);
            using var signal = new AutoResetEvent(false);
            client.Initialize(AudioClientShareMode.Shared, AudioClientStreamFlags.Loopback | AudioClientStreamFlags.EventCallback,
                1_000_000, 0, mix, Guid.Empty);
            client.SetEventHandle(signal.SafeWaitHandle.DangerousGetHandle());
            var capture = client.AudioCaptureClient;
            client.Start();
            ready.TrySetResult();
            try { ReadPackets(capture, format, signal, received); }
            finally { client.Stop(); client.Reset(); }
        }
        catch (Exception error)
        {
            ready.TrySetException(error);
            if (!lifetime.IsCancellationRequested)
                failed(error is NotSupportedException ? error.Message : "Audio source stopped or changed. Check the selected endpoint, then enable sharing again.");
        }
        finally { finished.TrySetResult(); }
    }

    private void ReadPackets(AudioCaptureClient capture, CaptureFormat format, AutoResetEvent signal, Action<SourcePacket> received)
    {
        long? expectedPosition = null;
        long previousTimestamp = 0;
        var timestampFailures = 0;
        var gap = false;
        WaitHandle[] signals = [signal, lifetime.Token.WaitHandle];
        while (!lifetime.IsCancellationRequested)
        {
            // Timeout polling also covers endpoints with unreliable event notifications.
            WaitHandle.WaitAny(signals, 20);
            while (!lifetime.IsCancellationRequested && capture.GetNextPacketSize() > 0)
            {
                var pointer = capture.GetBuffer(out var frames, out var flags, out var position, out var qpc100ns);
                if (frames <= 0) break;
                byte[] input;
                try
                {
                    if (frames > format.Rate) throw new IOException("Capture packet exceeded one second.");
                    input = new byte[checked(frames * format.FrameBytes)];
                    if ((flags & AudioClientBufferFlags.Silent) == 0) Marshal.Copy(pointer, input, 0, input.Length);
                }
                finally { capture.ReleaseBuffer(frames); }

                if ((flags & AudioClientBufferFlags.TimestampError) != 0 || qpc100ns <= 0 || qpc100ns > long.MaxValue / 100 || position < 0)
                {
                    gap = true;
                    expectedPosition = null;
                    if (++timestampFailures >= 3) throw new NotSupportedException("This audio endpoint is not providing reliable capture timestamps. Select another endpoint.");
                    continue;
                }
                var timestamp = qpc100ns * 100;
                var age = MonotonicClock.Nanoseconds - timestamp;
                if (timestamp < previousTimestamp || age is < -100_000_000 or > 250_000_000)
                {
                    gap = true;
                    expectedPosition = null;
                    if (++timestampFailures >= 3) throw new NotSupportedException("The audio endpoint clock is unstable. Select another endpoint and restart sharing.");
                    continue;
                }
                gap |= (flags & AudioClientBufferFlags.DataDiscontinuity) != 0 ||
                    (expectedPosition.HasValue && expectedPosition.Value != position);
                timestampFailures = 0;
                previousTimestamp = timestamp;
                expectedPosition = position + frames;
                for (var offset = 0; offset < frames; offset += format.Rate / 100)
                {
                    var count = Math.Min(format.Rate / 100, frames - offset);
                    var stereo = format.ToStereo16(input.AsSpan(offset * format.FrameBytes, count * format.FrameBytes), count,
                        (flags & AudioClientBufferFlags.Silent) != 0);
                    // Mix rate is preserved. Each split advances from the native
                    // first-frame timestamp by its exact source-frame position.
                    var capturedAt = timestamp + (long)((Int128)offset * 1_000_000_000 / format.Rate);
                    received(new(format.Rate, count, capturedAt, stereo, gap));
                    gap = false;
                }
            }
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (disposed) return;
        disposed = true;
        lifetime.Cancel();
        if (worker != null) await finished.Task.ConfigureAwait(false);
        lifetime.Dispose();
    }
}
