# 二进制 write 通道对齐 Linux/Web/OHOS 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Linux/Web/OHOS 三个平台真实实现二进制 write 通道（writeCharacteristic / writeDescriptor / setNotifyValue），与 iOS/Android 对齐。

**Architecture:** 沿用 iOS/Android 既有模式——平台插件类持有 handler，handler 复用插件内部状态与写入逻辑。三平台写入 API 均可 await，handler 内 await 写入完成后直接回包（encodeResponse），无需 pendingReplies。事件发射保持（onCharacteristicWritten / onDescriptorWritten）。

**Tech Stack:** Dart 3（records）、flutter_blue_plus_platform_interface（binary_protocol.dart）、BlueZ dart:ffi（Linux）、Web Bluetooth JS interop（Web）、ArkTS + @ohos/flutter_ohos（OHOS）。

**Spec:** `docs/superpowers/specs/2026-07-31-binary-channel-platform-alignment-design.md`

## Global Constraints

- 不改 Dart 端 `_BinaryWriteChannel`（lib/src/binary_channel.dart）与协议格式（platform_interface/lib/src/binary_protocol.dart）
- 不改 iOS/Android 实现
- 不做 pendingReplies 机制（三平台写入 API 均可 await）
- 事件语义保持：二进制路径仍发射 onCharacteristicWritten / onDescriptorWritten 事件
- 错误码对齐 iOS/Android 约定：-1 协议错误、1 设备未连接、2 特征未找到、3 属性不支持、4 写入失败、5 描述符未找到、6/7 CCCD 相关
- 仓库根：`/Users/shingo/develop/hujie/flutter_blue_plus`（工作目录 `packages/flutter_blue_plus`）
- 工作区存在大量未提交改动（二进制通道既有实现）——**每个任务只 `git add` 本任务涉及的文件**，不混入其他改动
- 所有命令在仓库根运行；Dart 3.0+ 已满足（pubspec `sdk: ^3.0.0`），records 可用

---

### Task 1: 协议层回归测试（platform_interface）

**Files:**
- Create: `packages/flutter_blue_plus_platform_interface/test/binary_protocol_test.dart`

**Interfaces:**
- Consumes: `encodeWriteCharacteristic` / `encodeWriteDescriptor` / `encodeSetNotifyValue` / `encodeResponse` / `decodeResponse` / `BinaryCommand` / `WriteFlags` / `NotifyFlags`（均在 `packages/flutter_blue_plus_platform_interface/lib/src/binary_protocol.dart`）
- Produces: 对既有编解码行为的回归锁存（后续任务不改协议层，此测试保证协议格式不被意外改动）

- [ ] **Step 1: 创建测试文件** `packages/flutter_blue_plus_platform_interface/test/binary_protocol_test.dart`：

```dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart'
    show BinaryCommand, WriteFlags, NotifyFlags, encodeResponse, decodeResponse,
        encodeWriteCharacteristic, encodeWriteDescriptor, encodeSetNotifyValue;

void main() {
  group('encodeWriteCharacteristic', () {
    ByteData encode() => encodeWriteCharacteristic(
          flags: WriteFlags.withoutResponse,
          instanceId: 3,
          remoteId: 'AA:BB:CC:DD:EE:FF',
          serviceUuid: '180d',
          characteristicUuid: '2a37',
          primaryServiceUuid: '180d',
          value: [0x01, 0x02, 0x03],
        );

    test('header: cmd, flags, instanceId', () {
      final data = encode();
      expect(data.getUint8(0), BinaryCommand.writeCharacteristic);
      expect(data.getUint8(1), WriteFlags.withoutResponse);
      expect(data.getUint16(2), 3);
    });

    test('16-bit UUIDs are sent in shortest form', () {
      final data = encode();
      final bytes = data.buffer.asUint8List();
      // offset 4: remoteId(1+17) = 21; serviceUuid len+str at 21
      expect(bytes[21], 4);
      expect(String.fromCharCodes(bytes.sublist(22, 26)), '180d');
    });

    test('value bytes appended after 5 strings + valueLen', () {
      final data = encode();
      final bytes = data.buffer.asUint8List();
      // 1+1+2 + (1+17) + (1+4) + (1+4) + (1+4) + (1+0) = 38; valueLen at 38
      expect(bytes[38] << 8 | bytes[39], 3);
      expect(bytes[40], 0x01);
      expect(bytes[41], 0x02);
      expect(bytes[42], 0x03);
    });

    test('empty primaryServiceUuid encodes as zero-length string', () {
      final data = encodeWriteCharacteristic(
        flags: 0,
        instanceId: 0,
        remoteId: 'AA:BB:CC:DD:EE:FF',
        serviceUuid: '180d',
        characteristicUuid: '2a37',
        primaryServiceUuid: null,
        value: [],
      );
      final bytes = data.buffer.asUint8List();
      // 1+1+2 + (1+17) + (1+4) + (1+4) = 31; primary len at 31
      expect(bytes[31], 0);
    });
  });

  group('encodeWriteDescriptor', () {
    test('includes descriptorUuid', () {
      final data = encodeWriteDescriptor(
        flags: 0,
        instanceId: 0,
        remoteId: 'AA:BB:CC:DD:EE:FF',
        serviceUuid: '180d',
        characteristicUuid: '2a37',
        primaryServiceUuid: null,
        descriptorUuid: '2902',
        value: [0x01, 0x00],
      );
      expect(data.getUint8(0), BinaryCommand.writeDescriptor);
      final bytes = data.buffer.asUint8List();
      // 1+1+2 + (1+17) + (1+4) + (1+4) + (1+0) = 32; desc len at 32
      expect(bytes[32], 4);
      expect(String.fromCharCodes(bytes.sublist(33, 37)), '2902');
    });
  });

  group('encodeSetNotifyValue', () {
    test('flags carry enable', () {
      final data = encodeSetNotifyValue(
        flags: NotifyFlags.enable,
        instanceId: 1,
        remoteId: 'AA:BB:CC:DD:EE:FF',
        serviceUuid: '180d',
        characteristicUuid: '2a37',
        primaryServiceUuid: null,
      );
      expect(data.getUint8(0), BinaryCommand.setNotifyValue);
      expect(data.getUint8(1), NotifyFlags.enable);
      expect(data.getUint16(2), 1);
    });
  });

  group('decodeResponse / encodeResponse', () {
    test('success roundtrip', () {
      final data = encodeResponse(success: true);
      final result = decodeResponse(data);
      expect(result['success'], 1);
      expect(result['errorCode'], 0);
      expect(result['errorString'], '');
    });

    test('error roundtrip', () {
      final data = encodeResponse(success: false, errorCode: 4, errorString: 'write failed');
      final result = decodeResponse(data);
      expect(result['success'], 0);
      expect(result['errorCode'], 4);
      expect(result['errorString'], 'write failed');
    });
  });
}
```

- [ ] **Step 2: 运行测试验证通过（锁存既有行为，应为 PASS）**

Run: `cd packages/flutter_blue_plus_platform_interface && flutter test`
Expected: `All tests passed!`

- [ ] **Step 3: 提交**

```bash
git add packages/flutter_blue_plus_platform_interface/test/binary_protocol_test.dart
git commit -m "test: lock binary protocol encode/decode behavior"
```

---

### Task 2: Linux 二进制通道

**Files:**
- Modify: `packages/flutter_blue_plus_linux/lib/src/binary_handler.dart`（占位 handler → 真实实例类）
- Modify: `packages/flutter_blue_plus_linux/lib/flutter_blue_plus_linux.dart`（新增 3 个 core 方法；writeCharacteristic/writeDescriptor/setNotifyValue 改造为委托）

**Interfaces:**
- Consumes: `BmWriteCharacteristicRequest` / `BmWriteDescriptorRequest` / `BmSetNotifyValueRequest`、`_onCharacteristicWrittenController` / `_onDescriptorWrittenController`、`_findCharacteristic` / `_instanceId`、`BlueZGattCharacteristicWriteType`（均在 flutter_blue_plus_linux.dart）
- Produces: `FlutterBluePlusLinux.binaryWriteCharacteristic` / `binaryWriteDescriptor` / `binarySetNotifyValue` —— 签名见下方代码；`LinuxBinaryHandler.register()` / `unregister()`，`registerWith()` 内接线

**前置事实：** Linux 包无 test 目录、`registerWith()` 为无参 static（:1067）。`BasicMessageChannel` 无 messenger 参数时使用默认 messenger，Dart 侧注册即可收到 `_BinaryWriteChannel` 的消息。

- [ ] **Step 1: 在 flutter_blue_plus_linux.dart 新增 core 方法**（放在 `writeCharacteristic` 附近）。返回 Dart 3 record `({bool success, int errorCode, String errorString})`。**事件语义：所有失败分支（设备查找、特征查找、写入失败）与成功分支都发射事件**——用户层 onCharacteristicWritten 监听不能因二进制路径而中断：

```dart
  /// Binary channel core: write a characteristic value.
  /// Emits onCharacteristicWritten events like [writeCharacteristic].
  Future<({bool success, int errorCode, String errorString})> binaryWriteCharacteristic({
    required String remoteId,
    required Guid? primaryServiceUuid,
    required Guid serviceUuid,
    required Guid characteristicUuid,
    required int instanceId,
    required bool withoutResponse,
    required List<int> value,
  }) async {
    BlueZDevice? device;
    try {
      await _initFlutterBluePlus();
      device = _client.devices.singleWhere((d) => d.remoteId.str == remoteId);
    } catch (e) {
      _onCharacteristicWrittenController.add(BmCharacteristicData(
        remoteId: DeviceIdentifier(remoteId),
        primaryServiceUuid: null,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        instanceId: instanceId,
        value: value,
        success: false,
        errorCode: 0,
        errorString: 'device is not connected',
      ));
      return (success: false, errorCode: 1, errorString: 'device is not connected');
    }

    _LinuxFoundCharacteristic found;
    try {
      found = _findCharacteristic(device, serviceUuid, characteristicUuid, instanceId);
    } on StateError catch (e) {
      _onCharacteristicWrittenController.add(BmCharacteristicData(
        remoteId: DeviceIdentifier(remoteId),
        primaryServiceUuid: null,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        instanceId: instanceId,
        value: value,
        success: false,
        errorCode: 0,
        errorString: e.toString(),
      ));
      return (success: false, errorCode: 2, errorString: e.toString());
    }
    final service = found.service;
    final characteristic = found.characteristic;

    try {
      await characteristic.writeValue(
        value,
        type: withoutResponse
            ? BlueZGattCharacteristicWriteType.command
            : BlueZGattCharacteristicWriteType.request,
      );
    } catch (e) {
      _onCharacteristicWrittenController.add(BmCharacteristicData(
        remoteId: device.remoteId,
        primaryServiceUuid: null,
        serviceUuid: Guid.fromBytes(service.uuid.value),
        characteristicUuid: Guid.fromBytes(characteristic.uuid.value),
        instanceId: _instanceId(device, service, characteristic),
        value: value,
        success: false,
        errorCode: 0,
        errorString: e.toString(),
      ));
      return (success: false, errorCode: 4, errorString: e.toString());
    }

    _onCharacteristicWrittenController.add(BmCharacteristicData(
      remoteId: device.remoteId,
      primaryServiceUuid: null,
      serviceUuid: Guid.fromBytes(service.uuid.value),
      characteristicUuid: Guid.fromBytes(characteristic.uuid.value),
      instanceId: _instanceId(device, service, characteristic),
      value: value,
      success: true,
      errorCode: 0,
      errorString: '',
    ));
    return (success: true, errorCode: 0, errorString: '');
  }
```

`binaryWriteDescriptor` 的设备查找（1）、特征查找（2）、descriptor 查找（5）失败分支同样先发 `BmDescriptorData` 失败事件，再返回错误码（与 write 路径及 public 方法 catch 行为对齐）。`binarySetNotifyValue` 全分支不发事件——Linux public setNotifyValue 原实现即无事件发射（startNotify/stopNotify 无 written 事件语义），二进制路径与之对齐。

- [ ] **Step 2: 同样新增 `binaryWriteDescriptor` 与 `binarySetNotifyValue`**

```dart
  /// Binary channel core: write a descriptor value.
  Future<({bool success, int errorCode, String errorString})> binaryWriteDescriptor({
    required String remoteId,
    required Guid? primaryServiceUuid,
    required Guid serviceUuid,
    required Guid characteristicUuid,
    required int instanceId,
    required Guid descriptorUuid,
    required List<int> value,
  }) async {
    BlueZDevice? device;
    try {
      await _initFlutterBluePlus();
      device = _client.devices.singleWhere((d) => d.remoteId.str == remoteId);
    } catch (e) {
      return (success: false, errorCode: 1, errorString: 'device is not connected');
    }

    _LinuxFoundCharacteristic found;
    try {
      found = _findCharacteristic(device, serviceUuid, characteristicUuid, instanceId);
    } on StateError catch (e) {
      return (success: false, errorCode: 2, errorString: e.toString());
    }
    final service = found.service;
    final characteristic = found.characteristic;

    final descriptor;
    try {
      descriptor = characteristic.descriptors.singleWhere((d) {
        return Guid.fromBytes(d.uuid.value) == descriptorUuid;
      });
    } on StateError {
      return (success: false, errorCode: 5, errorString: 'descriptor not found');
    }

    try {
      await descriptor.writeValue(value);
    } catch (e) {
      _onDescriptorWrittenController.add(BmDescriptorData(
        remoteId: device.remoteId,
        primaryServiceUuid: null,
        serviceUuid: Guid.fromBytes(service.uuid.value),
        characteristicUuid: Guid.fromBytes(characteristic.uuid.value),
        instanceId: _instanceId(device, service, characteristic),
        descriptorUuid: descriptorUuid,
        value: value,
        success: false,
        errorCode: 0,
        errorString: e.toString(),
      ));
      return (success: false, errorCode: 4, errorString: e.toString());
    }

    _onDescriptorWrittenController.add(BmDescriptorData(
      remoteId: device.remoteId,
      primaryServiceUuid: null,
      serviceUuid: Guid.fromBytes(service.uuid.value),
      characteristicUuid: Guid.fromBytes(characteristic.uuid.value),
      instanceId: _instanceId(device, service, characteristic),
      descriptorUuid: descriptorUuid,
      value: value,
      success: true,
      errorCode: 0,
      errorString: '',
    ));
    return (success: true, errorCode: 0, errorString: '');
  }
```

```dart
  /// Binary channel core: enable/disable notifications.
  Future<({bool success, int errorCode, String errorString})> binarySetNotifyValue({
    required String remoteId,
    required Guid? primaryServiceUuid,
    required Guid serviceUuid,
    required Guid characteristicUuid,
    required int instanceId,
    required bool enable,
  }) async {
    BlueZDevice? device;
    try {
      await _initFlutterBluePlus();
      device = _client.devices.singleWhere((d) => d.remoteId.str == remoteId);
    } catch (e) {
      return (success: false, errorCode: 1, errorString: 'device is not connected');
    }

    _LinuxFoundCharacteristic found;
    try {
      found = _findCharacteristic(device, serviceUuid, characteristicUuid, instanceId);
    } on StateError catch (e) {
      return (success: false, errorCode: 2, errorString: e.toString());
    }
    final characteristic = found.characteristic;

    try {
      if (enable) {
        await characteristic.startNotify();
      } else {
        await characteristic.stopNotify();
      }
    } catch (e) {
      return (success: false, errorCode: 4, errorString: e.toString());
    }
    return (success: true, errorCode: 0, errorString: '');
  }
```

- [ ] **Step 3: 不改动既有 public 方法**（`writeCharacteristic` :925、`writeDescriptor` :992、`setNotifyValue` :813 保持原实现）

**理由（pre-flight 修正）：** 委托会引入行为回归——原 `setNotifyValue` 无 try/catch（异常直接传播，Dart 端 `invokeMethod` 快速失败）；委托后失败变静默返回 false，Dart 端 MethodChannel 路径会等待事件流直到 15s 超时。core 方法是二进制路径专用新代码（错误码语义与 MethodChannel 路径不同），两个路径各自独立。代码有适度重复（write 校验/写入核心 ~50 行），可接受。

- [ ] **Step 4: 重写 `src/binary_handler.dart` 为实例类**（替换整个文件）：

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart'
    show binaryChannelName, encodeResponse, BinaryCommand, WriteFlags, NotifyFlags, Guid;

import '../flutter_blue_plus_linux.dart';

/// Binary message handler for Linux platform.
///
/// Registered by [FlutterBluePlusLinux.registerWith] to handle binary protocol
/// write requests with minimal overhead. All writes go through the plugin's
/// binary* core methods, which emit the same events as the MethodChannel path.
class LinuxBinaryHandler {
  LinuxBinaryHandler(this._plugin);

  final FlutterBluePlusLinux _plugin;

  BasicMessageChannel<ByteData>? _channel;

  /// Register the binary message handler.
  void register() {
    if (_channel != null) return;
    _channel = BasicMessageChannel<ByteData>(binaryChannelName, BinaryCodec());
    _channel!.setMessageHandler(_handleMessage);
  }

  /// Unregister the binary message handler.
  void unregister() {
    _channel?.setMessageHandler(null);
    _channel = null;
  }

  Future<ByteData?> _handleMessage(ByteData? message) async {
    if (message == null) return null;
    try {
      return await _handleMessageInner(message);
    } catch (e) {
      return encodeResponse(success: false, errorCode: -1, errorString: e.toString());
    }
  }

  Future<ByteData> _handleMessageInner(ByteData data) async {
    if (data.lengthInBytes < 4) {
      return encodeResponse(success: false, errorCode: -1, errorString: 'invalid message');
    }
    final cmd = data.getUint8(0);
    final flags = data.getUint8(1);
    final instanceId = data.getUint16(2);
    int offset = 4;

    String? readString() {
      if (offset >= data.lengthInBytes) return null;
      final len = data.getUint8(offset);
      offset += 1;
      if (len == 0) return '';
      if (offset + len > data.lengthInBytes) return null;
      final s = String.fromCharCodes(data.buffer.asUint8List().sublist(offset, offset + len));
      offset += len;
      return s;
    }

    ByteData? err(int code, String msg) =>
        encodeResponse(success: false, errorCode: code, errorString: msg);

    final remoteId = readString();
    if (remoteId == null) return err(-1, 'missing remoteId');
    final serviceUuid = readString();
    if (serviceUuid == null) return err(-1, 'missing serviceUuid');
    final characteristicUuid = readString();
    if (characteristicUuid == null) return err(-1, 'missing characteristicUuid');
    final primaryServiceUuid = readString() ?? '';
    final descriptorUuid = readString() ?? '';

    switch (cmd) {
      case BinaryCommand.writeCharacteristic: {
        final value = _readValue(data, offset);
        if (value == null) return err(-1, 'missing value');
        final result = await _plugin.binaryWriteCharacteristic(
          remoteId: remoteId,
          primaryServiceUuid: primaryServiceUuid.isEmpty ? null : Guid(primaryServiceUuid),
          serviceUuid: Guid(serviceUuid),
          characteristicUuid: Guid(characteristicUuid),
          instanceId: instanceId,
          withoutResponse: (flags & WriteFlags.withoutResponse) != 0,
          value: value,
        );
        return encodeResponse(
            success: result.success, errorCode: result.errorCode, errorString: result.errorString);
      }
      case BinaryCommand.writeDescriptor: {
        final value = _readValue(data, offset);
        if (value == null) return err(-1, 'missing value');
        final result = await _plugin.binaryWriteDescriptor(
          remoteId: remoteId,
          primaryServiceUuid: primaryServiceUuid.isEmpty ? null : Guid(primaryServiceUuid),
          serviceUuid: Guid(serviceUuid),
          characteristicUuid: Guid(characteristicUuid),
          instanceId: instanceId,
          descriptorUuid: Guid(descriptorUuid),
          value: value,
        );
        return encodeResponse(
            success: result.success, errorCode: result.errorCode, errorString: result.errorString);
      }
      case BinaryCommand.setNotifyValue: {
        final result = await _plugin.binarySetNotifyValue(
          remoteId: remoteId,
          primaryServiceUuid: primaryServiceUuid.isEmpty ? null : Guid(primaryServiceUuid),
          serviceUuid: Guid(serviceUuid),
          characteristicUuid: Guid(characteristicUuid),
          instanceId: instanceId,
          enable: (flags & NotifyFlags.enable) != 0,
        );
        return encodeResponse(
            success: result.success, errorCode: result.errorCode, errorString: result.errorString);
      }
      default:
        return err(-1, 'unknown cmd: $cmd');
    }
  }

  List<int>? _readValue(ByteData data, int offset) {
    if (offset + 2 > data.lengthInBytes) return null;
    final len = data.getUint16(offset);
    offset += 2;
    if (offset + len > data.lengthInBytes) return null;
    return data.buffer.asUint8List().sublist(offset, offset + len);
  }
}
```

- [ ] **Step 5: 在 `registerWith()` 接线**（:1067）：

```dart
  static void registerWith() {
    FlutterBluePlusPlatform.instance = FlutterBluePlusLinux();
  }
```

改为：

```dart
  static void registerWith() {
    final plugin = FlutterBluePlusLinux();
    FlutterBluePlusPlatform.instance = plugin;
    plugin._binaryHandler.register();
  }
```

并在类内新增字段（`_client` 附近）：

```dart
  final LinuxBinaryHandler _binaryHandler = LinuxBinaryHandler(_currentPlugin?);
```

**注意：** 无法在字段初始化器引用 `this`——改为在 `registerWith` 中赋值：

```dart
  static void registerWith() {
    final plugin = FlutterBluePlusLinux();
    FlutterBluePlusPlatform.instance = plugin;
    plugin._initBinaryHandler();
  }
```

类内新增：

```dart
  LinuxBinaryHandler? _binaryHandler;

  void _initBinaryHandler() {
    _binaryHandler = LinuxBinaryHandler(this);
    _binaryHandler!.register();
  }
```

- [ ] **Step 6: 静态检查**

Run: `cd packages/flutter_blue_plus_linux && flutter analyze`
Expected: `No issues found!`

- [ ] **Step 7: 提交**

```bash
git add packages/flutter_blue_plus_linux/lib/src/binary_handler.dart packages/flutter_blue_plus_linux/lib/flutter_blue_plus_linux.dart
git commit -m "feat(linux): real binary channel for write/descriptor/notify"
```

---

### Task 3: Web 二进制通道

**Files:**
- Modify: `packages/flutter_blue_plus_web/lib/src/binary_handler.dart`（占位 handler → 真实实例类）
- Modify: `packages/flutter_blue_plus_web/lib/flutter_blue_plus_web.dart`（新增 3 个 core 方法；writeCharacteristic/writeDescriptor/setNotifyValue 改造为委托）

**Interfaces:**
- Consumes: `_devices` map、`_findCharacteristicOrThrow`、`_onCharacteristicWrittenController` / `_onDescriptorWrittenController`、`_characteristicValueChangedEventListener`（均在 flutter_blue_plus_web.dart）
- Produces: `FlutterBluePlusWeb.binaryWriteCharacteristic` / `binaryWriteDescriptor` / `binarySetNotifyValue`；`WebBinaryHandler.register()` / `unregister()`；`registerWith(Registrar)` 内接线

**与 Linux 的差异：** Web 的 `_devices[remoteId]` 返回 null（不抛异常）；`_findCharacteristicOrThrow` 抛普通 `Exception`；写入 API 返回 JS Promise 需 `.toDart`；属性不支持时浏览器抛 `NotSupportedError`（错误消息含 "NotSupported"）。

- [ ] **Step 1: 在 flutter_blue_plus_web.dart 新增 core 方法**（放在 `writeCharacteristic` 附近）：

```dart
  /// Binary channel core: write a characteristic value.
  /// Emits onCharacteristicWritten events like [writeCharacteristic].
  Future<({bool success, int errorCode, String errorString})> binaryWriteCharacteristic({
    required String remoteId,
    required Guid? primaryServiceUuid,
    required Guid serviceUuid,
    required Guid characteristicUuid,
    required int instanceId,
    required bool withoutResponse,
    required List<int> value,
  }) async {
    final device = _devices[DeviceIdentifier(remoteId)];
    if (device == null) {
      _onCharacteristicWrittenController.add(BmCharacteristicData(
        remoteId: DeviceIdentifier(remoteId),
        primaryServiceUuid: null,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        instanceId: instanceId,
        value: value,
        success: false,
        errorCode: 0,
        errorString: 'device is not connected',
      ));
      return (success: false, errorCode: 1, errorString: 'device is not connected');
    }
    final gatt = device.gatt;
    if (gatt == null) {
      return (success: false, errorCode: 1, errorString: 'gatt is null');
    }

    final BluetoothRemoteGATTCharacteristic characteristic;
    try {
      characteristic = _findCharacteristicOrThrow(
        devId: device.remoteId,
        serviceUuid: Guid(serviceUuid.str128),
        charUuid: Guid(characteristicUuid.str128),
        instanceId: instanceId,
      );
    } catch (e) {
      _onCharacteristicWrittenController.add(BmCharacteristicData(
        remoteId: DeviceIdentifier(remoteId),
        primaryServiceUuid: null,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        instanceId: instanceId,
        value: value,
        success: false,
        errorCode: 0,
        errorString: e.toString(),
      ));
      return (success: false, errorCode: 2, errorString: e.toString());
    }

    try {
      if (withoutResponse) {
        await characteristic.writeValueWithoutResponse(Uint8List.fromList(value).toJS).toDart;
      } else {
        await characteristic.writeValueWithResponse(Uint8List.fromList(value).toJS).toDart;
      }
    } catch (e) {
      _onCharacteristicWrittenController.add(BmCharacteristicData(
        remoteId: device.remoteId,
        primaryServiceUuid: null,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        instanceId: instanceId,
        value: value,
        success: false,
        errorCode: 0,
        errorString: e.toString(),
      ));
      final code = e.toString().contains('NotSupported') ? 3 : 4;
      return (success: false, errorCode: code, errorString: e.toString());
    }

    _onCharacteristicWrittenController.add(BmCharacteristicData(
      remoteId: device.remoteId,
      primaryServiceUuid: null,
      serviceUuid: serviceUuid,
      characteristicUuid: characteristicUuid,
      instanceId: instanceId,
      value: value,
      success: true,
      errorCode: 0,
      errorString: '',
    ));
    return (success: true, errorCode: 0, errorString: '');
  }
```

- [ ] **Step 2: 同样新增 `binaryWriteDescriptor` 与 `binarySetNotifyValue`**

```dart
  /// Binary channel core: write a descriptor value.
  Future<({bool success, int errorCode, String errorString})> binaryWriteDescriptor({
    required String remoteId,
    required Guid? primaryServiceUuid,
    required Guid serviceUuid,
    required Guid characteristicUuid,
    required int instanceId,
    required Guid descriptorUuid,
    required List<int> value,
  }) async {
    final device = _devices[DeviceIdentifier(remoteId)];
    if (device == null) {
      _onDescriptorWrittenController.add(BmDescriptorData(
        remoteId: DeviceIdentifier(remoteId),
        primaryServiceUuid: null,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        instanceId: instanceId,
        descriptorUuid: descriptorUuid,
        value: value,
        success: false,
        errorCode: 0,
        errorString: 'device is not connected',
      ));
      return (success: false, errorCode: 1, errorString: 'device is not connected');
    }
    final gatt = device.gatt;
    if (gatt == null) {
      return (success: false, errorCode: 1, errorString: 'gatt is null');
    }

    final BluetoothRemoteGATTCharacteristic characteristic;
    try {
      characteristic = _findCharacteristicOrThrow(
        devId: device.remoteId,
        serviceUuid: Guid(serviceUuid.str128),
        charUuid: Guid(characteristicUuid.str128),
        instanceId: instanceId,
      );
    } catch (e) {
      _onDescriptorWrittenController.add(BmDescriptorData(
        remoteId: DeviceIdentifier(remoteId),
        primaryServiceUuid: null,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        instanceId: instanceId,
        descriptorUuid: descriptorUuid,
        value: value,
        success: false,
        errorCode: 0,
        errorString: e.toString(),
      ));
      return (success: false, errorCode: 2, errorString: e.toString());
    }

    final BluetoothRemoteGATTDescriptor descriptor;
    try {
      descriptor = await characteristic.getDescriptor(descriptorUuid.str128.toJS).toDart;
    } catch (e) {
      return (success: false, errorCode: 5, errorString: e.toString());
    }

    try {
      await descriptor.writeValue(Uint8List.fromList(value).toJS).toDart;
    } catch (e) {
      _onDescriptorWrittenController.add(BmDescriptorData(
        remoteId: device.remoteId,
        primaryServiceUuid: null,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        instanceId: instanceId,
        descriptorUuid: descriptorUuid,
        value: value,
        success: false,
        errorCode: 0,
        errorString: e.toString(),
      ));
      return (success: false, errorCode: 4, errorString: e.toString());
    }

    _onDescriptorWrittenController.add(BmDescriptorData(
      remoteId: device.remoteId,
      primaryServiceUuid: null,
      serviceUuid: serviceUuid,
      characteristicUuid: characteristicUuid,
      instanceId: instanceId,
      descriptorUuid: descriptorUuid,
      value: value,
      success: true,
      errorCode: 0,
      errorString: '',
    ));
    return (success: true, errorCode: 0, errorString: '');
  }
```

```dart
  /// Binary channel core: enable/disable notifications.
  Future<({bool success, int errorCode, String errorString})> binarySetNotifyValue({
    required String remoteId,
    required Guid? primaryServiceUuid,
    required Guid serviceUuid,
    required Guid characteristicUuid,
    required int instanceId,
    required bool enable,
  }) async {
    final device = _devices[DeviceIdentifier(remoteId)];
    if (device == null) {
      return (success: false, errorCode: 1, errorString: 'device is not connected');
    }
    final gatt = device.gatt;
    if (gatt == null) {
      return (success: false, errorCode: 1, errorString: 'gatt is null');
    }

    final BluetoothRemoteGATTCharacteristic characteristic;
    try {
      characteristic = _findCharacteristicOrThrow(
        devId: device.remoteId,
        serviceUuid: Guid(serviceUuid.str128),
        charUuid: Guid(characteristicUuid.str128),
        instanceId: instanceId,
      );
    } catch (e) {
      return (success: false, errorCode: 2, errorString: e.toString());
    }

    try {
      if (enable) {
        characteristic.addEventListener(
          'characteristicvaluechanged',
          _characteristicValueChangedEventListener,
        );
        await characteristic.startNotifications().toDart;
      } else {
        await characteristic.stopNotifications().toDart;
        characteristic.removeEventListener(
          'characteristicvaluechanged',
          _characteristicValueChangedEventListener,
        );
      }
    } catch (e) {
      return (success: false, errorCode: 4, errorString: e.toString());
    }
    return (success: true, errorCode: 0, errorString: '');
  }
```

- [ ] **Step 3: 不改动既有 public 方法**（`writeCharacteristic` :624、`writeDescriptor` :696、`setNotifyValue` :458 保持原实现）

**理由（pre-flight 修正）：** 同 Task 2 Step 3——原 `setNotifyValue` 无 try/catch、返回 false 的语义依赖既有调用方；委托会改变 MethodChannel 路径的失败行为。core 方法是二进制路径专用新代码，两个路径各自独立。

- [ ] **Step 4: 重写 `src/binary_handler.dart` 为实例类**（替换整个文件，与 Linux 版同构，差异为分派调用 `_plugin.binaryWriteCharacteristic` 等）：

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart'
    show binaryChannelName, encodeResponse, BinaryCommand, WriteFlags, NotifyFlags, Guid;

import '../flutter_blue_plus_web.dart';

/// Binary message handler for Web platform.
///
/// Registered by [FlutterBluePlusWeb.registerWith] to handle binary protocol
/// write requests. All writes go through the plugin's binary* core methods.
class WebBinaryHandler {
  WebBinaryHandler(this._plugin);

  final FlutterBluePlusWeb _plugin;

  BasicMessageChannel<ByteData>? _channel;

  /// Register the binary message handler.
  void register() {
    if (_channel != null) return;
    _channel = BasicMessageChannel<ByteData>(binaryChannelName, BinaryCodec());
    _channel!.setMessageHandler(_handleMessage);
  }

  /// Unregister the binary message handler.
  void unregister() {
    _channel?.setMessageHandler(null);
    _channel = null;
  }

  Future<ByteData?> _handleMessage(ByteData? message) async {
    if (message == null) return null;
    try {
      return await _handleMessageInner(message);
    } catch (e) {
      return encodeResponse(success: false, errorCode: -1, errorString: e.toString());
    }
  }

  Future<ByteData> _handleMessageInner(ByteData data) async {
    if (data.lengthInBytes < 4) {
      return encodeResponse(success: false, errorCode: -1, errorString: 'invalid message');
    }
    final cmd = data.getUint8(0);
    final flags = data.getUint8(1);
    final instanceId = data.getUint16(2);
    int offset = 4;

    String? readString() {
      if (offset >= data.lengthInBytes) return null;
      final len = data.getUint8(offset);
      offset += 1;
      if (len == 0) return '';
      if (offset + len > data.lengthInBytes) return null;
      final s = String.fromCharCodes(data.buffer.asUint8List().sublist(offset, offset + len));
      offset += len;
      return s;
    }

    ByteData? err(int code, String msg) =>
        encodeResponse(success: false, errorCode: code, errorString: msg);

    final remoteId = readString();
    if (remoteId == null) return err(-1, 'missing remoteId');
    final serviceUuid = readString();
    if (serviceUuid == null) return err(-1, 'missing serviceUuid');
    final characteristicUuid = readString();
    if (characteristicUuid == null) return err(-1, 'missing characteristicUuid');
    final primaryServiceUuid = readString() ?? '';
    final descriptorUuid = readString() ?? '';

    switch (cmd) {
      case BinaryCommand.writeCharacteristic: {
        final value = _readValue(data, offset);
        if (value == null) return err(-1, 'missing value');
        final result = await _plugin.binaryWriteCharacteristic(
          remoteId: remoteId,
          primaryServiceUuid: primaryServiceUuid.isEmpty ? null : Guid(primaryServiceUuid),
          serviceUuid: Guid(serviceUuid),
          characteristicUuid: Guid(characteristicUuid),
          instanceId: instanceId,
          withoutResponse: (flags & WriteFlags.withoutResponse) != 0,
          value: value,
        );
        return encodeResponse(
            success: result.success, errorCode: result.errorCode, errorString: result.errorString);
      }
      case BinaryCommand.writeDescriptor: {
        final value = _readValue(data, offset);
        if (value == null) return err(-1, 'missing value');
        final result = await _plugin.binaryWriteDescriptor(
          remoteId: remoteId,
          primaryServiceUuid: primaryServiceUuid.isEmpty ? null : Guid(primaryServiceUuid),
          serviceUuid: Guid(serviceUuid),
          characteristicUuid: Guid(characteristicUuid),
          instanceId: instanceId,
          descriptorUuid: Guid(descriptorUuid),
          value: value,
        );
        return encodeResponse(
            success: result.success, errorCode: result.errorCode, errorString: result.errorString);
      }
      case BinaryCommand.setNotifyValue: {
        final result = await _plugin.binarySetNotifyValue(
          remoteId: remoteId,
          primaryServiceUuid: primaryServiceUuid.isEmpty ? null : Guid(primaryServiceUuid),
          serviceUuid: Guid(serviceUuid),
          characteristicUuid: Guid(characteristicUuid),
          instanceId: instanceId,
          enable: (flags & NotifyFlags.enable) != 0,
        );
        return encodeResponse(
            success: result.success, errorCode: result.errorCode, errorString: result.errorString);
      }
      default:
        return err(-1, 'unknown cmd: $cmd');
    }
  }

  List<int>? _readValue(ByteData data, int offset) {
    if (offset + 2 > data.lengthInBytes) return null;
    final len = data.getUint16(offset);
    offset += 2;
    if (offset + len > data.lengthInBytes) return null;
    return data.buffer.asUint8List().sublist(offset, offset + len);
  }
}
```

- [ ] **Step 5: 在 `registerWith()` 接线**（:92-96）：

```dart
  static void registerWith(
    Registrar registrar,
  ) {
    FlutterBluePlusPlatform.instance = FlutterBluePlusWeb();
  }
```

改为：

```dart
  static void registerWith(
    Registrar registrar,
  ) {
    final plugin = FlutterBluePlusWeb();
    FlutterBluePlusPlatform.instance = plugin;
    plugin._initBinaryHandler();
  }
```

类内新增：

```dart
  WebBinaryHandler? _binaryHandler;

  void _initBinaryHandler() {
    _binaryHandler = WebBinaryHandler(this);
    _binaryHandler!.register();
  }
```

- [ ] **Step 6: 静态检查**

Run: `cd packages/flutter_blue_plus_web && flutter analyze`
Expected: `No issues found!`

- [ ] **Step 7: 提交**

```bash
git add packages/flutter_blue_plus_web/lib/src/binary_handler.dart packages/flutter_blue_plus_web/lib/flutter_blue_plus_web.dart
git commit -m "feat(web): real binary channel for write/descriptor/notify"
```

---

### Task 4: OHOS 二进制通道

**Files:**
- Modify: `packages/flutter_blue_plus_ohos/ohos/src/main/ets/components/plugin/BinaryProtocolHandler.ets`（占位 → 真实 handler）
- Modify: `packages/flutter_blue_plus_ohos/ohos/src/main/ets/components/plugin/FlutterBluePlusOhosPlugin.ets`（新增 3 个 public binary 方法；`onAttachedToEngine` 接线）

**Interfaces:**
- Consumes: `mConnectedDevices`、`getServices()`、`locateCharacteristic`、`getMaxPayload`、`typedArrayToBuffer`、`uuidStr`、`getInstanceId`、`getPrimaryService`、`getReadDescriptorFromArray`、`mMtu`、`channel.invokeMethod("OnCharacteristicWritten"/"OnDescriptorWritten")`（均在 FlutterBluePlusOhosPlugin.ets，同文件内可访问 private）
- Produces: `FlutterBluePlusOhosPlugin.binaryWriteCharacteristic` / `binaryWriteDescriptor` / `binarySetNotifyValue` —— 返回 `Promise<Map<string, number | string>>`（键：`success` 0/1、`errorCode`、`errorString`）；`BinaryProtocolHandler.register(binding)` 真实注册

**环境约束：** 无 DevEco/设备，本任务验证 = 代码评审清单（Step 7）。

- [ ] **Step 1: 前置验证——SDK 通道 codec 兼容性**

Dart 侧 `_BinaryWriteChannel` 用 `BinaryCodec`（原始字节）。OHOS 侧 BasicMessageChannel 必须用**同构 codec**（通道名与编解码器两端必须一致，官方文档明确）。检查 `packages/flutter_blue_plus_ohos/ohos/har/` 下的 SDK 产物或 @ohos/flutter_ohos 的类型定义，确认 `@ohos/flutter_ohos/src/main/ets/plugin/common/` 下是否存在 `BinaryMessageCodec`（或等效的原始字节 codec，如 `BinaryCodec`）。

- 若存在：继续 Step 2
- 若无法确认/不存在：**降级**——保持现有 fallback 行为，将 BinaryProtocolHandler.ets 的过时 TODO 注释改为准确说明（"SDK 无 binary codec，Dart 端 MissingPluginException → MethodChannel fallback"），跳过 Step 2-6，进入 Task 5。降级不违反设计（设计文档已标注该风险）。

- [ ] **Step 2: BinaryProtocolHandler.ets 补全**（替换 `register` 方法体 + 新增解析/分派）：

```ets
import { FlutterPluginBinding } from '@ohos/flutter_ohos';
import BasicMessageChannel, { Reply } from '@ohos/flutter_ohos/src/main/ets/plugin/common/BasicMessageChannel';
import { Buffer } from '@ohos/flutter_ohos/src/main/ets/plugin/common/Buffer'; // 或 SDK 实际提供的 binary codec 类型

// Binary protocol command IDs
const CMD_WRITE_CHARACTERISTIC: number = 0x01;
const CMD_WRITE_DESCRIPTOR: number = 0x02;
const CMD_SET_NOTIFY_VALUE: number = 0x03;

// Write flags
const FLAG_WITHOUT_RESPONSE: number = 1 << 0;
const FLAG_ALLOW_LONG_WRITE: number = 1 << 1;

// Notify flags
const FLAG_ENABLE: number = 1 << 0;
const FLAG_FORCE_INDICATIONS: number = 1 << 1;

const BINARY_CHANNEL: string = "flutter_blue_plus/binary";

/**
 * Binary protocol handler for low-latency BLE write operations on OHOS.
 * Handles binary-encoded BLE write requests via BasicMessageChannel,
 * bypassing MethodChannel serialization overhead.
 */
export default class BinaryProtocolHandler {
  private binding: FlutterPluginBinding | null = null;
  private channel: BasicMessageChannel<Uint8Array> | null = null;
  private plugin: any; // FlutterBluePlusOhosPlugin instance (set via register)

  /**
   * Register the binary message handler.
   */
  public register(binding: FlutterPluginBinding, plugin: any): void {
    this.binding = binding;
    this.plugin = plugin;
    this.channel = new BasicMessageChannel<Uint8Array>(
      binding.getBinaryMessenger(),
      BINARY_CHANNEL,
      new BinaryMessageCodec(), // Step 1 确认的 binary codec
    );
    this.channel.setMessageHandler({
      onMessage: (message: Uint8Array, reply: Reply<Uint8Array>) => {
        this.handleMessage(message, reply);
      }
    });
    console.info("[BinaryProtocolHandler] registered");
  }

  /**
   * Unregister the binary message handler.
   */
  public unregister(): void {
    this.channel?.setMessageHandler(null);
    this.channel = null;
    this.binding = null;
  }

  private handleMessage(message: Uint8Array, reply: Reply<Uint8Array>): void {
    if (message.length < 2) {
      reply.reply(this.encodeError(-1, "invalid message"));
      return;
    }
    const view = new DataView(message.buffer, message.byteOffset, message.byteLength);
    let offset = 0;
    const cmd = view.getUint8(offset); offset += 1;
    const flags = view.getUint8(offset); offset += 1;
    const instanceId = view.getUint16(offset); offset += 2;

    const remoteId = this.readString(view, offset);
    if (remoteId == null) { reply.reply(this.encodeError(-1, "missing remoteId")); return; }
    offset += 1 + remoteId.length;
    const serviceUuid = this.readString(view, offset);
    if (serviceUuid == null) { reply.reply(this.encodeError(-1, "missing serviceUuid")); return; }
    offset += 1 + serviceUuid.length;
    const characteristicUuid = this.readString(view, offset);
    if (characteristicUuid == null) { reply.reply(this.encodeError(-1, "missing characteristicUuid")); return; }
    offset += 1 + characteristicUuid.length;
    const primaryServiceUuid = this.readString(view, offset) ?? "";
    offset += 1 + primaryServiceUuid.length;
    const descriptorUuid = this.readString(view, offset) ?? "";
    offset += 1 + descriptorUuid.length;

    if (cmd === CMD_WRITE_CHARACTERISTIC || cmd === CMD_WRITE_DESCRIPTOR) {
      if (offset + 2 > message.length) { reply.reply(this.encodeError(-1, "missing valueLen")); return; }
      const valueLen = view.getUint16(offset); offset += 2;
      const value = message.slice(offset, offset + valueLen);
      if (cmd === CMD_WRITE_CHARACTERISTIC) {
        this.plugin.binaryWriteCharacteristic(
          remoteId, primaryServiceUuid, serviceUuid, characteristicUuid,
          instanceId, flags & FLAG_WITHOUT_RESPONSE ? 1 : 0, value,
        ).then((r: Map<string, number | string>) => {
          reply.reply(this.fromResult(r));
        }).catch((e: Error) => {
          reply.reply(this.encodeError(4, e.message));
        });
      } else {
        this.plugin.binaryWriteDescriptor(
          remoteId, primaryServiceUuid, serviceUuid, characteristicUuid,
          instanceId, descriptorUuid, value,
        ).then((r: Map<string, number | string>) => {
          reply.reply(this.fromResult(r));
        }).catch((e: Error) => {
          reply.reply(this.encodeError(4, e.message));
        });
      }
    } else if (cmd === CMD_SET_NOTIFY_VALUE) {
      this.plugin.binarySetNotifyValue(
        remoteId, primaryServiceUuid, serviceUuid, characteristicUuid,
        instanceId, (flags & FLAG_ENABLE) !== 0, (flags & FLAG_FORCE_INDICATIONS) !== 0,
      ).then((r: Map<string, number | string>) => {
        reply.reply(this.fromResult(r));
      }).catch((e: Error) => {
        reply.reply(this.encodeError(4, e.message));
      });
    } else {
      reply.reply(this.encodeError(-1, "unknown cmd: " + cmd));
    }
  }

  private readString(view: DataView, offset: number): string | null {
    if (offset >= view.byteLength) return null;
    const len = view.getUint8(offset);
    if (len === 0) return "";
    if (offset + 1 + len > view.byteLength) return null;
    const bytes = new Uint8Array(view.buffer, view.byteOffset + offset + 1, len);
    return String.fromCharCode.apply(null, Array.from(bytes));
  }

  /** Map {success, errorCode, errorString} → 协议响应字节 */
  private fromResult(r: Map<string, number | string>): Uint8Array {
    const success = r.get("success") as number;
    if (success === 1) return this.encodeSuccess();
    return this.encodeError(r.get("errorCode") as number, r.get("errorString") as string);
  }

  private encodeSuccess(): Uint8Array {
    return new Uint8Array([1, 0, 0, 0, 0, 0, 0]);
  }

  private encodeError(errorCode: number, errorString: string): Uint8Array {
    const msg = new TextEncoder().encode(errorString ?? "");
    const out = new Uint8Array(7 + msg.length);
    const view = new DataView(out.buffer);
    view.setUint8(0, 0);
    view.setInt32(1, errorCode);
    view.setUint16(5, msg.length);
    out.set(msg, 7);
    return out;
  }
}
```

**注意：** `DataView`/`TextEncoder`/`Array.from` 在 ArkTS 的可用性按 SDK 实际支持调整；`BinaryMessageCodec` 的 import 路径以 Step 1 确认为准。若 SDK 的 BasicMessageChannel 泛型不支持 `Uint8Array`，改用 `Any` 并在 onMessage 内断言。

- [ ] **Step 3: FlutterBluePlusOhosPlugin.ets 新增 public binary 方法**

在类内新增三个方法。方法体**复制**既有 MethodChannel case 的核心逻辑并改为 Promise 返回（`case "writeCharacteristic"` :794-916、`case "writeDescriptor"` :993-1094、`case "setNotifyValue"` :451-568，均已包含完整的查找/校验/写入/事件发射）。每个方法把 `result.error(...)` 分支改为 `return Promise.resolve({success: 0, errorCode: <码>, errorString: <消息>})`，`result.success(true)` 分支改为 `return Promise.resolve({success: 1, errorCode: 0, errorString: ""})`，事件发射（`this.channel?.invokeMethod("OnCharacteristicWritten", ...)` 等）原样保留。

错误码映射（替换原有文案）：设备未连接→1、`found.error`→2、属性不支持→3、写入异常/失败→4、描述符未找到→5、CCCD 相关→6/7。

签名：

```ets
public async binaryWriteCharacteristic(remoteId: string, primaryServiceUuid: string, serviceUuid: string,
    characteristicUuid: string, instanceId: number, writeType: number, value: Uint8Array):
    Promise<Map<string, number | string>>

public async binaryWriteDescriptor(remoteId: string, primaryServiceUuid: string, serviceUuid: string,
    characteristicUuid: string, instanceId: number, descriptorUuid: string, value: Uint8Array):
    Promise<Map<string, number | string>>

public async binarySetNotifyValue(remoteId: string, primaryServiceUuid: string, serviceUuid: string,
    characteristicUuid: string, instanceId: number, enable: boolean, forceIndications: boolean):
    Promise<Map<string, number | string>>
```

- [ ] **Step 4: 接线**——`onAttachedToEngine`（:68-71）内注册 handler：

```ets
onAttachedToEngine(binding: FlutterPluginBinding): void {
  this.channel = new MethodChannel(binding.getBinaryMessenger(), "flutter_blue_plus/methods");
  this.channel.setMethodCallHandler(this);
  this.binaryHandler = new BinaryProtocolHandler();
  this.binaryHandler.register(binding, this);
}
```

类内新增字段（`channel` 附近）：

```ets
private binaryHandler: BinaryProtocolHandler | null = null;
```

`onDetachedFromEngine` 内调用 `this.binaryHandler?.unregister(); this.binaryHandler = null;`。

- [ ] **Step 5: 静态自查**——核对 import 完整性（`BinaryProtocolHandler` 同目录无需 import；BasicMessageChannel 等按 Step 1 的 SDK 路径）

- [ ] **Step 6: 提交**

```bash
git add packages/flutter_blue_plus_ohos/ohos/src/main/ets/components/plugin/BinaryProtocolHandler.ets packages/flutter_blue_plus_ohos/ohos/src/main/ets/components/plugin/FlutterBluePlusOhosPlugin.ets
git commit -m "feat(ohos): real binary channel for write/descriptor/notify"
```

- [ ] **Step 7: 评审清单**（无实机环境的验证手段）

- [ ] 协议响应字节布局与 encodeSuccess/encodeError 对齐（success 1B + errorCode 4B BE + len 2B BE + 字符串）
- [ ] 二进制解析偏移与 Dart 端 `_encode` 布局一致（cmd/flags/instanceId/5 字符串/valueLen/value）
- [ ] 三个 public 方法与既有 MethodChannel case 的校验/事件发射行为一致
- [ ] 错误码符合 Global Constraints 表

---

### Task 5: 全局验证与收尾

**Files:**
- 无代码改动（验证 + 可选 CHANGELOG）

- [ ] **Step 1: 三个 Dart 包静态检查**

Run:
```bash
cd packages/flutter_blue_plus_linux && flutter analyze
cd packages/flutter_blue_plus_web && flutter analyze
cd packages/flutter_blue_plus_platform_interface && flutter analyze
```
Expected: 各 `No issues found!`

- [ ] **Step 2: 协议层测试**

Run: `cd packages/flutter_blue_plus_platform_interface && flutter test`
Expected: `All tests passed!`

- [ ] **Step 3: 回归确认**

Run: `cd packages/flutter_blue_plus && flutter analyze`
Expected: `No issues found!`（主包未改动；iOS/Android 未触碰）

- [ ] **Step 4: 提交收尾**

若改动过 CHANGELOG/文档则一并提交；否则无提交。

- [ ] **Step 5: 汇报**——总结各平台最终状态（iOS/Android 既有 + Linux/Web/OHOS 新增），标注 OHOS 的实机验证需求



