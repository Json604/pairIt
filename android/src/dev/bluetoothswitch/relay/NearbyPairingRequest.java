package dev.bluetoothswitch.relay;

import android.os.Handler;
import android.os.Looper;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Consumer;

/** A bootstrap request. Trust is established by comparing the code on the Mac. */
final class NearbyPairingRequest {
    private final Handler main=new Handler(Looper.getMainLooper());
    private final AtomicBoolean done=new AtomicBoolean();
    private final AtomicReference<Socket> socket=new AtomicReference<>();
    private final String nonce;
    final String comparison;
    NearbyPairingRequest(String pin) throws Exception {
        byte[] random=new byte[32];new SecureRandom().nextBytes(random);nonce=hex(random);
        String digest=hex(MessageDigest.getInstance("SHA-256").digest((pin+nonce).getBytes(StandardCharsets.US_ASCII))).substring(0,16).toUpperCase(java.util.Locale.ROOT);
        comparison=digest.replaceAll("(.{4})(?!$)","$1 ");
    }
    void start(NearbyDevices.Device device,Consumer<PairingCode> completion){
        Thread worker=new Thread(()->{
            PairingCode result=null;
            try(Socket connection=RelayConnection.openPinned(device.host,5002,device.pin,"REQUEST1 "+nonce,opened->{socket.set(opened);if(done.get())close();})){
                String response=RelayConnection.readLine(connection,96,45000);
                if(response.startsWith("OK REQUEST1 "))result=PairingCode.approved(device,response.substring(12));
            }catch(Exception ignored){}
            final PairingCode approved=result;
            main.post(()->{if(done.compareAndSet(false,true)){close();completion.accept(approved);}});
        },"nearby-pairing");worker.setDaemon(true);worker.start();
    }
    private static String hex(byte[] bytes){StringBuilder text=new StringBuilder();for(byte b:bytes)text.append(String.format(java.util.Locale.ROOT,"%02x",b&255));return text.toString();}
    void cancel(){done.set(true);close();main.removeCallbacksAndMessages(null);}
    private void close(){Socket connection=socket.getAndSet(null);if(connection!=null)try{connection.close();}catch(Exception ignored){}}
}
