package com.gearvr.pointer;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.view.View;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.CompoundButton;
import android.widget.LinearLayout;
import android.widget.RadioButton;
import android.widget.RadioGroup;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.TextView;

public class MainActivity extends Activity {

    private final Handler main = new Handler(Looper.getMainLooper());
    private SharedPreferences prefs;
    private TextView statusView;
    private TextView debugView;
    private TextView calibView;
    private Button calibButton;
    private boolean calibrating;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = getSharedPreferences(PointerService.PREFS, Context.MODE_PRIVATE);

        int pad = dp(16);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(pad, pad, pad, pad);
        ScrollView scroll = new ScrollView(this);
        scroll.addView(root);
        setContentView(scroll);

        statusView = text(root, "", 18);
        debugView = text(root, "", 12);

        heading(root, "Setup");
        button(root, "1. Allow Bluetooth", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                askPermissions();
            }
        });
        button(root, "2. Turn on \"Gear VR Pointer\" in Accessibility", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                try {
                    startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS));
                } catch (Exception ignored) {
                }
            }
        });
        text(root, "If the switch is greyed out (\"Restricted setting\"): open Settings > Apps > "
                + "Gear VR Pointer, tap the three-dot menu and choose \"Allow restricted settings\", "
                + "then try again.", 13);
        text(root, "3. Hold the controller's Home button until its light blinks. "
                + "The status above changes to \"Connected\".", 15);
        button(root, "Reconnect", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (PointerService.instance != null) PointerService.instance.reconnect();
            }
        });

        heading(root, "Pointer");
        RadioGroup group = new RadioGroup(this);
        final RadioButton motion = new RadioButton(this);
        motion.setText("Move by pointing the controller (touchpad swipes scroll)");
        motion.setId(View.generateViewId());
        final RadioButton touch = new RadioButton(this);
        touch.setText("Move with the touchpad, like a laptop trackpad");
        touch.setId(View.generateViewId());
        group.addView(motion);
        group.addView(touch);
        root.addView(group);
        group.check(prefs.getInt(PointerService.K_MODE, 0) == 0 ? motion.getId() : touch.getId());
        group.setOnCheckedChangeListener(new RadioGroup.OnCheckedChangeListener() {
            @Override
            public void onCheckedChanged(RadioGroup g, int id) {
                prefs.edit().putInt(PointerService.K_MODE, id == motion.getId() ? 0 : 1).apply();
            }
        });

        text(root, "Speed", 15);
        SeekBar speed = new SeekBar(this);
        speed.setMax(100);
        speed.setProgress(prefs.getInt(PointerService.K_SENS, 40));
        speed.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override
            public void onProgressChanged(SeekBar s, int progress, boolean fromUser) {
                prefs.edit().putInt(PointerService.K_SENS, progress).apply();
            }

            @Override
            public void onStartTrackingTouch(SeekBar s) {
            }

            @Override
            public void onStopTrackingTouch(SeekBar s) {
            }
        });
        root.addView(speed);

        calibButton = button(root, "Calibrate pointing directions", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                startCalibration();
            }
        });
        calibView = text(root, "Use this if the pointer moves the wrong way when you point.", 13);

        CheckBox reverse = new CheckBox(this);
        reverse.setText("Reverse touchpad scroll direction");
        reverse.setChecked(prefs.getBoolean(PointerService.K_REVERSE_SCROLL, false));
        reverse.setOnCheckedChangeListener(new CompoundButton.OnCheckedChangeListener() {
            @Override
            public void onCheckedChanged(CompoundButton b, boolean checked) {
                prefs.edit().putBoolean(PointerService.K_REVERSE_SCROLL, checked).apply();
            }
        });
        root.addView(reverse);

        heading(root, "Controls");
        text(root, "Trigger or touchpad click: tap\n"
                + "Hold, then release: long press\n"
                + "Hold and move, then release: swipe / drag along the path\n"
                + "Touchpad swipe: scroll\n"
                + "Back: back (hold for recent apps)\n"
                + "Home: home screen\n"
                + "Volume keys: media volume", 15);
    }

    @Override
    protected void onResume() {
        super.onResume();
        main.post(refresh);
    }

    @Override
    protected void onPause() {
        super.onPause();
        main.removeCallbacks(refresh);
    }

    private final Runnable refresh = new Runnable() {
        @Override
        public void run() {
            String s;
            if (PointerService.instance == null) {
                s = "Service is off - do step 2";
            } else {
                s = PointerService.status;
            }
            if (!GearVrController.hasPermissions(MainActivity.this)) {
                s = "Bluetooth not allowed yet - do step 1";
            }
            statusView.setText("Status: " + s);
            debugView.setText(PointerService.connected ? PointerService.debug : "");
            main.postDelayed(this, 300);
        }
    };

    private void askPermissions() {
        if (GearVrController.hasPermissions(this)) {
            statusView.setText("Status: Bluetooth already allowed");
            return;
        }
        if (Build.VERSION.SDK_INT >= 31) {
            requestPermissions(new String[]{
                    Manifest.permission.BLUETOOTH_SCAN,
                    Manifest.permission.BLUETOOTH_CONNECT}, 1);
        } else {
            // Android 11 and older need Location permission (and Location switched on) to scan.
            requestPermissions(new String[]{Manifest.permission.ACCESS_FINE_LOCATION}, 1);
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(requestCode, permissions, results);
        if (PointerService.instance != null) PointerService.instance.reconnect();
    }

    // ------------------------------------------------------------------
    // Direction calibration: find which gyro axis is left/right and up/down
    // ------------------------------------------------------------------

    private void startCalibration() {
        if (calibrating) return;
        if (PointerService.instance == null || !PointerService.connected) {
            calibView.setText("Connect the controller first.");
            return;
        }
        calibrating = true;
        calibButton.setEnabled(false);
        calibView.setText("Hold the controller still, pointing at the phone...");
        main.postDelayed(new Runnable() {
            @Override
            public void run() {
                measure(1, "NOW: turn the controller to the RIGHT (like pointing a torch right)");
            }
        }, 2000);
    }

    private void measure(final int step, String instruction) {
        calibView.setText(instruction);
        PointerService.calibSum[0] = PointerService.calibSum[1] = PointerService.calibSum[2] = 0;
        PointerService.calibStep = step;
        main.postDelayed(new Runnable() {
            @Override
            public void run() {
                PointerService.calibStep = 0;
                float[] sum = PointerService.calibSum.clone();
                int skip = step == 2 ? prefs.getInt(PointerService.K_AXIS_H, -1) : -1;
                int best = -1;
                for (int i = 0; i < 3; i++) {
                    if (i == skip) continue;
                    if (best < 0 || Math.abs(sum[i]) > Math.abs(sum[best])) best = i;
                }
                if (best < 0 || Math.abs(sum[best]) < 8f) {
                    finishCalibration("No clear movement detected. Tap Calibrate and try again.");
                    return;
                }
                float sign = Math.signum(sum[best]);
                if (step == 1) {
                    prefs.edit().putInt(PointerService.K_AXIS_H, best)
                            .putFloat(PointerService.K_SIGN_H, sign).apply();
                    calibView.setText("Good. Hold still again...");
                    main.postDelayed(new Runnable() {
                        @Override
                        public void run() {
                            measure(2, "NOW: tilt the controller UP (like pointing a torch at the ceiling)");
                        }
                    }, 2000);
                } else {
                    // Tilting up must move the pointer up, which is negative Y on screen.
                    prefs.edit().putInt(PointerService.K_AXIS_V, best)
                            .putFloat(PointerService.K_SIGN_V, -sign).apply();
                    finishCalibration("Calibration saved. Try pointing now.");
                }
            }
        }, 2500);
    }

    private void finishCalibration(String message) {
        calibrating = false;
        calibButton.setEnabled(true);
        calibView.setText(message);
    }

    // ------------------------------------------------------------------
    // Small view helpers
    // ------------------------------------------------------------------

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }

    private TextView text(LinearLayout root, String s, int sizeSp) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(sizeSp);
        t.setPadding(0, dp(6), 0, dp(6));
        root.addView(t);
        return t;
    }

    private void heading(LinearLayout root, String s) {
        TextView t = text(root, s, 20);
        t.setPadding(0, dp(20), 0, dp(4));
    }

    private Button button(LinearLayout root, String s, View.OnClickListener l) {
        Button b = new Button(this);
        b.setText(s);
        b.setAllCaps(false);
        b.setOnClickListener(l);
        root.addView(b);
        return b;
    }
}
