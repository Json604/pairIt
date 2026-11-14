package dev.bluetoothswitch.relay;

/** Describe the actual service state, rather than treating every non-playing state as paused. */
final class NotificationPlayback {
    final String status, label, action;
    NotificationPlayback(RelayState state, boolean requested, boolean computer) {
        boolean listening = requested && !computer;
        action = listening ? "MEDIA_PAUSE" : "PLAY";
        status = computer ? "Playing on computer"
                : state.phase == RelayState.Phase.PLAYING ? "Playing on phone"
                : state.phase == RelayState.Phase.PAUSED ? "Audio paused" : state.title;
        label = computer ? "Listen here" : listening ? "Pause"
                : state.phase == RelayState.Phase.ERROR || state.phase == RelayState.Phase.HEADPHONES ? "Retry"
                : state.phase == RelayState.Phase.PAUSED ? "Resume" : "Start audio";
    }
}
