using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using PairIt.Core;

namespace PairIt.Windows.Audio;

internal sealed class WasapiMicrophoneSink(string endpointId) : IMicrophoneSink
{
    private sealed record PendingAudio(byte[] Bytes, long EnqueuedAt);
    private readonly object state = new();
    private readonly Queue<PendingAudio> pending = new();
    private readonly AutoResetEvent signal = new(false);
    private readonly CancellationTokenSource lifetime = new();
    private readonly TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource finished = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private TaskCompletionSource? flush;
    private Exception? failure;
    private int queuedBytes, headOffset;
    private bool disposed;

    public async Task OpenAsync(CancellationToken cancellation)
    {
        var worker = new Thread(Render) { IsBackground = true, Name = "PairIt virtual microphone" };
        worker.SetApartmentState(ApartmentState.MTA);
        worker.Start();
        await ready.Task.WaitAsync(cancellation).ConfigureAwait(false);
    }

    public void Write(ReadOnlySpan<byte> monoPcm16)
    {
        lock (state)
        {
            if (disposed || failure != null) throw new IOException("Virtual microphone output stopped.");
            // At most 50 ms in this queue plus at most 50 ms in WASAPI.
            if (monoPcm16.Length is < 2 or > 1920 || (monoPcm16.Length & 1) != 0 || queuedBytes + monoPcm16.Length > 4800)
                throw new IOException("Microphone output fell behind.");
            pending.Enqueue(new(monoPcm16.ToArray(), MonotonicClock.Nanoseconds));
            queuedBytes += monoPcm16.Length;
        }
        signal.Set();
    }

    public async Task FlushAsync(CancellationToken cancellation)
    {
        Task acknowledgement;
        lock (state)
        {
            if (disposed || failure != null) throw new IOException("Virtual microphone output stopped.");
            ClearQueue();
            flush ??= new(TaskCreationOptions.RunContinuationsAsynchronously);
            acknowledgement = flush.Task;
        }
        signal.Set();
        await acknowledgement.WaitAsync(cancellation).ConfigureAwait(false);
    }

    private void Render()
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = enumerator.GetDevice(endpointId);
            if (device.DataFlow != DataFlow.Render || device.State != DeviceState.Active || !WindowsAudioEndpoints.IsVirtualCable(device.FriendlyName))
                throw new IOException("Select an available virtual cable render endpoint.");
            using var client = device.AudioClient;
            client.Initialize(AudioClientShareMode.Shared, AudioClientStreamFlags.AutoConvertPcm | AudioClientStreamFlags.SrcDefaultQuality,
                500_000, 0, new WaveFormat(48000, 16, 1), Guid.Empty);
            if (client.BufferSize > 2400) throw new IOException("The virtual endpoint needs more than 50 ms of buffering. Choose another endpoint.");
            var renderer = client.AudioRenderClient;
            client.Start();
            ready.TrySetResult();
            try { RenderPackets(client, renderer); }
            finally { client.Stop(); client.Reset(); }
        }
        catch (Exception error)
        {
            lock (state) { failure = error; ClearQueue(); flush?.TrySetException(new IOException("Virtual output stopped.")); }
            ready.TrySetException(error);
        }
        finally
        {
            lock (state) { ClearQueue(); flush?.TrySetCanceled(); }
            finished.TrySetResult();
        }
    }

    private void RenderPackets(AudioClient client, AudioRenderClient renderer)
    {
        WaitHandle[] signals = [signal, lifetime.Token.WaitHandle];
        while (!lifetime.IsCancellationRequested)
        {
            WaitHandle.WaitAny(signals, 5);
            if (lifetime.IsCancellationRequested) return;
            TaskCompletionSource? flushRequest;
            lock (state) { flushRequest = flush; flush = null; }
            if (flushRequest != null)
            {
                try
                {
                    client.Stop();
                    client.Reset();
                    client.Start();
                    flushRequest.TrySetResult();
                }
                catch { flushRequest.TrySetException(new IOException("Virtual output stopped during reset.")); throw; }
            }
            var frames = client.BufferSize - client.CurrentPadding;
            if (frames <= 0) continue;
            var bytes = new byte[frames * 2];
            var count = Fill(bytes);
            var pointer = renderer.GetBuffer(frames);
            try { if (count != 0) Marshal.Copy(bytes, 0, pointer, bytes.Length); }
            finally { renderer.ReleaseBuffer(frames, count == 0 ? AudioClientBufferFlags.Silent : AudioClientBufferFlags.None); }
        }
    }

    private int Fill(byte[] bytes)
    {
        lock (state)
        {
            var written = 0;
            while (written < bytes.Length && pending.TryPeek(out var first))
            {
                if (MonotonicClock.Nanoseconds - first.EnqueuedAt > 100_000_000) throw new IOException("Microphone samples became stale.");
                var length = Math.Min(bytes.Length - written, first.Bytes.Length - headOffset);
                first.Bytes.AsSpan(headOffset, length).CopyTo(bytes.AsSpan(written));
                written += length;
                queuedBytes -= length;
                headOffset += length;
                if (headOffset == first.Bytes.Length) { pending.Dequeue(); headOffset = 0; }
            }
            return written;
        }
    }

    private void ClearQueue() { pending.Clear(); queuedBytes = 0; headOffset = 0; }

    public async ValueTask DisposeAsync()
    {
        lock (state)
        {
            if (disposed) return;
            disposed = true;
            ClearQueue();
        }
        lifetime.Cancel();
        signal.Set();
        await finished.Task.ConfigureAwait(false);
        signal.Dispose();
        lifetime.Dispose();
    }
}
