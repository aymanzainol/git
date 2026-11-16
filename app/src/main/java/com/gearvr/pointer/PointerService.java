package com.gearvr.pointer;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.GestureDescription;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.res.Configuration;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.Point;
import android.graphics.Rect;
import android.media.AudioManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityEvent;

import java.util.ArrayList;

/**
 * Accessibility service that turns Gear VR controller input into an on-screen
 * pointer, taps, swipes and Back / Home / volume actions.
 */
public class PointerService extends AccessibilityService implements GearVrController.Listener {

    static final String PREFS = "cfg";
    static final String K_MODE = "mode";              // 0 = motion, 1 = touchpad
    static final String K_SENS = "sens";              // 0..100
    static final String K_AXIS_H = "axisH";           // gyro axis for left/right
    static final String K_AXIS_V = "axisV";           // gyro axis for up/down
    static final String K_SIGN_H = "signH";
    static final String K_SIGN_V = "signV";
    static final String K_REVERSE_SCROLL = "revScroll";

    private static final int BTN_TRIGGER = 1;
    private static final int BTN_HOME = 2;
    private static final int BTN_BACK = 4;
    private static final int BTN_PAD = 8;
    private static final int BTN_VOL_UP = 16;
    private static final int BTN_VOL_DOWN = 32;

    private static final float GYRO_DEG_PER_UNIT = 1f / 14.285f;
    private static final long LONG_PRESS_MS = 600;
    private static final long HIDE_AFTER_MS = 15000;

    // ---- state shared with MainActivity (everything runs on the main thread) ----
    static PointerService instance;
    static String status = "Service is off";
    static boolean connected;
    static String debug = "";
    /** 0 = idle, 1 = measuring "turn right", 2 = measuring "tilt up". */
    static int calibStep;
    static final float[] calibSum = new float[3];

    private final Handler main = new Handler(Looper.getMainLooper());
    private GearVrController controller;
    private WindowManager wm;
    private CursorView cursor;
    private AudioManager audio;
    private SharedPreferences prefs;

    private int screenW = 1080, screenH = 1920;
    private float x, y;
    private long lastPacketMs;
    private long lastActivityMs;
    private long lastDebugMs;

    private final float[] bias = new float[3];
    private int prevButtons;
    private boolean pressActive;
    private long pressStartMs;
    private final ArrayList<float[]> pressPath = new ArrayList<>();
    private long backDownMs;
    private long volRepeatMs;

    private boolean padTouching;
    private int padStartX, padStartY, padLastX, padLastY;

    // cached settings
    private int mode, axisH, axisV;
    private float signH, signV, sens;
    private boolean reverseScroll;
    private long prefsLoadedMs;

    @Override
    protected void onServiceConnected() {
        super.onServiceConnected();
        instance = this;
        prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        audio = (AudioManager) getSystemService(Context.AUDIO_SERVICE);
        wm = (WindowManager) getSystemService(Context.WINDOW_SERVICE);
        updateScreenSize();
        x = screenW / 2f;
        y = screenH / 2f;
        addCursor();
        loadPrefs();
        controller = new GearVrController(this, this);
        controller.start();
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        // Not used: this service only sends gestures.
    }

    @Override
    public void onInterrupt() {
    }

    @Override
    public void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        if (wm != null) updateScreenSize();
    }

    @Override
    public void onDestroy() {
        shutdown();
        super.onDestroy();
    }

    @Override
    public boolean onUnbind(android.content.Intent intent) {
        shutdown();
        return super.onUnbind(intent);
    }

    private void shutdown() {
        if (controller != null) {
            controller.stop();
            controller = null;
        }
        if (cursor != null) {
            try {
                wm.removeView(cursor);
            } catch (Exception ignored) {
            }
            cursor = null;
        }
        main.removeCallbacksAndMessages(null);
        if (instance == this) instance = null;
        status = "Service is off";
        connected = false;
    }

    /** Called from MainActivity after permissions change or on "Reconnect". */
    void reconnect() {
        if (controller != null) controller.restart(200);
    }

    @SuppressWarnings("deprecation")
    private void updateScreenSize() {
        if (Build.VERSION.SDK_INT >= 30) {
            Rect b = wm.getCurrentWindowMetrics().getBounds();
            screenW = b.width();
            screenH = b.height();
        } else {
            Point p = new Point();
            wm.getDefaultDisplay().getRealSize(p);
            screenW = p.x;
            screenH = p.y;
        }
        x = clamp(x, 0, screenW - 1);
        y = clamp(y, 0, screenH - 1);
    }

    private void addCursor() {
        cursor = new CursorView(this);
        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        if (Build.VERSION.SDK_INT >= 28) {
            lp.layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
        }
        try {
            wm.addView(cursor, lp);
        } catch (Exception e) {
            cursor = null;
            status = "Could not draw the pointer: " + e.getMessage();
        }
    }

    private void loadPrefs() {
        mode = prefs.getInt(K_MODE, 0);
        axisH = prefs.getInt(K_AXIS_H, 1);
        axisV = prefs.getInt(K_AXIS_V, 0);
        signH = prefs.getFloat(K_SIGN_H, -1f);
        signV = prefs.getFloat(K_SIGN_V, -1f);
        reverseScroll = prefs.getBoolean(K_REVERSE_SCROLL, false);
        int s = prefs.getInt(K_SENS, 40);
        sens = 0.3f + (s / 100f) * 2.7f;   // 0.3x .. 3.0x
        prefsLoadedMs = SystemClock.uptimeMillis();
    }

    // ------------------------------------------------------------------
    // GearVrController.Listener
    // ------------------------------------------------------------------

    @Override
    public void onStatus(String text, boolean isConnected) {
        status = text;
        connected = isConnected;
        if (!isConnected) {
            pressActive = false;
            padTouching = false;
            prevButtons = 0;
            redraw(false);
        }
    }

    @Override
    public void onPacket(byte[] d) {
        // Bluetooth thread: decode, then hand over to the main thread.
        float gx = 0, gy = 0, gz = 0;
        int n = 0;
        for (int i = 0; i < 3; i++) {
            int o = 16 * i;
            if (d.length < o + 16) break;
            gx += s16(d, o + 10);
            gy += s16(d, o + 12);
            gz += s16(d, o + 14);
            n++;
        }
        if (n > 0) {
            gx = gx / n * GYRO_DEG_PER_UNIT;
            gy = gy / n * GYRO_DEG_PER_UNIT;
            gz = gz / n * GYRO_DEG_PER_UNIT;
        }
        final int padX = (((d[54] & 0xF) << 6) + ((d[55] & 0xFC) >> 2)) & 0x3FF;
        final int padY = (((d[55] & 0x3) << 8) + (d[56] & 0xFF)) & 0x3FF;
        final int buttons = d[58] & 0x3F;
        final float fx = gx, fy = gy, fz = gz;
        main.post(new Runnable() {
            @Override
            public void run() {
                if (instance == PointerService.this) process(fx, fy, fz, padX, padY, buttons);
            }
        });
    }

    private static int s16(byte[] d, int o) {
        return (short) ((d[o] & 0xFF) | (d[o + 1] << 8));
    }

    // ------------------------------------------------------------------
    // Input processing (main thread)
    // ------------------------------------------------------------------

    private void process(float gx, float gy, float gz, int padX, int padY, int buttons) {
        long now = SystemClock.uptimeMillis();
        float dt = lastPacketMs == 0 ? 0f : (now - lastPacketMs) / 1000f;
        if (dt > 0.1f) dt = 0.1f;
        lastPacketMs = now;
        if (now - prefsLoadedMs > 500) loadPrefs();

        float[] g = {gx, gy, gz};

        // Slowly learn the gyro's resting offset while the controller is nearly still.
        boolean still = Math.abs(g[0] - bias[0]) < 6 && Math.abs(g[1] - bias[1]) < 6
                && Math.abs(g[2] - bias[2]) < 6;
        for (int i = 0; i < 3; i++) {
            if (still) bias[i] += 0.01f * (g[i] - bias[i]);
            g[i] -= bias[i];
        }

        if (calibStep != 0) {
            for (int i = 0; i < 3; i++) calibSum[i] += g[i] * dt;
        }
        if (now - lastDebugMs > 200) {
            lastDebugMs = now;
            debug = String.format(java.util.Locale.US,
                    "gyro %.0f / %.0f / %.0f   pad %d,%d   buttons %d",
                    g[0], g[1], g[2], padX, padY, buttons);
        }

        boolean moved = false;
        boolean touching = padX != 0 || padY != 0;

        // ---- pointer movement ----
        if (mode == 0) {
            float h = deadzone(g[axisH]) * signH;
            float v = deadzone(g[axisV]) * signV;
            if (h != 0 || v != 0) {
                float pxPerDeg = screenW / 30f * sens;
                x = clamp(x + h * dt * pxPerDeg, 0, screenW - 1);
                y = clamp(y + v * dt * pxPerDeg, 0, screenH - 1);
                moved = true;
            }
        } else if (touching && padTouching) {
            float k = screenW / 315f * 1.2f * sens;
            float dx = (padX - padLastX) * k;
            float dy = (padY - padLastY) * k;
            if (dx != 0 || dy != 0) {
                x = clamp(x + dx, 0, screenW - 1);
                y = clamp(y + dy, 0, screenH - 1);
                moved = true;
            }
        }

        // ---- touchpad swipe = scroll (motion mode only) ----
        if (touching && !padTouching) {
            padStartX = padX;
            padStartY = padY;
        }
        if (!touching && padTouching && mode == 0 && !pressActive) {
            int dx = padLastX - padStartX;
            int dy = padLastY - padStartY;
            if (Math.abs(dx) > 50 || Math.abs(dy) > 50) scroll(dx, dy);
        }
        if (touching) {
            padLastX = padX;
            padLastY = padY;
        }
        padTouching = touching;

        // ---- buttons ----
        int down = buttons & ~prevButtons;
        int up = ~buttons & prevButtons;
        prevButtons = buttons;

        boolean pressNow = (buttons & (BTN_TRIGGER | BTN_PAD)) != 0;
        if (pressNow && !pressActive) {
            pressActive = true;
            pressStartMs = now;
            pressPath.clear();
            pressPath.add(new float[]{x, y});
        } else if (pressNow) {
            float[] last = pressPath.get(pressPath.size() - 1);
            if (Math.hypot(x - last[0], y - last[1]) > 6 && pressPath.size() < 400) {
                pressPath.add(new float[]{x, y});
            }
        } else if (pressActive) {
            pressActive = false;
            finishPress(now - pressStartMs);
        }

        if ((down & BTN_HOME) != 0) performGlobalAction(GLOBAL_ACTION_HOME);
        if ((down & BTN_BACK) != 0) backDownMs = now;
        if ((up & BTN_BACK) != 0) {
            performGlobalAction(now - backDownMs >= LONG_PRESS_MS
                    ? GLOBAL_ACTION_RECENTS : GLOBAL_ACTION_BACK);
        }
        int vol = buttons & (BTN_VOL_UP | BTN_VOL_DOWN);
        if (vol != 0 && ((down & vol) != 0 || now - volRepeatMs > 300)) {
            volRepeatMs = now;
            try {
                audio.adjustStreamVolume(AudioManager.STREAM_MUSIC,
                        (vol & BTN_VOL_UP) != 0 ? AudioManager.ADJUST_RAISE : AudioManager.ADJUST_LOWER,
                        AudioManager.FLAG_SHOW_UI);
            } catch (Exception ignored) {
            }
        }

        if (moved || buttons != 0 || touching) lastActivityMs = now;
        redraw(now - lastActivityMs < HIDE_AFTER_MS);
    }

    private static float deadzone(float v) {
        if (v > 1.2f) return v - 1.2f;
        if (v < -1.2f) return v + 1.2f;
        return 0f;
    }

    private static float clamp(float v, float lo, float hi) {
        return v < lo ? lo : (v > hi ? hi : v);
    }

    private void redraw(boolean show) {
        if (cursor != null) cursor.setCursor(x, y, pressActive, show && connected);
    }

    // ------------------------------------------------------------------
    // Gestures
    // ------------------------------------------------------------------

    /** Trigger / touchpad click released: tap, long press, or swipe along the path travelled. */
    private void finishPress(long heldMs) {
        if (pressPath.isEmpty()) return;
        float[] first = pressPath.get(0);
        float maxDist = 0;
        for (float[] p : pressPath) {
            maxDist = Math.max(maxDist, (float) Math.hypot(p[0] - first[0], p[1] - first[1]));
        }
        float slop = screenW * 0.04f;
        Path path = new Path();
        path.moveTo(first[0], first[1]);
        long duration;
        if (maxDist < slop) {
            path.lineTo(first[0], first[1]);
            duration = heldMs >= LONG_PRESS_MS ? 800 : 60;
        } else {
            for (int i = 1; i < pressPath.size(); i++) {
                path.lineTo(pressPath.get(i)[0], pressPath.get(i)[1]);
            }
            duration = Math.max(120, Math.min(heldMs, 1500));
        }
        dispatch(path, duration);
    }

    /** Touchpad swipe: flick the screen content under the pointer. */
    private void scroll(int padDx, int padDy) {
        float dirX = 0, dirY = 0;
        if (Math.abs(padDx) > Math.abs(padDy)) dirX = Math.signum(padDx);
        else dirY = Math.signum(padDy);
        if (reverseScroll) {
            dirX = -dirX;
            dirY = -dirY;
        }
        float dist = (dirX != 0 ? screenW : screenH) * 0.35f;
        float sx = clamp(x - dirX * dist / 2, 1, screenW - 2);
        float sy = clamp(y - dirY * dist / 2, screenH * 0.08f, screenH * 0.92f);
        float ex = clamp(sx + dirX * dist, 1, screenW - 2);
        float ey = clamp(sy + dirY * dist, screenH * 0.08f, screenH * 0.92f);
        Path path = new Path();
        path.moveTo(sx, sy);
        path.lineTo(ex, ey);
        dispatch(path, 220);
    }

    private void dispatch(Path path, long durationMs) {
        try {
            GestureDescription.Builder b = new GestureDescription.Builder();
            b.addStroke(new GestureDescription.StrokeDescription(path, 0, durationMs));
            dispatchGesture(b.build(), null, null);
        } catch (Exception e) {
            debug = "Gesture failed: " + e.getMessage();
        }
    }
}
