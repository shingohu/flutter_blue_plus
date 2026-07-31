# 复测 v3 —— 修复验证 + 修复后剩余优化分析

> 基于 `git diff` 实际代码核对。前两轮报告：`PERF_ANALYSIS.md`（初版路径分析）、`PERF_ANALYSIS_FOLLOWUP.md`（P0 接上）、`REVIEW_CORRECTION.md`（纠正 iOS key 格式 bug + 新增超时死锁）。本轮：确认你修复的 3 处已正确落地，并给出修复后真实剩余瓶颈。

## 一、你修复的 3 处 —— 已验证正确生效

| 修复点 | 预期 | 代码现状 | 结论 |
|---|---|---|---|
| **iOS key 格式对齐** | store key 与 completion key 都用 128 位 | store 侧 `BinaryProtocolHandler.m:175-177/211-215/239-241` 用 `[self uuid128:...]`；delegate 侧 `FlutterBluePlusPlugin.m:1706-1707` 用 `[UUID uuidStr]`（128 位小写）拼 completion key | ✅ 两端均为 128 位小写，16/32 位标准 UUID 可正确匹配 |
| **Android setNotifyValue key** | 存/取 key 都含 CCCD descriptorUuid | `BinaryProtocolHandler.java:314` 存 key 已含 `plugin.uuidStr(cccd.getUuid())`，与 `onDescriptorWrite`（`FlutterBluePlusPlugin.java:2600-2601`）取 key 一致 | ✅ 匹配 |
| **Dart 二进制通道超时** | `_channel.send` 加超时，防死锁 | `binary_channel.dart:142` 已 `await _channel.send(request).timeout(_sendTimeout)`（15s），并捕获 `TimeoutException` 抛 `FbpErrorCode.timeout` | ✅ 死锁已被兜底 |

**iOS key 匹配推演（关键）：**
- Dart 发 `Guid.str`：`180d`（16 位短串）
- store：`uuid128("180d")` → strip → 128 位 `"0000180d-0000-1000-8000-00805f9b34fb"`
- completion：CoreBluetooth 的 `characteristic.UUID.uuidStr` 本身就是 128 位 → 同一串
- 两端相等 → reply 能找到。**之前会挂起的标准特征现在全部正常。**

**修复后真实可用性矩阵：**

| 操作 | iOS | Android |
|---|---|---|
| 写入（128 位 UUID） | ✅ | ✅ |
| 写入（16/32 位标准 BLE） | ✅ 已修 | ✅ |
| setNotifyValue | ✅ 已修 | ✅ 已修 |
| 任一不回包 | 15s 超时（不再死锁设备） | 15s 超时（不再死锁设备） |

> 三处修复把 TX 方向（写/通知开关）从「部分挂死」变成了「全绿」。这是实质性进展。

---

## 二、修复后仍有 6 个实质问题（按收益排序）

### P1-a｜Android 二进制 reply 线程不安全（隐患）
`FlutterBluePlusPlugin.java:2523-2525` 在 `onCharacteristicWrite` 回调里**直接**调用 `binaryReply.reply(...)`，该回调运行在 **GATT binder 线程**，而非主线程。

注意：同一方法里 `invokeMethodUIThread("OnCharacteristicWritten", ...)`（2545 行）被显式包了 UI 线程 —— 说明作者清楚回调不在主线程。但 binary reply 没包。
Flutter 的 `BinaryMessenger.BinaryReply` 要求在其绑定的 platform 线程（主线程）调用，跨线程调用在部分 Flutter 版本会导致丢消息 / 卡死。

- **修复**：把 `binaryReply.reply(...)` 用 `activity.runOnUiThread(...)` 包裹，与现有 `invokeMethodUIThread` 模式一致。
- iOS 无此问题（`CBCentralManager queue:nil` → 回调本就在主线程，`completeReply` 安全）。

### P1-b｜冗余的 OnCharacteristicWritten / OnDescriptorWritten 事件（性能浪费）
修复后二进制写入**同时**走两条路：
1. 二进制 reply（正确返回 `write()` 结果）—— 这是 Dart 实际用的
2. 仍派发 MethodChannel 事件 `OnCharacteristicWritten`（iOS 1732 行 / Android 2545 行），且 `response.put("value", value)` **把刚写入的 value 原样序列化回传**

这正是初版报告里点名的核心浪费：一条 write 付出 **2 倍**成本（二进制 reply + 一个带 value 拷贝的完整 MethodChannel 事件）。高吞吐 `writeWithoutResponse` 连发场景尤其吃亏。

- **修复**：当 `mBinaryReplyMap` 命中（说明是二进制路径）时，跳过 `OnCharacteristicWritten` 事件，或至少去掉 `value` 字段。
- 同样逻辑适用于 `onDescriptorWrite`。

### P1-c｜RX 通知（原生 → Flutter）仍是全量 MethodChannel —— 当前最大瓶颈
你最关心的「原生数据到 Flutter」方向，修复后**完全没动**：
- **Android** `onCharacteristicChanged`（2466 行）：8 字段 `HashMap` + `uuidStr()` ×3（3 次 UUID 字符串化）+ `invokeMethodUIThread("OnCharacteristicReceived", ...)`（主线程 hop）+ value 拷贝。
- **iOS** `didUpdateValueForCharacteristic` → `OnCharacteristicReceived` 同样全量 MethodChannel。
- **Dart 侧**：事件流 `_onCharacteristicReceived` → `_lastChrs`（每条通知做字符串 key 插值）+ 5 层 `where()` 链过滤 → 才到你的 `onValueReceived` 监听器。

高频通知（如 100Hz 传感器）这条路径的序列化 + 主线程 hop + 字符串化 + `where()` 过滤是主要延迟来源，比 TX 侧严重得多。

- **方向**：把 `OnCharacteristicReceived` 也改成独立 binary 通道（帧里只带 `remoteId + chrHandle + value`），原生侧用 `chrHandle`（或归一化 128 位 UUID key 复用现有 map）做 O(1) 分发，砍掉全部字符串化和主线程 hop。

### P1-d｜`_utf8Encode` 是 UTF-16 而非 UTF-8 —— 隐性正确性 bug
`binary_protocol.dart:230`：
```dart
Uint8List _utf8Encode(String s) => Uint8List.fromList(s.codeUnits);
```
`s.codeUnits` 是 **UTF-16 码元**，不是 UTF-8 字节。对 ASCII（hex UUID、MAC 地址、错误串）碰巧一致，但一旦 `remoteId` 或 `errorString` 含非 ASCII（某些设备名 / macOS 标识符），编码出的字节与原生侧按 UTF-8 解码**不一致** → key 匹配失败或乱码。

- **修复**：
  ```dart
  import 'dart:convert';
  Uint8List _utf8Encode(String s) => Uint8List.fromList(utf8.encode(s));
  String _utf8Decode(Uint8List b, int off, int len) => utf8.decode(b.sublist(off, off + len));
  ```

### P2-a｜iOS `CBCentralManager queue:nil` 跑主线程
`FlutterBluePlusPlugin.m:156`：`initWithDelegate:self queue:nil` → 所有 CoreBluetooth 回调挤主线程。UI 忙时，write 完成与通知投递被拖延。

- **修复**：用专用串行队列 `dispatch_queue_create("ble.cb", DISPATCH_QUEUE_SERIAL)`；注意 `completeReply` 涉及 `FlutterBinaryReply`，需在回调队列上调用（Flutter 二进制 reply 在任意线程调用是安全的，因为它内部 post 到 engine 线程）。

### P2-b｜`Guid.str` / `str128` 无缓存
`guid.dart`：`str` 每次访问都调 `str128` 并重算 `_hexEncode` 多次；`hashCode` 也调 `str128`。高吞吐通知下每条都重复。

- **修复**：构造时缓存 `str128`/`str` 到 `final` 字段（immutable 对象，线程安全）。

---

## 三、建议落地顺序

1. **P1-d**（UTF-8 编解码）—— 1 行改动，先消除隐性正确性风险
2. **P1-a**（Android reply 线程）—— 几行，消除跨线程隐患
3. **P1-b**（去掉冗余事件 + value 回传）—— 直接砍掉 TX 一半开销
4. **P1-c**（RX 走 binary 通道）—— 你最关心的方向，收益最大，工作量也最大
5. **P2-a / P2-b** —— 延迟进一步压榨

> 物理下限：connection interval ≥ 7.5ms（iOS）是 BLE 协议硬约束，软件优化突破不了。但当前软件胶水层远高于此，尤其 RX 路径，空间非常大。

## 四、关于「句柄化协议」的远景
当前二进制请求帧仍把 UUID 当 UTF-8 字符串传（每条 write 帧里 service/char/primary 三串 UUID，16 位场景仍约 40+ 字节）。更彻底的方案是**发现阶段给每个 characteristic 分配一个 uint16 handle**，写入帧头 6 字节即可定位，编解码降一个数量级。但这需要改发现期数据结构、跨 TX/RX 复用 handle 表，是 P1-c 之上的进一步重构，建议作为 v4 目标。
