package dev.bluetoothswitch.relay;

import android.Manifest;
import android.app.Activity;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.media.*;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.widget.*;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.concurrent.atomic.AtomicBoolean;

/** Explicit foreground microphone session; no recording, auto-start or background capture. */
public final class MicrophoneActivity extends Activity {
    private final AtomicBoolean running=new AtomicBoolean();
    private final Handler main=new Handler(Looper.getMainLooper());
    private volatile boolean workerActive;
    private volatile Socket socket;
    private volatile AudioRecord recorder;
    private volatile long lastWrite;
    private Button start;
    private TextView status;
    private final Runnable watchdog=new Runnable(){public void run(){if(running.get()){if(System.nanoTime()-lastWrite>6_000_000_000L){stop();status.setText("Computer stopped receiving. Check the connection and start again.");}else main.postDelayed(this,1000);}}};
    @Override public void onCreate(Bundle state){
        super.onCreate(state);
        LinearLayout body=new LinearLayout(this);body.setOrientation(LinearLayout.VERTICAL);int pad=(int)(24*getResources().getDisplayMetrics().density);body.setPadding(pad,pad*2,pad,pad);body.setBackgroundColor(0xfff6f6f8);
        TextView title=RelayComponents.text(this,"Phone microphone",30,GlassUI.INK,true);body.addView(title);
        TextView help=RelayComponents.text(this,"Use this phone’s microphone on your computer.\n\nIn the computer’s Settings, enable Phone microphone and select an installed virtual audio cable. Choose that cable as the microphone in your calling or recording app.\n\nKeep this screen open. Leaving it stops transmission. Nothing is recorded or uploaded.",15,GlassUI.SECONDARY,false);help.setPadding(0,pad,0,pad);body.addView(help);
        status=RelayComponents.text(this,"Microphone is off",15,GlassUI.INK,true);body.addView(status);
        start=RelayComponents.button(this,"Start microphone",()->{if(running.get()){stop();status.setText("Microphone is off");}else requestStart();});RelayComponents.style(start,true);body.addView(start);
        Button done=RelayComponents.button(this,"Done",this::finish);body.addView(done);ScrollView scroll=new ScrollView(this);scroll.addView(body);setContentView(scroll);
    }
    private void requestStart(){
        if(!new RelaySettings(this).paired()){status.setText("Pair a computer in Connect first.");return;}
        if(checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED){requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO},51);return;}
        RelayService.stopFromUi(this);
        if(!running.compareAndSet(false,true))return;
        start.setText("Stop microphone");status.setText("Connecting to your computer…");lastWrite=System.nanoTime();main.postDelayed(watchdog,1000);
        workerActive=true;new Thread(this::transmit,"pairit-microphone").start();
    }
    @Override public void onRequestPermissionsResult(int code,String[] permissions,int[] grants){super.onRequestPermissionsResult(code,permissions,grants);if(code==51){if(grants.length>0&&grants[0]==PackageManager.PERMISSION_GRANTED)requestStart();else status.setText("Microphone access was denied. You can still listen normally.");}}
    @android.annotation.SuppressLint("MissingPermission")
    private void transmit(){
        String outcome="Microphone is off";AudioRecord input=null;Socket connection=null;
        try{
            RelaySettings settings=new RelaySettings(this);
            connection=RelayConnection.open(settings.connectionHost(null),settings,true);socket=connection;
            if(!running.get())return;
            String reply=RelayConnection.readLine(connection,80,4000);
            if(!reply.equals("OK MIC1 48000"))throw new Exception(reply.contains("BUSY")?"Stop computer sharing and other microphone sessions first.":"Enable Phone microphone and select a virtual cable in the computer’s Settings.");
            int minimum=AudioRecord.getMinBufferSize(48000,AudioFormat.CHANNEL_IN_MONO,AudioFormat.ENCODING_PCM_16BIT);
            if(minimum<=0)throw new Exception("This microphone does not support 48 kHz recording.");
            input=new AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION,48000,AudioFormat.CHANNEL_IN_MONO,AudioFormat.ENCODING_PCM_16BIT,Math.max(minimum,7680));recorder=input;
            if(input.getState()!=AudioRecord.STATE_INITIALIZED)throw new Exception("Microphone unavailable. Close other recording apps and retry.");
            input.startRecording();main.post(()->{if(running.get())status.setText("Microphone live · sending to "+settings.computerName());});
            byte[] samples=new byte[1920];int sequence=0;java.io.OutputStream output=connection.getOutputStream();
            while(running.get()){
                int count=input.read(samples,0,samples.length);if(count<=0)throw new Exception("Microphone interrupted. Start again when ready.");
                count-=count%2;ByteBuffer packet=ByteBuffer.allocate(16+count).order(ByteOrder.LITTLE_ENDIAN);
                packet.putInt(0x314d5342).putInt(sequence++).putInt(48000).putInt(count/2).put(samples,0,count);
                output.write(packet.array());lastWrite=System.nanoTime();
            }
        }catch(Exception error){if(running.get())outcome=error.getMessage()==null?"Connection lost. Start microphone again when ready.":error.getMessage();}
        finally{
            if(input!=null){try{input.stop();}catch(Exception ignored){}input.release();}if(connection!=null)try{connection.close();}catch(Exception ignored){}
            recorder=null;socket=null;workerActive=false;running.set(false);String message=outcome;main.post(()->{start.setText("Start microphone");start.setEnabled(true);status.setText(message);});
        }
    }
    private void stop(){running.set(false);main.removeCallbacks(watchdog);Socket current=socket;if(current!=null)try{current.close();}catch(Exception ignored){}AudioRecord input=recorder;if(input!=null)try{input.stop();}catch(Exception ignored){}if(start!=null&&workerActive){start.setText("Stopping…");start.setEnabled(false);}}
    @Override protected void onPause(){stop();super.onPause();}
    @Override protected void onDestroy(){stop();super.onDestroy();}
}
