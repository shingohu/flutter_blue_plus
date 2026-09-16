# 公共 Dart 过滤链 A/B 验证

日期：2026-09-15。适用分析范围为 Android、iOS/Darwin、OHOS 共用的 Dart 特征事件过滤路径。

**最新状态：已按用户授权合并特征的 `onValueReceived`、`lastValueStream`、`read()` 和 `write()` 响应流过滤。** 第一批落地见第 10 节；第二批新增三处通过修改前后行为回归，完整测试合计 66 项，见第 11 节。第 1–9 节保留此前实验及当时决策，手机数据未重测或改写；整体通信延迟及内存风险仍未因此验收通过。

## 1. 决策

**合并过滤条件的原型具有可重复的本机性能收益，但尚不合入生产库。** 本轮只增加独立验证工具和结果，没有更改生产 getter、原生插件、设备队列或通道协议。没有把本机结果视为三端手机实测。

同日后续已完成 [OHOS 真机过滤链 A/B](PERF_OHOS_FILTER_AB_RESULTS.md)：3 个独立进程、38,400 条正式模拟事件，Dart 分发 P95 配对中位改善 9.22%–13.37%，但 RTT、首字段不匹配及内存证据尚不足以通过生产验收。下文第 4 节保留原本机 AOT 口径，不与手机结果混算。

再完成 [OHOS 50/100 Hz 及监听顺序复测](PERF_OHOS_FILTER_LOW_RATE_RESULTS.md)：48,000 条正式事件校验通过，Dart P95 配对中位改善 6.47%–18.04%；100 Hz 单监听 RTT 三个进程中位数均回退，部分 Dart P99 也变差，实际到达率仍未满足预设目标。候选继续保留在 example，未通过生产变更验收；不同频率与注册位置的数据独立统计。

候选范围仅为 `BluetoothCharacteristic.onValueReceived`：将 6 层 `.where()` 合并为按原顺序短路求值的一层 `.where()`，保留 `.map((c) => c.value)`。它减少 Stream 包装层，但仍对各订阅者执行匹配，并未实现按特征索引分发。不得把此次收益外推到尚未测试的 read/write 响应流、描述符或 `lastValueStream`。

## 2. 验证门槛

后续生产变更必须同时满足以下条件；本轮微基准结果只满足其中的原型筛选部分：

1. **行为一致**：匹配字段、重复 UUID/实例、主服务、事件顺序、payload 引用、成功/失败过滤、源错误及 stack、广播订阅、暂停/恢复、取消与重新订阅均有测试。公开 getter 集成后的结果必须与原型一致。
2. **收益可重复**：同设备、SDK、构建模式和工作量，预热后交替 A/B 顺序，使用多个独立进程。分别报告中位数和尾部，不仅挑选最快结果。三端结论分别标记，不能用 OHOS 数据代替 Android/iOS。
3. **无已知回退**：目标场景的耗时改善必须高于重复测量噪声；单监听、早期不匹配、空闲和长时运行不得出现可重复的延时或内存回退。孤立慢样本不自动判定代码回退，也不得删除后声称“没有回退”。
4. **控制范围**：一次只引入一个生产候选，不同时调整协议、锁、背压、缓存和线程。未经验证的改动留在原型中，不把“理论上更快”作为合入依据。

这些是后续验收要求，不是宣称本轮已通过完整验收，也不保证所有运行环境绝无副作用。

## 3. 方法

- macOS arm64 本机执行，使用 OHOS Flutter SDK 自带 Dart 3.11.5 编译为 AOT 可执行文件；未经过手机 Engine、MethodChannel 或 BLE。
- 使用仓库真实 `BmCharacteristicData`、`Guid`、`DeviceIdentifier` 类型，不以整数或简化字符串代替 UUID 比较。
- 工具读取生产 `onValueReceived` 源码，检查基线 6 条过滤条件顺序和 value 映射仍一致，防止无意对比过时基线。两条执行管线仍是独立工具内的原型，不是直接调用生产 getter。
- 监听数 1/16/64；每组均有一个目标监听器。其他监听器分别在 remoteId 处不匹配、instanceId 处不匹配，或全部匹配。监听数为 1 时三种场景实际都只有一个匹配监听者，不能当作不同覆盖。
- 每条件先预热两对（每次 512 个事件），再执行 10 对 A/B（每次 1,024 个事件）。偶数轮先基线，奇数轮先候选。3 个独立进程顺序执行，不并发竞争 CPU。
- 每批 128 个事件后等待异步队列排空；计时包括队列调度、过滤和接收端序号校验。消息构造、订阅建立、取消/关闭均在 wall 计时之外；订阅建立耗时另存为 `setup_us`，未用其宣称收益。
- 正式结果共 540 次管线运行、552,960 个源事件；多播后的接收次数可能更高。所有运行检查每个监听者的事件数和每条接收流的顺序。
- 表中为各进程内 10 对 `1 - fused_wall / baseline_wall` 的中位数，再列三个进程的范围；不是两个中位数相除，不是单事件 P95，也不是端到端通信延时。

## 4. 测量结果

| 监听者数 | 场景 | 三次进程的配对中位耗时下降 | 改善配对数 / 30 |
|---:|---|---:|---:|
| 1 | early_miss（实际全匹配） | 23.44%–27.84% | 25 |
| 1 | late_miss（实际全匹配） | 22.18%–26.89% | 24 |
| 1 | all_match | 25.78%–26.20% | 29 |
| 16 | 首字段不匹配 | 18.16%–20.40% | 28 |
| 16 | 实例 ID 不匹配 | 27.49%–29.34% | 28 |
| 16 | 全部匹配 | 24.70%–26.27% | 29 |
| 64 | 首字段不匹配 | 12.22%–16.90% | 27 |
| 64 | 实例 ID 不匹配 | 26.91%–27.87% | 29 |
| 64 | 全部匹配 | 26.18%–27.10% | 29 |

单监听器每组仅约毫秒级，容易受调度噪声影响。最差一对候选/基线耗时比为 2.47；多监听条件也有孤立回退，不能承诺每次更快。未采集完整单事件尾延时、CPU、分配率或长时内存，不根据 wall 时间推断它们已改善。

## 5. 正确性结果

每个进程执行同一套 81 项检查，全部通过。组合包括基线/候选、同步/异步广播源、primaryServiceUuid 为 null/非 null：

- 逐字段不匹配、实例 ID 区分、失败响应过滤、16/128-bit 等价服务 UUID；
- payload 对象 identity 保持，不引入复制；
- 源 error 和 StackTrace 转发；
- 多监听者、独立暂停与恢复、缓冲事件顺序；
- 取消、关闭、cancelOnError、取消后不重放旧事件、重新订阅。

这不是完整插件回归测试。此轮原型测试当时尚未覆盖真实 GATT 回调、断连竞态、服务重发现、公开 `lastValueStream` 初始值、用户自定义异常监听行为或跨平台插件注册切换。后续补充的公开接口与平台 Dart handler 测试见第 9 节，不能将两轮验证范围混为一谈。

## 6. 三端工作边界

| 层/平台 | 候选及主要风险 | 当前处理 |
|---|---|---|
| 三端公共 Dart | 合并过滤；之后再评估事件索引。索引增加订阅/缓存生命周期复杂性，不能丢失全部特征事件观察者 | 本轮只测合并原型，未修改生产库 |
| Android | 特征查找与实例元数据缓存；复用 UI Handler 可减少包装分配，但不能据此声称消除主线程等待 | 仅静态候选，待 Android 模拟回调及实机验证 |
| iOS/Darwin | 特征及主服务元数据缓存、循环外 UUID 转换；保留 CoreBluetooth 队列和 withoutResponse readiness 语义 | 仅静态候选，未改变原生代码 |
| OHOS | 通知需先可靠绑定来源设备，不能用跨设备 UUID 首次命中索引；服务缓存需验证断连/重发现失效 | 不实施未经验证的索引或并发更改 |

任何原生索引都必须保留设备、主服务、服务、特征、实例身份，以及三端现有的实例编号规则；不得只用两个 UUID。`Guid.bytes` 在当前 API 中暴露可变列表，新增 UUID 缓存还需考虑输入可变性，不能未经论证永久缓存转换值。

OHOS Engine/N-API 问题继续作为外部风险保留，不阻塞插件优化，也不继续进行 Engine 修复。`new Uint8Array(ArrayBuffer)` 创建视图，不等于复制 payload；codec 的实际复制需分层测量。

## 7. 环境与剩余验证

本机 AOT 验证阶段，`devecocli device list` 确认 Mate 60 Pro 在线，OHOS Flutter `--version` 正常。按 `hmos-arkts-syntax-checker` 构建技能要求检查工具后，当时没有所需 CodeGenie ETS 检查/构建 MCP，因此该阶段未构建 OHOS HAP。后续用户明确允许跳过此前置检查，现已使用 OHOS Flutter SDK 完成三次手机 A/B，详见独立手机报告。未安装工具或修改 MCP 配置。

本机 AOT 阶段系统 `git` 曾返回 Xcode license 未接受；后续手机测量阶段 `git` 已可正常使用。未代为接受协议，本轮仍未完成 Apple 构建验证。Dart AOT 编译、独立原型检查和测量不依赖该步骤，已实际执行；没有把技能工具缺失误写成 OHOS SDK 不可用。

公开 getter 的三端 Dart 行为集成与 OHOS 模拟事件真机 A/B 已补齐。剩余重点为稳定实际到达率、回退样本复核及分变体长时内存；Android/iOS 分别补原生模拟回调宿主与本机/真机基准。缺少外设的 GATT、无线链路项目继续跳过，并如实保留未验证状态。

## 8. 文件与复现

- [独立验证工具](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus/example/tool/stream_filter_ab.dart)
- [三次原始结果](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus/example/perf_results/2026-09-15-stream-filter-ab/)
- [既有 OHOS 通道基准](/Users/shingo/develop/hujie/flutter_blue_plus/PERF_OHOS_DEVICE_RESULTS.md)

在 `packages/flutter_blue_plus/example` 目录运行。输出文件必须不存在，工具拒绝覆盖：

```sh
/Users/shingo/develop/SDK/ohos_flutter/bin/cache/dart-sdk/bin/dart analyze tool/stream_filter_ab.dart
/Users/shingo/develop/SDK/ohos_flutter/bin/cache/dart-sdk/bin/dart compile exe tool/stream_filter_ab.dart -o /tmp/fbp_stream_filter_ab
/tmp/fbp_stream_filter_ab /tmp/fbp_stream_filter_new1.json
/tmp/fbp_stream_filter_ab /tmp/fbp_stream_filter_new2.json
/tmp/fbp_stream_filter_ab /tmp/fbp_stream_filter_new3.json
```

`dart analyze` 已通过，无诊断项。报告中的三个原始结果是实际本机运行数据，不是合成性能数字；合成事件仅用于驱动和验证真实 Dart 执行路径。

## 9. 三端 Dart 通道集成验证

同日继续验证：使用 OHOS Flutter SDK 的本机 Flutter test 运行器，通过 `StandardMethodCodec` 编码消息并注入 Flutter `channelBuffers`，分别运行真实 `FlutterBluePlusAndroid`、`FlutterBluePlusDarwin`、`FlutterBluePlusOhos` 的 Dart 接收 handler 和 `BmCharacteristicData.fromMap`。

基线直接订阅生产 `BluetoothCharacteristic.onValueReceived`；候选最初是测试文件内的子类，后移到 example 的 `benchmark/fused_characteristic.dart`，供测试和手机 A/B 共用；仅覆盖该 getter，将过滤条件合并。共享候选再次通过全部 33 项测试与静态分析。生产 getter 和原生实现均未改动。本节测试仅模拟 native 到 Dart 的消息入口及初始化的 `setLogLevel` 回执，没有运行 Java、Objective-C、ArkTS 或真实 GATT。

### 9.1 结果

三端各 11 项，共 **33 项集成测试通过**；静态分析无问题。机器可读记录复核为 33 个非隐藏测试成功、0 个 error 事件、最终 success=true。

| 检查 | 已验证行为 |
|---|---|
| 主服务 null/非 null、逐字段不匹配 | 设备、主服务、服务、特征、instanceId 和 success 过滤一致 |
| UUID 表示与 payload | 短/完整 UUID 匹配，解码后为 Uint8List，两条管线保持与原始事件相同的 value 对象引用 |
| 64 个重复实例订阅/每种管线 | 各实例仅收到自己的事件，全局公开观察者仍收到全部事件，包括失败和非目标设备事件 |
| 暂停、恢复、取消、重新订阅 | 暂停不阻塞其他订阅者；恢复有序；取消后不再收到事件；重新订阅不重放旧事件 |
| `lastValueStream` 并存 | 空缓存初始值正常；written 进入 lastValueStream 而不进入 onValueReceived；失败事件不进入二者 |
| 平台实例替换 | 已取得的流仍绑定旧 adapter；再次访问 getter 使用新 adapter，没有新增跨实例缓存 |
| 有界突发/订阅变化 | 每端 4,096 个事件，每批最多 32 个入口请求；32 个常驻监听者与临时订阅并存，未发现乱序、缺失或误投递 |
| 非法消息恢复 | 非法 value 类型返回错误 envelope，不发出 value；后续有效消息仍被两条管线正确接收 |

突发场景合计注入 12,288 个事件，不包含其他用例的事件数。临时订阅每批创建并取消，共每端 128 次；这里只验证事件行为，不把有限轮次当作内存无泄漏证据。`lastValueStream` 测试未验证全局初始化后非空 lastValue 缓存、断连清空或重发现流程。

### 9.2 环境处理与限制

首次 `--no-pub` 测试因仓库生成的 package_config 指向 Flutter 3.47、运行器却为 OHOS Flutter 3.41 而无法编译，错误涉及 `dart:ui` 新类型。这是 SDK/依赖错配，不是过滤候选失败。备份现有依赖文件后，执行 OHOS Flutter `pub get --offline` 对齐 SDK，再完成上述测试。

测试结束已还原该 package 的原始 pubspec.lock、package_config.json、package_graph.json，避免把临时解析的 6 项传递依赖变更混入优化；实际测试使用的 lock 文件随结果保留。没有修改 pubspec.yaml、接受 Xcode 协议或接入新的 MCP 配置。

本节补齐的是三端 **Dart 接收适配器与公开接口的行为对照**，不产生性能收益百分比。第 4 节的收益仍只属于本机 AOT 微基准。OHOS HAP 曾因 `hmos-arkts-syntax-checker` 要求的 CodeGenie 工具缺失而暂停，该限制不是 Flutter test 的阻塞条件；用户随后授权跳过此前置检查，已完成独立手机报告中的真实通道 A/B。Android/iOS 原生通道 A/B 仍未完成。

### 9.3 文件与复现

- [三端通道测试](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus/test/characteristic_filter_channel_test.dart)
- [机器可读测试结果](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus/example/perf_results/2026-09-15-channel-filter-tests/test-results.jsonl)
- [实际测试依赖锁定记录](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus/example/perf_results/2026-09-15-channel-filter-tests/tested-pubspec.lock)

在 `packages/flutter_blue_plus` 目录使用同一 SDK 解析和执行，不能把另一版本 SDK 的 package_config 与 `--no-pub` 混用。`pub get` 会调整生成依赖文件；工作区需要保留其他 SDK 配置时应先备份，并在测试后恢复。

```sh
/Users/shingo/develop/SDK/ohos_flutter/bin/flutter pub get --offline
/Users/shingo/develop/SDK/ohos_flutter/bin/flutter test --no-pub --reporter expanded test/characteristic_filter_channel_test.dart
/Users/shingo/develop/SDK/ohos_flutter/bin/flutter analyze --no-pub test/characteristic_filter_channel_test.dart
```

## 10. 生产落地记录

第一批落地由用户审阅最小 diff 后明确同意。该批生产代码仅修改 `BluetoothCharacteristic.onValueReceived`：将六个 `.where()` 合并为一个 `&&` 短路谓词，顺序仍为 remoteId、primaryServiceUuid、serviceUuid、characteristicUuid、instanceId、success，末尾保留 `.map((c) => c.value)`。该批没有扩展到 `lastValueStream`、读写响应流或原生实现；后续新增三处见第 11 节。

采用理由为公共 Dart 分发路径已有重复收益和行为对照证据；收益声明限定在已测分发路径。落地前手机实验中的 RTT/P99 回退、实际到达率偏差和未完成的独立内存验证继续有效，不视为全链路验收已通过，也不声明三端原生或无线链路都变快。

为保持后续验证有效，example 新增 `BenchmarkLegacyCharacteristic` 保存原六层 getter；三端通道测试和手机基准的 baseline 使用该旧实现，fused 使用真实生产 `BluetoothCharacteristic`。原 `BenchmarkFusedCharacteristic` 文件保留为历史原型，不再作为当前测试或手机基准的比较对象，避免新旧两组都调用优化后 getter。独立 AOT 工具仍保存旧/新两条管线，其源码一致性检查已改为检查生产的合并谓词，并增加 `--verify-only` 入口。

验证结果：

- 33 项三端 Dart 通道行为测试全部通过，涵盖真实 adapter 解码、字段匹配、实例、payload 引用、广播观察者、暂停/取消、平台替换、突发/订阅变化及非法消息恢复。此处测试的优化侧为修改后的生产 getter。
- 独立工具 `--verify-only` 的 81 项源码/Stream 语义检查通过；此次仅检查正确性，没有产生新的性能数字。
- example 手机入口、旧基线与独立工具静态分析通过。
- 生产文件及测试的 Flutter 静态分析返回 1 条警告：`bluetooth_characteristic.dart` 写入方法中原有的 `return Future.value()` 触发 `unawaited_return_in_try_block`。已与 HEAD 对照确认该代码在本次改动前存在，没有修改或隐藏此警告；未发现与本次 getter 改动有关的诊断。

三端行为测试使用根 package 当前依赖配置对应的 Flutter **3.47.3 / Dart 3.13.3**；example 工具使用其现有 OHOS SDK **Dart 3.11.5**。本次没有执行 pub get、切换依赖锁或重建 OHOS/Android/iOS 宿主。这里的 Dart 本机回归不等同于新一轮手机性能测试，原始结果目录保持原样。

复现（前两条在 `packages/flutter_blue_plus`，第三条在其 `example` 目录）：

```sh
/Users/shingo/develop/SDK/flutter_3.47/bin/flutter test --no-pub --reporter expanded test/characteristic_filter_channel_test.dart
/Users/shingo/develop/SDK/flutter_3.47/bin/flutter analyze --no-pub lib/src/bluetooth_characteristic.dart test/characteristic_filter_channel_test.dart
/Users/shingo/develop/SDK/ohos_flutter/bin/cache/dart-sdk/bin/dart tool/stream_filter_ab.dart --verify-only
```

源文件：[生产 getter](packages/flutter_blue_plus/lib/src/bluetooth_characteristic.dart)、[旧六层基线](packages/flutter_blue_plus/example/lib/benchmark/legacy_characteristic.dart)、[三端回归测试](packages/flutter_blue_plus/test/characteristic_filter_channel_test.dart)。

## 11. 第二批：lastValueStream 与读写响应过滤

用户确认按建议扩展到 `BluetoothCharacteristic` 的三处公共 Dart 路径：

| 路径 | 修改 | 保留的关键语义 |
|---|---|---|
| `lastValueStream` | 六层过滤合并为一层 | received/written 合并、字段顺序、success 过滤、value 引用、缓存初值及订阅前缓冲 |
| `read()` 响应流 | 五层身份过滤合并为一层 | 原缓存流及 `.first`，先监听后调用平台，成功和失败响应均可抵达等待者 |
| `write()` 响应流 | 五层身份过滤合并为一层 | 原缓存流及 `.first`，错误码转发、withoutResponse 的既有完成等待和设备级串行 |

读写流没有添加 `success == true` 条件：匹配的失败响应仍须立即进入原有错误处理，不能被过滤成超时。未调整锁、通道、超时、合并流、缓存失效逻辑或原生代码；描述符、CCCD 配置及设备状态的其它候选留待后续。

新增 11 项用例/平台，分别运行真实 Android、Darwin、OHOS Dart adapter、StandardMethodCodec 和公共 API。三端各用独立 Flutter test 文件/isolate，使生产全局初始化订阅绑定正确的 adapter；不增加生产测试钩子，不直接改写私有缓存。设备连接状态和 characteristic 事件从模拟原生消息入口注入，原生方法提交返回由测试控制，不需要 BLE 外设。

用例先在这三处尚未合并的原实现上通过 **33 项**，合并后再与原 `onValueReceived` 通道用例共同运行，**66 项全部通过**。新增覆盖如下：

- primaryServiceUuid 为 null/非 null、非零 instanceId、逐字段不匹配、等价长短 UUID；无关事件或单独的原生提交 ACK 不完成读写。
- 非空 lastValue 初始对象引用；获取 getter 后、订阅前发生的新事件继续缓冲并按序交付；分别获取的流独立暂停/恢复/取消，新 getter 获取当前值，断连后新 getter 的初值为空。
- received/written 均更新 lastValueStream，错误或非目标事件不进入目标流，失败事件不覆盖目标成功缓存。
- read、write withResponse、write withoutResponse 连续复用同一 characteristic：成功 → 原生失败码 133/原消息 → 再次成功；空闲期间的旧响应不被下一次操作重放。
- 响应在原生方法返回前到达仍不丢失；同设备 read 后 write 仍等待匹配响应，失败后锁可继续用于后续操作。

基线阶段曾发现初始测试预期遗漏了 getter 创建后即开始收集事件的既有行为；对照 `_mergeStreams` 后将其固定为回归预期，再完成原实现和新实现的完整对照，没有借此次优化改变该行为。

验证使用当前依赖对应的 Flutter 3.47.3 / Dart 3.13.3，未重新解析依赖。静态分析仅有生产写入路径原有的 `unawaited_return_in_try_block` 警告，没有新增诊断；`git diff --check` 通过。本轮没有新增手机性能测量，不将 `onValueReceived` 的既有收益百分比套用于这三条路径；这里确认的是减少过滤包装层及已覆盖行为的一致性。

测试文件：[共享行为套件](packages/flutter_blue_plus/test/support/characteristic_operations_suite.dart)、[Android 入口](packages/flutter_blue_plus/test/characteristic_operations_android_test.dart)、[Darwin 入口](packages/flutter_blue_plus/test/characteristic_operations_darwin_test.dart)、[OHOS 入口](packages/flutter_blue_plus/test/characteristic_operations_ohos_test.dart)。

在 `packages/flutter_blue_plus` 执行完整回归：

```sh
/Users/shingo/develop/SDK/flutter_3.47/bin/flutter test --no-pub --reporter expanded \
  test/characteristic_filter_channel_test.dart \
  test/characteristic_operations_android_test.dart \
  test/characteristic_operations_darwin_test.dart \
  test/characteristic_operations_ohos_test.dart
```
