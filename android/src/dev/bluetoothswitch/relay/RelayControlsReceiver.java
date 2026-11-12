package dev.bluetoothswitch.relay;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.view.KeyEvent;

/** Notification dismissal and resuming a paused relay never select a different source. */
public final class RelayControlsReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        RelaySettings settings = new RelaySettings(context);
        if ("DISCONNECT".equals(intent.getAction())) {
            RelayService.stopFromUi(context);
            return;
        }
        if (!Intent.ACTION_MEDIA_BUTTON.equals(intent.getAction()) || !settings.paired()
                || !"paused".equals(settings.controlsSource())) return;
        KeyEvent event = intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT);
        if (event == null || event.getAction() != KeyEvent.ACTION_DOWN || event.getRepeatCount() != 0) return;
        int key = event.getKeyCode();
        if (key != KeyEvent.KEYCODE_MEDIA_PLAY && key != KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
                && key != KeyEvent.KEYCODE_HEADSETHOOK) return;
        try { context.startForegroundService(new Intent(context, RelayService.class).setAction("MEDIA_RESUME")); }
        catch (IllegalStateException | SecurityException ignored) {
            // Android may require the user to open the app after a forced stop.
        }
    }
}
