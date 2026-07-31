# 二进制数据面重构（非侵入模型）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 master 的侵入式二进制实现重构为非侵入模型：原方法（write/setNotifyValue/writeDescriptor）还原为纯 MethodChannel，新增 *Binary 方法（TX 选择轴）+ setBinaryDataChannel 开关（RX 选择轴）+ binary_rx 通道 + TX 完成 gate（P1-b）+ iOS 背压修正。

**Architecture:** TX 选择靠方法名（write() 永远 MethodChannel，writeBinary() 永远二进制）；RX 选择靠 `FlutterBluePlus.setBinaryDataChannel(bool)` 开关（默认关）。二进制路径事件由 Dart 从 reply 合成（emit 钩子），原生命中二进制 pending 时跳过 On*Written 事件（P1-b）；RX 帧经 `flutter_blue_plus/binary_rx` BasicMessageChannel + BinaryCodec 喂现有 onCharacteristicReceived 控制器。

**Tech Stack:** Dart 3、BasicMessageChannel + BinaryCodec、Java（Android）、Objective-C（iOS/macOS）、ArkTS（OHOS）。

**Spec:** `docs/superpowers/specs/2026-07-31-binary-data-plane-refactor-design.md`

## Global Constraints

- 原方法 `write()` / `setNotifyValue()` / `writeDescriptor()` 还原为纯 MethodChannel——验证标准：与 0960565 版本方法体 diff 为空（git show 0960565 取原版对照）
- 不引入 EventChannel（RX 用 BasicMessageChannel + BinaryCodec，与 TX 同一通道模式）
- 原生 RX gate 严格：发 binary_rx 帧即 return 跳过 MethodChannel `OnCharacteristicReceived`，防双发
- TX gate 严格：命中二进制 pending 即跳过 `On*Written`，未命中（MethodChannel 写）走原逻辑
- 保留已修 bug 修复：空 primaryServiceUuid 归一化、断连清理、supersede、主线程 reply、128 归一 key、载荷检查、instanceId 语义、UTF-8 编解码、length 检查、调用方 timeout
- 平台接口只做**加性**改动（现有接口方法签名不动）
- 工作区有既有未提交改动时，每个任务只 git add 本任务文件
- 仓库根：`/Users/shingo/develop/hujie/flutter_blue_plus`

---

### Task 1: platform_interface 加性钩子 + RX 协议层

**Files:**
- Modify: `packages/flutter_blue_plus_platform_interface/lib/src/binary_protocol.dart`（新增 RX 协议）
- Modify: `packages/flutter_blue_plus_platform_interface/lib/flutter_blue_plus_platform_interface.dart`（加性钩子）
- Create: `packages/flutter_blue_plus_platform_interface/test/binary_protocol_test.dart`（协议单测，含 RX 帧）

**Interfaces:**
- Consumes: `BmCharacteristicData`（platform_interface model）、`utf8`（dart:convert，已在 binary_protocol.dart 引入）
- Produces: `binaryRxChannelName`（String）、`decodeNotification(ByteData) → BmCharacteristicData`；`FlutterBluePlusPlatform.emitCharacteristicWritten(BmCharacteristicData)` / `emitDescriptorWritten(BmDescriptorData)` / `setBinaryDataChannel(bool)`（默认 no-op）

- [ ] **Step 1: binary_protocol.dart 新增 RX 线规与解码**

在 `binaryChannelName` 定义旁新增通道名，并在文件末尾新增：

```dart
/// Binary RX (notification) channel name.
const String binaryRxChannelName = 'flutter_blue_plus/binary_rx';
```

```dart
/// Decode a binary notification frame (native → Dart).
///
/// Binary layout:
///   remoteIdLen(1) remoteId / serviceUuidLen(1) serviceUuid
///   characteristicUuidLen(1) characteristicUuid
///   primaryServiceUuidLen(1, 0=null) primaryServiceUuid
///   instanceId(u16 BE) valueLen(u16 BE) value
///   success(u8) errorCode(i32 BE) errorStrLen(u16 BE) errorStr
BmCharacteristicData decodeNotification(ByteData data) {
  int offset = 0;

  String? readString() {
    if (offset >= data.lengthInBytes) return null;
    final len = data.getUint8(offset);
    offset += 1;
    if (len == 0) return '';
    if (offset + len > data.lengthInBytes) return null;
    final s = utf8.decode(data.buffer.asUint8List().sublist(offset, offset + len),
        allowMalformed: true);
    offset += len;
    return s;
  }

  String? missing(String name) {
    throw FormatException('truncated notification frame: missing $name');
  }

  final remoteId = readString() ?? missing('remoteId');
  final serviceUuid = readString() ?? missing('serviceUuid');
  final characteristicUuid = readString() ?? missing('characteristicUuid');
  final primaryServiceUuid = readString() ?? '';

  if (offset + 2 > data.lengthInBytes) missing('instanceId');
  final instanceId = data.getUint16(offset);
  offset += 2;
  if (offset + 2 > data.lengthInBytes) missing('valueLen');
  final valueLen = data.getUint16(offset);
  offset += 2;
  if (offset + valueLen > data.lengthInBytes) missing('value');
  final value = data.buffer
      .asUint8List()
      .sublist(offset, offset + valueLen)
      .toList();
  offset += valueLen;

  if (offset + 1 > data.lengthInBytes) missing('success');
  final success = data.getUint8(offset);
  offset += 1;
  if (offset + 4 > data.lengthInBytes) missing('errorCode');
  final errorCode = data.getInt32(offset);
  offset += 4;
  if (offset + 2 > data.lengthInBytes) missing('errorStrLen');
  final errorStrLen = data.getUint16(offset);
  offset += 2;
  final errorStr = errorStrLen > 0
      ? utf8.decode(
          data.buffer.asUint8List().sublist(offset, offset + errorStrLen),
          allowMalformed: true)
      : '';

  return BmCharacteristicData(
    remoteId: DeviceIdentifier(remoteId),
    primaryServiceUuid: primaryServiceUuid.isEmpty ? null : Guid(primaryServiceUuid),
    serviceUuid: Guid(serviceUuid),
    characteristicUuid: Guid(characteristicUuid),
    instanceId: instanceId,
    value: value,
    success: success == 1,
    errorCode: errorCode,
    errorString: errorStr,
  );
}
```

文件头需确认 `BmCharacteristicData` / `DeviceIdentifier` / `Guid` 可访问（binary_protocol.dart 是 platform_interface 的 src 文件，同包 model 可直接 import；若无 import 则加 `import 'flutter_blue_plus_platform_interface.dart';` 或对应 model 文件的相对 import——以 analyzer 为准）。

- [ ] **Step 2: FlutterBluePlusPlatform 加性钩子**

在 `flutter_blue_plus_platform_interface.dart` 的 `FlutterBluePlusPlatform` 类内（现有事件 getter 之后）新增：

```dart
  /// Feed a synthetic characteristic-written event into the platform's
  /// onCharacteristicWritten stream. Used by the binary write path: the
  /// native side skips OnCharacteristicWritten when a binary reply was
  /// consumed, and the Dart side synthesizes the event here so that
  /// lastValue / lastValueStream keep working. Default: no-op.
  void emitCharacteristicWritten(BmCharacteristicData data) {}

  /// Feed a synthetic descriptor-written event. See [emitCharacteristicWritten].
  void emitDescriptorWritten(BmDescriptorData data) {}

  /// Enable/disable the binary RX (notification) channel on the platform.
  /// Default: no-op. android/darwin/ohos platforms forward to native.
  void setBinaryDataChannel(bool enabled) {}
```

- [ ] **Step 3: 单测** `packages/flutter_blue_plus_platform_interface/test/binary_protocol_test.dart`

创建文件（恢复既有 TX 测试并新增 RX 帧测试）。TX 部分用既有 8 用例（编解码布局锁存，见 git show 522a662 的测试文件）；RX 部分：

```dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart'
    show encodeResponse, decodeResponse, decodeNotification,
        encodeWriteCharacteristic, BinaryCommand, WriteFlags, NotifyFlags,
        BmCharacteristicData;

// ... 既有 TX 用例（8 个，从 522a662 的测试文件复制）...

group('decodeNotification', () {
  ByteData encodeFrame({
    String remoteId = 'AA:BB:CC:DD:EE:FF',
    String serviceUuid = '180d',
    String characteristicUuid = '2a37',
    String? primaryServiceUuid,
    int instanceId = 0,
    List<int> value = const [0x01, 0x02],
    int success = 1,
    int errorCode = 0,
    String errorString = '',
  }) {
    final remote = Uint8List.fromList(remoteId.codeUnits);
    final svc = Uint8List.fromList(serviceUuid.codeUnits);
    final chr = Uint8List.fromList(characteristicUuid.codeUnits);
    final primary = primaryServiceUuid != null
        ? Uint8List.fromList(primaryServiceUuid.codeUnits)
        : Uint8List(0);
    final err = Uint8List.fromList(errorString.codeUnits);
    final size = 1 + remote.length + 1 + svc.length + 1 + chr.length +
        1 + primary.length + 2 + 2 + value.length + 1 + 4 + 2 + err.length;
    final data = ByteData(size);
    int o = 0;
    void putStr(Uint8List bytes) {
      data.setUint8(o, bytes.length); o += 1;
      if (bytes.isNotEmpty) { data.buffer.asUint8List().setAll(o, bytes); o += bytes.length; }
    }
    putStr(remote); putStr(svc); putStr(chr); putStr(primary);
    data.setUint16(o, instanceId); o += 2;
    data.setUint16(o, value.length); o += 2;
    if (value.isNotEmpty) { data.buffer.asUint8List().setAll(o, value); o += value.length; }
    data.setUint8(o, success); o += 1;
    data.setInt32(o, errorCode); o += 4;
    data.setUint16(o, err.length); o += 2;
    if (err.isNotEmpty) { data.buffer.asUint8List().setAll(o, err); o += err.length; }
    return data;
  }

  test('decodes a full frame', () {
    final result = decodeNotification(encodeFrame(instanceId: 3));
    expect(result.remoteId.str, 'AA:BB:CC:DD:EE:FF');
    expect(result.serviceUuid.str, '180d');
    expect(result.characteristicUuid.str, '2a37');
    expect(result.primaryServiceUuid, isNull);
    expect(result.instanceId, 3);
    expect(result.value, [0x01, 0x02]);
    expect(result.success, isTrue);
    expect(result.errorCode, 0);
    expect(result.errorString, '');
  });

  test('decodes non-ASCII remoteId via UTF-8', () {
    final id = '设备-01';
    final result = decodeNotification(encodeFrame(remoteId: id));
    expect(result.remoteId.str, id);
  });

  test('decodes primaryServiceUuid and error fields', () {
    final result = decodeNotification(encodeFrame(
      primaryServiceUuid: '180d', success: 0, errorCode: 133, errorString: 'fail'));
    expect(result.primaryServiceUuid?.str, '180d');
    expect(result.success, isFalse);
    expect(result.errorCode, 133);
    expect(result.errorString, 'fail');
  });

  test('truncated frame throws FormatException', () {
    final data = encodeFrame();
    final truncated = ByteData.sublistView(data, 0, data.lengthInBytes - 3);
    expect(() => decodeNotification(truncated), throwsFormatException);
  });
});
```

- [ ] **Step 4: 运行测试与 analyze**

Run: `cd packages/flutter_blue_plus_platform_interface && flutter test && flutter analyze`
Expected: `All tests passed!` + `No issues found!`

- [ ] **Step 5: 提交**

```bash
git add packages/flutter_blue_plus_platform_interface/lib/src/binary_protocol.dart packages/flutter_blue_plus_platform_interface/lib/flutter_blue_plus_platform_interface.dart packages/flutter_blue_plus_platform_interface/test/binary_protocol_test.dart
git commit -m "feat(platform_interface): RX binary protocol, emit hooks, setBinaryDataChannel"
```

---

### Task 2: Dart 主包——原方法还原 + *Binary 方法 + RX 开关

**Files:**
- Modify: `packages/flutter_blue_plus/lib/src/bluetooth_characteristic.dart`
- Modify: `packages/flutter_blue_plus/lib/src/bluetooth_descriptor.dart`
- Modify: `packages/flutter_blue_plus/lib/src/flutter_blue_plus.dart`（RX 开关静态方法）
- Modify: 5 平台插件的 Dart 类（emit override + android/darwin/ohos 的 setBinaryDataChannel override + binary_rx handler 注册）：
  - `packages/flutter_blue_plus_android/lib/...`、`packages/flutter_blue_plus_darwin/lib/...`、`packages/flutter_blue_plus_ohos/lib/...`（这三者在 Dart 侧是 MethodChannel 转发，controller 在原生侧？——**注意**：Android/Darwin/OHOS 的 `onCharacteristicReceived` 事件 Stream 在插件 Dart 类的 `_onCharacteristicReceivedController`（若有）或来自原生 EventChannel。Task 2 先处理 linux/web 的 override；android/darwin/ohos 的 override 需要先确认其 Dart 插件类结构——在 Task 2 Step 5 中按实际结构实现）
  - `packages/flutter_blue_plus_linux/lib/flutter_blue_plus_linux.dart`、`packages/flutter_blue_plus_web/lib/flutter_blue_plus_web.dart`（controller 已有：`_onCharacteristicWrittenController` / `_onDescriptorWrittenController`）

**Interfaces:**
- Consumes: `FlutterBluePlusPlatform.emitCharacteristicWritten/emitDescriptorWritten/setBinaryDataChannel`（Task 1）、`_BinaryWriteChannel`（现有）
- Produces: `writeBinary` / `setNotifyValueBinary` / `writeDescriptorBinary`（公共 API）；`FlutterBluePlus.setBinaryDataChannel(bool)`；linux/web 的 emit override；linux/web 插件注册 `flutter_blue_plus/binary_rx` handler（**不注册**——linux/web RX 是 Dart 直连，见 Global Constraints）

- [ ] **Step 1: 还原 `write()`（bluetooth_characteristic.dart）**

删除方法内 `try { await _BinaryWriteChannel.instance.writeCharacteristic(...); return; } on MissingPluginException { }` 二进制块（当前在 mtx 后的 try 内、`final writeType = ...` 之前），方法体恢复为 0960565 原版（见 `git show 0960565:packages/flutter_blue_plus/lib/src/bluetooth_characteristic.dart` 的 write()）。`_cachedOnWrittenStream` 过滤逻辑保留原样。

**验证：`git diff 0960565 -- packages/flutter_blue_plus/lib/src/bluetooth_characteristic.dart` 对 write() 区域无差异（仅 writeBinary 新增部分除外）。**

- [ ] **Step 2: 新增 `writeBinary()`（bluetooth_characteristic.dart，write() 之后）**

```dart
  /// Writes a characteristic value via the binary fast path.
  ///
  /// Identical semantics to [write], but always uses the binary channel
  /// regardless of any platform state. Falls back to the MethodChannel path
  /// when the platform has no binary handler (e.g. Windows).
  Future<void> writeBinary(List<int> value,
      {bool withoutResponse = false,
      bool allowLongWrite = false,
      Duration timeout = const Duration(seconds: 15)}) async {
    //  check args
    if (withoutResponse && allowLongWrite) {
      throw ArgumentError("cannot longWrite withoutResponse, not allowed on iOS or Android");
    }

    // check connected
    if (device.isDisconnected) {
      throw FlutterBluePlusException(
          ErrorPlatform.fbp, "writeCharacteristic", FbpErrorCode.deviceIsDisconnected.index, "device is not connected");
    }

    // Only allow a single BLE operation to be underway per device.
    _Mutex mtx = _MutexFactory.getMutexForKey(FlutterBluePlus._bleOperationMutexKey(remoteId));
    await mtx.take();

    try {
      bool viaBinary = false;
      try {
        await _BinaryWriteChannel.instance.writeCharacteristic(
          remoteId: remoteId,
          primaryServiceUuid: primaryServiceUuid,
          serviceUuid: serviceUuid,
          characteristicUuid: characteristicUuid,
          instanceId: instanceId,
          withoutResponse: withoutResponse,
          allowLongWrite: allowLongWrite,
          value: value,
          timeout: timeout,
        );
        viaBinary = true;
      } on MissingPluginException {
        // no binary handler on this platform: fall back to MethodChannel
      }

      if (!viaBinary) {
        // MethodChannel path (same as write())
        final writeType = withoutResponse ? BmWriteType.withoutResponse : BmWriteType.withResponse;

        var request = BmWriteCharacteristicRequest(
          remoteId: remoteId,
          primaryServiceUuid: primaryServiceUuid,
          serviceUuid: serviceUuid,
          characteristicUuid: characteristicUuid,
          instanceId: instanceId,
          writeType: writeType,
          allowLongWrite: allowLongWrite,
          value: value,
        );

        Future<BmCharacteristicData> futureResponse =
            (_cachedOnWrittenStream ??= FlutterBluePlusPlatform.instance.onCharacteristicWritten
                .where((p) => p.remoteId == remoteId)
                .where((p) => p.primaryServiceUuid == primaryServiceUuid)
                .where((p) => p.serviceUuid == serviceUuid)
                .where((p) => p.characteristicUuid == characteristicUuid)
                .where((p) => p.instanceId == instanceId))
            .first;

        await FlutterBluePlus._invokePlatform(() => FlutterBluePlusPlatform.instance.writeCharacteristic(request));

        BmCharacteristicData response = await futureResponse
            .fbpEnsureAdapterIsOn("writeCharacteristic")
            .fbpEnsureDeviceIsConnected(device, "writeCharacteristic")
            .fbpTimeout(timeout, "writeCharacteristic");

        if (!response.success) {
          throw FlutterBluePlusException(_nativeError, "writeCharacteristic", response.errorCode, response.errorString);
        }

        return;
      }

      // Binary path: synthesize the written event so lastValue /
      // lastValueStream keep working (native skips OnCharacteristicWritten
      // when the binary reply was consumed).
      FlutterBluePlusPlatform.instance.emitCharacteristicWritten(BmCharacteristicData(
        remoteId: remoteId,
        primaryServiceUuid: primaryServiceUuid,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        instanceId: instanceId,
        value: value,
        success: true,
        errorCode: 0,
        errorString: '',
      ));
    } finally {
      mtx.give();
    }
  }
```

- [ ] **Step 3: 还原 `setNotifyValue()` 并新增 `setNotifyValueBinary()`（bluetooth_characteristic.dart）**

`setNotifyValue()` 删除二进制块还原为 0960565 原版。新增（setNotifyValue 之后）：

```dart
  /// Sets notifications or indications via the binary fast path.
  ///
  /// Identical semantics to [setNotifyValue], but always uses the binary
  /// channel. Falls back to the MethodChannel path when the platform has
  /// no binary handler.
  Future<bool> setNotifyValueBinary(bool notify,
      {Duration timeout = const Duration(seconds: 15), bool forceIndications = false}) async {
    // check connected
    if (device.isDisconnected) {
      throw FlutterBluePlusException(
          ErrorPlatform.fbp, "setNotifyValue", FbpErrorCode.deviceIsDisconnected.index, "device is not connected");
    }

    // check
    if (!kIsWeb && !Platform.isAndroid) {
      assert(forceIndications == false, "Only Android supports forcing indications");
    }

    // Only allow a single BLE operation to be underway per device.
    _Mutex mtx = _MutexFactory.getMutexForKey(FlutterBluePlus._bleOperationMutexKey(remoteId));
    await mtx.take();

    try {
      bool viaBinary = false;
      try {
        await _BinaryWriteChannel.instance.setNotifyValue(
          remoteId: remoteId,
          primaryServiceUuid: primaryServiceUuid,
          serviceUuid: serviceUuid,
          characteristicUuid: characteristicUuid,
          instanceId: instanceId,
          enable: notify,
          forceIndications: forceIndications,
          timeout: timeout,
        );
        viaBinary = true;
      } on MissingPluginException {
        // fall back to MethodChannel
      }

      if (!viaBinary) {
        var request = BmSetNotifyValueRequest(
          remoteId: remoteId,
          primaryServiceUuid: primaryServiceUuid,
          serviceUuid: serviceUuid,
          characteristicUuid: characteristicUuid,
          instanceId: instanceId,
          forceIndications: forceIndications,
          enable: notify,
        );

        Future<BmDescriptorData> futureResponse =
            (_cachedOnDescriptorWrittenStream ??= FlutterBluePlusPlatform.instance.onDescriptorWritten
                .where((p) => p.remoteId == remoteId)
                .where((p) => p.primaryServiceUuid == primaryServiceUuid)
                .where((p) => p.serviceUuid == serviceUuid)
                .where((p) => p.characteristicUuid == characteristicUuid)
                .where((p) => p.descriptorUuid == cccdUuid)
                .where((p) => p.instanceId == instanceId))
            .first;

        bool hasCCCD =
            await FlutterBluePlus._invokePlatform(() => FlutterBluePlusPlatform.instance.setNotifyValue(request));

        if (hasCCCD) {
          BmDescriptorData response = await futureResponse
              .fbpEnsureAdapterIsOn("setNotifyValue")
              .fbpEnsureDeviceIsConnected(device, "setNotifyValue")
              .fbpTimeout(timeout, "setNotifyValue");

          if (!response.success) {
            throw FlutterBluePlusException(_nativeError, "setNotifyValue", response.errorCode, response.errorString);
          }
        }
      }
    } finally {
      mtx.give();
    }

    return true;
  }
```

- [ ] **Step 4: 还原 `writeDescriptor()` 并新增 `writeDescriptorBinary()`（bluetooth_descriptor.dart）**

`writeDescriptor()` 删除二进制块还原为 0960565 原版。新增：

```dart
  /// Writes the value of a descriptor via the binary fast path.
  ///
  /// Identical semantics to [write], but always uses the binary channel.
  /// Falls back to the MethodChannel path when the platform has no binary
  /// handler.
  Future<void> writeDescriptorBinary(List<int> value,
      {Duration timeout = const Duration(seconds: 15)}) async {
    // check connected
    if (device.isDisconnected) {
      throw FlutterBluePlusException(
          ErrorPlatform.fbp, "writeDescriptor", FbpErrorCode.deviceIsDisconnected.index, "device is not connected");
    }

    // Only allow a single BLE operation to be underway per device.
    _Mutex mtx = _MutexFactory.getMutexForKey(FlutterBluePlus._bleOperationMutexKey(remoteId));
    await mtx.take();

    try {
      bool viaBinary = false;
      try {
        await _BinaryWriteChannel.instance.writeDescriptor(
          remoteId: remoteId,
          primaryServiceUuid: primaryServiceUuid,
          serviceUuid: serviceUuid,
          characteristicUuid: characteristicUuid,
          instanceId: instanceId,
          descriptorUuid: descriptorUuid,
          value: value,
          timeout: timeout,
        );
        viaBinary = true;
      } on MissingPluginException {
        // fall back to MethodChannel
      }

      if (!viaBinary) {
        var request = BmWriteDescriptorRequest(
          remoteId: remoteId,
          primaryServiceUuid: primaryServiceUuid,
          serviceUuid: serviceUuid,
          characteristicUuid: characteristicUuid,
          instanceId: instanceId,
          descriptorUuid: descriptorUuid,
          value: value,
        );

        Future<BmDescriptorData> futureResponse =
            (_cachedOnWrittenStream ??= FlutterBluePlusPlatform.instance.onDescriptorWritten
                .where((p) => p.remoteId == remoteId)
                .where((p) => p.primaryServiceUuid == primaryServiceUuid)
                .where((p) => p.serviceUuid == serviceUuid)
                .where((p) => p.characteristicUuid == characteristicUuid)
                .where((p) => p.instanceId == instanceId)
                .where((p) => p.descriptorUuid == descriptorUuid))
            .first;

        await FlutterBluePlus._invokePlatform(() => FlutterBluePlusPlatform.instance.writeDescriptor(request));

        BmDescriptorData response = await futureResponse
            .fbpEnsureAdapterIsOn("writeDescriptor")
            .fbpEnsureDeviceIsConnected(device, "writeDescriptor")
            .fbpTimeout(timeout, "writeDescriptor");

        if (!response.success) {
          throw FlutterBluePlusException(_nativeError, "writeDescriptor", response.errorCode, response.errorString);
        }

        return;
      }

      // Binary path: synthesize the written event.
      FlutterBluePlusPlatform.instance.emitDescriptorWritten(BmDescriptorData(
        remoteId: remoteId,
        primaryServiceUuid: primaryServiceUuid,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        instanceId: instanceId,
        descriptorUuid: descriptorUuid,
        value: value,
        success: true,
        errorCode: 0,
        errorString: '',
      ));
    } finally {
      mtx.give();
    }
  }
```

- [ ] **Step 5: RX 开关 + linux/web emit override + linux/web core 事件移除准备**

`flutter_blue_plus.dart` 的 `FlutterBluePlus` 类内新增：

```dart
  /// Enable/disable the binary RX (notification) channel.
  ///
  /// When enabled, notification frames arrive over the binary channel
  /// instead of the MethodChannel event stream. No-op on platforms that
  /// already deliver notifications directly to Dart (Linux/Web).
  /// Default: false.
  static void setBinaryDataChannel(bool enabled) {
    FlutterBluePlusPlatform.instance.setBinaryDataChannel(enabled);
  }
```

linux/web 插件类 override：

```dart
  // in FlutterBluePlusLinux / FlutterBluePlusWeb
  @override
  void emitCharacteristicWritten(BmCharacteristicData data) {
    _onCharacteristicWrittenController.add(data);
  }

  @override
  void emitDescriptorWritten(BmDescriptorData data) {
    _onDescriptorWrittenController.add(data);
  }
```

**注意：** linux/web 的 `binaryWriteCharacteristic` / `binaryWriteDescriptor` / `binarySetNotifyValue` core 方法的事件发射（成功与失败分支的 `_onCharacteristicWrittenController.add` / `_onDescriptorWrittenController.add`）在本任务**不删**——删除在 Task 6（与原生 TX gate 完成后一并验证双发消除）。

- [ ] **Step 6: android/darwin/ohos 的 Dart 插件 override 确认**

查看三个平台插件 Dart 类的实际结构（`grep -n "_onCharacteristicWrittenController\|class FlutterBluePlus" packages/flutter_blue_plus_android/lib/*.dart` 等）。按其实际 controller 结构实现 emit override；若无 Dart 侧 controller（事件在原生侧），则 emit override 为 no-op（保持基类默认，事件由原生 gate 语义保证——**此情况在 Task 3/4/5 原生侧实现后由 writeBinary 合成 + 原生跳过共同保证**）。`setBinaryDataChannel` override 为 `methodChannel.invokeMethod('setBinaryDataChannel', enabled)`。

- [ ] **Step 7: 静态检查**

Run: `cd packages/flutter_blue_plus && flutter analyze`
Expected: `No issues found!`（除既有 pubspec path 依赖警告）

- [ ] **Step 8: 还原证明 + 提交**

```bash
git diff 0960565 -- packages/flutter_blue_plus/lib/src/bluetooth_characteristic.dart | grep -c "^[+-]" | head -1
```
（预期只包含 writeBinary/setNotifyValueBinary 的新增行，无 write()/setNotifyValue() 方法体的修改行；若有修改行则修正还原。）

```bash
git add packages/flutter_blue_plus/lib/src/bluetooth_characteristic.dart packages/flutter_blue_plus/lib/src/bluetooth_descriptor.dart packages/flutter_blue_plus/lib/src/flutter_blue_plus.dart <5 平台插件文件>
git commit -m "refactor: non-intrusive binary write (writeBinary etc), RX switch, emit hooks"
```

---

### Task 3: Android native——TX gate + RX gate + 开关

**Files:**
- Modify: `packages/flutter_blue_plus_android/android/src/main/java/com/jmx/flutter_blue_plus/FlutterBluePlusPlugin.java`
- Modify: `packages/flutter_blue_plus_android/android/src/main/java/com/jmx/flutter_blue_plus/BinaryProtocolHandler.java`

**Interfaces:**
- Consumes: 既有 `mBinaryReplyMap`、`BinaryProtocolHandler.encodeSuccess/encodeError`、`mWriteChr`/`mWriteDesc`
- Produces: `FlutterBluePlusPlugin.mBinaryRxEnabled`（volatile boolean）、`setBinaryDataChannel` case、`onCharacteristicWrite`/`onDescriptorWrite` 的 gate（命中返回）、`onCharacteristicReceived` 的 RX gate、`BinaryProtocolHandler.sendNotification(...)`（帧构造 + 发送）

**前置事实：** Android 的 TX 消费在主类回调里（`onCharacteristicWrite` :2518 附近 `mBinaryReplyMap.remove(key)` 直接消费，不经过 handler 方法）。gate 即"命中则 reply + return 跳过事件"。

- [ ] **Step 1: BinaryProtocolHandler.java 新增 RX 通道注册与帧构造**

类内新增字段与方法（`CHANNEL_NAME` 定义旁）：

```java
    private static final String RX_CHANNEL_NAME = "flutter_blue_plus/binary_rx";
```

`register` 方法里注册 RX 通道（`BinaryCodec` 已 import）：

```java
    public void register(BinaryMessenger messenger) {
        messenger.setMessageHandler(CHANNEL_NAME, this);
        // RX channel: fire-and-forget notifications, no reply expected
        messenger.setMessageHandler(RX_CHANNEL_NAME, (message, reply) -> {
            reply.reply(null);
        });
    }
```

新增帧构造与发送方法（类内，`readValue` 旁）：

```java
    /** Build a binary RX notification frame (see binary_protocol.dart decodeNotification). */
    public static ByteBuffer buildNotificationFrame(String remoteId, String serviceUuid,
            String characteristicUuid, String primaryServiceUuid, int instanceId,
            byte[] value, boolean success, int errorCode, String errorString) {
        byte[] remoteBytes = remoteId.getBytes(StandardCharsets.UTF_8);
        byte[] svcBytes = serviceUuid.getBytes(StandardCharsets.UTF_8);
        byte[] chrBytes = characteristicUuid.getBytes(StandardCharsets.UTF_8);
        byte[] primaryBytes = primaryServiceUuid != null ? primaryServiceUuid.getBytes(StandardCharsets.UTF_8) : new byte[0];
        byte[] errBytes = errorString != null ? errorString.getBytes(StandardCharsets.UTF_8) : new byte[0];
        int size = 1 + remoteBytes.length + 1 + svcBytes.length + 1 + chrBytes.length
                + 1 + primaryBytes.length + 2 + 2 + value.length + 1 + 4 + 2 + errBytes.length;
        ByteBuffer frame = ByteBuffer.allocate(size).order(ByteOrder.BIG_ENDIAN);
        putString(frame, remoteBytes);
        putString(frame, svcBytes);
        putString(frame, chrBytes);
        putString(frame, primaryBytes);
        frame.putShort((short) instanceId);
        frame.putShort((short) value.length);
        frame.put(value);
        frame.put((byte) (success ? 1 : 0));
        frame.putInt(errorCode);
        frame.putShort((short) errBytes.length);
        frame.put(errBytes);
        frame.flip();
        return frame;
    }

    private static void putString(ByteBuffer buf, byte[] bytes) {
        buf.put((byte) bytes.length);
        buf.put(bytes);
    }
```

- [ ] **Step 2: FlutterBluePlusPlugin.java 开关字段与 case**

新增字段（`mBinaryReplyMap` 附近）：

```java
    private volatile boolean mBinaryRxEnabled = false;
```

`onMethodCall` 的 switch 新增 case（任意位置，建议 `setOptions` 附近）：

```java
        case "setBinaryDataChannel": {
            boolean enabled = Boolean.TRUE.equals(call.arguments);
            mBinaryRxEnabled = enabled;
            log(LogLevel.DEBUG, "setBinaryDataChannel: " + enabled);
            result.success(null);
            break;
        }
```

- [ ] **Step 3: TX gate——onCharacteristicWrite 命中跳过事件**

`onCharacteristicWrite` 中二进制消费块（`// Check if there is a pending binary reply (from BinaryProtocolHandler)` 起）改为：

```java
            // Check if there is a pending binary reply (from BinaryProtocolHandler)
            io.flutter.plugin.common.BinaryMessenger.BinaryReply binaryReply = mBinaryReplyMap.remove(key);
            if (binaryReply != null) {
                // Complete the binary channel with the result.
                // Reply on the main thread: we are on the GATT binder thread
                // here, and replying to the binary messenger from a binder
                // thread has been observed to race with engine teardown.
                boolean success = status == BluetoothGatt.GATT_SUCCESS;
                final int replyStatus = status;
                new Handler(Looper.getMainLooper()).post(() -> {
                    if (success) {
                        binaryReply.reply(BinaryProtocolHandler.encodeSuccess());
                    } else {
                        binaryReply.reply(BinaryProtocolHandler.encodeError(replyStatus, gattErrorString(replyStatus)));
                    }
                });
                // Binary write: Dart side synthesizes the written event from
                // the reply, so skip the redundant OnCharacteristicWritten.
                return;
            }
```

（在现有方法末尾的 `}` 前加 `return;` 即可——方法内后续是事件构造与 `invokeMethodUIThread("OnCharacteristicWritten", response)`。）

- [ ] **Step 4: TX gate——onDescriptorWrite 先 desc 后 notify**

`onDescriptorWrite` 的二进制消费块改为（先试带 descUuid 的 key，未命中再试 notify key）：

```java
            // Check binary reply (from BinaryProtocolHandler):
            // 1) descriptor write key (includes descriptorUuid)
            // 2) setNotifyValue key (CCCD write, no descriptorUuid)
            io.flutter.plugin.common.BinaryMessenger.BinaryReply binaryReply = mBinaryReplyMap.remove(key);
            if (binaryReply == null) {
                String notifyKey = remoteId + ":" + primaryServiceUuid + ":" + serviceUuid + ":" +
                    characteristicUuid + ":" + instanceId;
                binaryReply = mBinaryReplyMap.remove(notifyKey);
            }
            if (binaryReply != null) {
                boolean success = status == BluetoothGatt.GATT_SUCCESS;
                final int replyStatus = status;
                new Handler(Looper.getMainLooper()).post(() -> {
                    if (success) {
                        binaryReply.reply(BinaryProtocolHandler.encodeSuccess());
                    } else {
                        binaryReply.reply(BinaryProtocolHandler.encodeError(replyStatus, gattErrorString(replyStatus)));
                    }
                });
                // Binary write: skip the redundant OnDescriptorWritten.
                return;
            }
```

- [ ] **Step 5: RX gate——onCharacteristicReceived**

找到 `onCharacteristicReceived` 方法（特征值变化回调，发射 `OnCharacteristicReceived` 事件之前），在事件构造/发射**之前**插入 gate：

```java
            // binary RX fast path?
            if (mBinaryRxEnabled) {
                // frame fields: remoteId, serviceUuid, characteristicUuid, primaryServiceUuid, instanceId, value
                byte[] valueBytes = characteristic.getValue() != null ? characteristic.getValue() : new byte[0];
                ByteBuffer frame = BinaryProtocolHandler.buildNotificationFrame(
                        remoteId, serviceUuid, characteristicUuid,
                        primaryServiceUuid, instanceId, valueBytes, true, 0, "");
                binaryHandler.sendNotification(frame);
                return;
            }
```

（`remoteId`/`serviceUuid`/`characteristicUuid`/`primaryServiceUuid`/`instanceId` 需在此 gate 前已算出——若原方法里它们定义在事件构造处，则把 gate 放在它们计算之后、`OnCharacteristicReceived` invokeMethod 之前。）

`BinaryProtocolHandler` 新增发送方法：

```java
    /** Send a binary RX notification frame on the binary_rx channel (no reply expected). */
    public void sendNotification(ByteBuffer frame) {
        if (rxMessenger != null) {
            rxMessenger.send(RX_CHANNEL_NAME, frame);
        }
    }
```

`register` 里保存 `rxMessenger`（`private BinaryMessenger rxMessenger;` 字段）。

- [ ] **Step 6: 静态自查**

- javac 不可用 → 语法静态自查（括号配对、字段/方法引用存在、`ByteOrder`/`StandardCharsets`/`Handler`/`Looper` 已 import——ByteOrder/StandardCharsets 已在 BinaryProtocolHandler.java import；Handler/Looper 在 FlutterBluePlusPlugin.java 已有）
- 确认 `onCharacteristicReceived` 的 gate 位置在 `OnCharacteristicReceived` invokeMethod 之前且 return 后不执行事件发射

- [ ] **Step 7: 提交**

```bash
git add packages/flutter_blue_plus_android/android/src/main/java/com/jmx/flutter_blue_plus/FlutterBluePlusPlugin.java packages/flutter_blue_plus_android/android/src/main/java/com/jmx/flutter_blue_plus/BinaryProtocolHandler.java
git commit -m "feat(android): binary RX channel, TX gate (skip redundant events), setBinaryDataChannel"
```

---

### Task 4: iOS/macOS native——TX gate + RX gate + 背压修正

**Files:**
- Modify: `packages/flutter_blue_plus_darwin/darwin/flutter_blue_plus_darwin/Sources/flutter_blue_plus_darwin/BinaryProtocolHandler.h`
- Modify: `packages/flutter_blue_plus_darwin/darwin/flutter_blue_plus_darwin/Sources/flutter_blue_plus_darwin/BinaryProtocolHandler.m`
- Modify: `packages/flutter_blue_plus_darwin/darwin/flutter_blue_plus_darwin/Sources/flutter_blue_plus_darwin/FlutterBluePlusPlugin.m`

**Interfaces:**
- Consumes: 既有 `pendingReplies`、`complete*` 方法、`didWriteValueForCharacteristic`（:1700+，invokeMethod 在 :1736、complete 在 :1739）、`didUpdateValueForCharacteristic`、`didDisconnectPeripheral`（:1440+）
- Produces: `complete*` 返回 BOOL（命中语义）、`peripheralIsReadyToSendWriteWithoutResponse` 处理（背压）、`buildNotificationFrame`（Obj-C）、RX gate

**前置事实：** iOS 当前顺序是 `invokeMethod("OnCharacteristicWritten")`（:1736）在前、`completeWriteCharacteristic`（:1739）在后。TX gate 需调整为先 complete（拿 BOOL）再决定 invokeMethod。

- [ ] **Step 1: .h 声明更新**

`BinaryProtocolHandler.h` 中三个 complete 方法改返回 `BOOL`，新增背压完成方法与 RX 发送：

```objc
- (BOOL)completeWriteCharacteristic:(NSString *)remoteId
                  primaryServiceUuid:(NSString *)primaryServiceUuid
                        serviceUuid:(NSString *)serviceUuid
                  characteristicUuid:(NSString *)characteristicUuid
                         instanceId:(NSInteger)instanceId
                            success:(BOOL)success
                          errorCode:(int32_t)errorCode
                        errorString:(NSString *)errorString;

- (BOOL)completeWriteDescriptor:(NSString *)remoteId
              primaryServiceUuid:(NSString *)primaryServiceUuid
                    serviceUuid:(NSString *)serviceUuid
              characteristicUuid:(NSString *)characteristicUuid
                     instanceId:(NSInteger)instanceId
                 descriptorUuid:(NSString *)descriptorUuid
                        success:(BOOL)success
                      errorCode:(int32_t)errorCode
                    errorString:(NSString *)errorString;

- (BOOL)completeSetNotifyValue:(NSString *)remoteId
             primaryServiceUuid:(NSString *)primaryServiceUuid
                   serviceUuid:(NSString *)serviceUuid
             characteristicUuid:(NSString *)characteristicUuid
                    instanceId:(NSInteger)instanceId
                       success:(BOOL)success
                     errorCode:(int32_t)errorCode
                   errorString:(NSString *)errorString;

/// Complete pending writeWithoutResponse replies for a peripheral
/// (called from peripheralIsReadyToSendWriteWithoutResponse).
- (void)completePendingWithoutResponseForRemoteId:(NSString *)remoteId;

/// Send a binary RX notification frame on the binary_rx channel.
- (void)sendNotification:(NSData *)frame;
```

- [ ] **Step 2: .m——complete* 返回 BOOL + 背压 + RX 发送**

`completeReply` 改为返回 BOOL（命中返回 YES）：

```objc
- (BOOL)completeReply:(NSString *)key success:(BOOL)success errorCode:(int32_t)errorCode errorString:(NSString *)errorString {
    FlutterBinaryReply reply;
    @synchronized(self) {
        reply = self.pendingReplies[key];
        if (reply) {
            [self.pendingReplies removeObjectForKey:key];
        }
    }
    if (reply) {
        if (success) {
            reply([self encodeSuccess]);
        } else {
            reply([self encodeError:errorCode message:errorString]);
        }
        return YES;
    }
    return NO;
}
```

三个 complete 方法改为 `return [self completeReply:...]`。

`handleWriteCharacteristic` 的 withoutResponse 分支改为**不立即 reply、存 pending**（背压）：

```objc
    if (withoutResponse) {
        // writeWithoutResponse: reply only when CoreBluetooth signals
        // ready-to-send (peripheralIsReadyToSendWriteWithoutResponse).
        // Replying immediately here drops packets when the stack is busy.
        NSString *key = [NSString stringWithFormat:@"wr:%@:%@:%@:%@:%d",
                         remoteId,
                         [self uuid128:primaryServiceUuid],
                         [self uuid128:serviceUuid],
                         [self uuid128:characteristicUuid],
                         instanceId];
        @synchronized(self) {
            // supersede: complete any previous pending reply for this key
            FlutterBinaryReply old = self.pendingReplies[key];
            if (old) {
                [self.pendingReplies removeObjectForKey:key];
                old([self encodeError:4 message:@"operation superseded"]);
            }
            self.pendingReplies[key] = reply;
        }
        [peripheral writeValue:value forCharacteristic:characteristic type:CBCharacteristicWriteWithoutResponse];
    }
```

（注意 `wr:` 前缀与 withResponse 的 `write:` 前缀区分——`peripheralIsReadyToSendWriteWithoutResponse` 无特征参数，只能按 remoteId 前缀完成。）

新增背压完成方法（在 @synchronized 内取出 reply 并移除，锁外回包）：

```objc
- (void)completePendingWithoutResponseForRemoteId:(NSString *)remoteId {
    NSString *prefix = [NSString stringWithFormat:@"wr:%@:", remoteId];
    NSMutableArray<FlutterBinaryReply> *replies = [NSMutableArray array];
    @synchronized(self) {
        NSArray<NSString *> *allKeys = [self.pendingReplies allKeys];
        for (NSString *key in allKeys) {
            if ([key hasPrefix:prefix]) {
                FlutterBinaryReply r = self.pendingReplies[key];
                [self.pendingReplies removeObjectForKey:key];
                if (r) { [replies addObject:r]; }
            }
        }
    }
    for (FlutterBinaryReply r in replies) {
        r([self encodeSuccess]);
    }
}
```

新增 RX 发送（.m 内）：

```objc
- (void)sendNotification:(NSData *)frame {
    if (self.rxChannel) {
        [self.rxChannel sendMessage:frame reply:nil];
    }
}
```

（`rxChannel` 为 `FlutterBasicMessageChannel *` 属性，`registerWithMessenger` 里创建：`[FlutterBasicMessageChannel messageChannelWithName:@"flutter_blue_plus/binary_rx" binaryMessenger:messenger codec:[FlutterBinaryCodec sharedInstance]]`，并设置空 handler 以防 Dart 侧无订阅时引擎报错：`[rxChannel setMessageHandler:^(id message, FlutterReply reply) { reply(nil); }];`）

新增帧构造（Obj-C 版，大端）：

```objc
- (NSData *)buildNotificationFrameWithRemoteId:(NSString *)remoteId
                                   serviceUuid:(NSString *)serviceUuid
                             characteristicUuid:(NSString *)characteristicUuid
                            primaryServiceUuid:(NSString *)primaryServiceUuid
                                     instanceId:(uint16_t)instanceId
                                         value:(NSData *)value
                                        success:(BOOL)success
                                      errorCode:(int32_t)errorCode
                                    errorString:(NSString *)errorString {
    NSData *remote = [remoteId dataUsingEncoding:NSUTF8StringEncoding];
    NSData *svc = [serviceUuid dataUsingEncoding:NSUTF8StringEncoding];
    NSData *chr = [characteristicUuid dataUsingEncoding:NSUTF8StringEncoding];
    NSData *primary = [primaryServiceUuid dataUsingEncoding:NSUTF8StringEncoding];
    NSData *err = [errorString dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *frame = [NSMutableData data];
    uint8_t lenBuf[1];
    lenBuf[0] = (uint8_t)remote.length; [frame appendBytes:lenBuf length:1]; [frame appendData:remote];
    lenBuf[0] = (uint8_t)svc.length;    [frame appendBytes:lenBuf length:1]; [frame appendData:svc];
    lenBuf[0] = (uint8_t)chr.length;    [frame appendBytes:lenBuf length:1]; [frame appendData:chr];
    lenBuf[0] = (uint8_t)primary.length; [frame appendBytes:lenBuf length:1]; [frame appendData:primary];
    uint16_t inst = CFSwapInt16HostToBig(instanceId);
    [frame appendBytes:&inst length:2];
    uint16_t vlen = CFSwapInt16HostToBig((uint16_t)value.length);
    [frame appendBytes:&vlen length:2];
    [frame appendData:value];
    uint8_t succ = success ? 1 : 0;
    [frame appendBytes:&succ length:1];
    int32_t code = CFSwapInt32HostToBig(errorCode);
    [frame appendBytes:&code length:4];
    uint16_t elen = CFSwapInt16HostToBig((uint16_t)err.length);
    [frame appendBytes:&elen length:2];
    [frame appendData:err];
    return frame;
}
```

- [ ] **Step 3: FlutterBluePlusPlugin.m——TX gate（先 complete 再决定事件）**

`didWriteValueForCharacteristic` 中调整顺序：把 `invokeMethod(@"OnCharacteristicWritten", ...)`（:1736 附近）移到 complete 调用之后，并 gate：

```objc
    // Complete any pending binary reply first; if a binary write consumed
    // the reply, the Dart side synthesizes the written event — skip the
    // redundant MethodChannel event.
    BOOL consumed = [self.binaryHandler completeWriteCharacteristic:remoteId
                                                  primaryServiceUuid:primarySvcKey
                                                        serviceUuid:serviceUuid
                                                  characteristicUuid:characteristicUuid
                                                         instanceId:[instanceId integerValue]
                                                            success:(error == nil)
                                                          errorCode:(error ? (int32_t)error.code : 0)
                                                        errorString:(error ? [error localizedDescription] : @"")];

    if (!consumed) {
        [self.methodChannel invokeMethod:@"OnCharacteristicWritten" arguments:result];
    }
```

（原 `invokeMethod` 前的 result 构造代码保留；原 complete 调用删除。）

`didUpdateNotificationStateForCharacteristic`：同样改为先 `completeSetNotifyValue`（BOOL），未命中才 `invokeMethod(@"OnCharacteristicWritten", ...)`（该方法当前发射 OnCharacteristicWritten 事件——保留未命中路径）。

`didWriteValueForDescriptor`：同样先 `completeWriteDescriptor`，未命中才 invokeMethod。

- [ ] **Step 4: 背压回调**

在 FlutterBluePlusPlugin.m 实现 `peripheralIsReadyToSendWriteWithoutResponse`（若已有则补）：

```objc
- (void)peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral *)peripheral {
    [self.binaryHandler completePendingWithoutResponseForRemoteId:peripheral.identifier.UUIDString];
}
```

（remoteId 格式：iOS 的 remoteId 是 `[peripheral.identifier UUIDString]`——确认 `getConnectedPeripheral` 的 remoteId 来源一致，否则 key 前缀不匹配。以现有 didWriteValueForCharacteristic 里 remoteId 的取值方式为准。）

- [ ] **Step 5: RX gate——didUpdateValueForCharacteristic**

在 `didUpdateValueForCharacteristic` 的 `OnCharacteristicReceived` invokeMethod 之前插入：

```objc
    // binary RX fast path?
    if (self.binaryHandler.rxChannel != nil) {
        NSData *frame = [self.binaryHandler buildNotificationFrameWithRemoteId:remoteId
                                                                   serviceUuid:[characteristic.service.UUID uuidStr]
                                                             characteristicUuid:[characteristic.UUID uuidStr]
                                                            primaryServiceUuid:primarySvcKey
                                                                     instanceId:[instanceId unsignedShortValue]
                                                                         value:characteristic.value ?: [NSData data]
                                                                        success:(error == nil)
                                                                      errorCode:(error ? (int32_t)error.code : 0)
                                                                    errorString:(error ? [error localizedDescription] : @"")];
        [self.binaryHandler sendNotification:frame];
        return;
    }
```

（`remoteId`/`primarySvcKey`/`instanceId` 需在该方法内已算出——放在事件构造处之后、invokeMethod 之前。注意：RX 开关是 Dart 侧 `setBinaryDataChannel(true)` 才注册 rxChannel——即 rxChannel 非 nil 即"开关开"。**实现选择**：`setBinaryDataChannel` 的 MethodChannel case 里创建/销毁 rxChannel；或 rxChannel 常驻、用布尔 gate。推荐：Dart 的 `setBinaryDataChannel` case 里 `if (enabled) { 创建 rxChannel } else { rxChannel = nil; }`——注册/注销即开关，无额外布尔。）

- [ ] **Step 6: FlutterBluePlusPlugin.m——setBinaryDataChannel case**

`onMethodCall` 的 switch 新增：

```objc
        } else if ([@"setBinaryDataChannel" isEqualToString:call.method]) {
            BOOL enabled = [call.arguments boolValue];
            [self setBinaryDataChannel:enabled];
            result(@(YES));
```

并实现：

```objc
- (void)setBinaryDataChannel:(BOOL)enabled {
    if (enabled && self.binaryHandler.rxChannel == nil) {
        FlutterBasicMessageChannel *rx = [FlutterBasicMessageChannel
            messageChannelWithName:@"flutter_blue_plus/binary_rx"
                    binaryMessenger:self.registrar.messenger
                             codec:[FlutterBinaryCodec sharedInstance]];
        [rx setMessageHandler:^(id message, FlutterReply reply) { reply(nil); }];
        self.binaryHandler.rxChannel = rx;
    } else if (!enabled && self.binaryHandler.rxChannel != nil) {
        [self.binaryHandler.rxChannel setMessageHandler:nil];
        self.binaryHandler.rxChannel = nil;
    }
}
```

（`self.registrar` 需可用——若插件未持有 registrar，改用全局 `[FlutterBluePlusPlugin ...]` 的单例 messenger 或 `self.methodChannel.binaryMessenger`——以实际代码结构为准。）

- [ ] **Step 7: 静态自查 + 提交**

- `xcrun clang -fsyntax-only` 不可行则语法静态自查（括号、方法签名、`rxChannel` 属性在 .h/.m 均声明、`CFSwapInt16/32HostToBig` 需 `#include <CoreFoundation/CFByteOrder.h>`——通常经 Foundation 已引入）
- 确认三处 TX gate 顺序（complete 先、invokeMethod 条件后）

```bash
git add packages/flutter_blue_plus_darwin/darwin/flutter_blue_plus_darwin/Sources/flutter_blue_plus_darwin/BinaryProtocolHandler.h packages/flutter_blue_plus_darwin/darwin/flutter_blue_plus_darwin/Sources/flutter_blue_plus_darwin/BinaryProtocolHandler.m packages/flutter_blue_plus_darwin/darwin/flutter_blue_plus_darwin/Sources/flutter_blue_plus_darwin/FlutterBluePlusPlugin.m
git commit -m "feat(ios): binary RX channel, TX gate, writeWithoutResponse backpressure"
```

---

### Task 5: OHOS native——TX 事件移除 + RX gate + 开关

**Files:**
- Modify: `packages/flutter_blue_plus_ohos/ohos/src/main/ets/components/plugin/BinaryProtocolHandler.ets`
- Modify: `packages/flutter_blue_plus_ohos/ohos/src/main/ets/components/plugin/FlutterBluePlusOhosPlugin.ets`

**Interfaces:**
- Consumes: 既有 `binaryWriteCharacteristic` / `binaryWriteDescriptor` / `binarySetNotifyValue`（await 式，方法内 `this.channel?.invokeMethod("OnCharacteristicWritten"/"OnDescriptorWritten", response)` 发射事件）、`onCharacteristicChange` 回调（特征值变化）、`channel`（MethodChannel）
- Produces: TX gate（binary 方法内删除事件发射）、RX gate（onCharacteristicChange 发 binary_rx 帧 + return）、`setBinaryDataChannel` case、RX 通道注册（BasicMessageChannel + BinaryCodec，ArrayBuffer）

**前置事实：** OHOS 的 TX 是 await 式（无 pending map），"gate" = binary 方法内**删除**事件发射（Dart 侧从 reply 合成）；MethodChannel 路径（既有 case）事件保留。RX 事件源是 `onCharacteristicChange` 回调。

- [ ] **Step 1: TX gate——删除 binary 方法内的事件发射**

`binaryWriteCharacteristic` / `binaryWriteDescriptor` / `binarySetNotifyValue` 方法内删除 `this.channel?.invokeMethod("OnCharacteristicWritten" / "OnDescriptorWritten", response)` 调用（各自方法内"see: BmCharacteristicData"注释后的响应构造与 invokeMethod 段），方法其余逻辑（key 记录、事件数据构造）保留或一并删除——保留 mWriteChr/mWriteDesc 的记录与清除（无害且与 key 匹配逻辑共存），删除 invokeMethod 即可。注释注明：

```ets
    // Binary path: the Dart side synthesizes the written event from the
    // binary reply, so no OnCharacteristicWritten event is emitted here.
```

- [ ] **Step 2: RX 通道注册与帧构造（BinaryProtocolHandler.ets）**

`register` 里新增 RX 通道（ArrayBuffer 承载，BinaryCodec 已有）：

```ets
    this.rxChannel = new BasicMessageChannel<ArrayBuffer>(
      binding.getBinaryMessenger(),
      "flutter_blue_plus/binary_rx",
      new BinaryCodec(false),
    );
    this.rxChannel.setMessageHandler({
      onMessage: (message: ArrayBuffer, reply: Reply<ArrayBuffer>) => {
        reply.reply(new ArrayBuffer(0));
      }
    });
```

新增帧构造（对照 Dart `decodeNotification` 布局）：

```ets
  public buildNotificationFrame(remoteId: string, serviceUuid: string, characteristicUuid: string,
      primaryServiceUuid: string, instanceId: number, value: Uint8Array,
      success: boolean, errorCode: number, errorString: string): ArrayBuffer {
    const remote = new TextEncoder().encode(remoteId);
    const svc = new TextEncoder().encode(serviceUuid);
    const chr = new TextEncoder().encode(characteristicUuid);
    const primary = primaryServiceUuid ? new TextEncoder().encode(primaryServiceUuid) : new Uint8Array(0);
    const err = new TextEncoder().encode(errorString ?? "");
    const size = 1 + remote.length + 1 + svc.length + 1 + chr.length + 1 + primary.length
        + 2 + 2 + value.length + 1 + 4 + 2 + err.length;
    const buf = new ArrayBuffer(size);
    const view = new DataView(buf);
    let o = 0;
    const putStr = (bytes: Uint8Array): void => {
      view.setUint8(o, bytes.length); o += 1;
      if (bytes.length > 0) { new Uint8Array(buf, o, bytes.length).set(bytes); o += bytes.length; }
    };
    putStr(remote); putStr(svc); putStr(chr); putStr(primary);
    view.setUint16(o, instanceId); o += 2;
    view.setUint16(o, value.length); o += 2;
    if (value.length > 0) { new Uint8Array(buf, o, value.length).set(value); o += value.length; }
    view.setUint8(o, success ? 1 : 0); o += 1;
    view.setInt32(o, errorCode); o += 4;
    view.setUint16(o, err.length); o += 2;
    if (err.length > 0) { new Uint8Array(buf, o, err.length).set(err); o += err.length; }
    return buf;
  }

  public sendNotification(frame: ArrayBuffer): void {
    this.rxChannel?.send(frame);
  }
```

（`TextEncoder` 在 ArkTS 可用性以 SDK 为准；不可用则用既有 HexUtil/字符串转字节工具。`rxChannel` 为类字段，`unregister` 里置 null。）

- [ ] **Step 3: FlutterBluePlusOhosPlugin.ets——RX gate + 开关 case**

新增字段：

```ets
  private mBinaryRxEnabled: boolean = false;
  private binaryRxHandler: BinaryProtocolHandler | null = null;
```

`onMethodCall` switch 新增 case：

```ets
        case "setBinaryDataChannel": {
          let enabled: boolean = call.arguments as boolean;
          this.mBinaryRxEnabled = enabled;
          result.success(true);
          break;
        }
```

`onCharacteristicChange`（特征值变化回调，发射 OnCharacteristicReceived 之前）插入 gate：

```ets
          if (this.mBinaryRxEnabled && this.binaryRxHandler != null) {
            // fields: remoteId, serviceUuid, characteristicUuid, primaryServiceUuid,
            // instanceId, value, success, errorCode, errorString
            let frame = this.binaryRxHandler.buildNotificationFrame(
              remoteId, svcUuid, chrUuid, primarySvcUuid, instanceId, value, true, 0, "");
            this.binaryRxHandler.sendNotification(frame);
            return;
          }
```

（`remoteId`/`svcUuid`/`chrUuid`/`primarySvcUuid`/`instanceId`/`value` 以 onCharacteristicChange 实际参数为准——该回调的形参名需先查证，gate 放在事件构造处之后、invokeMethod 之前。）

- [ ] **Step 4: 静态自查 + 提交**

- 无 DevEco → 静态自查（字段/方法引用、ArrayBuffer/DataView 用法、gate 位置在 invokeMethod 之前且 return 完整）
- 确认 `onCharacteristicChange` 的实际签名（`grep -n "onCharacteristicChange" FlutterBluePlusOhosPlugin.ets`）后按实际参数名调整 gate 代码

```bash
git add packages/flutter_blue_plus_ohos/ohos/src/main/ets/components/plugin/BinaryProtocolHandler.ets packages/flutter_blue_plus_ohos/ohos/src/main/ets/components/plugin/FlutterBluePlusOhosPlugin.ets
git commit -m "feat(ohos): binary RX channel, TX event removal, setBinaryDataChannel"
```

---

### Task 6: Linux/Web——core 方法移除事件发射

**Files:**
- Modify: `packages/flutter_blue_plus_linux/lib/flutter_blue_plus_linux.dart`
- Modify: `packages/flutter_blue_plus_web/lib/flutter_blue_plus_web.dart`

**Interfaces:**
- Consumes: 既有 `binaryWriteCharacteristic` / `binaryWriteDescriptor` / `binarySetNotifyValue`（core 方法，当前成功与失败分支都 `_onCharacteristicWrittenController.add` / `_onDescriptorWrittenController.add`）
- Produces: core 方法不再发射任何事件（失败也只在返回的 record 里带 errorString）——事件统一由 Dart `writeBinary` 合成；`binarySetNotifyValue` 本就无事件

**前置事实：** 五平台语义统一为"二进制路径 = 原生不发声、Dart 从 reply 合成事件"。Linux/Web 的 core 方法只被 binary handler（writeBinary 路径）调用，删除事件发射不影响 MethodChannel 路径（public 方法事件保留）。

- [ ] **Step 1: Linux core 方法删除事件发射**

`flutter_blue_plus_linux.dart` 的 `binaryWriteCharacteristic`：删除全部 `_onCharacteristicWrittenController.add(BmCharacteristicData(...))` 调用（设备查找失败、特征查找失败、写入失败、成功四个分支的事件块），分支只保留 `return (success: ..., errorCode: ..., errorString: ...)`。`binaryWriteDescriptor` 同（`_onDescriptorWrittenController` 块）。`binarySetNotifyValue` 无事件不动。注释改为：

```dart
  // Note: the binary path does not emit onCharacteristicWritten events;
  // the Dart side synthesizes them from the binary reply (see writeBinary).
```

- [ ] **Step 2: Web core 方法删除事件发射**

`flutter_blue_plus_web.dart` 同 Step 1（删除 `_onCharacteristicWrittenController.add` / `_onDescriptorWrittenController.add` 块）。

- [ ] **Step 3: 验证**

Run: `cd packages/flutter_blue_plus_linux && flutter analyze` 与 `cd packages/flutter_blue_plus_web && flutter analyze`
Expected: 均 `No issues found!`

- [ ] **Step 4: 提交**

```bash
git add packages/flutter_blue_plus_linux/lib/flutter_blue_plus_linux.dart packages/flutter_blue_plus_web/lib/flutter_blue_plus_web.dart
git commit -m "refactor(linux,web): binary core emits no events (Dart synthesizes)"
```

---

### Task 7: 全局验证与收尾

**Files:** 无代码改动

- [ ] **Step 1: 全包静态检查**

```bash
cd packages/flutter_blue_plus_platform_interface && flutter analyze && flutter test
cd packages/flutter_blue_plus && flutter analyze
cd packages/flutter_blue_plus_linux && flutter analyze
cd packages/flutter_blue_plus_web && flutter analyze
```
Expected: 各 `No issues found!`（主包仅既有 pubspec path 依赖警告）+ platform_interface `All tests passed!`

- [ ] **Step 2: 侵入移除证明**

```bash
git diff 0960565 -- packages/flutter_blue_plus/lib/src/bluetooth_characteristic.dart
git diff 0960565 -- packages/flutter_blue_plus/lib/src/bluetooth_descriptor.dart
```
Expected: 仅 `*Binary` 方法新增行与文档注释；`write()` / `setNotifyValue()` / `writeDescriptor()` 方法体无修改（若有修改行 → 修正还原）。

- [ ] **Step 3: 四组合语义核对（静态）**

- `write()`（RX 关）：纯 MethodChannel，事件来自原生 ✅
- `write()`（RX 开）：TX MethodChannel + RX binary_rx 帧 → onCharacteristicReceived ✅
- `writeBinary()`（RX 关）：二进制 + Dart 合成 written 事件；原生 TX gate 跳过 On*Written（无双发）✅
- `writeBinary()`（RX 开）：全二进制数据面 ✅

核对点：合成事件与原生 gate 不双发（Task 3/4/5 gate 严格 return；Task 6 删除发射）；RX 帧喂现有 controller（Task 1 decodeNotification + Task 3/4/5 插件注册）。

- [ ] **Step 4: 汇报**

总结各平台最终状态 + 实机验证需求（A/B 延迟基准、四组合正确性、iOS 背压、OHOS RX 帧）。




