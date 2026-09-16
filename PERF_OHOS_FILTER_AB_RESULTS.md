# OHOS 真机公共 Dart 过滤链 A/B 结果

日期：2026-09-15。正式测量于北京时间 17:48–17:54 完成。

**最新落地状态：用户确认后，公共 Dart 的生产 `onValueReceived` 已采用合并过滤，详见 [生产落地记录](PERF_DART_FILTER_AB_RESULTS.md#10-生产落地记录)。** 以下正文保留落地前的实测数据与当时判断；没有重写原始数据或将 RTT/内存验收标记为通过。当前手机工具已改为保留旧 getter 对照真实生产 getter，本次落地未重跑手机性能测试。

后续状态：同日已完成 [50/100 Hz 及监听顺序复测](PERF_OHOS_FILTER_LOW_RATE_RESULTS.md)，新增 48,000 条正式模拟事件。Dart 分发收益再次复现，但单监听 RTT 出现跨进程回退，实际频率仍偏离目标，生产 getter 暂不变更。本报告保留首轮 200 Hz 请求配置的数据与当时结论，不与后续数据混算。

## 1. 结论与生产决策

**合并过滤条件在本次 OHOS 真机模拟事件测试中降低了 Dart 分发耗时，尚不足以通过生产变更验收。候选继续只保留在 example，生产 getter 未改动。**

四个场景的配对 P95 中位改善为 9.22%–13.37%。其中 64 个监听器、instanceId 不匹配场景的 12 对全部改善；但首字段不匹配场景第二个进程的中位结果回退 3.95%，通道 RTT 也未在各进程间一致改善。因此不能用汇总数据宣称“所有场景更快”或“通信延迟稳定降低”。本轮没有单独比较候选与基线的长时内存，不能宣称无内存副作用。

这轮测量实际运行了手机 Engine、MethodChannel、OHOS Dart adapter 与公开 getter；事件由 example 的 ArkTS 定时器生成，没有 BLE 外设，不包含 GATT、无线链路、真实通知来源定位、读写完成或连接状态变化。Android、iOS/Darwin 的公共 Dart 行为已经单独测试，但手机性能数据只属于 OHOS。

## 2. 候选和测量边界

基线直接使用生产 `BluetoothCharacteristic.onValueReceived`。候选为 example 中 `BenchmarkFusedCharacteristic` 子类，仅将六层 `.where()` 合并为一层短路条件，保留设备、主服务、服务、特征、instanceId、success 的原求值顺序，以及原 `.map((c) => c.value)`。

通道集成测试与手机程序共用同一个候选类，避免两份原型漂移。未改变生产接口、通道名称、消息格式、原生插件、锁、缓存或队列。

| 指标 | 实际计时范围 | 不代表什么 |
|---|---|---|
| `observer_to_filtered_us`，下称 Dart 分发 | 全局公开事件观察者记录时间，到最后注册的目标 characteristic 监听器入口；同一 Dart Stopwatch | 不含此前的 native 发送、codec 解码和事件对象解析；也不是单条谓词的纯 CPU 耗时 |
| `native_rtt_us`，下称 RTT | ArkTS 调用生产事件通道前，到该调用的自动回复抵达 ArkTS；同一原生时钟 | 不是 native 到业务监听器的单向延迟，也不是业务处理完成 ACK |
| `native_interval_us` | 连续两次原生发送起点的间隔 | 不是 BLE 通知间隔或吞吐上限 |
| 内存端点 | 混合 A/B 进程开始前、全部场景结束并冷却 10 秒后 | 不是候选/基线的独立内存 A/B，也不是长时泄漏测试 |

全局观察者先注册，目标监听器最后注册，因此 Dart 分发指标包括之前监听者的分发、匹配与异步调度，适合观察多监听者成本。计时前后还存在观察者校验、计时和采样写入开销；这些在两组保持一致。不能从 RTT 减去 Dart 分发时间推导出“纯通道耗时”，两者的计时边界和完成条件不同。

## 3. 实验设计与完整性

- 设备：HUAWEI Mate 60 Pro，序列号 `23E0224126000860`，OHOS arm64；设备报告内核 `HarmonyOS HongMeng Kernel 1.12.0`。
- SDK：Flutter `3.41.10-ohos-1.0.0`，Dart `3.11.5`，OHOS Flutter SDK 构建并运行 `profile` 模式，使用已签名的独立 example OHOS 宿主。
- 三次全新应用进程，PID 分别为 46408、48321、50071。各进程 4 轮配对，4 个场景，每场景基线/候选各一次；轮间交替 A/B、B/A，并反转场景顺序，第二个进程再反转初始顺序。
- 每场景 400 个事件、每条 244 B、定时器目标 200 Hz。监听数为 1、16、64；`late_miss` 让非目标监听者在 instanceId 处不匹配，`early_miss` 在 remoteId 处不匹配。1 个监听者时实际上全部匹配。
- 每进程先等待 3 秒，再对基线/候选分别做 100 条事件预热；正式场景结束后等待 100 ms 排空，再取消订阅；场景间等待 200 ms。没有持续刷新 UI，也没有周期性 VM 采样。
- 正式共 **96 个场景运行、38,400 条事件**；另有 600 条预热事件，不纳入统计。每个场景/变体汇总 4,800 个实际样本，保留每个进程的 12 组配对信息。
- 正式场景的 sent、replies、全局 observed、目标 received 全部为 400；validation_errors、unexpected、native_errors 全部为 0。每条检查序号与 payload，检查误投递，并验证 RTT 为 400 项、发送间隔为 399 项。
- 每次运行使用独立 token，进程 PID 和 token 同时匹配导出 JSON 与 manifest，避免 SDK 重放历史 hilog 导致旧结果混入。运行前后核验 5 个关键源码的 SHA256，没有运行中修改被测源码。

P50/P95/P99 对原始样本排序后采用 nearest-rank。配对改善为每对 `100 × (1 - fused P95 / baseline P95)`，再取 12 对的中位数；不能把这个值与两个汇总 P95 的比值混淆。样本在同一进程内相关，未把 4,800 条事件视为 4,800 次独立实验，也未声称统计显著性。没有删除慢样本。

## 4. Dart 分发结果

时间单位为 µs，箭头为基线 → 候选。改善对数只计严格更快，相同不计入。

| 监听数 / 场景 | 汇总 P50 | 汇总 P95 | 汇总 P99 | 配对 P95 中位改善 | 改善对数 / 12 |
|---|---:|---:|---:|---:|---:|
| 1 / 全匹配 | 54 → 48 | 87 → 70 | 188 → 169 | 9.22% | 10 |
| 16 / instanceId 不匹配 | 504 → 418 | 760 → 658 | 971 → 885 | 13.37% | 11 |
| 64 / instanceId 不匹配 | 1,521 → 1,366 | 2,011 → 1,776 | 2,666 → 2,325 | 11.46% | 12 |
| 64 / remoteId 不匹配 | 185 → 166 | 292 → 262 | 444 → 410 | 10.48% | 10 |

64 个监听器、后段不匹配时，汇总 P95 降低 235 µs；但候选 P95 仍为 1.776 ms。合并过滤层没有消除按监听者逐个匹配的成本，不能称为 O(1) 路由。

各独立进程内 4 对 P95 改善的中位数如下，负数为候选较慢：

| 场景 | 进程 1 | 进程 2（反转初始顺序） | 进程 3 |
|---|---:|---:|---:|
| 1 / 全匹配 | 17.39% | 6.85% | 8.51% |
| 16 / instanceId 不匹配 | 13.25% | 11.28% | 14.78% |
| 64 / instanceId 不匹配 | 15.22% | 10.49% | 11.46% |
| 64 / remoteId 不匹配 | 16.58% | -3.95% | 12.73% |

单监听有一对回退 21.88%，另有一对持平；16 个监听器有一对回退 0.43%；64 个监听器首字段不匹配有两对回退，最大 11.68%。汇总最大值也并非全部改善：16/late 为 4,086 → 6,113 µs，64/late 为 6,725 → 6,843 µs，64/early 为 5,081 → 7,075 µs。保留这些结果；当前数据无法区分孤立调度噪声与可重复候选回退。

## 5. RTT 与实际发送频率

RTT 单位为 ms，数值四舍五入至 3 位。

| 场景 | 汇总 P50 | 汇总 P95 | 汇总 P99 | 配对 P95 中位改善 | 改善对数 / 12 |
|---|---:|---:|---:|---:|---:|
| 1 / 全匹配 | 2.636 → 2.657 | 3.924 → 3.969 | 8.206 → 8.434 | 1.33% | 7 |
| 16 / instanceId 不匹配 | 2.941 → 2.790 | 4.782 → 4.233 | 8.931 → 8.266 | 9.27% | 9 |
| 64 / instanceId 不匹配 | 3.561 → 3.500 | 6.561 → 6.407 | 9.333 → 8.824 | 1.10% | 7 |
| 64 / remoteId 不匹配 | 2.899 → 2.738 | 4.063 → 4.038 | 8.967 → 8.482 | 1.02% | 8 |

16/late 的 RTT 配对中位改善在三个进程分别为 +28.50%、-16.27%、+7.26%，并不稳定。64/late 候选最大 RTT 为 118.850 ms，基线最大为 37.221 ms。不能仅凭汇总 P95/P99 的下降判定通道长尾已解决。

**目标 200 Hz 没有实际达到。** 下表是各场景运行的平均发送频率范围，按 `399 × 10⁶ / sum(native_interval_us)` 计算：

| 场景 | 基线实际 Hz | 候选实际 Hz |
|---|---:|---:|
| 1 / 全匹配 | 157.74–164.78 | 156.58–166.03 |
| 16 / instanceId 不匹配 | 147.62–159.21 | 152.54–161.18 |
| 64 / instanceId 不匹配 | 139.83–146.40 | 140.81–147.31 |
| 64 / remoteId 不匹配 | 153.45–161.00 | 156.56–162.10 |

两组的请求频率与事件数相同，实际频率受定时器及运行时调度影响、并不严格相同。因此本轮是固定事件数、相同定时器配置下的真实执行对照，不能称为稳定 200 Hz 负载测试、最大吞吐测试或严格相同到达率实验。后续宜先用设备可稳定维持的更低频率排除到达率偏差，再单独测压力场景。

## 6. 内存与行为风险

| 进程 | PSS 起点 → 终点（KB） | PSS 增量（KB） | Ark 已用堆起点 → 终点（KB） |
|---|---:|---:|---:|
| 46408 | 76,613 → 154,606 | 77,993 | 4,027 → 11,292 |
| 48321 | 77,528 → 157,854 | 80,326 | 4,027 → 16,841 |
| 50071 | 76,631 → 158,371 | 81,740 | 4,023 → 17,568 |

PSS 确有增长。进程同时执行 A/B，保留所有计时数组，端点跨越预热、全部场景、GC 和运行时初始化；既有 OHOS Engine/N-API 保留问题也属于环境背景。因此无法把增长归因于候选、断言全是 Engine 所致，或用它证明基线/候选内存相同。此轮未采集分变体 Dart 分配率、CPU、空闲曲线或长时稳态。

共享候选重新通过三端 Dart handler 的 **33 项集成测试**，覆盖字段匹配、64 个实例、全局观察者、payload 引用、暂停/恢复/取消、平台替换、非法消息恢复及有界突发。具体覆盖和未覆盖项见 [公共 Dart 验证报告第 9 节](PERF_DART_FILTER_AB_RESULTS.md#9-三端-dart-通道集成验证)。分析工具的 4 项合成夹具测试通过；夹具不作为手机性能数据。

用户已允许不修复 OHOS Engine 问题，继续将其列为外部风险；这不等于免除插件候选自身的行为和内存验证。

## 7. 三端下一步与验收状态

| 范围 | 已完成 | 尚缺的验收证据 |
|---|---|---|
| 公共 Dart | 本机 AOT 微基准、三端真实 Dart adapter 与公开 getter 行为 A/B、共享候选 | 空闲/长时及分配率；更多监听顺序、负载和非空缓存生命周期 |
| OHOS | 3 个手机进程、真实通道模拟事件、本报告的分发和 RTT 尾延迟 | 稳定到达率对照、首字段不匹配回退复核、候选/基线独立内存对照 |
| Android | Dart 接收路径行为覆盖；原生候选已静态分析 | Android 原生模拟事件宿主与实际 Engine/设备 A/B，不能复用 OHOS 的收益百分比 |
| iOS/Darwin | Dart 接收路径行为覆盖；原生候选已静态分析 | Darwin 原生模拟事件宿主与实际 Engine/设备 A/B；本轮未进行 Apple 构建 |
| BLE/GATT | 无外设，跳过 | 无线、设备队列、背压、断连、服务重发现及真实回调行为 |

优先继续验证当前单一候选，不同时引入事件索引、UUID 缓存、二进制协议或原生并发变更。下一轮应降低并核对实际事件频率、独立控制订阅顺序，并采用不保留完整样本的分变体长时对照。Android 与 Darwin 的相应 native-to-Dart 数据应独立取得；没有可用运行环境的项目明确跳过，不能以静态分析替代。

## 8. 异常尝试、环境恢复与复现

首次目录 `2026-09-15-ohos-filter-ab` 的第三个进程因设备自动休眠而未完成，runner 超时退出；PowerManager 显示 SLEEP/TIMEOUT，没有将其记录为插件崩溃。该目录原样保留，其前两次完整数据也全部排除，不与正式数据拼接。

之后为三次正式运行统一临时保持亮屏，加入独立 run token，重新执行完整套件。全部完成后已用 PowerManager 的 `-f` 恢复临时屏幕设置，读取 `-s` 确认 ScreenOffTime 为原始 600000 ms。测试应用已退出。所有 CLI 使用宿主权限执行，未使用沙箱 CLI。

CodeGenie ETS MCP 缺失曾阻止按技能流程构建；用户随后明确授权跳过该前置检查，使用现有 OHOS Flutter SDK。本次三次 profile 构建、安装、运行和结果导出均已完成，故该项不再是当前阻塞。没有安装 MCP、修改签名配置或访问其他业务项目。

文件：

- [手机 A/B 入口](packages/flutter_blue_plus/example/lib/filter_ab_main.dart)、[共享候选](packages/flutter_blue_plus/example/lib/benchmark/fused_characteristic.dart)。
- [运行器](packages/flutter_blue_plus/example/tool/run_filter_ab.mjs)、[严格汇总器](packages/flutter_blue_plus/example/tool/summarize_filter_ab.mjs)、[汇总器测试](packages/flutter_blue_plus/example/tool/summarize_filter_ab.test.mjs)。
- [正式 manifest](packages/flutter_blue_plus/example/perf_results/2026-09-15-ohos-filter-ab-awake/manifest.json)、[汇总及全部配对统计](packages/flutter_blue_plus/example/perf_results/2026-09-15-ohos-filter-ab-awake/summary.json)。同目录保留 run1/2/3.json 原始样本及运行日志。

在 `packages/flutter_blue_plus/example` 运行，新测量必须使用不存在的输出目录；保持设备解锁亮屏，如使用临时 PowerManager 覆盖，须在成功或失败后恢复：

```sh
node tool/run_filter_ab.mjs \
  /Users/shingo/develop/SDK/ohos_flutter/bin/flutter \
  /Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc \
  23E0224126000860 perf_results/NEW_FILTER_AB_DIRECTORY
node tool/summarize_filter_ab.mjs perf_results/NEW_FILTER_AB_DIRECTORY
node --test tool/summarize_filter_ab.test.mjs
```

runner 检查输出目录、源码指纹、独立 PID/token 和导出结果；汇总器进一步检查顺序、计数、错误数与原始样本。它没有自动管理亮屏设置。仅重新核对本次数据时，直接将汇总器参数设为 `perf_results/2026-09-15-ohos-filter-ab-awake`，无需重新构建或运行手机。
