# FlutterBluePlus BLE 通信性能分析与优化报告

## 1. 报告范围

本报告基于当前仓库 `master`（`cfb950b`）的实际代码和历史提交整理，目标是分析 Flutter 与各平台 BLE 实现之间的通信延时、吞吐和长尾问题。

当前代码已回退此前不完整的二进制传输实现，运行时使用传统的 `MethodChannel` 加平台事件流。仓库中的二进制设计文档和性能分析文档仅作为历史记录，不代表当前实现已启用二进制通道。

本报告覆盖：

- Dart API 到平台 BLE API 的调用延时；
- Native BLE 回调到 Dart 业务监听器的接收延时；
- 读、写、无响应写、通知和描述符操作；
- Android、Darwin、OHOS、Linux、Web、Windows 的差异；
- 已实现优化、仍存在的瓶颈和后续优化路线。

## 2. 当前通信链路

### 2.1 写入链路

```text
Dart BluetoothCharacteristic.write()
  -> 设备级互斥锁
  -> 构造 BmWriteCharacteristicRequest
  -> 注册 onCharacteristicWritten 过滤流
  -> MethodChannel.invokeMethod()
  -> Native 解析 Map
  -> 查找设备、Service、Characteristic
  -> 调用平台 BLE 写入 API
  -> BLE 系统协议栈和无线传输
  -> Native onCharacteristicWrite / didWriteValueForCharacteristic
  -> 构造写入完成事件 Map
  -> MethodChannel 发送 OnCharacteristicWritten
  -> Dart 多层 Stream 过滤
  -> write() Future 完成
```

### 2.2 通知/读回链路

```text
BLE 数据到达
  -> Native BLE callback
  -> 查找 primary service 和 instance id
  -> 构造完整事件 Map
  -> MethodChannel 发送 OnCharacteristicReceived
  -> Dart platform controller
  -> BluetoothCharacteristic 相关 Stream
  -> lastValue / onValueReceived / 业务监听器
```

当前通知路径没有独立的二进制接收通道。高频通知场景下，Native 对象构造、字符串转换、消息编码和 Dart 事件分发是重点关注对象。

## 3. 之前已经落地的优化

### 3.1 设备级并行队列

相关提交：`7343eba`、`e3b9d3e`

- 引入 `OperationQueueMode`；
- 默认模式改为 `perDevice`；
- 移除 `_invokePlatform` 的全局互斥锁；
- 同一设备内的读写操作仍然串行；
- 不同设备可以并发调用平台 API。

当前实现位于 [flutter_blue_plus.dart](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus/lib/src/flutter_blue_plus.dart)。

这项优化对多设备场景收益明显，但不能保证平台 BLE 栈允许任意并发。需要分别验证 Android GATT、CoreBluetooth、OHOS BLE API 的并发能力。

### 3.2 缓存响应 Stream

相关提交：`0960565`

`BluetoothCharacteristic` 和 `BluetoothDescriptor` 缓存已经过滤过的响应 Stream，避免每次 `read()`、`write()`、`setNotifyValue()` 重新创建多层 `.where()` 闭包。

这项优化减少了调用期间的短生命周期对象，但每条事件仍然要经过多层过滤，不能消除事件匹配的线性成本。

### 3.3 避免重复复制 `Uint8List`

相关提交：`0960565`

在 `BmWriteCharacteristicRequest` 和 `BmWriteDescriptorRequest` 中，如果输入已经是 `Uint8List`，直接复用该对象，否则才转换。它减少了 Dart 侧一次 value 拷贝，尤其适用于大 payload。

需要保证调用方在消息发送期间不会修改传入的 `Uint8List`。

### 3.4 Android 十六进制转换优化

相关提交：`b3fb846`

- 预分配 `StringBuilder` 容量；
- 使用 `Character.forDigit` 替代 `String.format`。

该优化主要影响扫描数据、PIN 和日志路径，不是连接后读写延时的主要来源。

### 3.5 Stream 初始值包装优化

相关提交：`22d7e4a`

重写 `newStreamWithInitialValue`，减少不必要的 `asBroadcastStream()` 包装，并在有监听者时才订阅底层 Stream。主要收益是降低长期订阅、取消订阅和事件转发的开销。

### 3.6 扫描结果降频和提前过滤

相关提交：`b7c348d`、`e0cd99c`、`9ce5cc4`

- `continuousUpdates` 默认关闭；
- 增加 `continuousDivisor`，按比例降低扫描结果上送频率；
- Android 对 `withKeywords` 提前过滤无名称设备；
- 广告数据内部 Map 只保存实际存在的字段。

这些优化主要针对扫描阶段，不直接降低连接后 BLE 读写延时。

### 3.7 超时参数统一为 `Duration`

相关提交：`e118a5f`

连接、发现服务、RSSI、MTU、绑定和读写 API 的超时统一改为 `Duration`。这项改动主要改善超时控制精度和 API 一致性，不会直接降低正常路径耗时，但可以减少不必要的长时间阻塞。

## 4. 之前二进制方案的结论

之前的二进制实现曾覆盖 Dart、Android、Darwin、Linux、Web 和 OHOS，并尝试绕过 StandardMessageCodec 和部分事件流开销。

该方案最终通过 `2b18c3c` 和 `cfb950b` 回退，原因不是二进制传输方向错误，而是实现中存在以下架构问题：

- 二进制路径侵入原有 `write()`、`setNotifyValue()` 和 `writeDescriptor()`；
- 完成 reply 与旧事件流的语义没有完全统一；
- Native 和 Dart 两侧的错误、超时、断连和 UUID key 处理复杂；
- RX 二进制通道和 TX 二进制通道没有形成完整、可选、可回退的数据面；
- 多个平台的线程模型和二进制消息类型不一致。

因此，二进制通道应视为后续可选架构，而不是当前已生效优化。

## 5. 当前主要性能瓶颈

### P0：缺少端到端分段测量

目前没有稳定的统一基准来区分以下时间：

```text
锁等待
MethodChannel 发送
Native handler 执行
BLE 系统调用
无线传输
Native callback
主线程排队
Dart 事件分发
业务监听器执行
```

在没有这些数据之前，直接改协议、改线程或改 Stream 都可能优化错位置。

### P1：通知接收路径的消息和对象开销

Android `onCharacteristicReceived` 和 Darwin `didUpdateValueForCharacteristic` 每次都需要：

- 计算设备 ID 和多个 UUID 字符串；
- 查找 primary service；
- 计算 instance ID；
- 创建完整 Map/NSDictionary；
- 封装 value；
- 通过 MethodChannel 发送事件；
- 在 Dart 侧经过多层 Stream 和对象转换。

高频通知时，这条路径很可能是当前最大软件瓶颈。

### P1：事件匹配仍是多层线性过滤

当前 Stream 缓存只避免过滤器重复创建，但事件到达后仍然执行：

```text
remoteId
primaryServiceUuid
serviceUuid
characteristicUuid
instanceId
```

当监听器、设备或通知频率增加时，匹配成本会增加。更高效的方式是使用预计算 key 或直接订阅者索引。

### P1：写入完成依赖第二条事件路径

一次写入需要先发起 MethodChannel 调用，再等待 Native 通过 `OnCharacteristicWritten` 事件返回结果。这样会产生：

- 一次请求消息；
- 一次完成事件消息；
- Native 侧保存待写入 value；
- Native 侧构造完整写入事件；
- Dart 侧事件过滤和 Future 完成。

这对低频写入影响有限，但在高频写入和 `writeWithoutResponse` 场景下会明显增加开销。

### P1：平台侧重复查找 GATT 对象

Android、Darwin、OHOS 每次读写通常都需要根据 UUID 查找 Service、Characteristic 和 Descriptor，并重新计算 instance ID。

如果服务结构不变，可以在服务发现完成后建立：

```text
(remoteId, serviceUuid, characteristicUuid, instanceId)
    -> native characteristic handle/object
```

断连、服务重置和重新发现服务时清理缓存。

### P1：主线程调度和 UI 忙时的长尾

Android BLE 回调来自 Binder/GATT 线程，而事件发送通常需要切换到 Flutter/UI 线程。iOS 当前 CoreBluetooth 队列也需要确认是否与主线程绑定。

需要关注的不是平均值，而是 P95/P99：

- Native callback 到任务入队；
- 任务入队到实际执行；
- 实际执行到 Dart handler；
- Flutter UI 忙时的排队情况。

### P2：UUID 和 Guid 重复计算

当前 `Guid.str`、`Guid.str128` 每次访问会重新计算字符串。理论上可以缓存，但当前 `Guid.bytes` 是可变 List，直接缓存可能造成数据不一致。

正确顺序应是：

1. 让 Guid 内部 bytes 真正不可变；
2. 对外提供不可变视图；
3. 再缓存 `str`、`str128` 和 `hashCode`。

### P2：Native 到 Dart 的 value 拷贝

Dart 侧已经减少了一次请求方向的 value 拷贝，但还需要确认 Native callback 到 Dart 的完整路径中是否存在：

- `byte[]` 到消息对象的复制；
- `NSData` 到 Flutter 消息的复制；
- `ArrayBuffer` 到 Dart `Uint8List` 的复制；
- `lastValue` 保存时的再次复制。

### P2：日志和字符串拼接

通知、读、写回调中的日志参数可能在日志级别判断之前就已经完成字符串拼接。应分别比较 `none`、`debug`、`verbose` 三种模式。

## 6. 建议的测量方案

2026-09-15 已完成独立 OHOS 宿主的真机模拟通信基准，结果见
[OHOS 真机测量报告](PERF_OHOS_DEVICE_RESULTS.md)。共 144 组测试，63,000 次 echo 和
24,840 个事件；结论仅覆盖报告列出的实测路径，以下完整 BLE 分段方案仍需外设验证。

同日追加了静态 UI、独立进程、无时延样本累积的 [内存分层实测](PERF_OHOS_MEMORY_RESULTS.md)。
244 B 通信组出现自然恢复，Dart GC 后已用堆接近空闲组；4096 B 字节数组仍有明显原生已分配增量。
首轮大幅 PSS 增长的根因尚未确定，不能直接判定为插件泄漏或据此重做传输协议。
追加六轮、每组 21,000 次大字节数组回环的配对实验后，关闭/开启周期 VM 采样仍分别有
约 107.26/107.88 MiB 原生已分配增量。周期采样不是该增长的必要条件；后续 nativehook 与 ArkTS 堆快照已将关键 7,000 个消息 buffer 定位到 Engine/N-API local handle，详见 [OHOS 原生分配归因结果](PERF_OHOS_NATIVE_ALLOCATION_RESULTS.md)。

### 6.1 统一操作 ID

为每次读、写、通知和描述符操作生成唯一 ID，并记录单调时钟，不使用墙上时间进行耗时计算。

### 6.2 写入时间点

```text
T0 Dart API 进入
T1 设备锁获取
T2 invokeMethod 发出
T3 Native handler 收到
T4 BLE API 调用返回
T5 Native BLE callback
T6 Native 事件发送
T7 Dart platform handler 收到
T8 业务监听器收到
```

对应指标：

```text
锁等待       = T1 - T0
通道传输     = T3 - T2
Native 处理  = T4 - T3
BLE 等待     = T5 - T4
Native hop   = T6 - T5
Dart 分发    = T8 - T7
端到端       = T8 - T0
```

### 6.3 通知时间点

通知通常无法直接获得无线包到达时间，因此至少记录：

```text
T5 Native callback
T6 Native 发出事件
T7 Dart 收到事件
T8 业务监听器收到
```

### 6.4 测试矩阵

| 维度 | 测试值 |
|---|---|
| 写类型 | with response / without response |
| 操作 | read / write / descriptor / notify |
| 通知频率 | 10 / 50 / 100 / 200 Hz |
| payload | 1 / 20 / 100 / 244 / 512 bytes |
| MTU | 23 / 100 / 247 |
| 并发设备 | 1 / 2 / 4 |
| 并发特征 | 1 / 2 / 4 |
| 日志 | none / debug / verbose |
| 构建模式 | profile / release |
| UI 状态 | 空闲 / 高负载 |

每组至少统计平均值、P50、P95、P99、最大值、超时、丢包、吞吐、CPU 和内存。

## 7. 优化路线

2026-09-15 新增 [公共 Dart 过滤链 A/B 验证](PERF_DART_FILTER_AB_RESULTS.md)：覆盖 Android、iOS/Darwin、OHOS 共用路径的候选原型，在 macOS Dart AOT 下三次独立复测得到正向中位收益，三端 Dart 接收适配器与公开接口的 33 项行为测试通过。

后续 [OHOS 真机过滤链 A/B](PERF_OHOS_FILTER_AB_RESULTS.md) 已完成 3 个独立进程、96 次场景运行、38,400 条正式模拟事件。Dart 分发 P95 配对中位改善 9.22%–13.37%；64 个监听器、instanceId 不匹配的 12 对全部改善。但 RTT 改善不稳定，首字段不匹配场景存在进程级回退；目标 200 Hz 实际仅约 140–166 Hz，混合 A/B 内存端点不能证明候选无内存回退。该测量阶段候选只保留在 example，未修改生产 getter。

同日完成 [OHOS 50/100 Hz 及监听顺序复测](PERF_OHOS_FILTER_LOW_RATE_RESULTS.md)：3 个独立进程、240 次场景运行、48,000 条正式事件，完整性校验全部通过。十个条件的 Dart 分发 P95 配对中位改善为 6.47%–18.04%，后段不匹配、目标末位在两个频率下均为 12/12 对改善。但 100 Hz 单监听 RTT 的进程中位数三次均回退约 0.57%–4.31%，四个条件的汇总 Dart P99 变差。实际频率仍低于目标，120 对中没有一对两组均达到目标 ±5%；不能据此宣称稳定到达率对照或无性能回退。测量结束时暂未修改生产 getter。

随后经评审并获用户明确授权，第一批将 **`BluetoothCharacteristic.onValueReceived` 六层 `.where()` 合并为一层短路谓词**，按公共 Dart 分发的局部优化落地。保留判断顺序、匹配字段和 value 引用。修改后的真实生产 getter 与保留的旧六层基线通过三端 Dart 通道 33 项行为测试；独立 Stream 工具的源码校验和语义检查共 81 项通过。详细验证环境及限制见 [落地记录](PERF_DART_FILTER_AB_RESULTS.md#10-生产落地记录)。

用户随后授权第二批三处优化：特征 `lastValueStream` 六层过滤合并为一层，`read()`/`write()` 响应流各五层合并为一层。读写流保留失败响应，继续使用现有缓存流、先监听后调用平台及设备锁。新增三端 33 项测试先在原实现通过，修改后与已有用例合计 **66 项回归全部通过**，覆盖非空初值、订阅前缓冲、字段区分、原生错误、缓存流复用和读写串行。详见 [第二批落地记录](PERF_DART_FILTER_AB_RESULTS.md#11-第二批lastvaluestream-与读写响应过滤)。该批没有新增手机性能数字，也未修改原生实现。

落地不表示上述 RTT、P99、稳定到达率或独立内存门槛已经通过，不新增整体 BLE 延迟收益声明，也不将实测回退直接归因于 Engine。现有手机性能数据保留为落地前候选证据，本次没有重新进行手机性能测量。

当前仍需分变体长时验证、到达率及 RTT 测量方法复核，以及 Android/iOS 原生通道 A/B。OHOS 数据不能替代三端手机数据，更不代表 BLE 无线或 GATT 延迟。以下路线均须先通过行为、收益及回退验证，不能将静态候选直接当作已实现优化。

### 阶段一：测量和低风险优化

1. 增加可关闭的性能埋点；
2. 分离锁等待、通道、BLE 和 Dart 分发耗时；
3. 确认并减少日志参数构造；
4. 完善 Guid 的不可变性后增加字符串缓存；
5. 检查 Native 和 Dart 两侧的 value 拷贝；
6. 复用平台侧稳定的 UUID、设备和 characteristic 信息。

验收目标：不改变公开 API 和事件语义，P95 延时不回退，内存分配量下降。

### 阶段二：事件分发优化

1. 为事件构造预计算匹配 key；
2. 评估从多层 `.where()` 改为 key 索引；
3. 保持全局事件流兼容，同时让内部等待 Future 走 O(1) 路由；
4. 对通知事件和写入完成事件分别优化，避免互相影响。

验收目标：监听器数量增加时，单条通知的分发耗时不再线性增长。

### 阶段三：Native handle 缓存

在服务发现完成后缓存 Native 对象或稳定句柄，读写时不再重复遍历服务树。必须处理：

- 断连清理；
- 服务重置；
- 重连后的对象失效；
- iOS CBPeripheral 和 Android BluetoothGatt 生命周期。

验收目标：服务数量增加时，查找耗时保持近似常数；所有平台行为和错误码保持一致。

### 阶段四：重新评估数据通道

只有在阶段一到三完成并证明 MethodChannel/事件流占据主要耗时后，才考虑重新引入二进制通道。

推荐设计：

- TX 使用独立的可选 API，不侵入现有 `write()`；
- RX 使用独立的可选通道，不改变默认事件流；
- 使用 request ID 或稳定 handle，避免字符串 key；
- 保留旧路径作为回退；
- 明确 `writeWithoutResponse` 的“已提交”和“已发送”语义；
- 先完成 Android 和 Darwin，再扩展 OHOS、Linux、Web、Windows。

验收目标：在相同设备、MTU、payload 和构建模式下，端到端 P95 延时和 CPU/内存开销都优于 MethodChannel 基线，同时不丢事件、不丢包、不改变错误语义。

## 8. 风险和约束

### BLE 物理和系统限制

Connection Interval、外设处理时间、MTU、系统协议栈调度和无线重传决定了延时下限。软件优化不能突破这些限制。

### 并发风险

设备级并行只表示 Flutter 层不再全局串行。平台 GATT 对象、CoreBluetooth 对象和 OHOS BLE 对象仍可能要求更严格的串行访问。

### 事件兼容性

任何减少 `OnCharacteristicWritten`、`OnDescriptorWritten` 或 `OnCharacteristicReceived` 的改动，都可能影响用户监听器、`lastValue` 和内部 Future。必须先验证事件语义，再减少事件。

### 缓存失效

Native handle、UUID 字符串和 Stream 缓存都必须定义生命周期。断连、服务重置、Hot Restart 和插件重新注册是重点场景。

## 9. 最终结论

之前的优化总体合理，已经解决了明显的全局串行、重复 Stream 创建、Dart value 复制和扫描事件过量问题。

当前最值得继续分析的不是扫描，而是连接后的数据路径：

1. Native callback 到 Dart listener 的 MethodChannel 和对象开销；
2. 多层 Stream 过滤和事件匹配；
3. 每次操作重复查找 GATT 对象；
4. Android/iOS 主线程调度造成的长尾；
5. `writeWithoutResponse` 的背压和完成语义。

建议先完成分段基准和 P95/P99 数据，再决定采用事件索引、Native handle 缓存、直连 reply，还是重新设计可选二进制数据通道。OHOS Engine/N-API local handle 保留问题已记录为外部运行时风险，本插件当前不跟进 Engine 修复，也不以重做二进制传输作为默认修复。
