package dev.bluetoothswitch.relay;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Handler;
import android.os.Looper;
import java.util.*;

/** Discovery is an untrusted display hint, never a source of pairing credentials. */
final class NearbyDevices {
    static final class Device {
        final String name, platform, pin, host;
        Device(DiscoveryRecord record,String host) {name=record.name;platform=record.platform;pin=record.pin;this.host=host;}
    }
    private final NsdManager manager;
    private final Handler main=new Handler(Looper.getMainLooper());
    private final Runnable changed;
    private final Map<String,Device> devices=new LinkedHashMap<>();
    private final Set<String> pending=new HashSet<>();
    private final ArrayDeque<NsdServiceInfo> queue=new ArrayDeque<>();
    private NsdManager.DiscoveryListener listener;
    private NsdManager.RegistrationListener registration;
    private String ownName;
    private final String presenceId=UUID.randomUUID().toString();
    private int generation;
    private boolean resolving, phones;
    NearbyDevices(Context context,Runnable changed){manager=context.getSystemService(NsdManager.class);this.changed=changed;}
    List<Device> snapshot(){return new ArrayList<>(devices.values());}
    void start(boolean phones){
        stop();this.phones=phones;final int session=generation;
        listener=new NsdManager.DiscoveryListener(){
            public void onDiscoveryStarted(String t){} public void onDiscoveryStopped(String t){}
            public void onStartDiscoveryFailed(String t,int e){retry(session);} public void onStopDiscoveryFailed(String t,int e){}
            public void onServiceLost(NsdServiceInfo info){main.post(()->{if(session==generation){String key=info.getServiceName();devices.remove(key);pending.remove(key);queue.removeIf(s->s.getServiceName().equals(key));changed.run();}});}
            public void onServiceFound(NsdServiceInfo info){main.post(()->{
                String key=info.getServiceName();
                if(session!=generation||key.equals(ownName)||devices.containsKey(key)||devices.size()+pending.size()>=24||!pending.add(key))return;
                queue.add(info);resolveNext(session);
            });}
        };
        try{manager.discoverServices(phones?"_pairit-phone._tcp.":"_audiorelay._tcp.",NsdManager.PROTOCOL_DNS_SD,listener);}catch(RuntimeException ignored){listener=null;retry(session);}
        if(phones)advertise(session);
    }
    private void retry(int session){
        main.postDelayed(()->{if(session==generation)start(phones);},2000);
    }
    private void resolveNext(int session){
        if(session!=generation||resolving||queue.isEmpty())return;
        NsdServiceInfo info=queue.remove();String key=info.getServiceName();resolving=true;
        try{manager.resolveService(info,new NsdManager.ResolveListener(){
            public void onResolveFailed(NsdServiceInfo service,int error){main.post(()->finish(null));}
            public void onServiceResolved(NsdServiceInfo service){main.post(()->finish(service));}
            private void finish(NsdServiceInfo service){
                if(session!=generation)return;resolving=false;boolean present=pending.remove(key);
                if(present&&service!=null&&!key.equals(ownName)&&!(phones&&isThisPhone(service.getHost()))){
                    byte[] identity=service.getAttributes().get("id");
                    if(identity!=null&&presenceId.equals(new String(identity,java.nio.charset.StandardCharsets.UTF_8))){resolveNext(session);return;}
                    DiscoveryRecord record=DiscoveryRecord.parse(service.getAttributes(),phones);
                    if(record!=null&&(phones||service.getPort()==5002)&&service.getHost()!=null){devices.put(key,new Device(record,service.getHost().getHostAddress()));changed.run();}
                }
                resolveNext(session);
            }
        });}catch(RuntimeException ignored){resolving=false;pending.remove(key);resolveNext(session);}
    }
    private boolean isThisPhone(java.net.InetAddress address){
        if(address==null)return false;
        if(address.isAnyLocalAddress()||address.isLoopbackAddress())return true;
        try{return java.net.NetworkInterface.getByInetAddress(address)!=null;}
        catch(java.net.SocketException ignored){return false;}
    }
    private void advertise(int session){
        ownName="PairIt-"+UUID.randomUUID().toString().substring(0,8);
        NsdServiceInfo info=new NsdServiceInfo();info.setServiceName(ownName);info.setServiceType("_pairit-phone._tcp.");
        // Presence only: nobody connects to this port, and no pairing secrets are advertised.
        info.setAttribute("id",presenceId);info.setPort(9);info.setAttribute("role","phone");info.setAttribute("v","1");info.setAttribute("platform","android");String model=android.os.Build.MODEL.replaceAll("[\\p{Cntrl}\\p{Cf}]", "").trim();info.setAttribute("name",model.isEmpty()?"Android phone":model.substring(0,Math.min(64,model.length())));
        registration=new NsdManager.RegistrationListener(){public void onRegistrationFailed(NsdServiceInfo i,int e){}public void onUnregistrationFailed(NsdServiceInfo i,int e){}public void onServiceUnregistered(NsdServiceInfo i){}public void onServiceRegistered(NsdServiceInfo i){main.post(()->{if(session==generation){ownName=i.getServiceName();devices.remove(ownName);changed.run();}});}};
        try{manager.registerService(info,NsdManager.PROTOCOL_DNS_SD,registration);}catch(RuntimeException ignored){registration=null;}
    }
    void stop(){generation++;if(listener!=null)try{manager.stopServiceDiscovery(listener);}catch(RuntimeException ignored){}if(registration!=null)try{manager.unregisterService(registration);}catch(RuntimeException ignored){}listener=null;registration=null;ownName=null;devices.clear();pending.clear();queue.clear();resolving=false;}
}
