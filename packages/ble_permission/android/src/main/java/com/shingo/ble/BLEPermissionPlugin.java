package com.shingo.ble;

import android.Manifest;
import android.app.Activity;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.location.LocationManager;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.app.ActivityCompat;
import androidx.core.content.PermissionChecker;

import com.hjq.device.compat.DeviceBrand;
import com.hjq.device.compat.DeviceOs;

import java.lang.reflect.Method;
import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import io.flutter.plugin.common.PluginRegistry;


/**
 * BLEPermissionPlugin
 */
public class BLEPermissionPlugin implements FlutterPlugin, MethodCallHandler, ActivityAware, PluginRegistry.RequestPermissionsResultListener, PluginRegistry.ActivityResultListener {
    private MethodChannel channel;

    private Context mContext;


    private Activity mActivity;
    ActivityPluginBinding activityBinding;


    Map<Integer, PermissionCallback> permissionCallbackMap = new HashMap<>();

    /// 定位服务开启回调
    Map<Integer, PermissionCallback> openLocationServiceCallbackMap = new HashMap<>();
    /// 蓝牙适配器开启
    Map<Integer, PermissionCallback> openBluetoothAdapterCallbackMap = new HashMap<>();
    Map<Integer, PermissionCallback> openPermissionCallbackMap = new HashMap<>();


    private static final String BLE_STATE_OFF = "android.bluetooth.BluetoothAdapter.STATE_OFF";
    private static final String BLE_STATE_ON = "android.bluetooth.BluetoothAdapter.STATE_ON";

    private BroadcastReceiver bluetoothStateReceiver;

    /**
     * 注册
     *
     * @param context
     */
    public void registerBluetoothState(Context context) {

        if (bluetoothStateReceiver == null) {
            bluetoothStateReceiver = new BroadcastReceiver() {
                @Override
                public void onReceive(Context context, Intent intent) {
                    if (channel == null) {
                        return;
                    }
                    int BLEState = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, 0);
                    switch (BLEState) {
                        case BluetoothAdapter.STATE_ON:
                            // 蓝牙已经打开
                            channel.invokeMethod("onBluetoothAdapterStateChanged", true);
                            break;
                        case BluetoothAdapter.STATE_TURNING_OFF:
                            // 蓝牙正在关闭
                            channel.invokeMethod("onBluetoothAdapterStateChanged", false);
                            break;
                    }
                }
            };
            IntentFilter filter = new IntentFilter();
            filter.setPriority(Integer.MAX_VALUE);
            // 监视蓝牙关闭和打开的状态
            filter.addAction(BluetoothAdapter.ACTION_STATE_CHANGED);
            filter.addAction(BLE_STATE_OFF);
            filter.addAction(BLE_STATE_ON);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(bluetoothStateReceiver, filter, Context.RECEIVER_EXPORTED);
            } else {
                context.registerReceiver(bluetoothStateReceiver, filter);
            }
        }

    }

    /**
     * 注销
     *
     * @param context
     */
    public void unregisterBluetoothState(Context context) {
        if (bluetoothStateReceiver != null) {
            context.unregisterReceiver(bluetoothStateReceiver);
            bluetoothStateReceiver = null;
        }
    }


    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding flutterPluginBinding) {
        channel = new MethodChannel(flutterPluginBinding.getBinaryMessenger(), "ble_permission");
        channel.setMethodCallHandler(this);
        mContext = flutterPluginBinding.getApplicationContext();
        registerBluetoothState(mContext);
    }


    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
        String method = call.method;
        if ("openBluetoothAdapter".equals(method)) {
            openBluetoothAdapter(result);
        } else if ("isBluetoothAdapterEnable".equals(method)) {
            result.success(isBluetoothAdapterOpen());
        } else if ("isLocationServiceEnable".equals(method)) {
            result.success(isLocationServiceEnable(mContext));
        } else if ("openLocationService".equals(method)) {
            openLocationService(result);
        } else if ("openPermission".equals(method)) {
            openPermission(result);
        } else if ("requestPermission".equals(method)) {
            requestPermission(result);
        } else if ("checkPermission".equals(method)) {
            result.success(checkBluetoothPermission());
        } else if ("isReady".equals(method)) {
            result.success(isReady());
        } else if ("isNeedLocationService".equals(method)) {
            result.success(isNeedLocationService());
        } else if ("isBluetoothTetheringEnable".equals(method)) {
            isBluetoothTetheringEnable(result, mContext);
        }
    }

    public boolean isReady() {
        boolean hasPermission = checkBluetoothPermission();
        boolean adapterOpen = isBluetoothAdapterOpen();
        if (hasPermission && adapterOpen) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                return isLocationServiceEnable(mContext);
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && DeviceBrand.isHuaWei()) {
                /// 华为Android31(12)还是需要开启定位服务
                return isLocationServiceEnable(mContext);
            }
            return true;
        } else {
            return false;
        }

    }

    public boolean isNeedLocationService() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            return true;
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && DeviceBrand.isHuaWei()) {
            /// 华为Android31(12)还是需要开启定位服务
            return true;
        }
        return false;
    }


    public void requestPermission(Result result) {

        PermissionCallback callback = new PermissionCallback() {
            @Override
            void onPermission(boolean hasPermission) {
                result.success(hasPermission);
                permissionCallbackMap.remove(result.hashCode());
            }
        };
        permissionCallbackMap.put(result.hashCode(), callback);
        if (checkBluetoothPermission()) {
            callback.onPermission(true);
        } else {
            if (mActivity != null) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    //targetSdkVersion 31 更改了蓝牙相关权限
                    ActivityCompat.requestPermissions(mActivity, new String[]{Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT}, result.hashCode());
                } else {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        //targetSdkVersion 28以及以下使用模糊定位权限即可,但是如果是29以及以上要使用精准定位权限,否则无法搜索到蓝牙
                        ActivityCompat.requestPermissions(mActivity, new String[]{Manifest.permission.ACCESS_FINE_LOCATION}, result.hashCode());
                    } else {
                        ActivityCompat.requestPermissions(mActivity, new String[]{Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION}, result.hashCode());
                    }

                }
            }
        }
    }


    public boolean checkBluetoothPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            int p1 = PermissionChecker.checkSelfPermission(mContext, Manifest.permission.BLUETOOTH_SCAN);
            int p2 = PermissionChecker.checkSelfPermission(mContext, Manifest.permission.BLUETOOTH_CONNECT);
            return p1 == PackageManager.PERMISSION_GRANTED && p2 == PackageManager.PERMISSION_GRANTED;
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            int p = PermissionChecker.checkSelfPermission(mContext, Manifest.permission.ACCESS_FINE_LOCATION);
            return p == PackageManager.PERMISSION_GRANTED;
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            int p1 = PermissionChecker.checkSelfPermission(mContext, Manifest.permission.ACCESS_FINE_LOCATION);
            int p2 = PermissionChecker.checkSelfPermission(mContext, Manifest.permission.ACCESS_COARSE_LOCATION);
            return p1 == PackageManager.PERMISSION_GRANTED || p2 == PackageManager.PERMISSION_GRANTED;
        }
        return true;
    }


    /// 打开蓝牙适配器
    private void openBluetoothAdapter(Result result) {
        PermissionCallback callback = new PermissionCallback() {
            @Override
            void onPermission(boolean hasPermission) {
                result.success(hasPermission);
                openBluetoothAdapterCallbackMap.remove(result.hashCode());
            }
        };
        openBluetoothAdapterCallbackMap.put(result.hashCode(), callback);
        if (isBluetoothAdapterOpen()) {
            callback.onPermission(true);
        } else {
            if (mActivity != null) {
                Intent btIntent = new Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE);
                btIntent.putExtra(Intent.EXTRA_PACKAGE_NAME, mActivity.getPackageName());
                mActivity.startActivityForResult(btIntent, result.hashCode());
            } else {
                callback.onPermission(false);
            }
        }

    }

    private void openPermission(Result result) {
        if (mActivity != null) {
            PermissionCallback callback = new PermissionCallback() {
                @Override
                void onPermission(boolean hasPermission) {
                    result.success(hasPermission);
                    openPermissionCallbackMap.remove(result.hashCode());
                }
            };
            openPermissionCallbackMap.put(result.hashCode(), callback);
            Intent intent = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .setData(Uri.fromParts("package", this.mActivity.getPackageName(), null));
            this.mActivity.startActivityForResult(intent, result.hashCode());
        } else {
            result.success(false);
        }
    }

    public boolean isBluetoothAdapterOpen() {
        BluetoothAdapter bluetoothAdapter = BluetoothAdapter.getDefaultAdapter();
        return bluetoothAdapter != null && bluetoothAdapter.isEnabled();
    }


    public boolean isLocationServiceEnable(Context context) {
        LocationManager locationManager = (LocationManager) context.getSystemService(Context.LOCATION_SERVICE);
        boolean gpsProvider = locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER);
        return gpsProvider;
    }


    /// 打开定位服务,android 12以下蓝牙权限需要
    public void openLocationService(Result result) {
        PermissionCallback callback = new PermissionCallback() {
            @Override
            void onPermission(boolean hasPermission) {
                result.success(hasPermission);
                openLocationServiceCallbackMap.remove(result.hashCode());
            }
        };
        openLocationServiceCallbackMap.put(result.hashCode(), callback);
        if (isLocationServiceEnable(mContext)) {
            callback.onPermission(true);
        } else {
            if (mActivity != null) {
                Intent locationIntent = new Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS);
                mActivity.startActivityForResult(locationIntent, result.hashCode());
            } else {
                callback.onPermission(false);
            }
        }
    }


    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        channel = null;
        closeProfileProxy();
        unregisterBluetoothState(binding.getApplicationContext());
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activityBinding = binding;
        mActivity = binding.getActivity();
        binding.addActivityResultListener(this);
        binding.addRequestPermissionsResultListener(this);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivity() {
        if (activityBinding != null) {
            activityBinding.removeRequestPermissionsResultListener(this);
            activityBinding.removeActivityResultListener(this);
            activityBinding = null;
            mActivity = null;
        }
    }

    @Override
    public boolean onActivityResult(int requestCode, int resultCode, @Nullable Intent data) {
        if (openLocationServiceCallbackMap.containsKey(requestCode)) {
            openLocationServiceCallbackMap.get(requestCode).onPermission(isLocationServiceEnable(mContext));
            return true;
        }
        if (openBluetoothAdapterCallbackMap.containsKey(requestCode)) {
            openBluetoothAdapterCallbackMap.get(requestCode).onPermission(isBluetoothAdapterOpen());
            return true;
        }
        if (openPermissionCallbackMap.containsKey(requestCode)) {
            openPermissionCallbackMap.get(requestCode).onPermission(checkBluetoothPermission());
            return true;
        }

        return false;
    }

    @Override
    public boolean onRequestPermissionsResult(int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
        if (permissionCallbackMap.containsKey(requestCode)) {
            if (grantResults.length > 0)
                if (grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                    permissionCallbackMap.get(requestCode).onPermission(true);
                    return true;
                } else {
                    permissionCallbackMap.get(requestCode).onPermission(false);
                }
        }
        return false;
    }


    abstract class PermissionCallback {
        abstract void onPermission(boolean hasPermission);
    }


    BluetoothProfile panProfile;

    Map<Integer, BluetoothTetheringCallback> bluetoothTetheringCallbackMap = new HashMap<>();

    abstract class BluetoothTetheringCallback {
        abstract void onResult(boolean enable);
    }

    public void isBluetoothTetheringEnable(Result result, Context context) {

        BluetoothTetheringCallback callback = new BluetoothTetheringCallback() {
            @Override
            void onResult(boolean enable) {
                result.success(enable);
                bluetoothTetheringCallbackMap.remove(result.hashCode());
                closeProfileProxy();
            }
        };
        bluetoothTetheringCallbackMap.put(result.hashCode(), callback);

        BluetoothAdapter adapter = BluetoothAdapter.getDefaultAdapter();
        if (adapter == null || !adapter.isEnabled()) {
            callback.onResult(false);
            return;
        }


        BluetoothProfile.ServiceListener listener = new BluetoothProfile.ServiceListener() {
            @Override
            public void onServiceConnected(int profile, BluetoothProfile proxy) {
                if (profile == 5) {
                    panProfile = proxy;
                    BluetoothTetheringCallback callback = bluetoothTetheringCallbackMap.get(result.hashCode());
                    if (callback != null) {
                        callback.onResult(isTetheringOn(proxy));
                    }
                    closeProfileProxy();
                }
            }

            @Override
            public void onServiceDisconnected(int profile) {
                if (profile == 5) {
                    BluetoothTetheringCallback callback = bluetoothTetheringCallbackMap.get(result.hashCode());
                    if (callback != null) {
                        callback.onResult(false);
                    }
                    closeProfileProxy();
                }
            }
        };

        boolean success = getPanProfileProxy(context, listener);
        if (!success) {
            callback.onResult(false);
        }

    }


    private boolean isTetheringOn(BluetoothProfile profile) {
        try {
            Method method = profile.getClass().getDeclaredMethod("isTetheringOn");
            method.setAccessible(true);
            return (boolean) method.invoke(profile);
        } catch (Exception e) {
            e.printStackTrace();
        }
        return false;
    }


    private boolean getPanProfileProxy(Context context, BluetoothProfile.ServiceListener listener) {
        BluetoothAdapter adapter = BluetoothAdapter.getDefaultAdapter();
        try {
            return adapter.getProfileProxy(context, listener, 5);
        } catch (Exception e) {
            e.printStackTrace();
        }
        return false;
    }

    private void closeProfileProxy() {
        if (panProfile != null) {
            try {
                BluetoothAdapter adapter = BluetoothAdapter.getDefaultAdapter();
                adapter.closeProfileProxy(5, panProfile);
            } catch (Exception e) {
                e.printStackTrace();
            }
            panProfile = null;
        }
    }


}
