package dev.bluetoothswitch.relay;

import android.os.Handler;
import android.os.Looper;
import java.net.Socket;
import java.util.function.IntConsumer;

/** Pinned, bounded display-only query. Unknown/older companions return -1. */
final class ComputerOccupancy {
    static void check(NearbyDevices.Device device, IntConsumer completed) {
        Handler main = new Handler(Looper.getMainLooper());
        Thread worker = new Thread(() -> {
            int count = -1; String names="";
            try(Socket socket = RelayConnection.openPinned(device.host,5002,device.pin,"STATUS1",s -> {})) {
                String line = RelayConnection.readLine(socket,1536,4000);
                String[] parts=line.split(" ",4);
                if(parts.length>=3 && parts[0].equals("OK") && parts[1].equals("STATUS1") && parts[2].matches("[0-4]")) {
                    count=Integer.parseInt(parts[2]);
                    if(parts.length==4) {
                        String decoded=new String(java.util.Base64.getDecoder().decode(parts[3]),java.nio.charset.StandardCharsets.UTF_8);
                        if(decoded.length()<=262 && decoded.codePoints().noneMatch(c->Character.isISOControl(c)||Character.getType(c)==Character.FORMAT))names=decoded;
                    }
                }
            } catch(Exception ignored) { }
            final int result=count;final String display=names;main.post(() -> {device.connectedNames=display;completed.accept(result);});
        }, "computer-occupancy");
        worker.setDaemon(true);worker.start();
    }
}
