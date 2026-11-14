using System.Diagnostics;
using System.Threading.Channels;
using PairIt.Core;

namespace PairIt.Linux;

/// Bounded mono playback into an explicitly selected virtual sink; never speakers.
public sealed class PulseMicrophoneSink : IMicrophoneSink
{
    private sealed record Packet(byte[] Bytes, long Created, int Generation);
    private readonly string endpoint;
    private readonly object gate = new();
    private readonly Channel<Packet> queue = Channel.CreateBounded<Packet>(new BoundedChannelOptions(2) {
        SingleReader = false, SingleWriter = false, FullMode = BoundedChannelFullMode.Wait
    });
    private readonly CancellationTokenSource lifetime = new();
    private Process process;
    private readonly Task writer;
    private readonly List<Task> drains = [];
    private Exception? failure;
    private bool disposed;
    private int generation;

    internal PulseMicrophoneSink(string endpoint)
    {
        if (!PulseAudio.ValidEndpoint(endpoint)) throw new IOException("Invalid virtual sink.");
        this.endpoint = endpoint;
        process = Open();
        writer = PumpAsync();
    }

    private Process Open()
    {
        var start = new ProcessStartInfo("/usr/bin/pacat") {
            UseShellExecute = false, RedirectStandardInput = true,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
        foreach (var arg in new[] { "--playback", "--raw", "--format=s16le", "--rate=48000",
                 "--channels=1", "--latency-msec=20", "--client-name=PairIt microphone", "--device=" + endpoint })
            start.ArgumentList.Add(arg);
        var result = Process.Start(start) ?? throw new IOException("Could not open virtual microphone output.");
        drains.RemoveAll(task => task.IsCompletedSuccessfully);
        drains.Add(result.StandardError.BaseStream.CopyToAsync(Stream.Null));
        drains.Add(result.StandardOutput.BaseStream.CopyToAsync(Stream.Null));
        return result;
    }

    public void Write(ReadOnlySpan<byte> pcm)
    {
        lock (gate) {
            if (disposed || failure != null) throw new IOException("Virtual microphone output stopped.");
            // Protocol packets contain no more than 20 ms at 48 kHz mono.
            if (pcm.Length is < 2 or > 1920 || (pcm.Length & 1) != 0 ||
                !queue.Writer.TryWrite(new(pcm.ToArray(), MonotonicClock.Nanoseconds, generation)))
                throw new IOException("Microphone output fell behind.");
        }
    }

    private async Task PumpAsync()
    {
        try {
            await foreach (var packet in queue.Reader.ReadAllAsync(lifetime.Token)) {
                if (MonotonicClock.Nanoseconds - packet.Created > 100_000_000)
                    throw new IOException("Microphone audio expired.");
                Process target;
                lock (gate) { if (packet.Generation != generation) continue; target = process; }
                try { await target.StandardInput.BaseStream.WriteAsync(packet.Bytes, lifetime.Token); }
                catch (Exception error) when (error is IOException or ObjectDisposedException) {
                    lock (gate) { if (target != process) continue; }
                    throw;
                }
            }
        } catch (Exception error) when (error is IOException or OperationCanceledException or ObjectDisposedException) {
            lock (gate) { failure = error; queue.Writer.TryComplete(); }
        }
    }

    public Task FlushAsync(CancellationToken cancellation)
    {
        cancellation.ThrowIfCancellationRequested();
        lock (gate) {
            if (disposed || failure != null) throw new IOException("Virtual microphone output stopped.");
            generation++;
            while (queue.Reader.TryRead(out _)) { }
            // Killing the old stream discards PulseAudio's queued samples as well.
            var old = process;
            process = Open();
            PulseAudio.Stop(old); old.Dispose();
        }
        return Task.CompletedTask;
    }

    public async ValueTask DisposeAsync()
    {
        lock (gate) {
            if (disposed) return;
            disposed = true; lifetime.Cancel(); queue.Writer.TryComplete(); PulseAudio.Stop(process);
        }
        await writer;
        try { await Task.WhenAll(drains); } catch (IOException) { }
        process.Dispose(); lifetime.Dispose();
    }
}
