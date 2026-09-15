# OHOS 真机内存分层测量报告

日期：2026-09-15。本报告接续 [首轮通信实测](PERF_OHOS_DEVICE_RESULTS.md)，调查其 PSS 从约 113 MiB 增至 575 MiB 的现象。只涉及本仓库的独立 Flutter example，不涉及其他业务项目，不修改生产 BLE 通信实现。

第 2–4 节描述原始六组短测；后续独立复现与六轮采样干扰对照见第 7 节，不能将两套不同工作量的数据混合统计。

## 1. 当前结论

- 244 B 回环、原始事件和插件事件的内存峰值均出现自然回落；本轮短测没有证据证明它们发生持续、不可回收的 Dart 对象泄漏。
- 插件事件组自然静置后的 Dart 已用堆约 20.67 MiB，单独执行 Dart GC 探针后降至 5.88 MiB，与空闲组 5.86 MiB 接近。自然静置不等于所有不可达对象都已回收。
- 4096 B 字节数组回环留下了更值得继续跟踪的原生侧增量：静置后分配器报告的已分配量增加约 56.87 MiB，Dart GC 后没有明显下降。不能将它直接归为 Dart 存活对象，也不能仅用“分配器空闲缓存”解释。
- 4096 B 字节数组已用全新进程复现：第二次运行完成 6,867 次操作，PSS 基线 80.21 MiB、峰值 199.32 MiB、自然结束 172.54 MiB，原生已分配增量 56.43 MiB；与第一次的 +56.87 MiB 基本一致。
- 随后的六轮配对实验中，两组各完成 21,000 次大字节数组回环，关闭/开启周期 VM 采样时原生已分配增量分别为 107.26/107.88 MiB。周期 VM 采样不是该增长出现的必要条件；六轮恢复终点尚未显示稳定平台，但仍未取得泄漏持有者证据。
- 4096 元素整数列表完成 3,043 次回环，ArkTS 累计分配增量约 2.52 GiB、GC 次数增量 101；自然结束 PSS 为 283.39 MiB，原生已分配增量 113.02 MiB。大列表是高分配压力条件，但原生增长仍需要持有者/调用栈证据。
- 首轮约 575 MiB 的完整增长原因仍未确定。本轮同时改变了 UI、负载组合、样本保留和进程生命周期，不能把改善归功于其中某个因素，更没有证明二进制通道改造能够解决它。

## 2. 测量方法

设备仍为 HUAWEI Mate 60 Pro，序列号 `23E0224126000860`，设备工具报告 OpenHarmony-6.1.1.120 / API 24。使用已签名 example 宿主和 OHOS Flutter SDK `3.41.10-ohos-1.0.0` / Dart 3.11.5，profile 模式、USB 和 VM 服务保持连接，所有 CLI 在宿主机沙箱外执行。

每个条件启动独立应用进程，不使用热重载或热重启。工作流为：初始化插件并关闭日志，基线 10 秒，执行两轮“负载 20 秒 + 恢复 20 秒”，取消测试订阅及 handler，再静置 20 秒。最后另做一次 Dart GC 探针，绝不混入自然恢复数据。

页面没有持续动画，仅在阶段变化时更新文字。手机只保存累计计数、当前 payload 和有限批次状态，不累计时延数组；事件桥接设置 `retain_samples: false`。主机保存每次采样和结束后的 Dart allocation profile。

| 条件 | 真实执行路径 |
|---|---|
| idle | 同样初始化插件、更新阶段和采样，但无模拟通信负载 |
| echo | Dart → 测试 MethodChannel → ArkTS 原样回复，Map + 244 B Uint8List |
| raw | ArkTS → 测试 MethodChannel → Dart 校验并自动回复，Map + 244 B 字节数组 |
| plugin | ArkTS → 生产事件通道 → 真实插件解析/广播/特征过滤，1 个监听器，244 B |
| echo_large_bytes | 与 echo 相同，payload 改为 4096 B Uint8List |
| echo_large_list | 与 echo 相同，payload 改为含 4096 个字节值的普通整数列表 |

负载目标 200 次/秒，echo 单个 in-flight；事件每批 200 个，前一批全部回执完成才启动下一批。事件负载阶段可能因整批收尾略超 20 秒。4096 B 是编码压力条件，不代表 BLE 单包。

对回环验证整个返回 payload；事件验证长度、序号、逐字节内容以及发送/接收/回执计数。测试事件并非真实 GATT 回调，也没有测外设、空口、MTU 或设备锁。

## 3. 内存结果

单位均为 MiB。基线取 `baseline/0` 的最后一次采样；结束值取 `complete`、尚未执行显式 GC 的样本。峰值只是采样点最大值，不保证抓到瞬时最高值。

| 条件 | PID | 完成次数 | 基线 PSS | 采样峰值 | 自然结束 PSS | 基线至结束增量 |
|---|---:|---:|---:|---:|---:|---:|
| idle | 55743 | 0 | 78.42 | 85.62 | 85.62 | +7.20 |
| echo | 59435 | 6,866 | 81.02 | 160.78 | 113.94 | +32.92 |
| raw | 61484 | 6,800 | 79.91 | 153.52 | 97.05 | +17.14 |
| plugin | 63472 | 6,400 | 80.32 | 179.12 | 108.03 | +27.71 |
| echo_large_bytes | 65279 | 6,893 | 80.65 | 186.83 | 172.86 | +92.21 |
| echo_large_list | 6291 | 3,043 | 80.07 | 331.88 | 283.39 | +203.32 |

原始六组有效运行共完成 30,002 次通信，均完成两轮，校验错误为 0。有效采样时间为北京时间 12:36:00 至 12:57:17，期间包含编译、分析及两次失败尝试，不是连续 21 分钟通信。该表每条件只有一次独立运行、其中两轮负载，并非多个独立重复实验；不计算置信区间，不据此比较几 MiB 的细小差异。

### 3.1 分层增量

下表同样比较基线和自然结束，最后一列为另行执行 Dart GC 后的已用堆，不能与前面各列相加。

| 条件 | 原生已分配增量 | ArkTS 已用堆增量 | Dart 已用堆增量 | Dart GC 后已用堆 |
|---|---:|---:|---:|---:|
| idle | +2.14 | +4.32 | +0.78 | 5.86 |
| echo | +9.53 | +12.63 | +0.45 | 5.87 |
| raw | +2.30 | +4.99 | +6.49 | 5.87 |
| plugin | +2.39 | +4.93 | +13.82 | 5.88 |
| echo_large_bytes | +56.87 | +7.99 | +9.28 | 5.87 |
| echo_large_list | +113.02 | +29.21 | +16.87 | 5.86 |

raw 和 plugin 的原生已分配增量与空闲组接近，ArkTS 也有自然 GC；这不支持把二者全部 PSS 增长归于新增原生存活分配。plugin 的 Dart 自然结束余量明显更多，但显式 GC 后回到接近空闲组的水平。这里仍可能有小规模合法缓存或泄漏，不能用总量接近证明每个对象的生命周期都正确。

echo_large_bytes 的原生已分配量从 63.21 MiB 增至 120.07 MiB，GC 探针后为 120.13 MiB；分配器空闲量从 9.38 MiB 降至 6.02 MiB。Dart externalUsage 从自然结束的 1.88 MiB 降至约 448 B，也没有伴随原生已分配量的等量大幅回落。增长并非仅由这部分 Dart externalUsage 解释，需进一步区分引擎持有对象、其他 native 分配、运行时分配器统计和真正泄漏。

第二次独立运行的原生已分配增量为 56.43 MiB，Dart GC 后为 56.76 MiB；PSS 自然结束增量为 92.33 MiB。两次结果接近，说明该条件的残留增长不是单次随机峰值。它仍可能是引擎/分配器按大 buffer 保留的容量，而非逐次泄漏；第 7 节已追加无周期 VM 采样对照，native allocation 调用栈仍待采集。

echo_large_list 自然结束时原生已分配量为 176.76 MiB，Dart GC 后仍为 177.81 MiB；Dart 已用堆则从 23.70 MiB 降至 5.86 MiB。ArkTS 已用堆为 33.21 MiB、容量 57.75 MiB，不能因为已经发生 GC 就认为其中全是长期存活对象。

从基线到自然结束，ArkTS API 报告的大列表累计分配增量为 2,584.76 MiB、释放增量 2,560.21 MiB、GC 次数增量 101；大字节数组对应为 89.11 MiB、84.95 MiB、17 次。虽然大列表实际只完成不到一半的操作数，累计分配仍显著更多。这里是整个当前 ArkTS VM 的累计统计，包含采样与宿主活动，不是生产插件的独立分配量；两组也不是等吞吐、等操作数的严格 A/B。

### 3.2 恢复轨迹

- echo：第一轮负载末采样 PSS 160.78 MiB，第一轮恢复末 110.74 MiB；第二轮恢复末 112.63 MiB。没有观察到两轮恢复终点持续大幅抬升。
- raw：第一轮恢复末 124.66 MiB，第二轮恢复末 98.54 MiB，自然结束 97.05 MiB。
- plugin：第一轮恢复末 132.78 MiB，第二轮恢复末 108.02 MiB，自然结束 108.03 MiB。
- echo_large_bytes：第一轮恢复末 127.87 MiB，第二轮恢复末 171.79 MiB，自然结束 172.86 MiB。这一条件恢复终点抬升，只有两轮尚无法区分阶梯式预热、延迟释放和持续增长。
- echo_large_list：第一轮恢复末 156.35 MiB，第二轮恢复末 282.68 MiB，自然结束 283.39 MiB。较大的恢复终点增量同样值得长期重复及原生分配跟踪。

## 4. 统计口径与干扰

`hidebug.getAppNativeMemInfo()` 的 PSS/RSS 来自进程内存统计；`getNativeHeapAllocatedSize()` / `getNativeHeapFreeSize()` 是分配器的 uordblks / fordblks，单位 bytes；`getAppVMMemoryInfo()` 的 heapUsed/totalHeap 是当前 ArkTS VM 的堆统计，单位 KB。Dart 使用 VM Service `getMemoryUsage`，单位 bytes。

这些层次并不互斥，也不是同一时刻的原子快照。分配器统计可能涵盖部分运行时分配，却不包含所有 mmap 内存；PSS 不能通过简单加总 Dart、ArkTS 和 malloc 指标重建。ArkTS GC 累计分配/释放统计也不能直接减出当前 live heap。

主机在每次采样完成后等 2 秒再取下一次；前五组实际采样间隔中位数约 2.78–3.69 秒，不是严格 2 秒等间隔。采样经过 VM 服务和测试通道，并在 ArkTS 侧调用同步内存 API，可能影响调度和对象分配。因此，本轮用于内存趋势，不作为新的低干扰时延基准。负载阶段内样本间的实际速率约为：244 B echo 172 次/秒、raw 163 次/秒、plugin 159 次/秒、大字节数组 172–173 次/秒，不代表 200 Hz 已稳定达成。

最后一组额外记录了完整采样 RPC 往返耗时，最小 24 ms、中位数 1,634 ms、最大 2,056 ms。它包含两次 VM 服务请求和原生统计，不能当成单次 MethodChannel 延迟，也无法据此断言原生线程被阻塞了同等时长。大列表负载阶段内实际完成速率约 75–77 次/秒。

GC 探针调用 `getAllocationProfile(gc: true)`，再等 2 秒采样。该调用本身会产生分配和统计开销：Dart 已用堆下降时 PSS 仍可能上升。本报告不使用其 PSS 差值估算“GC 释放的物理内存”，也未执行 ArkTS 强制 GC。

额外一次 `hidumper --mem 59435` 在 echo 第二轮恢复期得到系统分类：GL 14,872 KB、Graph/DMA 82,248 KB、ark ts heap PSS 22,697 KB、native heap PSS 42,596 KB，分类 Total 211,576 KB。相邻应用采样 PSS 为 115,214 KB；分类总数含额外图形口径，不能把两者差值当成泄漏，也不能将分类 PSS 当作 ArkTS 的 live heap。

### 4.1 失败尝试

大列表首次尝试因测试代码将解码后的 `List<Object?>` 强制转换为 `List<int>` 而失败。已改为按 `List<Object?>` 逐元素比较，没有改变 payload 或正式插件实现，记录保留在 `failed-list-type-check/`。

第二次尝试在已校验 814 次回环后发生 VM 采样超时。设备未找到该应用崩溃记录；脚本发生错误后会主动终止应用，随后 `hidumper` 返回进程不存在。因此，不能认定是应用自行崩溃或 OOM。记录保留在 `failed-list-vm-timeout/`，失败的系统内存抓取文本也保留，但不参与结果表。

将采样请求超时从 15 秒放宽为 30 秒、增加具体接口错误及采样耗时记录后，第三次相同负载完成全部两轮。有效结果表只使用该次成功运行，不拼接失败数据；不能因重测成功就推断第一次超时的具体根因。其他五组负载和结果未被覆盖。

## 5. 代码层依据与优化方向

本机实际安装的 OHOS Flutter 依赖中，`StandardMessageCodec.ets` 对普通列表逐项调用 `writeValue`，字节数组走 `writeBytes`；解码字节数组时分配新的 ArrayBuffer 并复制。`ByteBuffer.ets` 在扩容时分配新 buffer 并复制旧内容，输出 `buffer` 时调用 `slice`。

这解释了为什么应关注编码产生的分配和复制，但不是增长来源的调用栈证据。没有修改 SDK 或替换生产 MethodChannel。生产写请求已有 Uint8List 复用逻辑，应保留；不要把本次列表对照误写成生产仍用普通整数列表。

原生调用栈与 ArkTS 堆快照的后续归因见 [OHOS 原生分配归因结果](PERF_OHOS_NATIVE_ALLOCATION_RESULTS.md)。建议下一步按以下顺序进行：

1. 大字节数组独立复现、六轮配对、原生调用栈和 ArkTS 堆快照均已完成；当前证据指向 Engine/N-API local handle 保留消息 buffer。该问题归入 OHOS Flutter Engine 外部风险，本插件暂不跟进 Engine 源码修复。
2. 若未来升级 OHOS Flutter Engine，可用相同工作量复核关键 buffer 的 release 统计和恢复行为；强制 ArkTS GC 仍应作为独立干预记录，不能与自然恢复混算。
3. 单因素复现首轮：分别恢复持续动画、结果保留、大列表和混合长序列，每次只变一个因素。当前尚不能说其中任意因素就是 575 MiB 的根因。
4. 通信优化仍优先做多特征监听的索引分发和有界 in-flight 原型 A/B；同时验收取消订阅、顺序和错误语义。内存问题没有定位前，不以重做二进制协议作为默认修复。

不建议通过生产定时强制 GC、丢弃必要事件、缩短结果生命周期之外的语义更改来“修复”这组数字。没有 BLE 外设的 GATT、空口和锁等待项目仍跳过。

## 6. 文件与复现

- 测试入口：`packages/flutter_blue_plus/example/lib/memory_main.dart`。
- 原生桥接：`packages/flutter_blue_plus/example/ohos/entry/src/main/ets/benchmark/PerfBenchmarkPlugin.ets`。
- 主机执行：`packages/flutter_blue_plus/example/tool/run_memory_suite.mjs`。
- 校验汇总：`packages/flutter_blue_plus/example/tool/summarize_memory.mjs`。
- 原始数据、每组日志及 GC allocation profile：`packages/flutter_blue_plus/example/perf_results/2026-09-15-memory/`。
- 汇总：该目录的 `summary_memory.json`，保留每个阶段的首末值、采样峰值和实际操作速率。

在 example 目录，使用新的输出目录运行，脚本会拒绝覆盖已有 JSON 或日志：

```sh
node tool/run_memory_suite.mjs /Users/shingo/develop/SDK/ohos_flutter/bin/flutter 23E0224126000860 perf_results/memory-new idle echo raw plugin echo_large_bytes echo_large_list
node tool/summarize_memory.mjs perf_results/memory-new idle echo raw plugin echo_large_bytes echo_large_list
```

汇总会拒绝未完成运行、校验错误、进程 ID 重用、采样逆序及累计计数倒退。脚本退出时结束自己启动的 Flutter 应用；普通 `lib/main.dart` 不受影响。

## 7. 独立复现与采样干扰配对实验

### 7.1 控制变量

先用新进程 PID 40933 重复原来的两轮 20 秒大字节数组负载，完成 6,867 次回环，原始记录位于 `perf_results/2026-09-15-memory-repeat/`。其余短测数据没有覆盖。

随后改用固定操作数：每轮 3,500 次 4096 B Map + Uint8List 回环，共六轮 21,000 次；每轮恢复 20 秒，基线 10 秒，最后额外静置 20 秒。仍是单个 in-flight、目标 200 次/秒、静态 UI、日志关闭，不保留逐调用耗时或返回 payload。

两组使用完全相同的测试入口和负载配置，差别仅为主机是否进行周期 VM 采样：

- endpoints：开始前连接 VM 并启动实验，负载期间不发任何采样 RPC，通过设备输出的完成标记等待结束；结束后才获取最终 VM 数据及 Dart GC 探针。
- periodic：同样启动，在每次采样完成后等 2 秒再发下一次 VM/原生采样请求。

两组都在应用内记录基线、每轮负载结束、每轮恢复结束和最终静置点，共 14 个原生内存端点。记录数量受轮数限制，缓存在手机并输出到主机日志，最终一次性取回；periodic 组还会随 VM 快照序列化这些有限端点。这是整套周期采样链的开关，不是仅切换某一个 API。

此处“无周期采样”不等于“无 VM 服务”或“完全无测量”：两组都保持 profile/USB/Flutter 日志连接，也都有相同的 14 次端点采样。没有进行 release 或断开 VM 服务的对照。未额外调用 hidumper 或强制 ArkTS GC，以免引入新的不匹配干预。

端点组 PID 52671，主机任务北京时间 14:36:15–14:41:14；周期组 PID 57544，14:41:55–14:46:50。先端点后周期，各一次独立运行，未反转顺序、未给出统计显著性。两组都通过全部 21,000 次 payload 校验，14 个端点完整、操作数匹配、错误计数为 0。

### 7.2 相同操作数的恢复终点

以下均为各轮完成后恢复 20 秒的原生采样，单位 MiB。基线和最后额外静置点另列。

| 阶段 | 累计操作数 | 无周期采样 PSS | 周期采样 PSS | 无周期采样 native allocated | 周期采样 native allocated |
|---|---:|---:|---:|---:|---:|
| 基线 | 0 | 78.02 | 80.85 | 62.92 | 63.74 |
| 第 1 轮恢复末 | 3,500 | 124.44 | 129.37 | 82.99 | 85.65 |
| 第 2 轮恢复末 | 7,000 | 168.15 | 174.35 | 120.60 | 122.63 |
| 第 3 轮恢复末 | 10,500 | 185.89 | 193.52 | 121.48 | 124.28 |
| 第 4 轮恢复末 | 14,000 | 205.04 | 229.90 | 139.27 | 157.65 |
| 第 5 轮恢复末 | 17,500 | 216.09 | 226.69 | 166.28 | 165.42 |
| 第 6 轮恢复末 | 21,000 | 228.52 | 233.57 | 180.15 | 171.57 |
| 额外静置 20 秒后 | 21,000 | 220.51 | 229.71 | 170.19 | 171.61 |

| 基线至最终端点的变化 | 无周期采样 | 周期采样 |
|---|---:|---:|
| PSS 增量 MiB | +142.49 | +148.86 |
| 原生已分配增量 MiB | +107.26 | +107.88 |
| ArkTS 已用堆增量 MiB | +6.51 | +6.61 |
| 最终 VM 采样 Dart 已用堆 MiB | 11.98 | 14.86 |
| Dart GC 后已用堆 MiB | 5.98 | 5.98 |

GC 探针后的原生已分配量仍为 172.02/172.28 MiB，未随 Dart 已用堆回落而显著下降。最终原生端点和随后的 VM 快照存在时间差，前者用于主表比较，后者用于 Dart 指标，未混用 PSS。

### 7.3 判断与边界

1. **增长已独立复现，且不依赖周期 VM 采样。** 无周期组完成相同操作数后仍有 +107.26 MiB 原生已分配增量，与周期组 +107.88 MiB 接近。不能把主要增长解释为每隔几秒调用 VM 内存接口所独有的结果。
2. **六轮内尚未显示稳定恢复平台。** 恢复终点总体抬升，但不是每轮按固定字节数增加，最后静置仍有回落。不能按总增量除以操作数声称“每次必泄漏多少字节”，也不能证明无限增长。
3. **不是同等规模的 Dart 存活堆增长。** 两组 Dart GC 后已用堆都约 5.98 MiB，ArkTS 最终堆增量也远小于原生已分配增量。但不同统计层不能相加减直接推出某个剩余量的所有者。
4. **尚不能排除共同干扰，也没有定位持有者。** 引擎 profile 模式、VM 连接、端点采样、回环测试自身和系统运行时仍是共有条件；单次顺序配对也不足以量化几 MiB 的采样影响。更不能据此认定生产 BLE 插件泄漏，因为大量调用走的是独立测试 echo handler，不是 GATT handler。
5. **原生分配证据已取得。** 关键路径为 `napi_create_arraybuffer`，7,000 个 buffer 在 GC 后仍由 `LocalHandleRoot` 直接持有；具体 C++ 源码行和修复方式尚未确认。大整数列表的六轮配对、断开 VM 服务、真实 BLE 和原始混合长序列的单因素复现尚未执行。

### 7.4 复现与校验

在 example 目录，用新的输出目录分别执行以下命令，不能同时启动两组覆盖同一个设备应用：

```sh
env FBP_MEMORY_SAMPLING=endpoints FBP_MEMORY_CYCLES=6 FBP_MEMORY_OPERATIONS=3500 FBP_MEMORY_CHECKPOINTS=true node tool/run_memory_suite.mjs /Users/shingo/develop/SDK/ohos_flutter/bin/flutter 23E0224126000860 perf_results/pair-new-endpoints echo_large_bytes
env FBP_MEMORY_SAMPLING=periodic FBP_MEMORY_CYCLES=6 FBP_MEMORY_OPERATIONS=3500 FBP_MEMORY_CHECKPOINTS=true node tool/run_memory_suite.mjs /Users/shingo/develop/SDK/ohos_flutter/bin/flutter 23E0224126000860 perf_results/pair-new-periodic echo_large_bytes
node tool/summarize_memory_pair.mjs perf_results/pair-new-endpoints/echo_large_bytes.json perf_results/pair-new-periodic/echo_large_bytes.json perf_results/pair-new-periodic/summary_pair.json
node --test tool/summarize_memory_pair.test.mjs
```

本次原始目录为 `perf_results/2026-09-15-memory-pair-endpoints/` 和 `perf_results/2026-09-15-memory-pair-periodic/`；配对汇总 `summary_pair.json` 位于后者。不要对端点组使用依赖周期 `baseline` 样本的旧 `summarize_memory.mjs`。

配对汇总脚本检查两种模式、同一 workload、独立 PID、全部操作数、14 个端点的顺序和校验结果，并拒绝端点模式下出现多次 VM 工作流快照。六项合成数据单元测试覆盖单位转换、配置不匹配、PID 重用、端点缺失/计数错误、未完成运行和意外周期采样；合成数据只用于验证汇总器，不充当测量结果。
