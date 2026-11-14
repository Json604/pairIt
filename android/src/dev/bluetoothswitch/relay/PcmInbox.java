package dev.bluetoothswitch.relay;

import java.io.*;
import java.nio.*;
import java.util.concurrent.*;

/** Network reception must keep draining while Android initializes or blocks in AudioTrack. */
final class PcmInbox {
    static final class GroupFull extends IOException { GroupFull(){super("Listening group is full");} }
    static final class Packet {
        final int rate, frames;
        final byte[] pcm;
        final long capturedAt, receivedAt = System.nanoTime(), sequence;
        Packet(int rate, int frames, long capturedAt, long sequence, byte[] pcm) {
            this.rate = rate; this.frames = frames; this.capturedAt = capturedAt; this.sequence = sequence; this.pcm = pcm;
        }
    }
    // About 1.4 seconds at 256 frames. A ceiling, never a prefill target.
    private final ArrayBlockingQueue<Packet> queue = new ArrayBlockingQueue<>(256);
    private volatile IOException failure;
    java.util.function.IntConsumer onControlStatus, onDesktopRequest, onComputerVolume;
    Runnable onHeartbeat;
    volatile long framesReceived, sequenceGaps, discarded;
    private volatile long bestClockOffset = Long.MAX_VALUE;
    private volatile long synchronizedOffset;
    private volatile long bestRoundTrip = Long.MAX_VALUE;
    volatile int clockSamples;
    volatile int presentationTargetMs, presentationListeners, presentationCapable;
    private volatile long clockWindow;
    private void clockSample(long sent, long server, long received) {
        if (sent < 0 || server < 0) return;
        long roundTrip = received - sent;
        if (roundTrip < 0 || roundTrip > 1_000_000_000L) return;
        if (received - clockWindow > 30_000_000_000L) { bestRoundTrip = Long.MAX_VALUE; clockWindow = received; }
        if (roundTrip < bestRoundTrip) {
            bestRoundTrip = roundTrip;
            synchronizedOffset = sent + roundTrip / 2 - server;
        }
        clockSamples++;
    }
    long clockOffset() { return clockSamples > 0 ? synchronizedOffset : bestClockOffset; }
    double clockRoundTripMillis() { return clockSamples > 0 ? bestRoundTrip / 1e6 : -1; }

    void read(InputStream stream) {
        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO);
        DataInputStream input = new DataInputStream(stream);
        long previous = -1;
        try {
            while (true) {
                byte[] header = new byte[24]; input.readFully(header);
                ByteBuffer h = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN);
                int magic = h.getInt();
                if (magic == 0x34435342) {
                    int target = h.getInt();
                    if (target < 0 || target > 2000) throw new IOException("Invalid presentation target");
                    int listeners = h.getInt(), capable = h.getInt();
                    if (listeners < 0 || listeners > 4 || capable < 0 || capable > listeners) throw new IOException("Invalid presentation group");
                    presentationListeners = listeners; presentationCapable = capable;
                    presentationTargetMs = target; continue;
                }
                if (magic == 0x31455342 && h.getInt() == 1) throw new GroupFull();
                if (magic == 0x33435342) {
                    int volume = h.getInt();
                    if ((volume & ~0x103FF) != 0 || (volume & 0x3FF) > 1000) throw new IOException("Invalid computer volume");
                    if (onComputerVolume != null) onComputerVolume.accept(volume);
                    continue;
                }
                if(magic==0x32435342){int command=h.getInt();if(onDesktopRequest!=null)onDesktopRequest.accept(command);continue;}
                if (magic == 0x31435342) {
                    int controlStatus = h.getInt(); long sent = h.getLong(), server = h.getLong();
                    if (onHeartbeat != null) onHeartbeat.run();
                    if (onControlStatus != null) onControlStatus.accept(controlStatus);
                    clockSample(sent, server, System.nanoTime()); continue;
                }
                if (magic != 0x31415342) throw new IOException("Bad stream header");
                long sequence = Integer.toUnsignedLong(h.getInt());
                int rate = h.getInt(), frames = h.getInt();
                long capturedAt = h.getLong();
                if (frames == 0 && capturedAt == 0 && rate == 48000) { if(onHeartbeat!=null)onHeartbeat.run(); continue; } // Idle sender heartbeat.
                if ((rate != 48000 && rate != 44100) || frames < 1 || frames > 8192 || capturedAt < 0) throw new IOException("Unsupported packet format");
                byte[] pcm = new byte[frames * 4]; input.readFully(pcm);
                if (previous >= 0) sequenceGaps += (sequence - previous - 1) & 0xffffffffL;
                previous = sequence; framesReceived += frames;
                Packet packet = new Packet(rate, frames, capturedAt, sequence, pcm);
                bestClockOffset = Math.min(bestClockOffset, packet.receivedAt - capturedAt);
                if (!queue.offer(packet)) {
                    if (queue.poll() != null) discarded++;
                    queue.offer(packet);
                }
            }
        } catch (IOException e) { failure = e; }
    }
    Packet next() throws IOException, InterruptedException {
        Packet packet = queue.poll(100, TimeUnit.MILLISECONDS);
        if (packet == null && failure != null) throw failure;
        return packet;
    }
    void clear() { discarded += queue.size(); queue.clear(); }

    // Clocks are not synchronized: only variation above the session's best arrival
    // is observable here. Includes relative clock drift; never label it one-way latency.
    double arrivalVariationMillis(Packet packet) {
        return Math.max(0, packet.receivedAt - packet.capturedAt - bestClockOffset) / 1e6;
    }

    long bestClockOffset() { return bestClockOffset; }
    int queuedPackets() { return queue.size(); }
}
