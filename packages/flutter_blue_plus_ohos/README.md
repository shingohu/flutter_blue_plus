# flutter_blue_plus_ohos

## 简介

flutter_blue_plus_ohos 是 Flutter 的蓝牙插件，支持蓝牙设备的扫描、连接、数据读写及状态监测。它简化了蓝牙通信的开发流程，适用于智能家居、健康监测等应用场景。

## 构建

```
拉取代码后进入到 
cd ./example 执行 flutter build hap 可在example下编译出对应的har包
```

## 使用说明

1. 获取蓝牙关闭状态

```
// Note: The platform is initialized on the first call to any FlutterBluePlus method.
if (await FlutterBluePlus.isSupported == false) {
    print("Bluetooth not supported by this device");
    return;
}

// handle bluetooth on & off
// note: for iOS the initial state is typically BluetoothAdapterState.unknown
// note: if you have permissions issues you will get stuck at BluetoothAdapterState.unauthorized
var subscription = FlutterBluePlus.adapterState.listen((BluetoothAdapterState state) {
    print(state);
    if (state == BluetoothAdapterState.on) {
        // usually start scanning, connecting, etc
    } else {
        // show an error to the user, etc
    }
});

// turn on bluetooth ourself if we can
// for iOS, the user controls bluetooth enable/disable
if (Platform.isAndroid||Platform.operatingSystem == 'ohos') {
    await FlutterBluePlus.turnOn();
}

// cancel to prevent duplicate listeners
subscription.cancel();
```

2. 扫描设备

```
// listen to scan results
// Note: `onScanResults` only returns live scan results, i.e. during scanning. Use
//  `scanResults` if you want live scan results *or* the results from a previous scan.
var subscription = FlutterBluePlus.onScanResults.listen((results) {
        if (results.isNotEmpty) {
            ScanResult r = results.last; // the most recently found device
            print('${r.device.remoteId}: "${r.advertisementData.advName}" found!');
        }
    },
    onError: (e) => print(e),
);

// cleanup: cancel subscription when scanning stops
FlutterBluePlus.cancelWhenScanComplete(subscription);

// Wait for Bluetooth enabled & permission granted
// In your real app you should use `FlutterBluePlus.adapterState.listen` to handle all states
await FlutterBluePlus.adapterState.where((val) => val == BluetoothAdapterState.on).first;

// Start scanning w/ timeout
// Optional: use `stopScan()` as an alternative to timeout
await FlutterBluePlus.startScan(
  withServices:[Guid("180D")], // match any of the specified services
  withNames:["Bluno"], // *or* any of the specified names
  timeout: Duration(seconds:15));

// wait for scanning to stop
await FlutterBluePlus.isScanning.where((val) => val == false).first;
```

3. 连接到设备

```
// listen for disconnection
var subscription = device.connectionState.listen((BluetoothConnectionState state) async {
    if (state == BluetoothConnectionState.disconnected) {
        // 1. typically, start a periodic timer that tries to 
        //    reconnect, or just call connect() again right now
        // 2. you must always re-discover services after disconnection!
        print("${device.disconnectReason?.code} ${device.disconnectReason?.description}");
    }
});

// cleanup: cancel subscription when disconnected
//   - [delayed] This option is only meant for `connectionState` subscriptions.  
//     When `true`, we cancel after a small delay. This ensures the `connectionState` 
//     listener receives the `disconnected` event.
//   - [next] if true, the the stream will be canceled only on the *next* disconnection,
//     not the current disconnection. This is useful if you setup your subscriptions
//     before you connect.
device.cancelWhenDisconnected(subscription, delayed:true, next:true);

// Connect to the device
await device.connect();

// Disconnect from device
await device.disconnect();

// cancel to prevent duplicate listeners
subscription.cancel();
```

4. MTU

```
   final subscription = device.mtu.listen((int mtu) {
    // iOS: initial value is always 23, but iOS will quickly negotiate a higher value
    print("mtu $mtu");
});

// cleanup: cancel subscription when disconnected
device.cancelWhenDisconnected(subscription);

// You can also manually change the mtu yourself.
if (Platform.isAndroid||Platform.operatingSystem == 'ohos') {
    await device.requestMtu(512);
}
```

5. 发现服务

```
   // Note: You must call discoverServices after every re-connection!
List<BluetoothService> services = await device.discoverServices();
services.forEach((service) {
    // do something with service
});
```

6. 写入特性

```
// Writes to a characteristic
await c.write([0x12, 0x34]);
allowLongWrite：要写入大型特征（最多 512 字节），而不考虑 mtu，请使用：allowLongWrite
await c.write(data, allowLongWrite:true);
```

7. 订阅特征

```
        final subscription = characteristic.onValueReceived.listen((value) {
    // onValueReceived is updated:
    //   - anytime read() is called
    //   - anytime a notification arrives (if subscribed)
});

// cleanup: cancel subscription when disconnected
device.cancelWhenDisconnected(subscription);

// subscribe
// Note: If a characteristic supports both **notifications** and **indications**,
// it will default to **notifications**. This matches how CoreBluetooth works on iOS.
await characteristic.setNotifyValue(true);
```

8. 读取和写入描述符

```
            // Reads all descriptors
var descriptors = characteristic.descriptors;
for(BluetoothDescriptor d in descriptors) {
    List<int> value = await d.read();
    print(value);
}

// Writes to a descriptor
await d.write([0x12, 0x34])
          
```

9. 获取互联设备

```
List<BluetoothDevice> devs = FlutterBluePlus.connectedDevices;
for (var d in devs) {
    print(d);
}
          
```

### FlutterBluePlus API

|                        |  Android  |        iOS         | Ohos | Description                                                |
| :--------------------- |:---------:| :----------------: | :----: | :----------------------------------------------------------|
| setLogLevel            | :white_check_mark: | :white_check_mark: | :white_check_mark: | Configure plugin log level                                 |
| setOptions             | :white_check_mark: | :white_check_mark: | :white_check_mark: | Set configurable bluetooth options                         |
| isSupported            | :white_check_mark: | :white_check_mark: | :white_check_mark: | Checks whether the device supports Bluetooth               |
| turnOn                 | :white_check_mark: |  | :white_check_mark: | Turns on the bluetooth adapter                             |
| turnOff                 | :white_check_mark: |  | :white_check_mark: | Turns off the bluetooth adapter                             |
| adapterStateNow  | :white_check_mark: | :white_check_mark: |        | Current state of the bluetooth adapter                     |
| adapterState | :white_check_mark: | :white_check_mark: | :white_check_mark: | Stream of on & off states of the bluetooth adapter         |
| startScan              | :white_check_mark: | :white_check_mark: | :white_check_mark: | Starts a scan for Ble devices                              |
| stopScan               | :white_check_mark: | :white_check_mark: | :white_check_mark: | Stop an existing scan for Ble devices                      |
| onScanResults | :white_check_mark: | :white_check_mark: | :white_check_mark: | Stream of live scan results                                |
| scanResults | :white_check_mark: | :white_check_mark: | :white_check_mark: | Stream of live scan results or previous results            |
| lastScanResults  | :white_check_mark: | :white_check_mark: | :white_check_mark: | The most recent scan results                               |
| isScanning | :white_check_mark: | :white_check_mark: | :white_check_mark: | Stream of current scanning state                           |
| isScanningNow  | :white_check_mark: | :white_check_mark: | :white_check_mark: | Is a scan currently running?                               |
| connectedDevices  | :white_check_mark: | :white_check_mark: | :white_check_mark: | List of devices connected to *your app*                    |
| systemDevices          | :white_check_mark: | :white_check_mark: | :white_check_mark: | List of devices connected to the system, even by other apps|
| getPhySupport          | :white_check_mark: |                    |  | Get supported bluetooth phy codings                        |

### FlutterBluePlus Events API

|                                   |      Android       |        iOS         |        Ohos        | Description                                            |
| :-------------------------------- | :----------------: | :----------------: | :----------------: | :----------------------------------------------------- |
| events.onConnectionStateChanged 🌀 | :white_check_mark: | :white_check_mark: | :white_check_mark: | Stream of connection changes of *all devices*          |
| events.onMtuChanged             🌀 | :white_check_mark: | :white_check_mark: | :white_check_mark: | Stream of mtu changes of *all devices*                 |
| events.onReadRssi               🌀 | :white_check_mark: | :white_check_mark: | :white_check_mark: | Stream of rssi reads of *all devices*                  |
| events.onServicesReset          🌀 | :white_check_mark: | :white_check_mark: |                    | Stream of services resets of *all devices*             |
| events.onDiscoveredServices     🌀 | :white_check_mark: | :white_check_mark: | :white_check_mark: | Stream of services discovered of *all devices*         |
| events.onCharacteristicReceived 🌀 | :white_check_mark: | :white_check_mark: | :white_check_mark: | Stream of characteristic value reads of *all devices*  |
| events.onCharacteristicWritten  🌀 | :white_check_mark: | :white_check_mark: | :white_check_mark: | Stream of characteristic value writes of *all devices* |
| events.onDescriptorRead         🌀 | :white_check_mark: | :white_check_mark: | :white_check_mark: | Stream of descriptor value reads of *all devices*      |
| events.onDescriptorWritten      🌀 | :white_check_mark: | :white_check_mark: | :white_check_mark: | Stream of descriptor value writes of *all devices*     |
| events.onBondStateChanged       🌀 | :white_check_mark: |                    |                    | Stream of android bond state changes of *all devices*  |
| events.onNameChanged            🌀 |                    | :white_check_mark: |                    | Stream of iOS name changes of *all devices*            |


### BluetoothDevice API

|                           |      Android       |        iOS         |        Ohos        | Description                                                |
| :------------------------ | :----------------: | :----------------: | :----------------: | :--------------------------------------------------------- |
| platformName            ⚡ | :white_check_mark: | :white_check_mark: | :white_check_mark: | The platform preferred name of the device                  |
| advName                 ⚡ | :white_check_mark: | :white_check_mark: | :white_check_mark: | The advertised name of the device found during scanning    |
| connect                   | :white_check_mark: | :white_check_mark: | :white_check_mark: | Establishes a connection to the device                     |
| disconnect                | :white_check_mark: | :white_check_mark: | :white_check_mark: | Cancels an active or pending connection to the device      |
| isConnected             ⚡ | :white_check_mark: | :white_check_mark: | :white_check_mark: | Is this device currently connected to *your app*?          |
| isDisonnected           ⚡ | :white_check_mark: | :white_check_mark: | :white_check_mark: | Is this device currently disconnected from *your app*?     |
| connectionState        🌀  | :white_check_mark: | :white_check_mark: | :white_check_mark: | Stream of connection changes for the Bluetooth Device      |
| discoverServices          | :white_check_mark: | :white_check_mark: | :white_check_mark: | Discover services                                          |
| servicesList            ⚡ | :white_check_mark: | :white_check_mark: | :white_check_mark: | The current list of available services                     |
| onServicesReset        🌀  | :white_check_mark: | :white_check_mark: |                    | The services changed & must be rediscovered                |
| mtu                    🌀  | :white_check_mark: | :white_check_mark: |                    | Stream of current mtu value + changes                      |
| mtuNow                  ⚡ | :white_check_mark: | :white_check_mark: |                    | The current mtu value                                      |
| readRssi                  | :white_check_mark: | :white_check_mark: | :white_check_mark: | Read RSSI from a connected device                          |
| requestMtu                | :white_check_mark: |                    | :white_check_mark: | Request to change the MTU for the device                   |
| requestConnectionPriority | :white_check_mark: |                    |                    | Request to update a high priority, low latency connection  |
| bondState              🌀  | :white_check_mark: |                    |                    | Stream of device bond state. Can be useful on Android      |
| createBond                | :white_check_mark: |                    |                    | Force a system pairing dialogue to show, if needed         |
| removeBond                | :white_check_mark: |                    |                    | Remove Bluetooth Bond of device                            |
| setPreferredPhy           | :white_check_mark: |                    |                    | Set preferred RX and TX phy for connection and phy options |
| clearGattCache            | :white_check_mark: |                    |                    | Clear android cache of service discovery results           |

### BluetoothCharacteristic API

|                    |      Android       |        iOS         |        Ohos        | Description                                                  |
| :----------------- | :----------------: | :----------------: | :----------------: | :----------------------------------------------------------- |
| uuid             ⚡ | :white_check_mark: | :white_check_mark: | :white_check_mark: | The uuid of characteristic                                   |
| read               | :white_check_mark: | :white_check_mark: | :white_check_mark: | Retrieves the value of the characteristic                    |
| write              | :white_check_mark: | :white_check_mark: | :white_check_mark: | Writes the value of the characteristic                       |
| setNotifyValue     | :white_check_mark: | :white_check_mark: | :white_check_mark: | Sets notifications or indications on the characteristic      |
| isNotifying      ⚡ | :white_check_mark: | :white_check_mark: | :white_check_mark: | Are notifications or indications currently enabled           |
| onValueReceived 🌀  | :white_check_mark: | :white_check_mark: | :white_check_mark: | Stream of characteristic value updates received from the device |
| lastValue        ⚡ | :white_check_mark: | :white_check_mark: | :white_check_mark: | The most recent value of the characteristic                  |
| lastValueStream 🌀  | :white_check_mark: | :white_check_mark: | :white_check_mark: | Stream of onValueReceived + writes                           |

### BluetoothDescriptor API

|                    |      Android       |        iOS         |        Ohos        | Description                               |
| :----------------- | :----------------: | :----------------: | :----------------: | :---------------------------------------- |
| uuid             ⚡ | :white_check_mark: | :white_check_mark: | :white_check_mark: | The uuid of descriptor                    |
| read               | :white_check_mark: | :white_check_mark: | :white_check_mark: | Retrieves the value of the descriptor     |
| write              | :white_check_mark: | :white_check_mark: | :white_check_mark: | Writes the value of the descriptor        |
| onValueReceived 🌀  | :white_check_mark: | :white_check_mark: | :white_check_mark: | Stream of descriptor value reads & writes |
| lastValue        ⚡ | :white_check_mark: | :white_check_mark: | :white_check_mark: | The most recent value of the descriptor   |
| lastValueStream 🌀  | :white_check_mark: | :white_check_mark: | :white_check_mark: | Stream of onValueReceived + writes        |


## 约束与限制

-  DevEco Studio: 6.0.1

- sdk：6.0.1(21)

