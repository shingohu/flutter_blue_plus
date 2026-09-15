# OHOS 真机模拟通信性能测量

日期：2026-09-15。本文补充 `PERF_ANALYSIS_OPTIMIZATION_REPORT.md`，将代码分析中的推测与真机实测分开。测试对象仅为本仓库 `packages/flutter_blue_plus/example`。

## 1. 结果与范围

已在 HUAWEI Mate 60 Pro 上完成 144 组测试，即 48 种条件各重复 3 次。正式样本包含 63,000 次 echo 和 24,840 个模拟事件，全部通过数据校验，未发现丢失、重复、乱序、错误回执或 payload 错误。预热样本不计入以上数量。

本次最值得继续验证的方向是多监听器事件分发、并发排队和内存分配。现有 MethodChannel 内的字节数组传输已经明显优于逐项整数列表；不能据此推导“重做独立二进制通道还能获得同等收益”，因为当前生产写请求已经将 payload 转为 `Uint8List`。

这是无 BLE 外设条件下的真实手机进程测量。模拟的是数据来源，Flutter Engine、MethodChannel、ArkTS、Dart、插件事件解析和特征 Stream 过滤均在真机实际执行。没有改动生产插件的通信实现。

## 2. 环境与统计口径

| 项目 | 实际条件 |
|---|---|
| 设备 | HUAWEI Mate 60 Pro，序列号 23E0224126000860 |
| 系统 | 设备工具返回 OpenHarmony-6.1.1.120，API 24 |
| SDK | Flutter 3.41.10-ohos-1.0.0，framework eb712e92d4，Dart 3.11.5 |
| 应用 | com.jmx.flutter_blue_plus_example，独立 OHOS Flutter 宿主 |
| 构建 | profile，已签名，USB 连接，Flutter 日志/VM 服务连接存在 |
| 时间 | 北京时间 11:35:29 至 11:41:38，约 6 分 9 秒 |
| 页面状态 | 前台测试页，测试期间有不定进度条动画；不是严格的静态空闲 UI |
| echo | 每条件每轮 100 次预热、1,000 次正式调用 |
| 事件 | 全局 raw/plugin 各预热 50 个事件；每条件每轮发送目标频率 × 3 个事件 |
| 顺序 | 第二轮反转 payload 大小及 raw/plugin 测试顺序；非完整随机化实验 |
| 分位数 | 合并同条件三轮原始样本，nearest-rank；不平均各轮 P95/P99 |
| 单位 | 原始 JSON 耗时为微秒，本文主要表格转换为毫秒 |

10 Hz 事件条件每轮只有 30 个样本，合并后为 90 个，因此该条件 P99 接近最大值，不宜作为稳定的尾延迟估计。没有剔除长尾样本，也没有给出未经计算的置信区间。

## 3. 测到了哪些路径

1. **Echo RTT**：Dart `invokeMethod` 前，到 ArkTS 原样回复后 Dart Future 恢复。Dart `Stopwatch` 计时。包含双向编码、Engine 调度、平台处理和 Future 恢复，不是单向跨平台延迟。
2. **Raw 事件 RTT**：ArkTS 在独立测试通道发送带特征字段的 Map，Dart 接收、核验 payload 并返回自动回执。使用 ArkTS `systemDateTime.getUptime(ACTIVE, true)` 在同一侧测起止。
3. **插件事件 RTT**：测试宿主向已有 `flutter_blue_plus/methods` 通道发送 `OnCharacteristicReceived`，经过当前 `FlutterBluePlusOhos` 的真实 handler、`BmCharacteristicData.fromMap` 和现有广播流。记录到自动 handler 回执返回 ArkTS 的往返时间。测试插件不为生产通道安装或替换 handler。
4. **观察者到目标监听器间隔**：先在公开 `FlutterBluePlus.events.onCharacteristicReceived` 观察事件，再记录目标 `BluetoothCharacteristic.onValueReceived` 收到同一序号的时间。两端均在 Dart，用同一 Stopwatch。这是分发路径中两个观察点的间隔，不是从平台入口开始的完整 Dart 分发耗时。

Raw 和插件路径的 Dart handler 工作内容不同，自动回执也不是 BLE ACK。不能直接将两者 P95 相减当作“插件独有开销”，不能将事件 RTT 除以 2 当作单向延迟。上述测试也不能验证 `writeCharacteristic` 的真实 GATT 完成语义。

每个事件的前 4 字节保存序号，其余字节使用确定性模式核验。非目标监听器只在 `instance_id` 上与目标不同，目的是覆盖完整过滤链的较重情况；代表 1/16/64 个特征订阅，不代表真实并发连接了这些设备。

## 4. Echo 与 payload 表示

以下每行均为 3,000 次正式调用，串行执行。

| 参数 | P50 ms | P95 ms | P99 ms |
|---|---:|---:|---:|
| null | 0.151 | 0.307 | 0.633 |
| Uint8List，20 B | 0.143 | 0.269 | 0.660 |
| List<int>，20 B | 0.227 | 0.475 | 0.948 |
| Uint8List，244 B | 0.148 | 0.302 | 0.635 |
| List<int>，244 B | 0.890 | 1.434 | 2.044 |
| 特征字段 Map + Uint8List，244 B | 0.262 | 0.570 | 1.025 |
| Uint8List，512 B | 0.148 | 0.303 | 0.654 |
| List<int>，512 B | 1.691 | 2.469 | 4.741 |
| 特征字段 Map + Uint8List，512 B | 0.235 | 0.477 | 0.870 |
| Uint8List，4096 B | 0.175 | 0.362 | 0.747 |
| List<int>，4096 B | 12.582 | 14.921 | 64.031 |

4096 B 是通道压力测试，超出常规单次 ATT characteristic value 场景，不能作为 BLE 单包性能结论。

244 B 整数列表的 P50 约为字节数组的 6 倍。字节数组在 20–512 B 区间没有表现出相似的线性增长，而 Map 元数据仍有可见成本。这里的 Map 是预先构造的近似特征写请求，不包含真实请求每次建 Map、UUID 转换和查找 GATT 对象的时间；echo 吞吐还包含测试端的回复校验，不是纯通道带宽。

**对已有优化的判断**：`BmWriteCharacteristicRequest.toMap` 与 `BmWriteDescriptorRequest.toMap` 已复用 `Uint8List`，否则执行 `Uint8List.fromList`；OHOS 通知也已使用 `Uint8Array`。这些方向合理，应保留。本测试没有单独对“复用 vs 每次 fromList”做 A/B，不能量化避免该次复制的独立收益。

## 5. 并发与尾延迟

参数为特征字段 Map + 244 B 字节数组。并发表示同时未完成的 MethodChannel echo 数量，不表示并发 GATT 操作数。

| 并发 | P50 ms | P95 ms | P99 ms | 三轮实际完成速率 ops/s |
|---|---:|---:|---:|---|
| 1 | 0.262 | 0.570 | 1.025 | 2,829–3,237 |
| 4 | 0.797 | 1.371 | 1.947 | 4,343–4,607 |
| 16 | 2.992 | 3.883 | 11.014 | 4,585–5,256 |

从 4 增加到 16 并发，吞吐增长有限，单次调用和尾延迟明显上升。这支持控制 in-flight 请求数、避免无上限同时调用；不能据此直接把生产 GATT 并发上限设为 4。生产上限仍需结合按设备串行约束和真实回调语义确定。现有设备锁是否应调整，本次尚无直接 A/B 证据。

## 6. 事件与特征过滤

244 B，日志关闭，每条件三轮共 1,800 个事件，目标为 200 Hz：

| 路径 | 回执 RTT P50 ms | P95 ms | P99 ms | 三轮实际发送 Hz |
|---|---:|---:|---:|---|
| Raw Map 事件 | 2.082 | 6.939 | 9.119 | 169.5–171.4 |
| 插件，1 个特征监听器 | 2.282 | 6.974 | 8.143 | 170.1–170.8 |
| 插件，16 个特征监听器 | 2.602 | 7.383 | 9.196 | 155.3–166.1 |
| 插件，64 个特征监听器 | 3.418 | 8.735 | 20.036 | 158.2–159.7 |

对应的 Dart 观察者到目标监听器间隔：

| 特征监听器数 | P50 ms | P95 ms | P99 ms |
|---|---:|---:|---:|
| 1 | 0.052 | 0.090 | 0.176 |
| 16 | 0.436 | 0.621 | 0.831 |
| 64 | 1.388 | 1.818 | 2.421 |

这里额外存在一个用于计时的公开事件观察者，以及插件本身的内部订阅。目标监听器在非目标监听器之后注册，结果体现了当前订阅顺序下的过滤和异步分发成本，不是通用的单次 `.where` 执行耗时。

结果支持将 `(remoteId, primaryServiceUuid, serviceUuid, characteristicUuid, instanceId)` 的事件索引分发列为后续优化重点。仍需通过保持顺序、取消订阅、错误过滤、重复特征及初始值语义的实现做 A/B 验证。本次没有测到缓存 read/write 响应 Stream 的独立收益。

**定时器限制**：目标 10/50/100/200 Hz 对应的真实频率整体约为 9.8–9.9 / 46–48 / 85–88 / 155–174 Hz。以实测 `native_interval_us` 为准。未出现丢事件，只说明已实际发送的事件均送达，不能说明稳定承载了 200 Hz，更不能认为 170 Hz 是 MethodChannel 的吞吐上限。timer 调度、前台动画、回执流量和运行环境均参与结果。

低频事件的 RTT 可高于连续 echo，说明两种工作负载不能互相替代。是否来自 Engine 唤醒、线程调度、功耗策略或 UI 帧，需要进一步分段跟踪；本次不能直接归因。

## 7. 日志、CPU 与内存

244 B、目标 200 Hz、1 个特征监听器：关闭日志的 RTT P50/P95/P99 为 2.282/6.974/8.143 ms，verbose 为 2.650/7.981/9.635 ms。verbose 的 P95 高约 14%，P99 高约 18%。这是包含格式化、输出和已连接日志消费端的观测差异；日志组固定在每轮末尾，存在顺序影响，不是严格随机化因果估计。关闭高频 payload 日志的建议仍合理。

CPU 通过 `hidumper --cpuusage 22522` 定向采样 12 次，设备报告的时间窗口约覆盖第三轮末段 11:40:40–11:41:38。进程 CPU 使用率读数为 **6.50%–8.64%**。保留系统原始百分比，不换算单核占用；这些窗口有重叠，不计算时间加权平均，也不能分摊给每个 3 秒测试条件。此数值包含整个应用及进度动画的消耗，不能当作插件单独 CPU 成本。

每组计时前后调用 `hidebug.getAppNativeMemInfo`，采样操作在测试循环之外：

| 指标 | 首次采样 KB | 最后采样 KB | 采样点最大值 KB |
|---|---:|---:|---:|
| PSS | 115,863 | 589,276 | 591,710 |
| RSS | 207,080 | 683,988 | 686,400 |

PSS 从约 113 MiB 增至 575 MiB，值得优先调查。它是进程物理内存快照，不能视为累计分配量或证明泄漏。测试中保留了原始样本，SDK/ArkTS/Dart 也可能出现堆增长和回收；不同测试顺序、4096 B 整数列表压力、未强制 GC 和仅在组边界采样均限制归因。本次未抓取堆快照或分配调用栈，不能将增长归责给某个生产插件缓存。

后续已完成静态 UI 和独立进程的 [内存分层测量](PERF_OHOS_MEMORY_RESULTS.md)：244 B 条件有明显自然回落，Dart GC 后已用堆接近空闲组；大字节数组条件仍有原生已分配余量。该补充缩小了排查范围，但尚未确定本节 575 MiB 的完整成因。

## 8. 更新后的优化优先级

| 优先级 | 下一项工作 | 本次依据 / 限制 |
|---|---|---|
| P0 | 对同一低负载条件反复运行，静态 UI 下做内存时间序列及 Dart/ArkTS/Native 归因 | PSS 明显增长，但尚无泄漏证据 |
| P1 | 特征事件索引分发原型与同条件 A/B | 1→64 监听器，观察点间隔 P95 0.090→1.818 ms |
| P1 | 检查 in-flight 上限和排队时长 | 16 并发 RTT P99 11.014 ms，吞吐增益有限 |
| P1 | 高频日志默认关闭、按需采样 | verbose 组尾延迟更高 |
| P2 | Map 字段与 UUID 处理、对象分配优化 | Map 有可见成本，但真实 GATT handler/构图尚未分段计时 |
| P2 | Engine 调度跟踪、静态 UI 对照、release 复测、稳定频率事件源 | 低频事件、连续 echo、定时器驱动负载差异明显 |
| 后置 | 新的二进制数据通道、跨线程方案 | 已有 typed bytes 路径较快；没有证据支持立刻重做传输协议 |

## 9. 未测项目

- BLE 空口时延、连接间隔、MTU 协商、无线重传、外设处理、真实读写及通知确认。
- 真实多设备并发、按设备锁等待、GATT 队列、Native GATT 对象查找/缓存和操作关联 ID。
- ArkTS→Dart 单向延迟、完整 T7→T8 分段；没有跨运行时时钟校准，不使用墙上时钟相减。
- release 模式、严格静态 UI、持续过载/突发流量、长期稳定性、内存分配率与 GC 因果跟踪。
- 与未优化版本的 A/B、优化收益百分比的因果证明。

以上项目未产生结果，不填入估算值。

## 10. 文件与复现

- Dart 测试入口：`packages/flutter_blue_plus/example/lib/perf_main.dart`。
- ArkTS 测试桥接：`packages/flutter_blue_plus/example/ohos/entry/src/main/ets/benchmark/PerfBenchmarkPlugin.ets`。
- 原始样本：`packages/flutter_blue_plus/example/perf_results/2026-09-15/profile.json`。
- 三轮汇总：同目录 `summary_profile.json`。
- CPU 原始采样：同目录 `cpu_profile.json`。
- 校验与汇总脚本：`packages/flutter_blue_plus/example/tool/summarize_perf.mjs`。
- CPU 采样脚本：`packages/flutter_blue_plus/example/tool/collect_perf_cpu.mjs`。

在 `packages/flutter_blue_plus/example` 下，使用宿主机环境和 OHOS Flutter SDK 执行：

```sh
/Users/shingo/develop/SDK/ohos_flutter/bin/flutter run -d 23E0224126000860 --profile -t lib/perf_main.dart
```

页面会自动运行；`--dart-define=PERF_AUTORUN=false` 可改为点击 Run 开始。等待 `FBP_PERF_DONE ... cases=144 failure=false`，然后导出当前应用生成的文件。手机上的同名结果在下次运行时会覆盖，需先导出保留。

```sh
/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc -t 23E0224126000860 file recv -b com.jmx.flutter_blue_plus_example /data/storage/el2/base/haps/entry/files/fbp_performance_profile.json perf_results/2026-09-15/profile.json
node tool/summarize_perf.mjs perf_results/2026-09-15/profile.json perf_results/2026-09-15/summary_profile.json
```

重测应换用新的本地结果目录。汇总脚本会检查错误计数、echo 样本数、发送/接收/回执一致性及每条件重复轮数，再计算分位数。普通 `lib/main.dart` 仍为原来的 BLE 示例，不会启动性能测试。
