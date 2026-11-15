package dev.bluetoothswitch.relay;

import java.net.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.*;
import java.util.function.Consumer;
import java.util.concurrent.atomic.AtomicBoolean;

/** Foreground-only invitations. One exchange at a time; no credentials in discovery. */
final class ListeningInvitations {
    interface UI {
        void confirm(String title,String comparison,Consumer<Boolean> answer);
        void received(String code);
        void finished(String message);
        default void progress(String message) {}
        default boolean canHost(){return true;}
    }
    private final Executor main;
    private static final ScheduledExecutorService deadlines=Executors.newSingleThreadScheduledExecutor(r->{Thread t=new Thread(r,"invitation-deadlines");t.setDaemon(true);return t;});
    private long lastIncoming;
    private final UI ui;
    private final AtomicBoolean busy=new AtomicBoolean();
    private volatile ServerSocket server;
    private volatile Socket active;
    private volatile CompletableFuture<Boolean> decision;
    private volatile int generation;
    private volatile boolean hosting;
    private volatile String notice="";
    boolean hosting(){return hosting;}
    String notice(){return notice;}
    static String hostProblem(boolean connected,boolean phoneOutput,boolean available){
        if(!connected)return "Connect this phone to a computer first, then invite a listener. Or keep Together open to join a friend’s invitation.";
        if(!phoneOutput)return "Choose This phone on Connect before inviting a listener.";
        if(!available)return "Choose an available audio output on this phone before inviting.";
        return "";
    }
    private void progress(int session,String message){notice=message;main.execute(()->{if(session==generation)ui.progress(message);});}
    ListeningInvitations(UI ui,Executor main){this.ui=ui;this.main=main;}
    boolean busy(){return busy.get();}
    int start(){
        if(server!=null)return server.getLocalPort();
        try {
            ServerSocket listening=new ServerSocket(0,2);server=listening;final int session=generation;
            Thread thread=new Thread(()->{
                while(server==listening)try {
                    Socket socket=listening.accept();socket.setSoTimeout(65000);
                    if(System.nanoTime()-lastIncoming<TimeUnit.SECONDS.toNanos(3)||!busy.compareAndSet(false,true)){socket.close();continue;}
                    lastIncoming=System.nanoTime();
                    active=socket;hosting=false;progress(session,"Invitation received. Compare the code with your host.");exchange(socket,null,null,session);
                }catch(IOException ignored){break;}
            },"listening-invitations");thread.setDaemon(true);thread.start();return listening.getLocalPort();
        }catch(IOException error){return 0;}
    }
    void invite(String host,int port,String code,String computer){
        if(port==0){ui.finished("Update PairIt on that phone to receive invitations.");return;}
        if(!busy.compareAndSet(false,true)){ui.finished("Finish the current invitation first.");return;}
        final int session=generation;hosting=true;progress(session,"Inviting listener… Keep PairIt open on both phones.");
        Thread thread=new Thread(()->{
            try {
                Socket socket=new Socket();active=socket;socket.connect(new InetSocketAddress(host,port),5000);socket.setSoTimeout(65000);
                exchange(socket,code,computer,session);
            }catch(Exception error){finish(session,"Couldn’t reach that phone. Keep PairIt open on both phones.");}
        },"send-listening-invitation");thread.setDaemon(true);thread.start();
    }
    private void exchange(Socket socket,String code,String computer,int session){
        String outcome="Invitation declined or expired. Try again.";
        ScheduledFuture<?> timeout=deadlines.schedule(()->{try{socket.close();}catch(IOException ignored){}CompletableFuture<Boolean> answer=decision;if(session==generation&&answer!=null)answer.complete(false);},65,TimeUnit.SECONDS);
        try(Socket connection=socket){
            InvitationCrypto crypto=new InvitationCrypto();
            if(code!=null){
                String name=java.util.Base64.getUrlEncoder().encodeToString(computer.getBytes(StandardCharsets.UTF_8));
                send(connection,"INVITE1 "+InvitationCrypto.hex(crypto.publicKey())+" "+name);
                String ready=read(connection,160);
                if(!ready.startsWith("READY1 "))throw new IOException();
                crypto.agree(InvitationCrypto.unhex(ready.substring(7)),true);
                if(!approve(session,"Host listening on "+computer,crypto.comparison())||!read(connection,16).equals("ACCEPT1")||!ui.canHost())throw new IOException();
                send(connection,"CODE1 "+InvitationCrypto.hex(crypto.seal(code.getBytes(StandardCharsets.UTF_8))));
                if(!read(connection,16).equals("RECEIVED1"))throw new IOException();
                outcome="Invitation accepted. Your guest is connecting to the computer.";
            } else {
                String[] offer=read(connection,1024).split(" ");
                if(offer.length!=3||!offer[0].equals("INVITE1"))throw new IOException();
                String name=new String(java.util.Base64.getUrlDecoder().decode(offer[2]),StandardCharsets.UTF_8).replaceAll("[\\p{Cntrl}\\p{Cf}]","");
                if(name.isEmpty()||name.length()>80)throw new IOException();
                crypto.agree(InvitationCrypto.unhex(offer[1]),false);send(connection,"READY1 "+InvitationCrypto.hex(crypto.publicKey()));
                if(!approve(session,"Join listening on "+name+"?",crypto.comparison()))throw new IOException();
                send(connection,"ACCEPT1");String encrypted=read(connection,16390);
                if(!encrypted.startsWith("CODE1 "))throw new IOException();
                String received=new String(crypto.open(InvitationCrypto.unhex(encrypted.substring(6))),StandardCharsets.UTF_8);
                if(received.length()>4096||!received.startsWith("audiorelay://pair/"))throw new IOException();send(connection,"RECEIVED1");
                main.execute(()->{if(session==generation)ui.received(received);});outcome="";
            }
        }catch(Exception ignored){}finally{timeout.cancel(false);finish(session,outcome);}
    }
    private boolean approve(int session,String title,String comparison) throws Exception {
        CompletableFuture<Boolean> answer=new CompletableFuture<>();decision=answer;
        main.execute(()->{if(session==generation)ui.confirm(title,comparison,answer::complete);else answer.complete(false);});
        try{return answer.get(60,TimeUnit.SECONDS)&&session==generation;}finally{if(decision==answer)decision=null;}
    }
    private static void send(Socket socket,String line) throws IOException {socket.getOutputStream().write((line+"\n").getBytes(StandardCharsets.US_ASCII));socket.getOutputStream().flush();}
    private static String read(Socket socket,int limit) throws IOException {
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();for(int i=0;i<=limit;i++){int b=socket.getInputStream().read();if(b<0)throw new EOFException();if(b==10)return bytes.toString("US-ASCII");if(b<32||b>126)throw new IOException();bytes.write(b);}throw new IOException("Invitation too large");
    }
    private void finish(int session,String message){
        if(session!=generation)return;Socket socket=active;active=null;if(socket!=null)try{socket.close();}catch(IOException ignored){}
        busy.set(false);notice=message;main.execute(()->{if(session==generation)ui.finished(message);});
    }
    void stop(){generation++;CompletableFuture<Boolean> answer=decision;decision=null;if(answer!=null)answer.complete(false);ServerSocket listener=server;server=null;if(listener!=null)try{listener.close();}catch(IOException ignored){}Socket socket=active;active=null;if(socket!=null)try{socket.close();}catch(IOException ignored){}busy.set(false);}
}
