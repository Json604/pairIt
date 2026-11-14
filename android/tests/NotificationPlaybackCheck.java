package dev.bluetoothswitch.relay;

public final class NotificationPlaybackCheck {
    public static void main(String[] args) {
        check(RelayState.Phase.ERROR, "Computer unavailable", false, "Computer unavailable", "Retry", "PLAY");
        check(RelayState.Phase.HEADPHONES, "Waiting for headphones", false, "Waiting for headphones", "Retry", "PLAY");
        check(RelayState.Phase.CONNECTING, "Connecting to PC", true, "Connecting to PC", "Pause", "MEDIA_PAUSE");
        check(RelayState.Phase.RECONNECTING, "Waiting for your computer", true, "Waiting for your computer", "Pause", "MEDIA_PAUSE");
        check(RelayState.Phase.PAUSED, "Listening paused", false, "Audio paused", "Resume", "PLAY");
        check(RelayState.Phase.PLAYING, "Listening", true, "Playing on phone", "Pause", "MEDIA_PAUSE");
        check(RelayState.Phase.IDLE, "Ready", false, "Ready", "Start audio", "PLAY");
        System.out.println("Notification playback states passed");
    }
    private static void check(RelayState.Phase phase,String title,boolean requested,String status,String label,String action) {
        NotificationPlayback model=new NotificationPlayback(new RelayState(phase,title,""),requested,false);
        if(!model.status.equals(status)||!model.label.equals(label)||!model.action.equals(action))
            throw new AssertionError("Incorrect notification for "+phase);
    }
}
