"""Run the actual Android write callback body against minimal JVM test doubles.

Checks current/obsolete GATT identity before shared-cache access and again at
UI dispatch. Uses real method bodies; does not simulate a radio or build the
complete plugin.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
source = (root / "packages/flutter_blue_plus_android/android/src/main/java/com/jmx/flutter_blue_plus/FlutterBluePlusPlugin.java").read_text()
def method(signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end]

callback = "\n".join(method(signature) for signature in [
    "public void onCharacteristicWrite(BluetoothGatt gatt,",
    "public void onMtuChanged(BluetoothGatt gatt,",
    "public void onReadRemoteRssi(BluetoothGatt gatt,",
    "private void runWithCurrentGatt(",
    "private void invokeMethodUIThread(final String method, HashMap<String, Object> data, BluetoothGatt gatt)",
])

harness = r'''
import java.util.*;
import java.util.concurrent.Semaphore;
public class AndroidReviewProbe {
    enum LogLevel { DEBUG, ERROR }
    static class BluetoothDevice { String getAddress() { return "device"; } }
    static class BluetoothGatt {
        static final int GATT_SUCCESS = 0;
        BluetoothDevice getDevice() { return new BluetoothDevice(); }
    }
    static class BluetoothGattService { String getUuid() { return "180f"; } }
    static class BluetoothGattCharacteristic {
        String getUuid() { return "2a19"; }
        BluetoothGattService getService() { return new BluetoothGattService(); }
    }
    final Map<String, BluetoothGatt> mConnectedDevices = new HashMap<>();
    final Map<String, byte[]> mWriteChr = new HashMap<>();
    final Map<String, Integer> mMtu = new HashMap<>();
    final Semaphore mMethodCallMutex = new Semaphore(1);
    static void acquireMutex(Semaphore mutex) { mutex.acquireUninterruptibly(); }
    final List<HashMap<String, Object>> events = new ArrayList<>();
    class Handler {
        final Queue<Runnable> tasks = new ArrayDeque<>();
        void post(Runnable action) { tasks.add(action); }
        void drain() { while (!tasks.isEmpty()) tasks.remove().run(); }
    }
    final Handler mainHandler = new Handler();
    class Channel {
        void invokeMethod(String name, HashMap<String, Object> event) { events.add(event); }
    }
    final Channel methodChannel = new Channel();
    boolean isLogEnabled(LogLevel level) { return false; }
    void log(LogLevel level, String text) {}
    String uuidStr(String uuid) { return uuid; }
    String gattErrorString(int status) { return "success"; }
    BluetoothGattService getPrimaryService(BluetoothGatt gatt, BluetoothGattCharacteristic chr) { return null; }
    Integer getInstanceId(BluetoothGatt gatt, BluetoothGattCharacteristic chr, BluetoothGattService service) { return 0; }
    CALLBACK
    public static void main(String[] args) {
        AndroidReviewProbe probe = new AndroidReviewProbe();
        BluetoothGatt oldGatt = new BluetoothGatt(), nextGatt = new BluetoothGatt();
        probe.mConnectedDevices.put("device", nextGatt);
        String key = "device::180f:2a19:0";
        probe.mWriteChr.put(key, new byte[] { 2 }); // New connection's pending write.
        probe.onCharacteristicWrite(oldGatt, new BluetoothGattCharacteristic(), 0);
        if (!probe.mWriteChr.containsKey(key) || !probe.events.isEmpty()) {
            throw new AssertionError("Old GATT must not consume a new pending write");
        }
        probe.onMtuChanged(oldGatt, 512, 0);
        if (probe.mMtu.containsKey("device")) throw new AssertionError("Old GATT changed MTU");
        probe.onReadRemoteRssi(oldGatt, -50, 0);
        if (!probe.mainHandler.tasks.isEmpty()) throw new AssertionError("Obsolete data was queued");

        // Callback was current when handled, but becomes obsolete before UI delivery.
        probe.onCharacteristicWrite(nextGatt, new BluetoothGattCharacteristic(), 0);
        probe.mConnectedDevices.put("device", oldGatt);
        probe.mainHandler.drain();
        if (!probe.events.isEmpty()) throw new AssertionError("Obsolete queued event escaped");

        probe.mWriteChr.put(key, new byte[] { 3 });
        probe.onCharacteristicWrite(oldGatt, new BluetoothGattCharacteristic(), 0);
        probe.onMtuChanged(oldGatt, 247, 0);
        probe.onReadRemoteRssi(oldGatt, -42, 0);
        probe.mainHandler.drain();
        if (probe.events.size() != 3 || probe.mWriteChr.containsKey(key) ||
            ((byte[]) probe.events.get(0).get("value"))[0] != 3 || probe.mMtu.get("device") != 247) {
            throw new AssertionError("Current callbacks must still update caches and deliver responses");
        }
        System.out.println("PASS: obsolete callbacks and queued events are fenced; current write/MTU/RSSI work");
    }
}
'''.replace("CALLBACK", callback)

with tempfile.TemporaryDirectory(prefix="fbp-android-review-") as directory:
    java = Path(directory) / "AndroidReviewProbe.java"
    java.write_text(harness)
    subprocess.run(["javac", str(java)], check=True)
    subprocess.run(["java", "-cp", directory, "AndroidReviewProbe"], check=True)
