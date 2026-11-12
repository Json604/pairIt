package dev.bluetoothswitch.relay;

import android.Manifest;
import android.app.PendingIntent;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

/** Quick Settings controls use the existing playback service, with no second audio path. */
public final class RelayTileService extends TileService {
    private final Handler handler = new Handler(Looper.getMainLooper());
    private boolean listening;
    private final Runnable refresh = new Runnable() {
        @Override public void run() { update(); if (listening) handler.postDelayed(this, 500); }
    };
    @Override public void onStartListening() { listening = true; handler.removeCallbacks(refresh); handler.post(refresh); }
    @Override public void onStopListening() { listening = false; handler.removeCallbacks(refresh); }
    @Override public void onDestroy() { handler.removeCallbacks(refresh); super.onDestroy(); }
    @Override public void onClick() {
        super.onClick();
        if (isLocked()) { unlockAndRun(this::toggle); return; }
        toggle();
    }
    private void toggle() {
        RelaySettings settings = new RelaySettings(this);
        if (PairingInterstitial.isPresenting()) {
            android.widget.Toast.makeText(this, "Close the advertisement, then tap the PairIt tile again.", android.widget.Toast.LENGTH_LONG).show();
            return;
        }
        boolean bluetooth = Build.VERSION.SDK_INT < 31 || checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED;
        // All playback notifications belong to a MediaSession. Android exempts
        // these from POST_NOTIFICATIONS; declining unrelated alerts must not
        // force every source switch to open the app.
        if (!settings.paired() || (settings.output() == OutputRoute.BLUETOOTH && !bluetooth)) { openReceiver(); return; }
        try {
            startForegroundService(new Intent(this, RelayService.class).setAction(RelayService.state.macSelected() ? "USE_PHONE" : "PLAY"));
            handler.postDelayed(this::update, 250);
        } catch (IllegalStateException | SecurityException error) { openReceiver(); }
    }
    private void openReceiver() {
        Intent intent = new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP).putExtra("listen_from_tile", true);
        if (Build.VERSION.SDK_INT >= 34) startActivityAndCollapse(PendingIntent.getActivity(this, 18, intent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
        else openBeforeAndroid14(intent);
    }
    // The PendingIntent overload does not exist before API 34. This method is
    // reached only on older Android versions, where the Intent form is valid.
    @android.annotation.SuppressLint("StartActivityAndCollapseDeprecated")
    private void openBeforeAndroid14(Intent intent) { startActivityAndCollapse(intent); }
    private void update() {
        Tile tile = getQsTile(); if (tile == null) return;
        RelayState state = RelayService.state;
        tile.setLabel(getString(R.string.app_name));
        tile.setSubtitle(state.macSelected() ? "computer audio" : "Tap for computer audio");
        tile.setState(state.macSelected() ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
        if (Build.VERSION.SDK_INT >= 30) tile.setStateDescription(state.macSelected() ? "Computer selected. Tap to use phone audio." : "Tap to listen to the computer.");
        tile.updateTile();
    }
}
