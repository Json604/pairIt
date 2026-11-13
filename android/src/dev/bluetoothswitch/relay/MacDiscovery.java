package dev.bluetoothswitch.relay;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Handler;
import android.os.Looper;
import java.nio.charset.StandardCharsets;

/** Saved-identity locator only. TLS pin verification still authenticates every connection. */
final class MacDiscovery {
    private final NsdManager manager;
    private final Handler main=new Handler(Looper.getMainLooper());
    private NsdManager.DiscoveryListener listener;
    private int generation, attempts;
    private boolean resolving;
    private String resolvedName;
    volatile String host;
    MacDiscovery(Context context){manager=context.getSystemService(NsdManager.class);}
    void start(String pin){
        stop();if(!pin.matches("[a-f0-9]{64}"))return;
        final int session=generation;final String expected="AudioRelay-"+pin.substring(0,8);
        listener=new NsdManager.DiscoveryListener(){
            public void onDiscoveryStarted(String t){}public void onDiscoveryStopped(String t){}
            public void onStartDiscoveryFailed(String t,int e){retry(pin,session);}public void onStopDiscoveryFailed(String t,int e){}
            public void onServiceLost(NsdServiceInfo info){main.post(()->{if(session==generation&&info.getServiceName().equals(resolvedName)){host=null;resolvedName=null;}});}
            public void onServiceFound(NsdServiceInfo info){main.post(()->{
                String name=info.getServiceName();
                if(session!=generation||resolving||attempts>=8||!(name.equals(expected)||name.matches(java.util.regex.Pattern.quote(expected)+" \\([2-9][0-9]?\\)")))return;
                resolving=true;attempts++;
                try{manager.resolveService(info,new NsdManager.ResolveListener(){
                    public void onResolveFailed(NsdServiceInfo service,int error){retry(pin,session);}
                    public void onServiceResolved(NsdServiceInfo service){main.post(()->{
                        if(session!=generation)return;resolving=false;
                        byte[] role=service.getAttributes().get("role"), advertised=service.getAttributes().get("pin");
                        if(role!=null&&!new String(role,StandardCharsets.UTF_8).equals("computer"))return;
                        if(advertised!=null&&!new String(advertised,StandardCharsets.US_ASCII).equals(pin))return;
                        if(service.getPort()==5002&&service.getHost()!=null){host=service.getHost().getHostAddress();resolvedName=name;}
                    });}
                });}catch(RuntimeException ignored){resolving=false;}
            });}
        };
        try{manager.discoverServices("_audiorelay._tcp.",NsdManager.PROTOCOL_DNS_SD,listener);}catch(RuntimeException ignored){listener=null;retry(pin,session);}
    }
    private void retry(String pin,int session){
        main.postDelayed(()->{if(session==generation)start(pin);},2000);
    }
    void stop(){generation++;if(listener!=null)try{manager.stopServiceDiscovery(listener);}catch(RuntimeException ignored){}listener=null;host=null;resolvedName=null;resolving=false;attempts=0;}
}
