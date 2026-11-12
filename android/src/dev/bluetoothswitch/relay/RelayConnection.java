package dev.bluetoothswitch.relay;

import java.net.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.security.cert.*;
import javax.net.ssl.*;

final class RelayConnection {
    static Socket open(String host, RelaySettings settings, boolean microphone) throws Exception {
        if (!settings.paired() || !RelaySettings.validHost(host)) throw new IOException("Pair a computer first");
        final String expectedPin = settings.pin(), token = settings.token();
        Socket raw = new Socket();
        try {
            raw.setTcpNoDelay(true);
            raw.connect(new InetSocketAddress(host, 5002), 4000);
            raw.setSoTimeout(4000);
            raw.setKeepAlive(true);
            X509TrustManager pinned = new X509TrustManager() {
                public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
                public void checkClientTrusted(X509Certificate[] chain, String authType) throws CertificateException { throw new CertificateException("Client certificates unsupported"); }
                public void checkServerTrusted(X509Certificate[] chain, String authType) throws CertificateException {
                    if (chain == null || chain.length == 0) throw new CertificateException("Missing server identity");
                    chain[0].checkValidity();
                    try {
                        byte[] digest = MessageDigest.getInstance("SHA-256").digest(chain[0].getEncoded());
                        StringBuilder fingerprint = new StringBuilder();
                        for (byte b : digest) fingerprint.append(String.format(java.util.Locale.US, "%02x", b & 255));
                        if (!MessageDigest.isEqual(fingerprint.toString().getBytes(StandardCharsets.US_ASCII), expectedPin.getBytes(StandardCharsets.US_ASCII)))
                            throw new CertificateException("Computer identity changed. Pair this phone again");
                    } catch (NoSuchAlgorithmException e) { throw new CertificateException(e); }
                }
            };
            SSLContext context = SSLContext.getInstance("TLS");
            context.init(null, new TrustManager[]{pinned}, null);
            SSLSocket tls = (SSLSocket)context.getSocketFactory().createSocket(raw, host, 5002, true);
            tls.setEnabledProtocols(new String[]{"TLSv1.3", "TLSv1.2"});
            tls.startHandshake();
            tls.getOutputStream().write((token + (microphone ? " MIC1\n" : "\n")).getBytes(StandardCharsets.US_ASCII));
            tls.getOutputStream().flush();
            return new PinnedSocket(raw, tls);
        } catch (Exception e) { raw.close(); throw e; }
    }
    static String readLine(Socket socket, int limit, int timeoutMs) throws IOException {
        InputStream input = socket.getInputStream();
        long deadline = System.nanoTime() + timeoutMs * 1_000_000L;
        ByteArrayOutputStream line = new ByteArrayOutputStream();
        for (int i = 0; i < limit; i++) {
            long remaining = deadline - System.nanoTime();
            if (remaining <= 0) throw new SocketTimeoutException("Computer response timed out");
            socket.setSoTimeout(Math.max(1, (int)(remaining / 1_000_000L)));
            int next = input.read();
            if (next < 0) throw new EOFException("Computer closed the connection");
            if (next == '\n') return line.toString(StandardCharsets.US_ASCII.name());
            if (next < 32 || next > 126) throw new IOException("Invalid computer response");
            line.write(next);
        }
        throw new IOException("Computer response is too long");
    }
    /** Abort the underlying TCP descriptor before TLS cleanup, including a stalled TLS writer. */
    private static final class PinnedSocket extends Socket {
        private final Socket raw;
        private final SSLSocket tls;
        PinnedSocket(Socket raw, SSLSocket tls) { this.raw = raw; this.tls = tls; }
        @Override public InputStream getInputStream() throws IOException { return tls.getInputStream(); }
        @Override public OutputStream getOutputStream() throws IOException { return tls.getOutputStream(); }
        @Override public void setSoTimeout(int timeout) throws SocketException { tls.setSoTimeout(timeout); }
        @Override public boolean isClosed() { return raw.isClosed(); }
        @Override public void close() throws IOException { raw.close(); tls.close(); }
    }
}
