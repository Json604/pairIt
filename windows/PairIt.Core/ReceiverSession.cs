using System.Collections.Generic;
using System.Net.Security;
using System.Net.Sockets;

namespace PairIt.Core;

internal sealed class ReceiverSession(TcpClient socket, SslStream stream) : IDisposable
{
    private sealed record QueuedFrame(byte[] Bytes, long EnqueuedAt);
    private readonly object queueLock = new();
    private readonly Queue<QueuedFrame> pending = new();
    private readonly SemaphoreSlim available = new(0);
    private readonly CancellationTokenSource lifetime = new();
    private int queuedBytes, closed, closeRequested;
    public Guid Id { get; } = Guid.NewGuid();
    public bool Active { get; set; } = true;
    public bool Parked { get; set; }
    public bool VolumeControls { get; set; }
    public bool DesktopControls { get; set; }
    public bool? DesktopRequest { get; set; }
    public bool AudioResumeOffered { get; set; }
    public bool HandoffAdvertised { get; set; }
    public bool HandoffNegotiated { get; set; }
    public uint IntentToken { get; set; }
    public ReceiverIntent LastIntent { get; set; }
    public ParkReason ParkReason { get; set; }
    public string? InstallationId { get; set; }
    public double? SyncMilliseconds { get; set; }
    public long LastControlAt { get; set; } = MonotonicClock.Nanoseconds;
    public CancellationToken Cancellation => lifetime.Token;

    public bool TryEnqueue(byte[] bytes)
    {
        lock (queueLock)
        {
            if (closed != 0 || Volatile.Read(ref closeRequested) != 0 || queuedBytes + bytes.Length > 256 * 1024 ||
                (pending.TryPeek(out var first) && IsOld(first))) return false;
            pending.Enqueue(new(bytes, MonotonicClock.Nanoseconds));
            queuedBytes += bytes.Length;
            available.Release();
            return true;
        }
    }

    public async Task WriteFramesAsync()
    {
        try
        {
            while (!Cancellation.IsCancellationRequested)
            {
                await available.WaitAsync(Cancellation).ConfigureAwait(false);
                QueuedFrame frame;
                lock (queueLock)
                {
                    if (!pending.TryDequeue(out var next)) continue;
                    frame = next;
                    queuedBytes -= frame.Bytes.Length;
                }
                if (IsOld(frame)) throw new IOException("Receiver fell behind.");
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(Cancellation);
                var remaining = 250 - (MonotonicClock.Nanoseconds - frame.EnqueuedAt) / 1_000_000d;
                deadline.CancelAfter(TimeSpan.FromMilliseconds(Math.Max(1, remaining)));
                await stream.WriteAsync(frame.Bytes, deadline.Token).ConfigureAwait(false);
            }
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or ObjectDisposedException)
        {
            Close();
        }
    }

    private static bool IsOld(QueuedFrame frame) => MonotonicClock.Nanoseconds - frame.EnqueuedAt > 250_000_000;

    public void DiscardQueuedAudio()
    {
        lock (queueLock)
        {
            // Only stereo PCM frames have a payload. Keep 24-byte clock and
            // heartbeat frames; one already-started TLS frame completes intact.
            var controls = pending.Where(frame => frame.Bytes.Length == 24).ToArray();
            var removed = pending.Count - controls.Length;
            pending.Clear();
            queuedBytes = 0;
            foreach (var frame in controls) { pending.Enqueue(frame); queuedBytes += frame.Bytes.Length; }
            // One permit may already belong to the writer waiting on this
            // lock; it skips an empty queue if its frame was discarded.
            while (removed-- > 0 && available.Wait(0)) { }
        }
    }

    public void RequestCloseOnce()
    {
        // Capture must not do socket I/O. One scheduled close per peer also
        // bounds work items when the pool is starved and more PCM arrives.
        if (Interlocked.Exchange(ref closeRequested, 1) != 0) return;
        ThreadPool.QueueUserWorkItem(_ => Close());
    }

    public void Close()
    {
        if (Interlocked.Exchange(ref closed, 1) != 0) return;
        Interlocked.Exchange(ref closeRequested, 1);
        lifetime.Cancel();
        socket.Dispose(); // Unblocks both TLS directions before worker lifetimes drain.
    }

    public void Dispose()
    {
        Close();
        lock (queueLock) pending.Clear();
        lifetime.Dispose();
        available.Dispose();
    }
}
