# 二进制数据面实现设计文档

> 本文档记录在 `1.38.0` 基线上、以"非侵入 + 可选 + 可对比/回退"为原则的二进制数据面实现方案。
> 代码已被清除（按需重做），本文作为实现蓝图与评审依据。

---

## 1. 目标与约束

| 项 | 要求 |
|---|---|
| 基线 | `1.38.0` 分支（HEAD `0960565`），干净祖先，无二进制代码 |
| 范围 | **数据面 only**（写特征值 / 写描述符 / setNotify + 通知 RX / 读 RX）。控制面（扫描/连接/发现/MTU/RSSI/绑定）保持 MethodChannel |
| 侵入性 | 现有 `write()` / `setNotifyValue()` / `writeDescriptor()` / `read()` / `lastValueStream` **一字不改**（git diff vs 1.38.0 为空） |
| 可选性 | 二进制作为并行路径，**默认关**（=纯 1.38.0 行为）；开关 + 方法名双重选择 |
| 对比/回退 | TX 换方法名、RX 翻开关，各自独立可测；回退 = 换回原方法 / 关开关 |
| 实现来源 | 从零按自有思路实现，不参考 master 的 `BinaryProtocolHandler`，最后与 master 对比 |

---

## 2. 架构总览

```
                 控制面 (MethodChannel, 不动)        数据面 (二进制, 新增可选)
请求(Dart→Native)  scan/connect/discover/mtu/...      write*/setNotify* → *Binary() 方法
                                                   ↓ BasicMessageChannel<ByteData> + BinaryCodec
通知/读(Native→Dart) OnCharacteristicReceived(默认)    binary_rx 帧 (开关开时)
```

**两条独立选择轴：**
- **TX（写）**：调原方法 `write()`（MethodChannel）或新方法 `writeBinary()`（二进制）。完成模型不同（MethodChannel 等 `On*Written` 事件 vs 二进制等 reply），故需独立方法名。
- **RX（通知/读）**：`FlutterBluePlus.setBinaryDataChannel(bool)` 开关（默认关）。开关开 → native 走 `binary_rx` + 跳过 MethodChannel `OnCharacteristicReceived`；Dart 侧 handler 解码喂**同一个** `onCharacteristicReceived` 控制器 → `read()`/`lastValueStream`/`onValueReceived` 不改也照常工作。**RX 对 Dart 透明**，`read()` 无需 binary 变体。

**四组合 A/B 矩阵：**

| | RX 关 | RX 开 |
|---|---|---|
| `write()` | 纯 1.38.0（默认） | TX 走 MethodChannel，RX 走二进制 |
| `writeBinary()` | TX 走二进制，RX 走 MethodChannel | 全二进制数据面 |

---

## 3. 线规（`binary_protocol.dart`，platform_interface）

所有整数大端，字符串 UTF-8 + 1 字节长度前缀（≤255），value 用 uint16 长度前缀（≤65535）。

### 3.1 TX 请求帧
```
cmd(1) flags(1) instanceId(u16)
remoteIdLen(1) remoteId
serviceUuidLen(1) serviceUuid
characteristicUuidLen(1) characteristicUuid
primaryServiceUuidLen(1, 0=null) primaryServiceUuid
descriptorUuidLen(1, 0=null) descriptorUuid
valueLen(u16) value
```
cmd: 0x01 writeCharacteristic / 0x02 writeDescriptor / 0x03 setNotifyValue
flags: write → withoutResponse(1<<0) allowLongWrite(1<<1)；notify → enable(1<<0) forceIndications(1<<1)

### 3.2 TX 响应帧（native→Dart reply）
```
success(u8) errorCode(i32 BE) errorStrLen(u16 BE) errorStr
```

### 3.3 RX 通知/读帧（native→Dart，fire-and-forget）
```
remoteIdLen(1) remoteId
serviceUuidLen(1) serviceUuid
characteristicUuidLen(1) characteristicUuid
primaryServiceUuidLen(1, 0=null) primaryServiceUuid
instanceId(u16 BE)
valueLen(u16 BE) value
success(u8)
errorCode(i32 BE)
errorStrLen(u16 BE) errorStr
```
Dart `decodeNotification(ByteData)` → `BmCharacteristicData`。**各 native 帧构造必须逐字节对齐。**

### 3.4 通道名
- TX：`flutter_blue_plus/binary`
- RX：`flutter_blue_plus/binary_rx`

---

## 4. Dart 侧实现（已完成并验证，后被清除）

> 这部分代码此前已落盘并通过 `flutter analyze` + 18 单测，后按用户要求清除。重做时照此实现。

### 4.1 `guid.dart` — Guid 懒缓存（P2-b）
`Guid` 不可变（`bytes` final），`str128`/`str` 改为委托 `_computeStr128()`/`_computeStr()` 并缓存到 `String? _str128Cache/_strCache`。`==`/`hashCode` 走 `str128` 自动受益。TX 每次写读 4 次 `.str`、RX 每条通知的流过滤 `==` 都命中缓存。无 native 改动，风险最低。

### 4.2 `binary_protocol.dart`（platform_interface，新文件）
导出 `binaryChannelName`/`binaryRxChannelName` + `BinaryCommand`/`WriteFlags`/`NotifyFlags` + `encodeWriteCharacteristic`/`encodeWriteDescriptor`/`encodeSetNotifyValue`/`decodeResponse`/`decodeNotification`。纯加性，现有接口方法不动。配套 `binary_protocol_test.dart`（10 测试，含非 ASCII UTF-8 往返、空 value、oversized 抛错）。

### 4.3 `binary_channel.dart`（flutter_blue_plus，新 part）
`_BinaryWriteChannel` 单例：`writeCharacteristic`/`writeDescriptor`/`setNotifyValue`，各调 `encodeX` → `BasicMessageChannel<ByteData>.send` → `decodeResponse`，失败抛 `FlutterBluePlusException`。`instanceId > 0xFFFF` 抛 `MissingPluginException`（回退 MethodChannel）。`_sendAndReceive` 用调用方 `timeout`（保护 per-device 互斥锁不死锁）。

### 4.4 新增 `*Binary()` 写方法（bluetooth_characteristic.dart / bluetooth_descriptor.dart）
- `BluetoothCharacteristic.writeBinary(...)`
- `BluetoothCharacteristic.setNotifyValueBinary(...)`
- `BluetoothDescriptor.writeDescriptorBinary(...)`

每个：mutex → `_BinaryWriteChannel.*` → 成功后经 `emitCharacteristicWritten`/`emitDescriptorWritten` **合成** `BmCharacteristicData`/`BmDescriptorData` 喂现有控制器（保证 `lastValue`/`lastValueStream` 照常更新）。现有 `write()`/`setNotifyValue()`/`writeDescriptor()` 不动。

### 4.5 平台接口加性钩子
- `FlutterBluePlusPlatform.emitCharacteristicWritten(BmCharacteristicData)` / `emitDescriptorWritten(BmDescriptorData)`：默认 no-op，5 平台插件 override 为 `_on*WrittenController.add(data)`。
- `FlutterBluePlusPlatform.setBinaryDataChannel(bool enabled)`：默认 no-op；android/darwin/ohos override 为 `methodChannel.invokeMethod('setBinaryDataChannel', enabled)`。
- `FlutterBluePlus.setBinaryDataChannel(bool)`：静态，转调平台方法（RX 开关）。

### 4.6 RX handler 注册（android/darwin/ohos Dart 插件）
`registerWith()` 里 `BasicMessageChannel<ByteData>(binaryRxChannelName, BinaryCodec()).setMessageHandler((msg) async { 控制器.add(decodeNotification(msg)); return ByteData(0); })`。handler 返回类型 `Future<ByteData>`（非空，返回空 `ByteData(0)` 作"无回复"）。linux/web 不注册（其 RX 本就是 Dart 直连 bluez/Web Bluetooth，无 MethodChannel 跳）。

---

## 5. Android Native 实现计划（未编码）

### 5.1 形态：非静态内部类
`BinaryProtocolHandler` 作为 `FlutterBluePlusPlugin` 的**非静态内部类**，直接复用已验证的私有 helper：`locateCharacteristic` / `getInstanceId` / `getPrimaryService` / `getMaxPayload` / `getDescriptorFromArray` / `uuidStr` / `gattErrorString` / `bluetoothStatusString` / `mConnectedDevices` / `mMtu` / `CCCD`。现有方法零改动。

### 5.2 接线（最小侵入）
- `onAttachedToEngine`：`binaryHandler = new BinaryProtocolHandler(messenger);`
- `onDetachedFromEngine`：`binaryHandler.dispose(); binaryHandler = null;`
- 新增字段 `private volatile boolean mBinaryRxEnabled = false;`
- `onMethodCall` 加 `case "setBinaryDataChannel":` → 置 `mBinaryRxEnabled`。

### 5.3 TX 处理
- 通道 `flutter_blue_plus/binary`，`BinaryCodec.INSTANCE`。
- **关键坑**：Android `BinaryCodec` 的消息类型是 **`ByteBuffer`**，不是 `byte[]`。`BasicMessageChannel<ByteBuffer>`，`MessageHandler<ByteBuffer>`，reply 也是 `Reply<ByteBuffer>`。解析时 `msg.remaining()` 取字节拷到 `byte[]` 再 `ByteBuffer.wrap` 读。
- 解析帧 → 按 cmd 分发 `handleWriteCharacteristic`/`handleWriteDescriptor`/`handleSetNotifyValue`，逻辑镜像现有 MethodChannel 写 handler（属性检查、`getMaxPayload`/MTU 检查、SDK 33+ `gatt.writeCharacteristic(chr,value,type)` vs 旧 `setValue`+`setWriteType`+`writeCharacteristic`）。
- **pending reply map**：`ConcurrentHashMap<String, Reply<ByteBuffer>>`，key 形如 `write:remoteId:primary:svc:chr:instanceId`（descriptor 加 `:descUuid`，notify 用 `notify:` 前缀无 descUuid）。
- **key 匹配无需 128 归一**：Dart 侧发 `.str`（最短形式），native 回调用 `uuidStr(gatt)`（也是最短形式），两者对 16/32/128-bit UUID 都一致。直接用 Dart 传入字符串作 store key，回调用 `uuidStr(gatt)` 作 lookup key。
- **supersede**：同 key 新 reply 覆盖旧的，旧的在主线程回 error（"superseded"）。
- **reply 线程**：所有 `reply.reply(ByteBuffer.wrap(bytes))` 经 `Handler(Looper.getMainLooper()).post()` —— FlutterJNI 要求 UI 线程。
- **writeWithoutResponse 背压**：**不**立即 reply，存 pending，等 `onCharacteristicWrite` 回调完成（Android 在缓冲区有空间时才回调，天然背压）。与现有 MethodChannel `write()` 等待 `OnCharacteristicWritten` 一致。

### 5.4 RX 处理
- 通道 `flutter_blue_plus/binary_rx`，`BinaryCodec`。
- `buildNotificationFrame(...)`：按 §3.3 布局用 `ByteBuffer.allocate(BIG_ENDIAN)` 构造。
- `onCharacteristicReceived` 顶部 gate（在 1801/2A05 OnServicesReset 块之后、OnCharacteristicReceived 发射之前）：
  `if (mBinaryRxEnabled && binaryHandler != null) { binaryHandler.sendNotification(...); return; }` —— 跳过 MethodChannel `OnCharacteristicReceived`。

### 5.5 TX 完成 gate（= P1-b，自然落地）
- `onCharacteristicWrite`：算出 remoteId/primary/svc/chr/instanceId 后，`if (binaryHandler.completeWriteCharacteristic(...)) return;` —— 命中则跳过 `OnCharacteristicWritten`（Dart 侧 `writeBinary` 已从 reply 合成事件）。未命中（MethodChannel 写）走原逻辑。
- `onDescriptorWrite`：先试 `completeWriteDescriptor(...descUuid...)`，再试 `completeSetNotify(...)`，任一命中则 return 跳过 `OnDescriptorWritten`。
- `completeReply(key,...)`：`pendingReplies.remove(key)`，命中则主线程 reply，返回 true。

### 5.6 断连清理
`onConnectionStateChange(DISCONNECTED)` 里 `binaryHandler.failPendingForRemoteId(remoteId)`：遍历 pending map，匹配 `write:remoteId:` / `desc:remoteId:` / `notify:remoteId:` 前缀，主线程回 error（"device is disconnected"），避免 Dart 等满 15s 超时。

### 5.7 验证
`javac -cp flutter.jar:android.jar:androidx-*.jar` 编译通过（注意 flutter.jar 含 `io.flutter.plugin.common.BinaryCodec`，**无** `BinaryMessageCodec`）。

---

## 6. iOS Native 实现计划（未编码）

### 6.1 形态
`BinaryProtocolHandler`（独立 `.m`/`.h`），持 `FlutterBasicMessageChannel *binaryChannel`/`binaryRxChannel` + `NSMutableDictionary<NSString*, FlutterBinaryReply> pendingReplies`。`FlutterBluePlusPlugin` 持有它，回调里调用。

### 6.2 队列
`CBCentralManager` 保持 `queue:nil`（主线程）。原因：Flutter iOS 平台消息**必须**主线程发送；专用队列收益有限且引入插件共享 `NSMutableDictionary` 跨线程并发 + `CBPeripheral` 非线程安全。

### 6.3 TX
- `didWriteValueForCharacteristic`：算 key（**需 128 归一**：iOS `[CBUUID UUIDString]` 恒为 128 位小写，Dart 发最短 → store key 用 `uuid128:` 归一再存；lookup 同样归一）→ `completeWriteCharacteristic` 返回 `BOOL`，命中则跳过 `OnCharacteristicWritten`。
- `didWriteValueForDescriptor`：同，`completeWriteDescriptor` 返回 BOOL。
- `complete*` 改返回 BOOL（命中 pending 才跳事件）。

### 6.4 writeWithoutResponse 背压（**修正 master 的丢包风险**）
`writeWithoutResponse` **不**立即 reply。存 pending，在 `peripheralIsReadyToSendWriteWithoutResponse:peripheral` 回调里完成该 remoteId 的 pending reply。这避免 iOS 在 `canSendWriteWithoutResponse=NO` 时丢包。master 那版立即 reply 有丢包风险，本方案修正。

### 6.5 RX
`didUpdateValueForCharacteristic`：若 `binaryRxChannel` 已注册，`buildNotificationFrame`（Obj-C 版，`NSMutableData` + `CFSwapInt16/32HostToBig`）→ `[binaryRxChannel sendMessage:frame]` → `return`（跳过 `OnCharacteristicReceived`）。

### 6.6 断连
`didDisconnectPeripheral` 调 `clearPendingRepliesForRemoteId:`（遍历 key 含 `:remoteId:` 的，reply error）。

### 6.7 验证
`xcrun clang -fsyntax-only` 对 `Flutter.xcframework` 头通过。注意既有坑：`uuidStr` 分类要移到公共头让 handler 可见；`complete*` 须实现（master 漏实现会运行时崩溃）。

---

## 7. OHOS Native 实现计划（未编码）
ETS `BinaryProtocolHandler`，结构与 Android 类似（`BasicMessageChannel<ArrayBuffer>` + `BinaryCodec`）。TX: 解析帧 → `ble.writeCharacteristicValue` 等，pending reply map。RX: `onCharacteristicChanged` 顶部 gate 发帧 + return。需核对 OHOS `writeNoResponse` 是否触发完成回调（不触发则靠 15s 超时兜底，或改立即 reply）。

---

## 8. Linux / Web
- **RX**：已是 Dart 直连（bluez / Web Bluetooth），无 native→Dart MethodChannel 跳，**无需** RX 二进制。
- **TX**：可选补 `binary_handler.dart`（二进制写请求），本轮可推迟。其 `write()` 不动 → `writeBinary` 可对齐。

---

## 9. 验证计划
1. `dart analyze` 全包 0 error；`flutter test` platform_interface（binary_protocol + guid，18 测试）全绿。
2. Android `javac` 对 `flutter.jar:android.jar:androidx-*.jar` 编译通过；iOS `clang -fsyntax-only` 通过。
3. **A/B 延迟基准**：同设备同特征值，`write()` vs `writeBinary()`（高频写入），`setBinaryDataChannel(false)` vs `true`（高频通知），量 end-to-end 延迟与抖动。
4. **正确性**：`lastValue`/`lastValueStream` 在四种组合下都正确更新；断连时 pending 写快速失败；标准 16/32/128-bit UUID key 都能匹配。

---

## 10. 风险与开放问题
| 风险 | 缓解 |
|---|---|
| 帧布局跨平台不一致 → 解码错乱 | 共享 `binary_protocol.dart` 单一真源 + 单测锁线规；native 实现后加跨平台往返测试 |
| `binary_rx` 与 MethodChannel 双发 | native gate 必须严格：发 binary_rx 即 return 跳 MethodChannel；开关默认关 |
| iOS 128 归一 key 不匹配 | store/lookup 都走 `uuid128:`；单测覆盖 16/32/128-bit |
| iOS writeWithoutResponse 丢包 | reply 延后到 `peripheralIsReadyToSendWriteWithoutResponse` |
| OHOS writeNoResponse 回调不明 | 实现前先验证；不触发则靠超时或立即 reply |
| P1-b 与 lastValue 双发 | P1-b 由 native gate + Dart 合成事件协同：native 跳事件时 Dart 已从 reply 合成，不会双发 |

---

## 11. 实施顺序建议
1. **Dart 侧**（§4）：Guid 缓存 → 协议层 → `_BinaryWriteChannel` → `*Binary` 方法 + emit + setBinaryDataChannel + RX handler 注册。全 `dart analyze` + 单测。
2. **Android native**（§5）：参考实现，javac 验证。
3. **iOS native**（§6）：注意 128 归一 + writeWithoutResponse 背压。
4. **OHOS native**（§7）。
5. **对比 master**：同线规、不同实现，A/B 基准。
6. linux/web TX binary（可选）。

---

## 附：当前仓库状态
- `feature/binary-data-plane` 分支已被沙箱重置清除（Dart 实现丢失）。
- 当前 HEAD = `master`（`ee48d5a`，含 master 旧二进制通道）。
- `1.38.0` 基线分支在 `0960565`，干净。
- 重做时：从 `1.38.0` 新建分支，按本文 §4→§7 实现。
