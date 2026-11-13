package dev.bluetoothswitch.relay;

import android.app.*;
import android.content.Context;
import android.graphics.drawable.Icon;

/** Shared by the live notification and the isolated tutorial preview. */
final class PlaybackNotification {
    static Notification build(Context context, String name, String status, boolean paused, boolean computer,
                              PendingIntent open, PendingIntent playback, PendingIntent output, PendingIntent stop) {
        return new Notification.Builder(context, "relay").setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(name).setContentText(status).setContentIntent(open).setOnlyAlertOnce(true).setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE).setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(new Notification.Action.Builder(Icon.createWithResource(context, paused ? R.drawable.ic_play : R.drawable.ic_pause),
                computer ? "Listen here" : paused ? "Resume" : "Pause", playback).build())
            .addAction(new Notification.Action.Builder(null, "Computer", output).build())
            .addAction(new Notification.Action.Builder(null, "Disconnect", stop).build()).build();
    }
}
