package dev.bluetoothswitch.relay;

import android.app.*;
import android.content.*;
import android.media.*;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.os.*;
import android.util.Log;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.locks.LockSupport;

/** Playback owns AudioTrack; main thread owns user intent and audio focus. */
public class RelayService extends Service {
    static volatile String computerVolume = "";
    private static final String TAG = "AudioRelayLab";
    static volatile RelayState state = new RelayState(RelayState.Phase.IDLE, "Your headphones. Both devices.", "Choose an output on this phone, then listen to your computer.");
    static volatile String diagnostics = "No active session.";
    static volatile String headphoneName = "Bluetooth headphones";
    static volatile String routeKey = "default";
    static volatile String timingProfileKey = "";
    static volatile boolean outputControlSupported, computerOutputSelected;
    private static RelayService liveInstance;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final AtomicInteger generation = new AtomicInteger();
    private volatile boolean running, requestedMac, focusGranted;
    private volatile Socket socket;
    private volatile AudioTrack activeTrack;
    private volatile RelayHandoff handoff;
    private volatile int pendingOutputOnConnect = -1;
    private volatile RelayHandoff.Intent parkedIntent = RelayHandoff.Intent.PAUSE;
    private final boolean useWifi = true;
    private volatile int outputRevision;
    private volatile OutputRoute selectedOutput = OutputRoute.BLUETOOTH;
    private volatile boolean interactiveMode, profileReady;
    static volatile String groupTimingStatus = "";
    /** Shown when an updated Mac has not been allowed to pause its media from earphones. */
    static volatile String mediaControlHint = "";
    /** The computer is silent (its player paused) while this phone keeps listening. */
    static volatile boolean computerPlayerPaused;
    private volatile boolean computerVolumeLinked;
    private final java.util.concurrent.ConcurrentLinkedQueue<String> mediaCommands = new java.util.concurrent.ConcurrentLinkedQueue<>();
    private volatile String alignmentReport = "STATS ALIGN1 320 -1\n";
    private volatile int selectedDeviceId = -1;
    private volatile String activeProfileKey = "";
    private String sessionPin, sessionOverride;
    private int manualResyncs, connections;
    private volatile long lastTrafficAt;
    private final ListeningFeedback listeningFeedback = new ListeningFeedback();
    private final Object controlWake = new Object();
    private android.database.ContentObserver volumeObserver;
    private final Runnable connectionWatchdog = new Runnable() {
        public void run() {
            if (!running || userStopped) return;
            if (ConnectionHealth.expired(SystemClock.elapsedRealtime(), lastTrafficAt, requestedMac || parkedIntent == RelayHandoff.Intent.PHONE, computerOutputSelected)) {
                recoverNetwork();
                return;
            }
            main.postDelayed(this, 500);
        }
    };
    private android.net.ConnectivityManager connectivity;
    private android.net.Network localNetwork;
    private volatile boolean networkAvailable = true;
    private volatile int networkRevision;
    private volatile boolean resumeWhenQuietAfterReconnect;
    private final android.net.ConnectivityManager.NetworkCallback networkCallback = new android.net.ConnectivityManager.NetworkCallback() {
        @Override public void onAvailable(android.net.Network network) {
            if(liveInstance!=RelayService.this)return;
            if (network.equals(localNetwork)) return;
            boolean networkChanged = localNetwork != null || !networkAvailable;
            localNetwork = network; networkAvailable = true; networkRevision++;
            if(settings.paired())discovery.start(settings.pin());
            if(networkChanged && running && (requestedMac || parkedIntent==RelayHandoff.Intent.PHONE)) {
                recoverNetwork();
                if(running && reconnectable())locks.reconnectWindow();
            }
            main.post(()->scheduleExternalOutput());
            if(worker!=null)LockSupport.unpark(worker);
        }
        @Override public void onLost(android.net.Network network) {
            if(liveInstance!=RelayService.this)return;
            if(!network.equals(localNetwork))return;
            localNetwork=null;networkAvailable=false;networkRevision++;
            if(running && (requestedMac || parkedIntent==RelayHandoff.Intent.PHONE))recoverNetwork();
        }
    };
    private boolean reconnectable() {
        return !userStopped && (outputRecovery.waiting() || ConnectionHealth.retainSession(settings.autoReconnect(),requestedMac,parkedIntent,false));
    }
    private void recoverNetwork() {
        if(!running || userStopped || (!requestedMac && parkedIntent!=RelayHandoff.Intent.PHONE))return;
        if(!reconnectable()) {
            pausePlayback(RelayState.Phase.ERROR,"Computer unavailable","Keep both devices on the same Wi-Fi, then tap Connect.");
            return;
        }
        // Retain the user's listening intent and foreground service, not stale audio.
        // PHONE restores only the control connection; a fresh offer is still required for audio.
        mute(); generation.incrementAndGet();closeConnection();locks.release();
        lastTrafficAt=SystemClock.elapsedRealtime();
        publish(requestedMac?RelayState.Phase.RECONNECTING:RelayState.Phase.PHONE,"Waiting for your computer","Reconnecting automatically. Keep both devices on the same Wi-Fi and PairIt open on your computer.");
        foreground(false);
        main.removeCallbacks(connectionWatchdog);main.postDelayed(connectionWatchdog,500);
    }
    static void restoreOutputMonitoring(Context context) {
        RelaySettings saved = new RelaySettings(context);
        if(liveInstance != null || !saved.autoReconnect() || !saved.paired()
                || !saved.pin().equals(saved.outputRecoveryPin())) return;
        try { context.startForegroundService(new Intent(context, RelayService.class).setAction("RESTORE_OUTPUT")); }
        catch(IllegalStateException | SecurityException error) { Log.w(TAG,"Output monitoring could not restart",error); }
    }

    static boolean hasControlConnection() { RelayService service=liveInstance; return service!=null&&service.socket!=null; }

    private Thread worker;
    private AudioManager audio;
    private PlaybackLocks locks;
    private RelaySettings settings;
    private MacDiscovery discovery;
    private AudioFocusRequest focus;
    private MediaSession mediaSession;
    private boolean userStopped;
    private final ExternalOutputRecovery outputRecovery=new ExternalOutputRecovery();
    private int automaticOutputAttempts;
    private final Runnable retryExternalOutput=()->resumeExternalOutput();
    private void cancelOutputRecovery(){settings.outputRecovery(false);outputRecovery.cancel();main.removeCallbacks(retryExternalOutput);}
    private void scheduleExternalOutput(){
        if(!outputRecovery.waiting())return;
        main.removeCallbacks(retryExternalOutput);main.postDelayed(retryExternalOutput,750);
    }
    private void resumeExternalOutput(){
        if(!outputRecovery.waiting()||userStopped||liveInstance!=this)return;
        if(!settings.autoReconnect()||!settings.paired()||!settings.outputRecoveryPin().equals(settings.pin())){cancelOutputRecovery();requestStop();return;}
        AudioDeviceInfo destination=selectedOutput.find(audio);OutputRoute kind=selectedOutput;
        if(destination==null){
            for(OutputRoute candidate:new OutputRoute[]{OutputRoute.BLUETOOTH,OutputRoute.WIRED}){
                destination=candidate.find(audio);if(destination!=null){kind=candidate;break;}
            }
        }
        boolean allowed=networkAvailable&&audio.getMode()==AudioManager.MODE_NORMAL&&PhoneAudioSession.availableTo(this);
        if(!outputRecovery.ready(destination!=null&&kind!=OutputRoute.SPEAKER,allowed)){
            // Device callbacks wake an absent route; only retry a present route held by a call/network.
            if(destination!=null)scheduleExternalOutput();return;
        }
        if(++automaticOutputAttempts>3){
            pausePlayback(RelayState.Phase.ERROR,"Couldn’t use these headphones","Reconnect your headphones, then tap Connect.");return;
        }
        settings.output(kind,destination.getId());selectedOutput=kind;outputRevision++;
        cancelOutputRecovery();startListening(true, false);
        if(!requestedMac && !userStopped && running && state.phase==RelayState.Phase.PHONE){
            outputRecovery.lost(true,settings.autoReconnect());settings.outputRecovery(outputRecovery.waiting());scheduleExternalOutput();
        }
        if(worker!=null)LockSupport.unpark(worker);
    }
    private void waitForExternalOutput(){
        outputRecovery.lost(selectedOutput!=OutputRoute.SPEAKER,settings.autoReconnect());
        settings.outputRecovery(outputRecovery.waiting());
        if(!outputRecovery.waiting()){park(RelayHandoff.Intent.OUTPUT,RelayState.Phase.HEADPHONES,"Output disconnected");return;}
        ++startTicket;main.removeCallbacks(finishPausedService);main.removeCallbacks(connectionWatchdog);
        requestedMac=false;focusGranted=false;profileReady=false;parkedIntent=RelayHandoff.Intent.OUTPUT;
        resumeWhenQuietAfterReconnect=false;pendingOutputOnConnect=-1;
        generation.incrementAndGet();mute();closeConnection();handoff=null;locks.release();audio.abandonAudioFocusRequest(focus);
        outputControlSupported=false;computerOutputSelected=false;mediaSession.setActive(false);
        publish(RelayState.Phase.HEADPHONES,"Waiting for headphones","Reconnect Bluetooth, wired or USB audio to resume automatically.");
        foreground(false);
        if(!running){running=true;worker=new Thread(this::receive,"relay-playback");worker.start();}
        scheduleExternalOutput();
    }
    private int startTicket;
    private final Runnable finishPausedService = () -> { if (!requestedMac && socket == null && !reconnectable()) stopSelf(); };
    private final AudioAttributes attributes = new AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build();
    static boolean ownsAudioFocus(){RelayService service=liveInstance;return service!=null&&service.focusGranted&&service.requestedMac;}
    private boolean canPlay() {
        RelayHandoff current = handoff;
        return running && requestedMac && focusGranted && (current == null || !current.computerOutput());
    }
    private final Runnable renewLocks = new Runnable() {
        public void run() {
            if (canPlay() && socket != null) locks.acquire(useWifi); else locks.release();
            if (running) main.postDelayed(this, 60000);
        }
    };
    private final AudioDeviceCallback devices = new AudioDeviceCallback() {
        @Override public void onAudioDevicesAdded(AudioDeviceInfo[] added){
            for(AudioDeviceInfo d:added)if(d.isSink()&&(OutputRoute.BLUETOOTH.accepts(d)||OutputRoute.WIRED.accepts(d))){automaticOutputAttempts=0;scheduleExternalOutput();break;}
        }
        @Override public void onAudioDevicesRemoved(AudioDeviceInfo[] removed) {
            for (AudioDeviceInfo device : removed) if (device.isSink() && device.getId() == selectedDeviceId && !computerOutputSelected && (requestedMac || parkedIntent == RelayHandoff.Intent.PHONE)) loseOutput();
        }
    };
    private final BroadcastReceiver noisy = new BroadcastReceiver() {
        public void onReceive(Context context, Intent intent) { if (!computerOutputSelected && selectedOutput!=OutputRoute.SPEAKER && (requestedMac || parkedIntent == RelayHandoff.Intent.PHONE)) loseOutput(); }
    };

    @Override public void onCreate() {
        super.onCreate(); liveInstance = this;
        audio = getSystemService(AudioManager.class);
        settings = new RelaySettings(this);
        if (state.phase == RelayState.Phase.IDLE && settings.paired()) {
            if ("paused".equals(settings.controlsSource())) state = new RelayState(RelayState.Phase.PAUSED, "Listening paused", "Resume with your headphones or choose Computer.");
            else if ("phone".equals(settings.controlsSource())) state = new RelayState(RelayState.Phase.PHONE, "Phone audio", "Choose Computer in the notification to return.");
        }
        locks = new PlaybackLocks(this);
        discovery = new MacDiscovery(this); if (settings.paired()) discovery.start(settings.pin());
        connectivity=getSystemService(android.net.ConnectivityManager.class);
        try {
            connectivity.registerNetworkCallback(new android.net.NetworkRequest.Builder()
                .addTransportType(android.net.NetworkCapabilities.TRANSPORT_WIFI)
                .addTransportType(android.net.NetworkCapabilities.TRANSPORT_ETHERNET).build(),networkCallback,main);
        } catch(SecurityException error) { Log.w(TAG,"Network monitoring unavailable"); }

        focus = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN).setAudioAttributes(attributes)
                .setWillPauseWhenDucked(true).setOnAudioFocusChangeListener(change -> {
                    if(change<0)ConnectionChime.stopSound();
                    if (change != AudioManager.AUDIOFOCUS_GAIN && requestedMac && !computerOutputSelected) {
                        park(audio.getMode() == AudioManager.MODE_NORMAL
                                ? RelayHandoff.Intent.PHONE : RelayHandoff.Intent.OUTPUT,
                                RelayState.Phase.PHONE, "Phone audio has priority");
                    }
                }, main).build();
        audio.registerAudioDeviceCallback(devices, main);
        // Report this phone's media volume promptly so the computer's controls stay in step.
        volumeObserver = new android.database.ContentObserver(main) {
            @Override public void onChange(boolean self) { synchronized (controlWake) { controlWake.notifyAll(); } }
        };
        try { getContentResolver().registerContentObserver(android.provider.Settings.System.CONTENT_URI, true, volumeObserver); }
        catch (SecurityException error) { volumeObserver = null; }
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(noisy, new IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY), RECEIVER_NOT_EXPORTED);
        else registerReceiver(noisy, new IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY));
        getSystemService(NotificationManager.class).createNotificationChannel(new NotificationChannel("relay",getString(R.string.app_name),NotificationManager.IMPORTANCE_LOW));
        mediaSession=new MediaSession(this,"Computer audio");
        mediaSession.setPlaybackToLocal(attributes);
        mediaSession.setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS | MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS);
        if (Build.VERSION.SDK_INT >= 31) mediaSession.setMediaButtonBroadcastReceiver(new ComponentName(this, RelayControlsReceiver.class));
        else setLegacyMediaReceiver();
        mediaSession.setSessionActivity(PendingIntent.getActivity(this,0,new Intent(this,MainActivity.class),PendingIntent.FLAG_IMMUTABLE));
        mediaSession.setCallback(new MediaSession.Callback(){
            @Override public void onPlay(){
                if(playComputerWhilePaused())return;
                if(state.macSelected())mediaAction("PLAY");
            }
            // Bluetooth earbuds still receive (silent) audio, so they send an explicit Pause
            // even though the computer is paused. In that state every press means "play".
            @Override public void onPause(){if(!playComputerWhilePaused())pauseComputer();}
            @Override public void onStop(){if(!playComputerWhilePaused())pauseComputer();}
            // Earphone double/triple taps: next/previous track in the computer's player.
            // A skip while paused is a request to hear the new track: resume this phone too.
            @Override public void onSkipToNext(){sendMediaKey("NEXT");if(state.phase==RelayState.Phase.PAUSED)mediaAction("PLAY");}
            @Override public void onSkipToPrevious(){sendMediaKey("PREVIOUS");if(state.phase==RelayState.Phase.PAUSED)mediaAction("PLAY");}
            @Override public void onCustomAction(String action,Bundle extras){
                if("disconnect".equals(action)){settings.groupGuest(false);requestStop();}
                else if("use_phone".equals(action))mediaAction("USE_PHONE");
            }
        },main);
        mediaSession.setMetadata(new MediaMetadata.Builder().putString(MediaMetadata.METADATA_KEY_TITLE,"Computer audio")
                .putString(MediaMetadata.METADATA_KEY_ARTIST,getString(R.string.app_name)).build());
        mediaSession.setActive(state.macSelected());updateMediaState();
    }

    @Override public int onStartCommand(Intent intent, int flags, int id) {
        if (intent == null || "RESTORE_OUTPUT".equals(intent.getAction())) {
            // Android may recreate a sticky service hours after process eviction.
            // Restore only a saved headphone-loss intent, never an old PLAY command.
            selectedOutput = settings.output();
            outputRecovery.restore(settings.outputRecoveryPin(), settings.pin(), settings.autoReconnect() && settings.paired());
            if (!outputRecovery.waiting()) { requestStop(); return START_NOT_STICKY; }
            foreground(false);
            waitForExternalOutput();
            return START_STICKY;
        }
        String action = intent.getAction();
        foreground(canPlay());
        if ("STOP".equals(action)) { settings.groupGuest(false); requestStop(); return START_NOT_STICKY; }
        if ("OUTPUT_COMPUTER".equals(action)) { selectComputerOutput(); return START_STICKY; }
        if ("LOCAL_OUTPUT".equals(action)) {
            cancelOutputRecovery();
            boolean resume = requestedMac && !computerOutputSelected;
            if (resume) requestedMac = false;
            mute(); activeTrack = null;
            selectedOutput = settings.output();
            AudioDeviceInfo destination = selectedOutput.find(audio, settings.outputDeviceId());
            selectedDeviceId = destination == null ? -1 : destination.getId();
            outputRevision++; generation.incrementAndGet();
            if (resume) startListening(false);
            else if (!running || socket==null) stopSelf();
            return START_STICKY;
        }
        if ("SYNC".equals(action)) return START_STICKY; // Control thread sends saved calibration.
        if ("RESYNC".equals(action)) {
            if (canPlay()) { manualResyncs++; generation.incrementAndGet(); publish(RelayState.Phase.BUFFERING, "Refreshing audio", "Keeping your selected output connected."); }
            return START_STICKY;
        }
        if ("PAUSE".equals(action) || "USE_PHONE".equals(action)) {
            park(RelayHandoff.Intent.PAUSE, RelayState.Phase.PHONE, "Phone audio");
            return START_STICKY;
        }
        if ("MEDIA_RESUME".equals(action)) {
            if (!"paused".equals(settings.controlsSource())) { stopSelf(); return START_STICKY; }
            action = "PLAY";
        }
        if ("MEDIA_PAUSE".equals(action)) {
            if (state.macSelected()) pauseComputer(); else stopSelf();
            return START_STICKY;
        }
        if (!"PLAY".equals(action)) { requestStop(); return START_NOT_STICKY; }
        cancelOutputRecovery();automaticOutputAttempts=0;
        main.removeCallbacks(finishPausedService);
        final int ticket = ++startTicket;
        startWhenReleased(ticket, SystemClock.uptimeMillis() + 5000);
        return START_STICKY;
    }

    private void startWhenReleased(int ticket, long deadline) {
        if (ticket != startTicket || userStopped) return;
        // A rapid pause/play must not revive the previous socket/AudioTrack worker.
        if ((!running && worker != null && worker.isAlive()) || !PhoneAudioSession.availableTo(this)) {
            if (SystemClock.uptimeMillis() >= deadline) {
                publish(RelayState.Phase.ERROR, "Audio is still stopping", "Wait a moment, then choose Computer again.");
                stopSelf(); return;
            }
            main.postDelayed(() -> startWhenReleased(ticket, deadline), 50); return;
        }
        startListening(true);
    }

    private void startListening(boolean selectPhoneOutput) { startListening(selectPhoneOutput, selectPhoneOutput); }

    private void startListening(boolean selectPhoneOutput, boolean allowOutputFallback) {
        if (!settings.paired()) {
            publish(RelayState.Phase.ERROR, "Connect your computer", "Paste a pairing code from the desktop companion.");
            stopSelf(); return;
        }
        if (running && requestedMac && focusGranted && worker != null && worker.isAlive()) return;
        if (userStopped) return;
        RelayHandoff current = handoff;
        selectedOutput = settings.output();
        interactiveMode = settings.interactive(); profileReady = false; timingProfileKey = "";
        sessionPin = settings.pin(); sessionOverride = settings.overrideHost();
        AudioDeviceInfo chosenOutput = settings.connectionOutput(audio, allowOutputFallback);
        if (chosenOutput != null) {
            selectedOutput = OutputRoute.kind(chosenOutput);
            settings.output(selectedOutput, chosenOutput.getId());
            headphoneName = OutputRoute.name(chosenOutput);
        }
        if (chosenOutput == null && selectedOutput!=OutputRoute.SPEAKER && settings.autoReconnect()) {waitForExternalOutput();return;}
        if (chosenOutput == null) {
            publish(RelayState.Phase.HEADPHONES, "Output unavailable", "Connect " + selectedOutput.label.toLowerCase(Locale.ROOT) + ", or choose another output in Settings.");
            if (!running) stopSelf();
            return;
        }
        interactiveMode = settings.interactive();
        selectedDeviceId=chosenOutput.getId();
        resumeWhenQuietAfterReconnect=false;
        if (!PhoneAudioSession.availableTo(this)) {
            android.widget.Toast.makeText(this, PhoneAudioSession.busyReason(), android.widget.Toast.LENGTH_LONG).show();
            if (!running) stopSelf();
            return;
        }
        if (selectPhoneOutput) {
            pendingOutputOnConnect = 0;
            if (current != null) current.requestOutput(false);
        }
        if (current != null && current.computerOutput()) {
            requestedMac = true; current.request(RelayHandoff.Intent.LISTEN);
            settings.controlsSource("computer");
            publish(RelayState.Phase.COMPUTER_OUTPUT, "Playing on computer", "Switching audio to this phone. Your connection stays paired.");
            return;
        }
        if (!PhoneAudioSession.acquire(this)) {
            String reason = PhoneAudioSession.busyReason();
            publish(RelayState.Phase.ERROR, "Finish the current session", reason);
            android.widget.Toast.makeText(this, reason, android.widget.Toast.LENGTH_LONG).show();
            stopSelf(); return;
        }
        requestedMac = true;
        foreground(true);
        focusGranted = audio.requestAudioFocus(focus) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
        generation.incrementAndGet();
        if (!focusGranted) {
            requestedMac = false;
            if (current != null) current.request(RelayHandoff.Intent.PAUSE);
            settings.controlsSource("phone");
            publish(RelayState.Phase.PHONE, "Phone audio has priority", "Finish the current call or audio session, then choose Computer.");
            if (!running) stopSelf();
            return;
        }
        lastTrafficAt=SystemClock.elapsedRealtime();
        main.removeCallbacks(connectionWatchdog);main.post(connectionWatchdog);
        locks.acquire(useWifi);
        if (current != null) current.request(RelayHandoff.Intent.LISTEN);
        mediaSession.setActive(true);
        settings.controlsSource("computer");
        publish(RelayState.Phase.CONNECTING, "Connecting to " + settings.computerName(), "Output: " + headphoneName + ". Keep the desktop companion open.");
        if (!running || worker == null || !worker.isAlive()) {
            running = true; main.removeCallbacks(renewLocks);main.removeCallbacks(connectionWatchdog); main.post(renewLocks);
            worker = new Thread(this::receive, "relay-playback"); worker.start();
            main.post(connectionWatchdog);
        }
    }

    private void selectComputerOutput() {
        cancelOutputRecovery();
        RelayHandoff current = handoff;
        if (current == null || !current.outputSupported()) {
            android.widget.Toast.makeText(this, "Connect to an updated computer companion to change its output.", android.widget.Toast.LENGTH_LONG).show();
            if (!running || socket==null) stopSelf();
            return;
        }
        pendingOutputOnConnect = 1; current.requestOutput(true);
        holdForComputerOutput();
    }

    private void holdForComputerOutput() {
        groupTimingStatus = "";
        computerOutputSelected = true;
        focusGranted = false; profileReady = false;
        generation.incrementAndGet(); mute(); locks.release();
        audio.abandonAudioFocusRequest(focus);
        mediaSession.setActive(false);
        RelayHandoff current = handoff;
        boolean confirmed = current != null && current.computerOutputConfirmed();
        if (requestedMac) publish(RelayState.Phase.COMPUTER_OUTPUT,
                confirmed ? "Playing on computer" : "Switching to computer",
                confirmed ? "The computer output is selected for all listeners. Choose Listen here to return to this phone."
                        : "Waiting for your computer to confirm the output change. Your connection stays paired.");
        else publish(state.phase, state.title,
                "Computer output is selected for all listeners. This phone stays paused until you choose Listen here.");
        foreground(false);
    }

    private void mute() {
        AudioTrack track = activeTrack;
        if (track != null) try { track.setVolume(0); } catch (IllegalStateException ignored) { }
    }
    private void pausePlayback(RelayState.Phase phase, String title, String detail) {
        groupTimingStatus = "";
        cancelOutputRecovery();
        ++startTicket; main.removeCallbacks(finishPausedService);
        main.removeCallbacks(renewLocks);main.removeCallbacks(connectionWatchdog);
        requestedMac = false; focusGranted = false; running = false; profileReady = false;
        generation.incrementAndGet(); mute(); closeConnection(); locks.release();
        audio.abandonAudioFocusRequest(focus);
        settings.controlsSource("phone");
        mediaSession.setActive(false);
        publish(phase, title, detail); stopSelf();
    }
    private void pauseComputer() {
        if(outputRecovery.waiting()){cancelOutputRecovery();pausePlayback(RelayState.Phase.PAUSED,"Listening paused","Tap Resume when ready.");return;}
        if (!state.macSelected() || state.phase == RelayState.Phase.PAUSED) return;
        park(RelayHandoff.Intent.PAUSE, RelayState.Phase.PAUSED, "Listening paused");
    }
    private void loseOutput() {
        if(userStopped||outputRecovery.waiting())return;
        waitForExternalOutput();
    }
    private void foreground(boolean playing) {
        int type = android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE;
        if (playing) type |= android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK;
        startForeground(1, notification(), type);
    }
    private void park(RelayHandoff.Intent intent, RelayState.Phase phase, String title) {
        groupTimingStatus = "";
        cancelOutputRecovery();
        if (userStopped) return;
        ++startTicket; main.removeCallbacks(finishPausedService);
        requestedMac = false; focusGranted = false; profileReady = false; parkedIntent = intent;
        resumeWhenQuietAfterReconnect=false;
        generation.incrementAndGet(); mute(); locks.release();
        audio.abandonAudioFocusRequest(focus);
        RelayHandoff current = handoff;
        if (current != null) current.request(intent);
        settings.controlsSource(phase == RelayState.Phase.PAUSED ? "paused" : "phone");
        mediaSession.setActive(phase == RelayState.Phase.PAUSED);
        publish(phase, title, "Returning audio control to your phone. Choose Computer to listen again.");
        foreground(false);
        if (!running || socket == null) main.postDelayed(finishPausedService, 2000);
    }
    private void controlStatus(Socket connection, RelayHandoff control, int value) {
        boolean resumeOffer = control.acceptStatus(value);
        if (socket == connection && handoff == control && control.computerOutput()) mute();
        main.post(() -> {
            if (socket != connection || handoff != control) return;
            outputControlSupported = control.outputSupported();
            // Only an updated Mac (it links volume keys) can be asked to allow media control.
            mediaControlHint = computerVolumeLinked && control.supported() && !control.playerControl()
                    ? "On your Mac, open PairIt and choose Allow next to Headphone buttons so earphones can pause Mac videos." : "";
            if (userStopped) { if (control.released()) finishStop(); return; }
            if (!control.outputSupported() && pendingOutputOnConnect == 1) {
                pendingOutputOnConnect = -1; computerOutputSelected = false;
                park(RelayHandoff.Intent.PAUSE, RelayState.Phase.PAUSED, "Computer output unavailable");
                return;
            }
            if (control.pendingOutput() < 0 && (pendingOutputOnConnect == 0 && !control.computerOutputConfirmed()
                    || pendingOutputOnConnect == 1 && control.computerOutputConfirmed())) pendingOutputOnConnect = -1;
            if (control.computerOutput()) {
                if (!computerOutputSelected || focusGranted || requestedMac
                        && control.computerOutputConfirmed() && state.title.equals("Switching to computer")) holdForComputerOutput();
                return;
            }
            // The authenticated desktop has accepted LISTEN. Silence is not a failed connection.
            if (control.supported() && control.readyForAudio() && canPlay() && !listeningFeedback.established()) {
                listeningFeedback.audioStarted();
                acknowledgeConnection(connections,0);
            }
            boolean returningFromComputer = computerOutputSelected;
            computerOutputSelected = false;
            if (returningFromComputer && requestedMac) {
                startListening(false);
                return;
            }
            if (returningFromComputer) mediaSession.setActive(state.phase == RelayState.Phase.PAUSED);
            if (!requestedMac && control.held()) {
                String detail = control.playerPaused() ? "Computer player paused. Choose Computer to return."
                        : (!settings.platform().equals("windows") && !settings.platform().equals("linux")) ? "Mac output is held. Media may still be playing silently. Choose Computer to return."
                        : "Relay is held. Pause unsupported computer players yourself; choose Computer to return.";
                if (!state.detail.equals(detail)) publish(state.phase, state.title, detail);
            }
            if ((resumeOffer && control.isCurrentOffer(value) || resumeWhenQuietAfterReconnect && control.held() && !audio.isMusicActive())
                    && (state.phase == RelayState.Phase.PHONE || state.phase == RelayState.Phase.PAUSED && control.intent() == RelayHandoff.Intent.PAUSE && resumeOffer)
                    && audio.getMode() == AudioManager.MODE_NORMAL && PhoneAudioSession.availableTo(this)
                    && selectedOutput == settings.output()) {
                AudioDeviceInfo route = selectedOutput.find(audio,settings.outputDeviceId());
                if (route != null && route.getId() == selectedDeviceId) startListening(false);
            }
        });
    }
    private void desktopPlaybackRequest(Socket connection,RelayHandoff control,int value){
        main.post(()->{if(socket!=connection||handoff!=control||userStopped)return;
            int desktopRequest=control.desktopRequest(value);
            if(desktopRequest==2){settings.groupGuest(false);requestStop();return;}
            if(desktopRequest==0){park(RelayHandoff.Intent.PAUSE,RelayState.Phase.PAUSED,"Listening paused");return;}
            if(desktopRequest==1) {
                if(audio.getMode()==AudioManager.MODE_NORMAL && PhoneAudioSession.availableTo(this))startListening(true);
                else park(RelayHandoff.Intent.OUTPUT,RelayState.Phase.PHONE,"Finish the current phone session, then resume");
                return;
            }
        });
    }
    private int phoneVolumeLevel() {
        return PhoneVolume.level(audio.getStreamVolume(AudioManager.STREAM_MUSIC), audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC));
    }
    /** A computer volume key or slider. The phone's own volume moves; nothing is attenuated. */
    private void setPhoneVolume(int level) {
        int max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC);
        int current = audio.getStreamVolume(AudioManager.STREAM_MUSIC);
        int index = PhoneVolume.index(level, current, max);
        if (index == current) return;
        try { audio.setStreamVolume(AudioManager.STREAM_MUSIC, index, 0); }
        catch (SecurityException error) { Log.w(TAG, "Phone volume change refused"); }
    }
    /** Paused on the computer while this phone is still listening: start the computer's player. */
    private boolean playComputerWhilePaused() {
        if (!requestedMac || !computerPlayerPaused || (state.phase != RelayState.Phase.PLAYING && state.phase != RelayState.Phase.BUFFERING)) return false;
        sendMediaKey("PLAY"); return true;
    }
    private void sendMediaKey(String key) {
        if (socket == null || handoff == null) return;
        mediaCommands.add("STATS MEDIA1 " + key + "\n");
        synchronized (controlWake) { controlWake.notifyAll(); }
    }
    static boolean awaitingPlaybackAcknowledgment(){RelayService s=liveInstance;return s!=null&&s.handoff!=null&&!s.handoff.acknowledged();}
    private static final class OutputUnavailable extends IOException {
        OutputUnavailable(String message) { super(message); }
    }
    private AudioTrack newTrack(int rate) throws IOException {
        AudioDeviceInfo device = selectedOutput.find(audio,settings.outputDeviceId());
        if (device == null) throw new OutputUnavailable("Selected output disconnected");
        selectedDeviceId = device.getId();
        headphoneName = OutputRoute.name(device);
        profileReady = false;
        int minimum = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT);
        if (minimum <= 0) throw new OutputUnavailable("Unsupported sample rate");
        AudioTrack track = new AudioTrack.Builder().setAudioAttributes(attributes)
                .setAudioFormat(new AudioFormat.Builder().setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                .setTransferMode(AudioTrack.MODE_STREAM).setBufferSizeInBytes(Math.max(minimum * 2, rate * 4 * PlaybackBuffer.TARGET_MS / 1000)).build();
        if (track.getState() != AudioTrack.STATE_INITIALIZED) { track.release(); throw new OutputUnavailable("Couldn’t open audio output"); }
        track.setVolume(0);
        if (!track.setPreferredDevice(device)) { track.release(); throw new OutputUnavailable("Selected output is unavailable"); }
        activeTrack = track;
        int requestedFrames = rate * PlaybackBuffer.TARGET_MS / 1000;
        if (interactiveMode) InteractivePlayback.configure(track, minimum);
        else track.setBufferSizeInFrames(requestedFrames);
        if (!interactiveMode && Build.VERSION.SDK_INT >= 31) track.setStartThresholdInFrames(Math.min(requestedFrames, track.getBufferSizeInFrames()));
        Log.i(TAG, "TRACK rate=" + rate + " size=" + track.getBufferSizeInFrames() + " capacity=" + track.getBufferCapacityInFrames() + " threshold=" + PlaybackBuffer.startThreshold(track));
        track.addOnRoutingChangedListener(router -> {
            if (activeTrack == track && track.getPlayState() == AudioTrack.PLAYSTATE_PLAYING
                    && !selectedOutput.confirmed(router, selectedDeviceId)) {
                mute();
                if (profileReady || !OutputRoute.actual(router).isEmpty()) loseOutput();
            }
        }, main);
        return track;
    }

    private void receive() {
        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO);
        int failures = 0;
        try { while (running) {
            if(outputRecovery.waiting()){LockSupport.parkNanos(1_000_000_000L);continue;}
            if (!requestedMac && !reconnectable()) { LockSupport.parkNanos(100_000_000L); continue; }
            if (!networkAvailable) { LockSupport.parkNanos(1_000_000_000L); continue; }
            final int attemptNetwork=networkRevision;
            String host = settings.connectionHost(discovery.host);
            try (Socket connection = RelayConnection.open(host, settings, false)) {
                if (!running || userStopped || attemptNetwork!=networkRevision || !networkAvailable) continue;
                resumeWhenQuietAfterReconnect=connections>0 && !requestedMac && parkedIntent==RelayHandoff.Intent.PHONE;
                socket = connection; connections++; profileReady = false;
                lastTrafficAt=SystemClock.elapsedRealtime();
                main.post(()->{if(socket==connection&&requestedMac&&focusGranted){locks.acquire(useWifi);foreground(true);}});
                handoff = new RelayHandoff(requestedMac ? RelayHandoff.Intent.LISTEN : parkedIntent);
                int pendingOutput = pendingOutputOnConnect;
                if (pendingOutput >= 0) handoff.requestOutput(pendingOutput == 1);
                interactiveMode = settings.interactive();
                alignmentReport = "STATS ALIGN1 320 -1\n"; groupTimingStatus = "";
                startControl(connection);
                playSession(connection);
                failures = 0;
            } catch (Exception error) {
                if (!running) break;
                Log.w(TAG, "Connection interrupted: " + error.getClass().getSimpleName());
                if (error instanceof PcmInbox.GroupFull) {
                    main.post(() -> pausePlayback(RelayState.Phase.ERROR, "Listening group is full", "Four phones are already connected. Disconnect one phone, then tap Connect again."));
                    break;
                } else if (ConnectionHealth.identityRejected(error)) {
                    main.post(() -> pausePlayback(RelayState.Phase.ERROR, "Pair with your computer again", "Open pairing in the desktop companion and enter its new code in Connection settings."));
                    break;
                } else if (error instanceof OutputUnavailable) {
                    main.post(this::loseOutput);
                } else if (outputRecovery.waiting()) {
                    // Socket closed deliberately: the desktop releases this listener.
                } else if (requestedMac || reconnectable()) {
                    failures++;
                    if(!reconnectable()) {
                        main.post(()->pausePlayback(RelayState.Phase.ERROR,"Computer unavailable","Keep both devices on the same Wi-Fi, then tap Connect."));break;
                    }
                    main.post(()->{if(liveInstance==this&&running&&socket==null){locks.release();foreground(false);}});
                    publish(requestedMac?RelayState.Phase.RECONNECTING:RelayState.Phase.PHONE, "Reconnecting to your computer", "Check the local network and desktop companion. Audio returns after a secure connection.");
                }
            } finally {
                main.post(this::endListeningFeedback);
                socket = null; handoff = null;
                outputControlSupported = false; computerOutputSelected = false;
                if (!requestedMac && !reconnectable()) {
                    main.post(() -> {
                        if (!requestedMac && socket == null && !reconnectable()) {
                            if (!userStopped && state.phase != RelayState.Phase.ERROR) publish(RelayState.Phase.ERROR, "Computer disconnected", "Keep both devices on the same Wi-Fi and open PairIt on your computer, then reconnect.");
                            stopSelf();
                        }
                    });
                    break;
                }
            }
            long until = SystemClock.elapsedRealtime() + Math.min(5000, 500L << Math.min(failures, 3));
            while (running && (requestedMac || reconnectable()) && SystemClock.elapsedRealtime() < until && attemptNetwork==networkRevision) LockSupport.parkNanos(50_000_000L);
        } } finally { PhoneAudioSession.release(this); }
    }

    private void playSession(Socket connection) throws Exception {
        computerVolume = ""; computerPlayerPaused = false;
        groupTimingStatus = ""; mediaControlHint = ""; computerVolumeLinked = false; mediaCommands.clear();
        PcmInbox inbox = new PcmInbox();
        RelayHandoff control = handoff;
        inbox.onHeartbeat = () -> lastTrafficAt=SystemClock.elapsedRealtime();
        inbox.onControlStatus = value -> controlStatus(connection, control, value);
        inbox.onDesktopRequest = value -> desktopPlaybackRequest(connection,control,value);
        inbox.onComputerVolume = value -> main.post(() -> {
            if (socket != connection) return;
            computerVolumeLinked = (value & 0x20000) != 0;
            computerVolume = (value & 0x10000) != 0 ? "Computer muted"
                    : (value & 0x20000) != 0 ? "Computer volume keys linked"
                    : "Computer volume · " + Math.round((value & 0x3FF) / 10f) + "%";
        });
        inbox.onPlayerState = playing -> main.post(() -> {
            if (socket != connection || computerPlayerPaused == ((playing & 1) == 0)) return;
            computerPlayerPaused = (playing & 1) == 0;
            updateMediaState(); getSystemService(NotificationManager.class).notify(1, notification());
        });
        inbox.onVolumeSet = level -> main.post(() -> { if (socket == connection) setPhoneVolume(level); });
        InputStream input = connection.getInputStream();
        Thread reader = new Thread(() -> inbox.read(input), "relay-network"); reader.start();
        AudioTrack track = null;
        int seenOutputRevision = outputRevision;
        int rate = 0, seenGeneration = -1, underruns = 0, primedFrames = 0, leadFrames = 0;
        int cushionMs = PlayoutTiming.CUSHION_MS, minimumCushionMs = cushionMs, outputDelayMs = -1;
        alignmentReport = "STATS ALIGN1 " + minimumCushionMs + " -1\n";
        InteractivePlayback interactive = interactiveMode ? new InteractivePlayback() : null;
        boolean learning = interactive != null;
        long previousSequence = -1, writtenFrames = 0, lastReport = 0, started = 0;
        boolean playing = false, routeConfigured = false;
        PlaybackBuffer policy = new PlaybackBuffer();
        PlayoutTiming timing = new PlayoutTiming();
        VideoTiming videoTiming = new VideoTiming();
        PcmRamp ramp = new PcmRamp();
        PcmInbox.Packet firstPacket = null;
        try {
            while (running && socket == connection) {
              try {
                if (seenOutputRevision != outputRevision) {
                    if (track != null) { activeTrack = null; releaseTrack(track); track = null; }
                    seenOutputRevision = outputRevision; inbox.clear();
                    interactiveMode = settings.interactive();
                    interactive = interactiveMode ? new InteractivePlayback() : null;
                    learning = interactive != null;
                    cushionMs = minimumCushionMs = PlayoutTiming.CUSHION_MS;
                    timing = new PlayoutTiming();
                    outputDelayMs = -1; alignmentReport = "STATS ALIGN1 " + minimumCushionMs + " -1\n";
                }
                if (!canPlay()) {
                    groupTimingStatus = "";
                    if (track != null) { activeTrack = null; releaseTrack(track); track = null; }
                    main.post(() -> { if (!canPlay()) PhoneAudioSession.release(this); });
                    inbox.next(); inbox.clear(); // Parse clocks, discard PCM; no silent AudioTrack.
                    continue;
                }
                if (interactiveMode && interactive != null && interactive.fallback() && track != null) {
                    interactiveMode = false; learning = false; cushionMs = minimumCushionMs = PlayoutTiming.CUSHION_MS;
                    alignmentReport = "STATS ALIGN1 " + minimumCushionMs + " " + outputDelayMs + "\n";
                    int previousRecoveries = timing.recoveries;
                    timing = new PlayoutTiming(); timing.recoveries = previousRecoveries;
                    track.setVolume(0); track.pause(); track.flush();
                    AudioDeviceInfo fallbackRoute = selectedOutput.find(audio,settings.outputDeviceId());
                    if (fallbackRoute == null) throw new OutputUnavailable("Selected output disconnected");
                    policy = new PlaybackBuffer(); policy.configure(track, fallbackRoute, rate); routeConfigured = true;
                    profileReady = false; generation.incrementAndGet();
                    publish(RelayState.Phase.BUFFERING, "Using Reliable for this session", "The connection needs a larger audio buffer.");
                }
                PcmInbox.Packet packet = inbox.next();
                if (seenOutputRevision != outputRevision) continue;
                if(packet!=null)lastTrafficAt=SystemClock.elapsedRealtime();
                if (packet == null) {
                    if (learning && interactive != null) interactive.timedOut();
                    if (canPlay() && track == null && state.phase != RelayState.Phase.BUFFERING)
                        publish(RelayState.Phase.BUFFERING, "Waiting for computer audio", "Play a video or music on your computer.");
                    continue;
                }
                if (!canPlay() || !control.readyForAudio()) { inbox.clear(); continue; }
                if (track == null || packet.rate != rate) {
                    if (track != null) { activeTrack = null; releaseTrack(track); }
                    rate = packet.rate;
                    outputDelayMs = -1; alignmentReport = "STATS ALIGN1 " + minimumCushionMs + " -1\n";
                    try { track = newTrack(rate); }
                    catch (OutputUnavailable unavailable) {
                        requestedMac = false; main.post(this::loseOutput); continue;
                    }
                    policy = new PlaybackBuffer(); routeConfigured = false; seenGeneration = -1;
                    if (interactive != null) { interactive.resetLearning(); learning = !interactive.fallback(); }
                    if (learning) leadFrames = prepareInteractiveTrack(track, rate);
                    if (interactive != null && leadFrames * 1000.0 / rate > PlayoutTiming.CUSHION_MS) {
                        interactive.useReliable(); continue;
                    }
                }
                if (seenGeneration != generation.get()) {
                    track.pause(); track.flush(); track.setPlaybackRate(rate);
                    writtenFrames = 0; playing = false; primedFrames = 0; firstPacket = null;
                    timing.reset(); videoTiming.reset(); ramp.restart(rate); previousSequence = -1;
                    seenGeneration = generation.get(); inbox.clear(); continue;
                }
                if (!canPlay()) continue; // Keep draining, never replay phone-mode audio.
                if (inbox.clockSamples < 3) { inbox.clear(); continue; }
                if (learning) {
                    if (!interactive.observe(packet, leadFrames)) continue;
                    if (interactive.fallback()) { inbox.clear(); continue; }
                    learning = false; interactiveMode = !interactive.fallback();
                    cushionMs = minimumCushionMs = interactive.cushionMs(); timing = new PlayoutTiming(cushionMs);
                    alignmentReport = "STATS ALIGN1 " + minimumCushionMs + " " + outputDelayMs + "\n";
                    // Learning packets are never played. The next packet is a fresh epoch anchor.
                    inbox.clear(); previousSequence = -1; continue;
                }
                groupTimingStatus = inbox.presentationListeners < 2 ? "" : inbox.presentationCapable < inbox.presentationListeners
                        ? "Update other phones for shared timing" : inbox.presentationTargetMs == 0 || outputDelayMs < 0
                        ? "Learning shared timing…" : "Shared timing adjusted";
                int baseCushion = PresentationTiming.renderDelay(minimumCushionMs, outputDelayMs, inbox.presentationTargetMs);
                int desiredCushion = ("linux".equals(settings.platform()) || "windows".equals(settings.platform()))
                        ? PresentationTiming.correctedDelay(baseCushion, settings.profileCorrection(activeProfileKey)) : baseCushion;
                int correctedTarget = inbox.presentationTargetMs + desiredCushion - baseCushion;
                if (desiredCushion != cushionMs) {
                    cushionMs = desiredCushion;
                    int previousRecoveries = timing.recoveries;
                    timing = new PlayoutTiming(cushionMs); timing.recoveries = previousRecoveries;
                    generation.incrementAndGet();
                    publish(RelayState.Phase.BUFFERING, "Aligning listeners", "Keeping the connection while matching output timing.");
                    continue;
                }
                int currentGeneration = seenGeneration;
                boolean discontinuity = previousSequence >= 0 && packet.sequence != ((previousSequence + 1) & 0xffffffffL);
                previousSequence = packet.sequence;
                if (playing && (discontinuity || track.getUnderrunCount() > underruns)) {
                    timing.recoveries++;
                    if (interactiveMode && interactive != null) {
                        interactive.recovery();
                    }
                    generation.incrementAndGet();
                    publish(RelayState.Phase.BUFFERING, "Restoring smooth playback", "Refreshing audio after a connection interruption.");
                    continue;
                }
                if (!playing && firstPacket == null) {
                    firstPacket = packet;
                    publish(RelayState.Phase.BUFFERING, "Getting audio ready", "Preparing " + headphoneName + ".");
                }
                ramp.apply(packet.pcm);
                int offset = 0;
                while (offset < packet.pcm.length && canPlay() && socket == connection && generation.get() == currentGeneration) {
                    int count = track.write(packet.pcm, offset, packet.pcm.length - offset, AudioTrack.WRITE_NON_BLOCKING);
                    if (count < 0) throw new OutputUnavailable("Audio output stopped (" + count + ")");
                    offset += count; writtenFrames += count / 4; primedFrames += count / 4;
                    if (!playing && (count == 0 || primedFrames >= Math.min(track.getBufferSizeInFrames(), (interactiveMode ? leadFrames : rate * PlaybackBuffer.TARGET_MS / 1000)))) {
                        int ready = timing.start(inbox, firstPacket, inbox.presentationTargetMs > 0 && outputDelayMs >= 0,
                                () -> canPlay() && generation.get() == currentGeneration);
                        if (ready != PlayoutTiming.READY) {
                            Log.i(TAG, "PREFILL restart reason=" + ready + " primedFrames=" + primedFrames + " ageMs=" + (System.nanoTime() - firstPacket.receivedAt) / 1e6);
                            if (ready == PlayoutTiming.TOO_LATE && interactiveMode) { timing.recoveries++; interactive.recovery(); }
                            generation.incrementAndGet(); break;
                        }
                        track.setVolume(0); track.play(); playing = true; started = SystemClock.elapsedRealtime();
                        underruns = track.getUnderrunCount();
                    }
                    if (count == 0) LockSupport.parkNanos(2_000_000L);
                }
                if (!playing || generation.get() != currentGeneration) continue;
                java.util.List<AudioDeviceInfo> actualRoutes = OutputRoute.actual(track);
                if (!selectedOutput.confirmed(actualRoutes, selectedDeviceId)) {
                    track.setVolume(0);
                    if (!actualRoutes.isEmpty() || SystemClock.elapsedRealtime() - started > 2000) {
                        requestedMac = false; main.post(this::loseOutput); continue;
                    }
                    continue;
                }
                AudioDeviceInfo route = actualRoutes.get(0);
                headphoneName = OutputRoute.name(route);
                routeKey = route.getType() + ":" + headphoneName;
                activeProfileKey = RelaySettings.profileKey(sessionPin, sessionOverride, routeKey, interactiveMode);
                timingProfileKey = activeProfileKey; profileReady = true;
                if (!interactiveMode) {
                    // Reliable keeps the existing live 120 ms track policy, unchanged.
                    if (policy.configure(track, route, rate)) {
                        if (routeConfigured) timing.recoveries++;
                        routeConfigured = true;
                        outputDelayMs = -1; alignmentReport = "STATS ALIGN1 " + minimumCushionMs + " -1\n";
                        generation.incrementAndGet(); continue;
                    }
                } else if (track.getBufferSizeInFrames() != leadFrames) {
                    // A routed OS buffer change requires a new learning epoch; never shrink a live target.
                    track.setVolume(0); track.pause(); track.flush();
                    leadFrames = prepareInteractiveTrack(track, rate);
                    interactive.resetLearning(); learning = true; profileReady = false;
                    generation.incrementAndGet(); continue;
                }
                if (canPlay()) track.setVolume(1);
                if (state.phase != RelayState.Phase.PLAYING) publish(RelayState.Phase.PLAYING,
                        "Listening to " + settings.computerName(), headphoneName + " · "
                        + (interactiveMode ? "Adaptive latency" : (settings.interactive() ? "Reliable (session fallback)" : "Reliable")));
                Integer videoDelay = videoTiming.observe(track, inbox, packet, writtenFrames, started);
                if (videoDelay != null && canPlay() && generation.get() == currentGeneration) {
                    if (outputDelayMs < 0) {
                        outputDelayMs = PresentationTiming.outputDelay(videoDelay, cushionMs);
                        alignmentReport = "STATS ALIGN1 " + minimumCushionMs + " " + outputDelayMs + "\n";
                    }
                    settings.profileEstimate(activeProfileKey, videoDelay);
                    Log.i(TAG, "VIDEO_TIMING estimateMs=" + videoDelay + " correctionMs=" + settings.profileCorrection(activeProfileKey));
                }
                long now = SystemClock.elapsedRealtime();
                // Let route startup settle before correcting tiny clock differences.
                if (now - started > 3000 && timing.correctionDue()) {
                    int corrected = inbox.presentationTargetMs > 0 && outputDelayMs >= 0
                            ? timing.correctedPresentationRate(videoTiming.presentationDelay(track, inbox, packet, writtenFrames), correctedTarget, rate)
                            : timing.correctedRate(packet);
                    if (corrected != 0) track.setPlaybackRate(corrected);
                }
                if (now - lastReport >= 1000) {
                    AudioTimestamp stamp = new AudioTimestamp();
                    String backlog = "unavailable";
                    if (track.getTimestamp(stamp)) {
                        double presented = stamp.framePosition + (System.nanoTime() - stamp.nanoTime) * rate / 1e9;
                        backlog = String.format(Locale.US, "%.1f ms", (writtenFrames - presented) * 1000.0 / rate);
                    }
                    diagnostics = String.format(Locale.US, "Transport: %s\nRoute: %s\nSample rate: %d Hz\nReceived: %.1f s\nSender gaps: %d\nUnderruns: %d\nAutomatic recoveries: %d\nManual refreshes: %d\nConnections: %d\nQueued packets: %d\nDiscarded packets: %d\nArrival variation: %.1f ms\nClock RTT: %.1f ms\nCapture age: %.1f ms\nOutput backlog estimate: %s\nTrack buffer: %d frames\nPlayback rate: %d Hz\nNetwork prefill: %d ms\n\nSoftware counters; not an acoustic latency measurement.",
                            "Local network · TLS", headphoneName, rate, inbox.framesReceived / (double)rate,
                            inbox.sequenceGaps, track.getUnderrunCount(), timing.recoveries, manualResyncs, connections,
                            inbox.queuedPackets(), inbox.discarded, inbox.arrivalVariationMillis(packet), inbox.clockRoundTripMillis(), (System.nanoTime() - packet.capturedAt - inbox.clockOffset()) / 1e6, backlog,
                            track.getBufferSizeInFrames(), track.getPlaybackRate(), cushionMs);
                    Log.i(TAG, diagnostics.replace('\n', ' ')); lastReport = now;
                }
              } catch (OutputUnavailable | IllegalStateException outputError) {
                requestedMac = false; mute(); main.post(this::loseOutput);
                // Main thread releases this listener and waits for a safe external output.
              }
            }
        } finally {
            groupTimingStatus = "";
            activeTrack = null;
            releaseTrack(track);
            try { connection.close(); } finally { reader.interrupt(); reader.join(1500); }
        }
    }
    private static void releaseTrack(AudioTrack track) {
        if (track == null) return;
        try { track.setVolume(0); track.pause(); track.flush(); } catch (IllegalStateException ignored) { }
        finally { track.release(); }
    }

    private void startControl(Socket connection) {
        RelayHandoff control = handoff;
        new Thread(() -> {
            int sentSync = -1, pings = 0, sentVolume = -1;
            String sentAlignment = "";
            try {
                OutputStream output = connection.getOutputStream();
                // STATS lines are ignored by older desktops; VOLUME2/CONTROLS2 are opt-in extensions.
                output.write(("HELLO " + settings.installationId() + "\nNAME1 " + PhoneDisplayName.encoded(this) + "\nSTATS CONTROLS1\nSTATS VOLUME1\nSTATS VOLUME2\nSTATS CONTROLS2\nSTATS PLAYER1\n").getBytes(StandardCharsets.US_ASCII)); output.flush();
                while (running && socket == connection) {
                    int sync = profileReady ? settings.profileCompensation(activeProfileKey) : -1;
                    String message = control.nextCommand() + "PING " + System.nanoTime() + "\n";
                    if (canPlay()) message += "STATS " + state.phase + " " + diagnostics.replace('\n', ' ') + "\n";
                    String alignment = alignmentReport;
                    if (!alignment.equals(sentAlignment)) { message = alignment + message; sentAlignment = alignment; }
                    if (sync >= 0 && sync != sentSync) { message = "SYNC " + sync + "\n" + message; sentSync = sync; }
                    for (String media; (media = mediaCommands.poll()) != null; ) message = media + message;
                    int volume = phoneVolumeLevel();
                    if (volume != sentVolume) { message = "STATS PVOL1 " + volume + "\n" + message; sentVolume = volume; }
                    output.write(message.getBytes(StandardCharsets.UTF_8)); output.flush();
                    long wait = ++pings < 10 || !canPlay() && !control.acknowledged() ? 250 : 1000;
                    synchronized (controlWake) { if (phoneVolumeLevel() == sentVolume && mediaCommands.isEmpty()) controlWake.wait(wait); }
                }
            } catch (IOException | InterruptedException ignored) { }
        }, "relay-control").start();
    }
    private Notification notification() {
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class), PendingIntent.FLAG_IMMUTABLE);
        NotificationPlayback controls = new NotificationPlayback(state, requestedMac, computerOutputSelected);
        boolean paused = !requestedMac || computerOutputSelected;
        PendingIntent playback = PendingIntent.getForegroundService(this, 3, new Intent(this, RelayService.class).setAction(controls.action), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        PendingIntent phone = PendingIntent.getForegroundService(this, 1, new Intent(this, RelayService.class).setAction("OUTPUT_COMPUTER"), PendingIntent.FLAG_IMMUTABLE);
        PendingIntent stop = PendingIntent.getService(this, 2, new Intent(this, RelayService.class).setAction("STOP"), PendingIntent.FLAG_IMMUTABLE);
        return PlaybackNotification.build(this, settings.computerName(),
                controls.status, controls.label,
                paused, open, playback, outputControlSupported && socket != null ? phone : null, stop);
    }
    @android.annotation.SuppressLint("UnspecifiedImmutableFlag")
    private void setLegacyMediaReceiver() {
        // Pre-31 MediaSession supplies EXTRA_KEY_EVENT through a fill-in intent.
        mediaSession.setMediaButtonReceiver(PendingIntent.getBroadcast(this, 24,
                new Intent(this, RelayControlsReceiver.class).setAction(Intent.ACTION_MEDIA_BUTTON), 0));
    }
    @android.annotation.SuppressLint("NotificationPermission")
    static void restoreControlsNotification(Context context) {
        if (liveInstance != null) return;
        RelaySettings saved = new RelaySettings(context);
        if (!saved.paired() || saved.controlsSource().isEmpty()) return;
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel("relay", context.getString(R.string.app_name), NotificationManager.IMPORTANCE_LOW));
        NotificationPlayback controls = new NotificationPlayback(state, false, false);
        PendingIntent computer = PendingIntent.getForegroundService(context, 11, new Intent(context, RelayService.class).setAction("PLAY"), PendingIntent.FLAG_IMMUTABLE);
        PendingIntent end = PendingIntent.getBroadcast(context, 12, new Intent(context, RelayControlsReceiver.class).setAction("DISCONNECT"), PendingIntent.FLAG_IMMUTABLE);
        PendingIntent open = PendingIntent.getActivity(context, 0, new Intent(context, MainActivity.class), PendingIntent.FLAG_IMMUTABLE);
        manager.notify(1, new Notification.Builder(context, "relay").setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(saved.computerName())
                .setContentText(controls.status)
                .setContentIntent(open).setOnlyAlertOnce(true).setOngoing(true)
                .addAction(new Notification.Action.Builder(null, controls.label, computer).build())
                .addAction(new Notification.Action.Builder(null, "Disconnect", end).build()).build());
    }
    @android.annotation.SuppressLint("NotificationPermission")
    private void publish(RelayState.Phase phase, String title, String detail) {
        if ((phase == RelayState.Phase.PLAYING || phase == RelayState.Phase.BUFFERING || phase == RelayState.Phase.RECONNECTING) && !canPlay()) return;
        state = new RelayState(phase, title, detail);
        Log.i(TAG, "STATE " + phase + " " + title);
        main.post(() -> {
            if(phase==RelayState.Phase.RECONNECTING||phase==RelayState.Phase.ERROR||phase==RelayState.Phase.HEADPHONES)endListeningFeedback();
            else if(phase==RelayState.Phase.PLAYING&&state.phase==RelayState.Phase.PLAYING){automaticOutputAttempts=0;listeningFeedback.audioStarted();acknowledgeConnection(connections,0);}
            updateMediaState();if (mediaSession != null && liveInstance == this) getSystemService(NotificationManager.class).notify(1, notification()); });
    }
    private void endListeningFeedback() {
        if(listeningFeedback.disconnected())ConnectionChime.disconnected(this,settings);
    }
    private void acknowledgeConnection(int connection, int attempt) {
        if(liveInstance!=this||userStopped||connections!=connection||(state.phase!=RelayState.Phase.PLAYING && (handoff==null||!handoff.supported()||!handoff.readyForAudio()))||!canPlay())return;
        ConnectionChime.connected(this,settings);
        // A Bluetooth route can settle after the desktop accepts the listening session.
        if(attempt<4)main.postDelayed(()->acknowledgeConnection(connection,attempt+1),500);
    }
    private void mediaAction(String action) {
        try { startService(new Intent(this,RelayService.class).setAction(action)); }
        catch(IllegalStateException | SecurityException error){stopSelf();}
    }
    static void stopFromUi(Context context) {
        new RelaySettings(context).groupGuest(false);
        RelayService current = liveInstance;
        if (current != null) current.requestStop();
        else {
            new RelaySettings(context).outputRecovery(false);
            new RelaySettings(context).controlsSource("");
            context.getSystemService(NotificationManager.class).cancel(1);
            state = new RelayState(RelayState.Phase.IDLE, "Ready when you are", "Choose Computer to listen.");
            context.stopService(new Intent(context, RelayService.class));
        }
    }
    private void requestStop() {
        groupTimingStatus = "";
        cancelOutputRecovery();
        endListeningFeedback();
        ++startTicket; settings.controlsSource(""); main.removeCallbacks(finishPausedService);
        pendingOutputOnConnect = -1;
        userStopped = true; requestedMac = false; focusGranted = false; profileReady = false;
        generation.incrementAndGet(); mute(); locks.release(); audio.abandonAudioFocusRequest(focus);
        RelayHandoff control = handoff;
        if (control != null) {
            control.request(RelayHandoff.Intent.RELEASE);
            main.postDelayed(this::finishStop, 1800);
        } else finishStop();
    }
    private void finishStop() { if (!userStopped) return; running = false; closeConnection(); stopSelf(); }
    private void updateMediaState() {
        if(mediaSession==null)return;
        int playback=state.phase==RelayState.Phase.PLAYING&&computerPlayerPaused?PlaybackState.STATE_PAUSED:
                state.phase==RelayState.Phase.PLAYING?PlaybackState.STATE_PLAYING:
                state.phase==RelayState.Phase.CONNECTING || state.phase==RelayState.Phase.RECONNECTING?PlaybackState.STATE_CONNECTING:
                state.phase==RelayState.Phase.BUFFERING?PlaybackState.STATE_BUFFERING:
                state.phase==RelayState.Phase.ERROR?PlaybackState.STATE_ERROR:
                state.phase==RelayState.Phase.IDLE?PlaybackState.STATE_STOPPED:PlaybackState.STATE_PAUSED;
        mediaSession.setPlaybackState(new PlaybackState.Builder().setActions(PlaybackState.ACTION_PLAY|PlaybackState.ACTION_PAUSE|PlaybackState.ACTION_STOP|PlaybackState.ACTION_PLAY_PAUSE|PlaybackState.ACTION_SKIP_TO_NEXT|PlaybackState.ACTION_SKIP_TO_PREVIOUS)
                .setState(playback,PlaybackState.PLAYBACK_POSITION_UNKNOWN,playback==PlaybackState.STATE_PLAYING?1:0,SystemClock.elapsedRealtime()).build());
    }
    private int prepareInteractiveTrack(AudioTrack track, int rate) throws IOException {
        int minimum = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT);
        byte[] silence = new byte[Math.max(4, Math.min(track.getBufferSizeInFrames(), 2048) * 4)];
        track.setVolume(0); track.play();
        long deadline = System.nanoTime() + 2_000_000_000L;
        while (canPlay() && System.nanoTime() < deadline) {
            if (selectedOutput.confirmed(track, selectedDeviceId)) {
                InteractivePlayback.configure(track, minimum);
                int lead = Math.max((minimum + 3) / 4, track.getBufferSizeInFrames());
                track.pause(); track.flush(); return lead;
            }
            if (!OutputRoute.actual(track).isEmpty()) throw new OutputUnavailable("Output does not match your selection");
            if (track.write(silence, 0, silence.length, AudioTrack.WRITE_NON_BLOCKING) < 0) throw new OutputUnavailable("Output stopped");
            LockSupport.parkNanos(2_000_000L);
        }
        throw new OutputUnavailable("Could not confirm the selected output");
    }
    private void closeConnection() {
        Socket current = socket; socket = null; generation.incrementAndGet();
        // SSLSocket.close can emit TLS close_notify; never run it on the UI thread.
        if (current != null) new Thread(() -> {
            // Closing also releases legacy desktops. Do not wait on a control write to send ACTIVE 0.
            try { current.close(); } catch (IOException ignored) { }
        }, "relay-disconnect").start();
    }
    @Override public void onDestroy() {
        endListeningFeedback();
        if (liveInstance == this) liveInstance = null;
        running = false; requestedMac = false; focusGranted = false; outputControlSupported = false; computerOutputSelected = false;
        generation.incrementAndGet(); mute(); closeConnection();
        if (worker != null) worker.interrupt();
        try { connectivity.unregisterNetworkCallback(networkCallback); } catch(IllegalArgumentException ignored) { }
        main.removeCallbacksAndMessages(null); locks.release(); discovery.stop();
        audio.unregisterAudioDeviceCallback(devices); unregisterReceiver(noisy);
        if (volumeObserver != null) getContentResolver().unregisterContentObserver(volumeObserver); audio.abandonAudioFocusRequest(focus);
        if (worker == null || !worker.isAlive()) PhoneAudioSession.release(this);
        ++startTicket;
        if (userStopped || (state.phase != RelayState.Phase.ERROR && state.phase != RelayState.Phase.HEADPHONES && state.phase != RelayState.Phase.PHONE && state.phase != RelayState.Phase.PAUSED))
            state = new RelayState(RelayState.Phase.IDLE, "Ready when you are", "Choose Computer to listen through your selected output.");
        stopForeground(STOP_FOREGROUND_REMOVE);
        if(mediaSession!=null){mediaSession.setActive(false);mediaSession.release();mediaSession=null;}
        if (!userStopped && !settings.controlsSource().isEmpty()) {
            if ("computer".equals(settings.controlsSource())) settings.controlsSource("paused");
            restoreControlsNotification(this);
        }
        super.onDestroy();
    }
    @Override public IBinder onBind(Intent intent) { return null; }
}
