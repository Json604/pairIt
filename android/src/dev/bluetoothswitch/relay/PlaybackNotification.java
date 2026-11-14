package dev.bluetoothswitch.relay;

import android.app.*;
import android.content.Context;
import android.graphics.drawable.Icon;

/** Listening notification controls. */
final class PlaybackNotification {
    static Notification build(Context context, String name, String status, String playbackLabel, boolean paused,
                              PendingIntent open, PendingIntent playback, PendingIntent output, PendingIntent stop) {
        Notification.Builder builder = new Notification.Builder(context, "relay").setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(name).setContentText(status).setContentIntent(open).setOnlyAlertOnce(true).setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE).setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(new Notification.Action.Builder(Icon.createWithResource(context, paused ? R.drawable.ic_play : R.drawable.ic_pause),
                playbackLabel, playback).build());
        if (output != null) builder
            .addAction(new Notification.Action.Builder(null, "Computer", output).build());
        return builder
            .addAction(new Notification.Action.Builder(null, "Disconnect", stop).build()).build();
    }
}
