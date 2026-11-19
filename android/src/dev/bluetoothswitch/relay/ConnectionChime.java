package dev.bluetoothswitch.relay;

import android.content.Context;
import android.media.*;
import android.os.Handler;
import android.os.Looper;

/** A short local acknowledgment, routed and muted defensively like the live audio. */
final class ConnectionChime {
    private static String acknowledgedPin="";
    private static ConnectionChime current;
    private final Handler main=new Handler(Looper.getMainLooper());
    private final AudioManager audio;
    private final AudioFocusRequest focus;
    private AudioTrack track;
    private final OutputRoute route;
    private final int outputId;
    private boolean closed, ownsFocus;
    private long startedAt;
    private final Runnable acknowledged;
    static void stopSound(){if(current!=null)current.close();}
    static void disconnected(){acknowledgedPin="";if(current!=null)current.close();}
    static void disconnected(Context context,RelaySettings settings){
        disconnected();
        play(context,settings,true);
    }
    static void connected(Context context,RelaySettings settings){
        if(!RelayService.ownsAudioFocus())return;
        play(context,settings,false);
    }
    private static void play(Context context,RelaySettings settings,boolean disconnect){
        if(!settings.paired()||(!disconnect&&acknowledgedPin.equals(settings.pin())))return;
        if(AppOpenAds.isPresenting()||current!=null)return;
        if(!settings.soundFeedback())return;
        AudioManager audio=context.getSystemService(AudioManager.class);
        if(audio.getStreamVolume(AudioManager.STREAM_MUSIC)==0)return;
        AudioDeviceInfo output=settings.output().find(audio,settings.outputDeviceId());
        // A private route must exist before creating any sound; never substitute a speaker.
        if(output==null)return;
        if(current!=null)current.close();
        final String pin=settings.pin();
        try{current=new ConnectionChime(context,audio,settings.output(),output,disconnect,()->{if(!disconnect&&settings.pin().equals(pin))acknowledgedPin=pin;});current.start();}catch(RuntimeException ignored){if(current!=null)current.close();}
    }
    private ConnectionChime(Context context,AudioManager audio,OutputRoute route,AudioDeviceInfo output,boolean disconnect,Runnable acknowledged){
        this.acknowledged=acknowledged;
        this.audio=audio;this.route=route;outputId=output.getId();
        AudioAttributes attributes=new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build();
        focus=new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK).setAudioAttributes(attributes).setOnAudioFocusChangeListener(change->{if(change<0)close();},main).build();
        // Keep the 100 ms route-settling lead-in; the audible cue lasts 900 ms.
        short[] pcm=new short[48000];
        for(int i=4800;i<pcm.length;i++)pcm[i]=(short)Math.round((disconnect?ConnectionTone.disconnectSample((i-4800)/48000.0):ConnectionTone.sample((i-4800)/48000.0))*32767);
        try{track=new AudioTrack.Builder().setAudioAttributes(attributes).setAudioFormat(new AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(48000).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build()).setTransferMode(AudioTrack.MODE_STATIC).setBufferSizeInBytes(pcm.length*2).build();
        track.setVolume(0);track.setPreferredDevice(output);track.write(pcm,0,pcm.length);
        track.addOnRoutingChangedListener(router->updateRoute(),main);
        }catch(RuntimeException failure){if(track!=null){track.release();track=null;}throw failure;}
    }
    private void start(){
        if(!RelayService.ownsAudioFocus()){
            ownsFocus=audio.requestAudioFocus(focus)==AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
            if(!ownsFocus){close();return;}
        }
        startedAt=android.os.SystemClock.elapsedRealtime();track.play();main.postDelayed(this::updateRoute,110);
        main.postDelayed(this::close,1100);
    }
    private void updateRoute(){
        if(closed||track==null)return;
        boolean audible=route.confirmed(track,outputId)&&audio.getStreamVolume(AudioManager.STREAM_MUSIC)>0;
        track.setVolume(audible?1:0);
        if(audible&&track.getPlayState()==AudioTrack.PLAYSTATE_PLAYING&&android.os.SystemClock.elapsedRealtime()-startedAt>=100)acknowledged.run();
    }
    private void close(){
        if(closed)return;closed=true;main.removeCallbacksAndMessages(null);
        if(track!=null){AudioTrack sound=track;track=null;try{sound.setVolume(0);sound.pause();sound.flush();}catch(RuntimeException ignored){}finally{sound.release();}}
        if(ownsFocus)audio.abandonAudioFocusRequest(focus);if(current==this)current=null;
    }
}
