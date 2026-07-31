# 二进制数据面重构（非侵入模型）设计文档

日期：2026-07-31
状态：已获用户分节批准（基线 A：master 现状改造；TX 方法名选择；RX BasicMessageChannel + BinaryCodec；Linux/Web 与 Android/iOS 语义统一）

## 背景

`BINARY_DATA_PLANE_DESIGN.md` 定义了"非侵入 + 可选 + 可对比/回退"的二进制数据面蓝图（基线 1.38.0 = 0960565）。master 当前已有一套**侵入式**二进制实现（`write()` 内部 try-binary-first + fallback），经 23 个提交修复与完善。本设计将 master 现状**改造为蓝图模型**：

- 保留 master 已修的全部 bug 修复与 Linux/Web 支持
- 移除对原方法的侵入（`write()` / `setNotifyValue()` / `writeDescriptor()` 还原为纯 MethodChannel）
- 新增 `*Binary()` 显式方法（TX 选择轴）与 `setBinaryDataChannel` 开关（RX 选择轴）
- 补齐 RX 二进制通道（P1-c）与 TX 完成 gate（P1-b）

## 架构

```
                 控制面 (MethodChannel, 不动)         数据面 (二进制, 可选)
请求(Dart→Native)  scan/connect/discover/mtu/...       write* → *Binary() 方法
                                                     ↓ BasicMessageChannel<ByteData> + BinaryCodec
通知(Native→Dart)  OnCharacteristicReceived(默认)       binary_rx 帧 (开关开时)
```

**两条独立选择轴：**
- **TX**：原方法（MethodChannel）或新方法 `writeBinary()` / `setNotifyValueBinary()` / `writeDescriptorBinary()`（二进制）。完成模型不同（MethodChannel 等 `On*Written` 事件 vs 二进制等 reply），故需独立方法名。原方法**一字不改**。
- **RX**：`FlutterBluePlus.setBinaryDataChannel(bool)` 开关（默认关）。开 → native 发 binary_rx 帧并跳过 MethodChannel `OnCharacteristicReceived`；Dart 解码喂**同一个** `onCharacteristicReceived` 控制器 → `read()` / `lastValueStream` / `onValueReceived` 不改也照常。

## 线规（binary_protocol.dart，已有 + 新增）

### TX 请求帧（已有）
```
cmd(1) flags(1) instanceId(u16)
remoteIdLen(1) remoteId / serviceUuidLen(1) serviceUuid / characteristicUuidLen(1) characteristicUuid
primaryServiceUuidLen(1, 0=null) primaryServiceUuid / descriptorUuidLen(1, 0=null) descriptorUuid
valueLen(u16) value
```
cmd: 0x01 writeCharacteristic / 0x02 writeDescriptor / 0x03 setNotifyValue
通道名：`flutter_blue_plus/binary`

### TX 响应帧（已有）
```
success(u8) errorCode(i32 BE) errorStrLen(u16 BE) errorStr
```

### RX 通知帧（新增，native→Dart，fire-and-forget）
```
remoteIdLen(1) remoteId / serviceUuidLen(1) serviceUuid / characteristicUuidLen(1) characteristicUuid
primaryServiceUuidLen(1, 0=null) primaryServiceUuid
instanceId(u16 BE) valueLen(u16 BE) value success(u8) errorCode(i32 BE) errorStrLen(u16 BE) errorStr
```
通道名：`flutter_blue_plus/binary_rx`（BasicMessageChannel + BinaryCodec；原生 `send` 不带 reply（无往返），Dart handler 返回空 `ByteData(0)` 满足签名、无实际回传）
Dart `decodeNotification(ByteData)` → `BmCharacteristicData`

## Dart 侧改动

### 1. 原方法还原（侵入移除）

`write()` / `setNotifyValue()` / `writeDescriptor()` 移除二进制 fast path，方法体还原为纯 MethodChannel 实现（git 历史 0960565 版本的方法体）。**验证标准：三方法与 0960565 版 diff 为空。** 放弃 `useBinaryChannel` 开关方案（TX 选择完全靠方法名）。

### 2. 新增 *Binary 方法

- `BluetoothCharacteristic.writeBinary(List<int> value, {bool withoutResponse = false, bool allowLongWrite = false, Duration timeout = 15s})`
- `BluetoothCharacteristic.setNotifyValueBinary(bool notify, {bool forceIndications = false, Duration timeout = 15s})`
- `BluetoothDescriptor.writeDescriptorBinary(List<int> value, {Duration timeout = 15s})`

结构（以 writeBinary 为例）：check connected → per-device mutex → `_BinaryWriteChannel.writeCharacteristic(...)` → 成功则 `FlutterBluePlusPlatform.instance.emitCharacteristicWritten(BmCharacteristicData(...))` 合成事件（保证 lastValue / lastValueStream）；`MissingPluginException`（无 handler 平台如 Windows）回退 MethodChannel 原路径。

### 3. 平台接口加性钩子（纯加性，现有接口不动）

- `emitCharacteristicWritten(BmCharacteristicData)` / `emitDescriptorWritten(BmDescriptorData)`：默认 no-op，5 平台插件 override 为 `_on*WrittenController.add`
- `setBinaryDataChannel(bool enabled)`：默认 no-op；android/darwin/ohos override 为 `methodChannel.invokeMethod('setBinaryDataChannel', enabled)`
- `FlutterBluePlus.setBinaryDataChannel(bool)`：静态 RX 开关（默认 false）

### 4. RX 通道（platform_interface + 3 平台插件）

- `binary_protocol.dart` 新增 `binaryRxChannelName` + `decodeNotification(ByteData)` + 单测（非 ASCII、空 value、oversized、逐字节布局）
- android/darwin/ohos 插件 `registerWith` 注册 `flutter_blue_plus/binary_rx` handler：`decodeNotification` → `_onCharacteristicReceivedController.add`（喂现有控制器）
- linux/web 不注册（其 RX 本就是 Dart 直连 bluez / Web Bluetooth，无 MethodChannel 跳）

## 原生侧改动

### Android（BinaryProtocolHandler.java + FlutterBluePlusPlugin.java）

- **TX gate（P1-b）**：`onCharacteristicWrite` 算出 key 后先 `if (binaryHandler.completeWriteCharacteristic(...)) return;`——命中（二进制写）跳过 `OnCharacteristicWritten`；未命中（MethodChannel 写）走原逻辑。`onDescriptorWrite` 先试 desc key 再试 notify key，任一命中则跳过 `OnDescriptorWritten`
- **RX gate**：`onCharacteristicReceived` 在 `OnCharacteristicReceived` 发射之前：`if (mBinaryRxEnabled && binaryHandler != null) { binaryHandler.sendNotification(frame); return; }`
- **开关**：`onMethodCall` 加 `case "setBinaryDataChannel"` → 置 `volatile boolean mBinaryRxEnabled`
- **保留**：空 primaryServiceUuid 归一化（C1）、断连清理 failPendingForRemoteId（C-1）、supersede、主线程 reply（P1-a）、allowLongWrite、UTF-8

### iOS（BinaryProtocolHandler.m + FlutterBluePlusPlugin.m）

- **TX gate**：`complete*` 改返回 BOOL，命中则跳过 `OnCharacteristicWritten` / `OnDescriptorWritten`
- **RX gate**：`didUpdateValueForCharacteristic` 若 binaryRxChannel 已注册 → `buildNotificationFrame` → `sendMessage`（无 reply）→ return（跳过 MethodChannel 事件）
- **iOS 背压修正**：`writeWithoutResponse` **不立即 reply**——存 pending，在 `peripheralIsReadyToSendWriteWithoutResponse` 回调完成该 remoteId 的 pending reply（消除立即 reply 的丢包风险）
- **保留**：128 归一 key、断连清理 clearPendingRepliesForRemoteId、载荷检查（maximumWriteValueLengthForType）、instanceId 全局计数语义、supersede

### OHOS（BinaryProtocolHandler.ets + FlutterBluePlusOhosPlugin.ets）

同 Android 结构：TX gate（complete 命中跳事件）、RX gate（发帧 + return）、`setBinaryDataChannel` case。保留 allowLongWrite 透传、空串归一化、null 安全。

### Linux/Web

- **TX 语义统一**：core 方法（binaryWriteCharacteristic / binaryWriteDescriptor / binarySetNotifyValue）**移除事件发射**（成功与失败都不发，失败走 Dart 抛异常）——事件统一由 Dart `*Binary()` 合成，与 iOS/Android TX gate 语义一致，消除双发
- **RX**：维持 Dart 直连（无中间层可省；开关对 linux/web 天然 no-op）

## 验证

1. `flutter analyze` 全包 0 error；platform_interface 单测（恢复 binary_protocol 测试 + decodeNotification、非 ASCII UTF-8 往返、空 value、oversized）全绿
2. 侵入移除证明：`git diff` 三原方法与 0960565 版为空
3. 四组合静态核对：write/writeBinary × RX 开关开/关，lastValue / lastValueStream 语义正确、无双发
4. iOS/Android/OHOS 无编译环境 → 静态自查清单
5. 实机 A/B 延迟基准（write vs writeBinary 高频写；RX 开关开 vs 关高频通知）留给用户执行

## 范围外（明确不做）

- 控制面（扫描/连接/发现/MTU/RSSI/绑定）不二进制化
- `read()` 不加 Binary 变体（RX 通道透明覆盖读/通知）
- Windows 无 TX handler（writeBinary 回退 MethodChannel，可用）
- 不引入 EventChannel（RX 用 BasicMessageChannel + BinaryCodec，与 TX 同一通道模式）
