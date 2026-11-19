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
        int invitationPort;
        boolean occupancySupported;
        String connectedNames = "";
        Device(PairingCode code) {name=code.name;platform=code.platform;pin=code.pin;host=code.host;}
        Device(DiscoveryRecord record,String host) {name=record.name;platform=record.platform;pin=record.pin;this.host=host;}
    }
    private final NsdManager manager;
    private final String displayName;
    private final RelaySettings settings;
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
    int invitationPort;
    private boolean resolving, phones;
    NearbyDevices(Context context,Runnable changed){displayName=PhoneDisplayName.get(context);settings=new RelaySettings(context);manager=context.getSystemService(NsdManager.class);this.changed=changed;}
    List<Device> snapshot(){return new ArrayList<>(devices.values());}
    void start(boolean phones){
        stop();this.phones=phones;final int session=generation;
        discover(session);
        advertise(session);
    }
    /** Discovery retries never touch the advertisement: re-registering under a new name
     * makes this phone flicker in and out for computers and other phones. */
    private void discover(int session){
        if(session!=generation)return;
        if(listener!=null){try{manager.stopServiceDiscovery(listener);}catch(RuntimeException ignored){}listener=null;}
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
    }
    private void retry(int session){
        main.postDelayed(()->{if(session==generation)discover(session);},2000);
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
                    if(record!=null&&(phones||service.getPort()==5002)&&service.getHost()!=null){Device device=new Device(record,service.getHost().getHostAddress());byte[] invite=service.getAttributes().get("invite");if(phones&&invite!=null&&new String(invite,java.nio.charset.StandardCharsets.US_ASCII).equals("1")&&service.getPort()>0)device.invitationPort=service.getPort();devices.put(key,device);changed.run();}
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
        // Invitation endpoint carries an ephemeral, user-approved encrypted exchange.
        info.setAttribute("id",presenceId);info.setPort(invitationPort>0?invitationPort:9);if(invitationPort>0)info.setAttribute("invite","1");info.setAttribute("role","phone");info.setAttribute("v","1");info.setAttribute("platform","android");info.setAttribute("name",displayName);String tags=computerTags();if(!tags.isEmpty())info.setAttribute("c",tags);
        registration=new NsdManager.RegistrationListener(){public void onRegistrationFailed(NsdServiceInfo i,int e){}public void onUnregistrationFailed(NsdServiceInfo i,int e){}public void onServiceUnregistered(NsdServiceInfo i){}public void onServiceRegistered(NsdServiceInfo i){main.post(()->{if(session==generation){ownName=i.getServiceName();devices.remove(ownName);changed.run();}});}};
        try{manager.registerService(info,NsdManager.PROTOCOL_DNS_SD,registration);}catch(RuntimeException ignored){registration=null;}
    }
    /** One daily-rotating tag per saved computer: SHA-256(token:installation:day). Only a
     * computer holding that pairing token can recognise (and offer to connect) this phone. */
    private String computerTags(){
        StringBuilder tags=new StringBuilder();long day=System.currentTimeMillis()/86_400_000L;String installation=settings.installationId();
        for(PairingCode saved:settings.savedComputers()){
            if(tags.length()>=13*8)break;
            String tag=tag(saved.token,installation,day);if(tag.isEmpty())continue;
            if(tags.length()>0)tags.append(',');tags.append(tag);
        }
        return tags.toString();
    }
    static String tag(String token,String installation,long day){
        try{byte[] hash=java.security.MessageDigest.getInstance("SHA-256").digest((token+":"+installation+":"+day).getBytes(java.nio.charset.StandardCharsets.UTF_8));
            StringBuilder hex=new StringBuilder();for(int i=0;i<6;i++)hex.append(String.format(java.util.Locale.ROOT,"%02x",hash[i]&0xff));return hex.toString();}
        catch(java.security.NoSuchAlgorithmException impossible){return "";}
    }
    void stop(){generation++;if(listener!=null)try{manager.stopServiceDiscovery(listener);}catch(RuntimeException ignored){}if(registration!=null)try{manager.unregisterService(registration);}catch(RuntimeException ignored){}listener=null;registration=null;ownName=null;devices.clear();pending.clear();queue.clear();resolving=false;}
}
