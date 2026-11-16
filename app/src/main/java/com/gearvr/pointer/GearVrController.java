package com.gearvr.pointer;

import android.Manifest;
import android.annotation.SuppressLint;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;

import java.util.ArrayDeque;
import java.util.Set;
import java.util.UUID;

/**
 * Bluetooth LE link to a Samsung Gear VR controller (ET-YO324).
 * Protocol as documented by the open-source gearvr-controller-webbluetooth project.
 */
@SuppressLint("MissingPermission")
@SuppressWarnings("deprecation")
class GearVrController {

    interface Listener {
        /** Called on the main thread. */
        void onStatus(String status, boolean connected);

        /** Called on a Bluetooth thread with one raw 60-byte sensor packet. */
        void onPacket(byte[] data);
    }

    private static final String NAME_PREFIX = "Gear VR Controller";
    private static final UUID SERVICE = UUID.fromString("4f63756c-7573-2054-6872-65656d6f7465");
    private static final UUID CHAR_NOTIFY = UUID.fromString("c8c51726-81bc-483b-a052-f7a14ea3d281");
    private static final UUID CHAR_WRITE = UUID.fromString("c8c51726-81bc-483b-a052-f7a14ea3d282");
    private static final UUID CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");

    private static final byte[] CMD_SENSOR = {0x01, 0x00};
    private static final byte[] CMD_KEEP_ALIVE = {0x04, 0x00};
    private static final byte[] CMD_VR_MODE = {0x08, 0x00};

    private final Context ctx;
    private final Listener listener;
    private final Handler main = new Handler(Looper.getMainLooper());

    private BluetoothAdapter adapter;
    private BluetoothLeScanner scanner;
    private BluetoothGatt gatt;
    private BluetoothGattCharacteristic writeChar;
    private BluetoothGattCharacteristic notifyChar;

    private final ArrayDeque<byte[]> writeQueue = new ArrayDeque<>();
    private boolean writing;
    private boolean started;
    private boolean scanning;
    private boolean streaming;
    private int session;
    private int cccdAttempts;
    private volatile long lastPacketAt;

    GearVrController(Context ctx, Listener listener) {
        this.ctx = ctx.getApplicationContext();
        this.listener = listener;
    }

    static boolean hasPermissions(Context c) {
        if (Build.VERSION.SDK_INT >= 31) {
            return c.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED
                    && c.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED;
        }
        return c.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    void start() {
        started = true;
        restart(0);
    }

    void stop() {
        started = false;
        session++;
        main.removeCallbacksAndMessages(null);
        stopScan();
        closeGatt();
    }

    /** Drop everything and begin looking for the controller again. */
    void restart(long delayMs) {
        final int s = ++session;
        main.removeCallbacksAndMessages(null);
        stopScan();
        closeGatt();
        main.postDelayed(new Runnable() {
            @Override
            public void run() {
                if (started && s == session) begin();
            }
        }, delayMs);
    }

    private void status(final String text, final boolean connected) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            listener.onStatus(text, connected);
            return;
        }
        main.post(new Runnable() {
            @Override
            public void run() {
                listener.onStatus(text, connected);
            }
        });
    }

    private void begin() {
        if (!hasPermissions(ctx)) {
            status("Bluetooth permission missing - open the app and tap step 1", false);
            retryLater(4000);
            return;
        }
        BluetoothManager bm = (BluetoothManager) ctx.getSystemService(Context.BLUETOOTH_SERVICE);
        adapter = bm == null ? null : bm.getAdapter();
        if (adapter == null || !adapter.isEnabled()) {
            status("Bluetooth is off - turn it on", false);
            retryLater(4000);
            return;
        }
        scanner = adapter.getBluetoothLeScanner();
        if (scanner == null) {
            status("Bluetooth scanner not available", false);
            retryLater(4000);
            return;
        }
        try {
            ScanSettings settings = new ScanSettings.Builder()
                    .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build();
            scanner.startScan(null, settings, scanCallback);
            scanning = true;
            status("Searching... hold the controller's Home button until its light blinks", false);
        } catch (Exception e) {
            status("Scan failed: " + e.getMessage(), false);
            retryLater(5000);
            return;
        }
        // Android throttles long scans, so start a fresh one every minute.
        final int s = session;
        main.postDelayed(new Runnable() {
            @Override
            public void run() {
                if (started && s == session && scanning) restart(500);
            }
        }, 60000);
    }

    private void retryLater(long ms) {
        final int s = session;
        main.postDelayed(new Runnable() {
            @Override
            public void run() {
                if (started && s == session) begin();
            }
        }, ms);
    }

    private void stopScan() {
        if (scanning && scanner != null) {
            try {
                scanner.stopScan(scanCallback);
            } catch (Exception ignored) {
            }
        }
        scanning = false;
    }

    private void closeGatt() {
        streaming = false;
        writing = false;
        writeQueue.clear();
        writeChar = null;
        notifyChar = null;
        if (gatt != null) {
            try {
                gatt.disconnect();
                gatt.close();
            } catch (Exception ignored) {
            }
            gatt = null;
        }
    }

    private boolean isController(BluetoothDevice device, String advertisedName) {
        String name = advertisedName;
        if (name == null) {
            try {
                name = device.getName();
            } catch (Exception ignored) {
            }
        }
        if (name != null && name.startsWith(NAME_PREFIX)) return true;
        try {
            Set<BluetoothDevice> bonded = adapter.getBondedDevices();
            if (bonded != null) {
                for (BluetoothDevice b : bonded) {
                    String bn = b.getName();
                    if (bn != null && bn.startsWith(NAME_PREFIX)
                            && b.getAddress().equals(device.getAddress())) {
                        return true;
                    }
                }
            }
        } catch (Exception ignored) {
        }
        return false;
    }

    private final ScanCallback scanCallback = new ScanCallback() {
        @Override
        public void onScanResult(int callbackType, final ScanResult result) {
            main.post(new Runnable() {
                @Override
                public void run() {
                    if (!scanning || result == null || result.getDevice() == null) return;
                    String name = result.getScanRecord() == null ? null
                            : result.getScanRecord().getDeviceName();
                    if (!isController(result.getDevice(), name)) return;
                    stopScan();
                    connect(result.getDevice());
                }
            });
        }

        @Override
        public void onScanFailed(final int errorCode) {
            main.post(new Runnable() {
                @Override
                public void run() {
                    scanning = false;
                    status("Bluetooth scan failed (code " + errorCode + "), retrying", false);
                    restart(5000);
                }
            });
        }
    };

    private void connect(BluetoothDevice device) {
        status("Controller found, connecting...", false);
        cccdAttempts = 0;
        final int s = session;
        try {
            gatt = device.connectGatt(ctx, false, gattCallback, BluetoothDevice.TRANSPORT_LE);
        } catch (Exception e) {
            status("Connect failed: " + e.getMessage(), false);
            restart(3000);
            return;
        }
        // Give up if nothing is streaming after 20 seconds.
        main.postDelayed(new Runnable() {
            @Override
            public void run() {
                if (started && s == session && !streaming) {
                    status("Connection timed out, retrying", false);
                    restart(1000);
                }
            }
        }, 20000);
    }

    private final BluetoothGattCallback gattCallback = new BluetoothGattCallback() {
        @Override
        public void onConnectionStateChange(final BluetoothGatt g, final int st, final int newState) {
            main.post(new Runnable() {
                @Override
                public void run() {
                    if (g != gatt) return;
                    if (newState == BluetoothProfile.STATE_CONNECTED && st == BluetoothGatt.GATT_SUCCESS) {
                        status("Connected, reading services...", false);
                        final int s = session;
                        main.postDelayed(new Runnable() {
                            @Override
                            public void run() {
                                if (s == session && gatt != null) gatt.discoverServices();
                            }
                        }, 600);
                    } else {
                        status("Controller disconnected, searching again", false);
                        restart(2000);
                    }
                }
            });
        }

        @Override
        public void onServicesDiscovered(final BluetoothGatt g, final int st) {
            main.post(new Runnable() {
                @Override
                public void run() {
                    if (g != gatt) return;
                    BluetoothGattService service = g.getService(SERVICE);
                    if (st != BluetoothGatt.GATT_SUCCESS || service == null) {
                        status("Controller service not found, retrying", false);
                        restart(3000);
                        return;
                    }
                    notifyChar = service.getCharacteristic(CHAR_NOTIFY);
                    writeChar = service.getCharacteristic(CHAR_WRITE);
                    if (notifyChar == null || writeChar == null) {
                        status("Controller characteristics not found, retrying", false);
                        restart(3000);
                        return;
                    }
                    enableNotifications();
                }
            });
        }

        @Override
        public void onDescriptorWrite(final BluetoothGatt g, BluetoothGattDescriptor d, final int st) {
            main.post(new Runnable() {
                @Override
                public void run() {
                    if (g != gatt) return;
                    if (st == BluetoothGatt.GATT_SUCCESS) {
                        startStreaming();
                    } else {
                        retryNotifications(st);
                    }
                }
            });
        }

        @Override
        public void onCharacteristicWrite(final BluetoothGatt g, BluetoothGattCharacteristic c, int st) {
            main.post(new Runnable() {
                @Override
                public void run() {
                    if (g != gatt) return;
                    writing = false;
                    pumpWrites();
                }
            });
        }

        // Android 12 and older
        @Override
        public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic c) {
            deliver(c.getValue());
        }

        // Android 13 and newer
        @Override
        public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic c, byte[] value) {
            deliver(value);
        }
    };

    private void deliver(byte[] value) {
        if (value == null || value.length < 59) return;
        lastPacketAt = SystemClock.uptimeMillis();
        listener.onPacket(value);
    }

    private void enableNotifications() {
        if (gatt == null || notifyChar == null) return;
        status("Connected, starting sensors...", false);
        gatt.setCharacteristicNotification(notifyChar, true);
        BluetoothGattDescriptor d = notifyChar.getDescriptor(CCCD);
        if (d == null) {
            // No descriptor to write; try to start anyway.
            startStreaming();
            return;
        }
        d.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE);
        if (!gatt.writeDescriptor(d)) retryNotifications(-1);
    }

    private void retryNotifications(int st) {
        if (gatt == null) return;
        if (++cccdAttempts > 4) {
            status("Could not start the controller's sensors (code " + st + "), retrying", false);
            restart(3000);
            return;
        }
        try {
            BluetoothDevice dev = gatt.getDevice();
            if (dev.getBondState() == BluetoothDevice.BOND_NONE) {
                status("Pairing with the controller - accept the pairing request if asked", false);
                dev.createBond();
            }
        } catch (Exception ignored) {
        }
        final int s = session;
        main.postDelayed(new Runnable() {
            @Override
            public void run() {
                if (s == session) enableNotifications();
            }
        }, 3000);
    }

    private void startStreaming() {
        if (streaming) return;
        streaming = true;
        lastPacketAt = 0;
        send(CMD_SENSOR);
        send(CMD_VR_MODE);
        status("Connected - controller is active", true);
        final int s = session;
        main.postDelayed(new Runnable() {
            int ticks;

            @Override
            public void run() {
                if (s != session || gatt == null) return;
                ticks++;
                long idle = SystemClock.uptimeMillis() - lastPacketAt;
                if (lastPacketAt == 0 || idle > 3000) {
                    // Sensor stream not running: ask for it again.
                    send(CMD_SENSOR);
                    status("Connected - waiting for sensor data (press a controller button)", true);
                } else {
                    status("Connected - controller is active", true);
                    if (ticks % 5 == 0) send(CMD_KEEP_ALIVE);
                }
                main.postDelayed(this, 3000);
            }
        }, 3000);
    }

    private void send(byte[] cmd) {
        writeQueue.add(cmd);
        pumpWrites();
    }

    private void pumpWrites() {
        if (writing || gatt == null || writeChar == null) return;
        byte[] next = writeQueue.poll();
        if (next == null) return;
        writeChar.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT);
        writeChar.setValue(next);
        if (gatt.writeCharacteristic(writeChar)) {
            writing = true;
            // Safety net in case the write callback never arrives.
            final int s = session;
            main.postDelayed(new Runnable() {
                @Override
                public void run() {
                    if (s == session && writing) {
                        writing = false;
                        pumpWrites();
                    }
                }
            }, 2000);
        }
    }
}
