package com.gearvr.pointer;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.view.View;

/** Full-screen, touch-transparent overlay that draws the pointer. */
class CursorView extends View {

    private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint ring = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final int[] origin = new int[2];
    private final float radius;
    private float cx, cy;
    private boolean pressed;
    private boolean shown;

    CursorView(Context context) {
        super(context);
        float density = context.getResources().getDisplayMetrics().density;
        radius = 9f * density;
        fill.setStyle(Paint.Style.FILL);
        ring.setStyle(Paint.Style.STROKE);
        ring.setStrokeWidth(2.5f * density);
        ring.setColor(0xFFFFFFFF);
    }

    /** Position in absolute screen pixels. */
    void setCursor(float x, float y, boolean pressed, boolean shown) {
        this.cx = x;
        this.cy = y;
        this.pressed = pressed;
        this.shown = shown;
        invalidate();
    }

    @Override
    protected void onDraw(Canvas canvas) {
        if (!shown) return;
        getLocationOnScreen(origin);
        float x = cx - origin[0];
        float y = cy - origin[1];
        fill.setColor(pressed ? 0xE0FF5722 : 0xC02196F3);
        canvas.drawCircle(x, y, pressed ? radius * 1.35f : radius, fill);
        canvas.drawCircle(x, y, pressed ? radius * 1.35f : radius, ring);
    }
}
