# 二进制 write 通道对齐到 Linux/Web/OHOS 平台 · 设计文档

日期：2026-07-31
状态：已获用户批准（分两节确认）

## 背景

`flutter_blue_plus` 引入了二进制协议通道（`flutter_blue_plus/binary`，BasicMessageChannel + BinaryCodec），
用于低延迟 BLE 写入（writeCharacteristic / writeDescriptor / setNotifyValue），绕过 MethodChannel
序列化与事件流过滤开销。当前状态：

- **iOS / Android**：已完整实现（handler 由插件类持有，pendingReplies + 原生回调消费回包），优化生效
- **Linux / Web**：有未接线的占位 handler（解析请求后直接返回成功，**不执行写入**）；
  一旦被接线会静默吞写，比 fallback 更危险
- **OHOS**：仅常量占位；原有 TODO 注释称 SDK 不支持 `setMessageHandler`——经查 OpenHarmony
  官方文档，`BasicMessageChannel.setMessageHandler` 可用，该假设过时

目标：三平台实现真实的二进制写入处理，与 iOS/Android 对齐。

## 目标平台现状（关键事实）

| 平台 | 写入 API | 可 await | 现有 handler | 事件发射 |
|---|---|---|---|---|
| Linux | `characteristic.writeValue(value, type: request/command)`（BlueZ dart:ffi） | ✅ | 骨架（解析完备，无执行） | `_onCharacteristicWrittenController.add` |
| Web | `writeValueWithResponse` / `writeValueWithoutResponse`（Promise → toDart） | ✅ | 骨架（仅解析 cmd） | `_onCharacteristicWrittenController.add` |
| OHOS | `gatt.writeCharacteristicValue(characteristic, writeType)` | ✅ | 常量占位 | MethodChannel 内联事件 |

三平台写入 API 均可 await → **不需要 iOS/Android 的 pendingReplies + 回调消费机制**，
handler 内 await 写入完成后直接回包。

## 架构

沿用 iOS/Android 既有模式：**插件类持有并注册 binary handler，handler 访问插件内部状态与方法**。

### 数据流

```
Dart write() → _BinaryWriteChannel.send(request)   [现有二进制协议，不改]
  → 平台 binary handler：解析 → 校验（设备/特征/属性/payload）→ await 写入
  → 回包（encodeSuccess / encodeError）
  → Dart 解码：成功即返回；失败抛 FlutterBluePlusException（已有 15s 超时保护）
```

事件发射由 handler 复用平台内部 controller，保持用户层 `onCharacteristicWritten` /
`onDescriptorWritten` 监听不中断。

## 各平台实现

### Linux（flutter_blue_plus_linux）

- `LinuxBinaryHandler` 改为实例类，持有 `FlutterBluePlusLinux` 引用；`registerWith()` 接线
- 复用 `writeCharacteristic`（flutter_blue_plus_linux.dart:925）既有逻辑：
  `_client.devices` 查找 → `_findCharacteristic` → `characteristic.writeValue`（withResponse →
  `request` 类型 / withoutResponse → `command`）→ 发事件 → 回包
- 同样实现 `writeDescriptor`（:992）与 `setNotifyValue`（:813，BlueZ CCCD 写入）

### Web（flutter_blue_plus_web）

- `WebBinaryHandler` 实例化并接线（`registerWith` 的 `Registrar` 可拿到 messenger）
- 复用 `writeCharacteristic`（flutter_blue_plus_web.dart:624）既有逻辑：
  `_devices` 查找 → `_findCharacteristicOrThrow` → `writeValueWithResponse` / `writeValueWithoutResponse`
  → 发事件 → 回包
- 同样实现 `writeDescriptor`（:696）与 `setNotifyValue`（:458）

### OHOS（flutter_blue_plus_ohos）

- 补全 `BinaryProtocolHandler.ets`：`new BasicMessageChannel(binding.getBinaryMessenger(),
  "flutter_blue_plus/binary", <binary codec>)` + `setMessageHandler`（官方 API 已确认）
- 复用 `FlutterBluePlusOhosPlugin.ets` 既有逻辑：`mConnectedDevices` 查找 → `getServices` →
  `locateCharacteristic` → 属性/maxPayload 校验 → `gatch.writeCharacteristicValue` → 发事件 → 回包
- `writeDescriptor` 与 `setNotifyValue`（CCCD 写入）同理
- 实现期确认：Dart 侧 `BinaryCodec`（原始字节）在 OHOS `BasicMessageChannel` 的对应承载类型
  （`StandardMessageCodec` + `Uint8Array` 或 binary codec，按 SDK 实际类型调整）

## 错误码对齐（与 iOS/Android 既有约定一致）

| 码 | 语义 | 三平台映射 |
|---|---|---|
| -1 | 协议错误 / 未知命令 | 解析失败、未知 cmd |
| 1 | 设备未连接 | 设备查找失败、`mConnectedDevices` 为 null |
| 2 | 特征未找到 | `_findCharacteristic` / `locateCharacteristic` 失败 |
| 3 | 属性不支持 | write/writeNoResponse 属性缺失、Web `NotSupportedError` |
| 4 | 写入失败 | BlueZ / browser / Gatt 写入异常 |
| 5 | 描述符未找到 | `writeDescriptor` 路径 |
| 6/7 | CCCD 相关 | `setNotifyValue` 路径 |

Dart 端无需改动：`decodeResponse` 已统一解析，失败抛 `FlutterBluePlusException`。

## 事件语义（保持兼容）

三平台二进制路径**仍发射** `onCharacteristicWritten` / `onDescriptorWritten` 事件
（复用平台内既有 controller），与 MethodChannel 路径及 iOS/Android 二进制路径行为一致。

## 验证策略（无实机约束）

1. **Dart 协议层单测**：扩展/补充 `binary_protocol.dart` 编解码测试（错误码映射、空
   primaryServiceUuid、16/32 位 UUID）
2. **静态检查**：`flutter analyze`（三个 Dart 包）
3. **编译级验证**：Linux/Web 可 `flutter build linux` / `flutter build web`（无设备也验证编译）；
   OHOS 无 DevEco 环境则仅代码评审
4. **回归确认**：iOS/Android 现有实现不受影响（`flutter analyze` + 评审）

## 范围外（明确不做）

- 不改 Dart 端 `_BinaryWriteChannel` 与协议格式
- 不改 iOS/Android 实现
- 不做 pendingReplies 机制（三平台用不上）
- 不处理 RX（通知）通道——独立 P1 项
