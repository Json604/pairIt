package dev.bluetoothswitch.relay;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.os.SystemClock;
import android.view.View;

/** Compact activity indicator with twelve fading spokes. */
final class ActivitySpinner extends View {
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    ActivitySpinner(Context context) {
        super(context);
        setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
        paint.setColor(Color.WHITE);
        paint.setStrokeCap(Paint.Cap.ROUND);
    }
    @Override protected void onDraw(Canvas canvas) {
        float radius = Math.min(getWidth(), getHeight()) * .42f;
        paint.setStrokeWidth(radius * .2f);
        int step = (int)(SystemClock.uptimeMillis() / 80 % 12);
        canvas.save();
        canvas.translate(getWidth() / 2f, getHeight() / 2f);
        for (int i = 0; i < 12; i++) {
            paint.setAlpha(45 + ((i - step + 12) % 12) * 19);
            canvas.drawLine(0, -radius * .55f, 0, -radius, paint);
            canvas.rotate(30);
        }
        canvas.restore();
        if (isShown()) postInvalidateDelayed(80);
    }
}
