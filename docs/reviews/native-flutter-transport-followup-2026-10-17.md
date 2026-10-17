# 传输修复复审与补充审查（2026-10-17）

最新状态：以下 5 项已按用户要求修复，并对修复后的实现再次审查。新增的复现现已转成期望正确行为的回归；下文问题描述保留为修复前的历史证据。本轮未进行 LiberLive 集成或设备性能测量。

| 问题 | 当前修复 | 验证 |
|---|---|---|
| 连接超时重试竞态 | 按设备保留 native 调用与共享取消屏障；先尝试取消，等旧提交结束再确认断连；重试及 GATT 操作不能越过屏障，等待者仍可超时；取消失败保留隔离并允许重试 | 公开 API 回归覆盖迟到 connected、挂起调用、两阶段取消、断连确认、取消失败重试及不同设备并行 |
| Android 旧 GATT 数据回调 | 数据回调在既有连接 mutex 下验证对象身份并访问缓存；Handler 实际发送事件前再次验证，过滤队列中的旧事件 | 实际 write/MTU/RSSI 方法体 JVM 回归通过；完整 Android 插件 Java 编译通过 |
| OHOS 旧服务树恢复 | 服务相关操作保存 revision，在定位、native await 后及响应前校验；服务缓存只由 servicesFor 写入；Service Changed 同时清除旧写入和通知加载引用 | read/write/descriptor/notify/discovery 7 条中断恢复回归，以及变更后通知重新查询回归通过 |
| turnOn 超时挂起 | 使用原始适配器事件订阅，状态查询与 ON 事件竞争；查询挂起不阻塞取消，快照不会覆盖更新的适配器事件 | 查询挂起超时、迟到失败、ON 事件先到、旧 OFF 缓存/查询 ON、查询期间更新 OFF 回归通过 |
| OHOS 歧义通知路由 | 同时考虑 primary 和 included 的服务/特征候选；无法唯一证明归属时拒绝；拒绝失效重复实例 handle 和当前快照中不存在的普通特征 | 两种服务顺序的歧义、可证明的归属、失效 handle 和缺失特征回归通过 |

再次审查覆盖：锁的获取/释放顺序、取消屏障失败重试、Dart 迟到异常处理、Android 缓存校验与 UI 队列之间的窗口、OHOS revision 从缓存到 native 完成的全路径，以及正常数据响应是否仍可投递。复审中补修了 Service Changed 后新通知加入旧查询、turnOn 旧缓存与更新事件优先级、失效通知实例校验，以及取消路径保留 Android 最小断连间隔和时间戳清理。当前范围内未发现剩余阻断问题；这不代表 Windows 和真机生命周期已经验收。

当前验证：Flutter/Dart 跨包测试 86/86 通过，最终 Dart 改动补跑 followup/lifecycle 通过；主包 lib/test analyzer 无问题；OHOS 实际 ETS 逻辑 mock 29/29 通过；18 个 ETS 文件转成 TS 后除缺少原生 SDK import 外无语法/语义诊断；Android Java 编译与实际回调方法体回归通过。TypeScript 检查不等同于 ArkTS 构建，JVM 替身不模拟 Android 蓝牙调度。

剩余限制：native 调用永不结束时，该设备继续被隔离，各次等待按自己的 timeout 返回；不能安全地靠 Dart 超时强行允许新连接。取消阶段的失败可通过再次 disconnect 重试。Android 数据校验复用既有 mutex，新增开销未做设备延迟测量。Windows 完整 teardown/session 路径和完整 ArkTS 构建、设备验证仍待相应环境。

## 修复前的审查结论与证据

初次复审确认 5 项问题，其中连接超时后的取消/重试存在首次修复引入的竞态；其他问题属于修复覆盖不完整或补充发现的既有缺陷。当时仅新增复现和文档，随后用户授权本轮修复。

基线：`master` / `0a519e58` 加当前未提交修改。重点复审 Dart scope、FIFO、共享初始化，以及 Android/Darwin/OHOS/Windows 的相关修改；沿关键读写/通知路径补查连接代次、服务缓存与路由。Linux 初始化也已检查。此报告补充并限定首次报告中“10 项已修复”的结论。

## 1. [P1] 连接超时取消未结束就释放队列，重试与旧请求重叠

位置：[bluetooth_device.dart:180](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus/lib/src/bluetooth_device.dart:180)。来源：本轮修改。

超时处理把此前等待 native disconnect 改成 `.ignore()`，随后释放操作与断连 mutex。`connect` 的 scope 使用 `connected: false`，也不受已提交 GATT 超时的 `_needsReconnect` 保护。因此，在 native connect 或取消尚未完成时，同设备第二次 connect 已能提交；响应仅按 remoteId 过滤，旧尝试的 connected/disconnected 事件会被新尝试接收。需要异步获取设备、权限或建立连接的平台尤其会经过这个窗口。Windows 的 ConnectAsync 本身跨多次 await，并且连接集合按 remoteId 操作，不能假定所有平台 connect 都立即返回。

公开 API mock 复现：第一次 native connect 始终 pending，10ms 后 Dart 报超时并调用 disconnect；让 disconnect 也 pending，立即重试，第二次 native connect 已被调用；再注入第一次尝试迟到的 connected 事件，第二次 connect 成功返回，此时第一次 connect 和取消仍都未结束。这证明 Dart 层没有尝试隔离，不代表已经在设备上测得此调度顺序。

建议：保持调用方超时可返回，但把设备留在取消中的状态；在 native 取消确认/旧请求结束前阻止新尝试，或用 native 尝试代次完整隔离旧提交、清理和事件。不能仅在原处无界 await，否则会恢复 native 挂起导致队列永远占用的问题。

## 2. [P1] Android 旧 GATT 数据回调仍能污染新连接

位置：[onCharacteristicWrite:2492](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_android/android/src/main/java/com/jmx/flutter_blue_plus/FlutterBluePlusPlugin.java:2492)、[onCharacteristicReceived:2403](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_android/android/src/main/java/com/jmx/flutter_blue_plus/FlutterBluePlusPlugin.java:2403)。来源：既有数据回调缺陷，本轮连接状态防护未覆盖。

新增的 GATT 对象比对只在 onConnectionStateChange 内执行。读、写、通知、描述符、RSSI 和 MTU 回调仍未验证传入 gatt 是否为当前连接。尤其 onCharacteristicWrite 的待写数据以设备+UUID+instanceId 为键，不含 GATT 身份；重连后身份相同，旧写完成会 `remove` 新写的数据，并以它发出 success。Dart 在断连后清除了超时屏障，新请求也只按相同路由字段匹配，因此重连不能单独保证迟到写响应隔离。onMtuChanged 还会直接覆盖按 remoteId 保存的当前 MTU。

复现脚本从当前 Java 文件直接抽取实际 onCharacteristicWrite 方法体，在 JVM 上配最小类型替身：当前连接是新 GATT、缓存含新连接 payload `[2]`，调用旧 GATT 的写完成；结果新缓存被删除，并发出携带 `[2]` 的成功事件。这里验证实际方法的数据流，未模拟 Android 回调调度或执行整插件设备测试。

建议：所有数据回调在读写共享缓存前验证当前 GATT；事件经 Handler 排队后还应在实际发送时验证代次，防止入队时有效、出队时已重连的事件穿透。缓存和待写上下文同样绑定连接代次。

## 3. [P1] OHOS 读取完成会在 Service Changed 后恢复旧服务缓存

位置：[读取后校验:103](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_ohos/ohos/src/main/ets/components/plugin/BleCharacteristicManager.ets:103)、[emitReadResult:159](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_ohos/ohos/src/main/ets/components/plugin/BleCharacteristicManager.ets:159)。来源：既有回写行为；本轮新增服务 revision 只保护服务查询，未覆盖使用快照的后续操作。

servicesFor 校验的是 getServices 前后的 servicesRevision。若读取已取得旧快照，再在 readCharacteristicValue 等待期间收到 Service Changed，invalidateServices 会删除缓存、递增 revision，但 session.assertCurrent 只检查连接是否相同，仍然通过。emitReadResult 随后无条件把旧 services 写回并回报成功；后续读写/通知继续命中已失效的句柄树，直到下一次清理。

运行实际 ETS 生产逻辑的 mock 复现：预填服务缓存并挂起 native read；注入 1801/2a05 后确认缓存已删除；完成旧 read 后，缓存再次等于旧 services，调用收到 success。既有“Service Changed during getServices”测试不覆盖该窗口。

建议：操作上下文同时保存连接代次与服务 revision；在定位后、native await 后、缓存回写和发事件前验证两者。读取结果不应重复无条件回写其取得的服务快照。写入、描述符与配置通知等使用旧树的路径应采用同一规则。

## 4. [P2] turnOn 的 finally 可能无限等待，抵消执行超时

位置：[turnOn:191](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus/lib/src/flutter_blue_plus.dart:191)、[scope.close:107](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus/lib/src/utils.dart:107)。来源：本轮统一订阅清理后的遗漏。

首次开启蓝牙且 adapter cache 尚未知时，adapterState 是 async*，会先 await getAdapterState。用户接受 turnOn 后进入该流，如果 native 查询不返回，执行计时器虽会触发，finally 的 scope.close 却等待 subscription.cancel；async* 的取消要等当前 await 结束，最终 turnOn 仍无法把超时交给调用方。

公开 API 复现：用户接受、getAdapterState 保持 pending；turnOn(timeout:10ms) 在 100ms 后仍未完成，只有解除 native 查询后才抛出已发生的超时。100ms 是诊断等待窗口，不是性能数据。

建议：turnOn 内部使用可独立取消的原始适配器事件监听，并将状态查询作为单独受 deadline 约束的 Future 与缓存配合；不要让取消被挂起的 async* 查询阻塞。避免简单忽略所有取消 Future 导致真实清理错误被吞掉。

## 5. [P2] OHOS 无 handle 的主服务通知可被误判为 included service

位置：[getPrimaryService:195](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_ohos/ohos/src/main/ets/components/plugin/BleGattShared.ets:195)。来源：本轮精确路由修复的 fallback 不完整。

API < 18 的克隆通知无法通过对象身份或 handle 找到归属，fallback 只统计 included service 的 UUID 命中，不统计相同 UUID 的主服务候选。如果设备既有主服务 180f，又有另一个主服务 1810 包含同 UUID 的 included service 180f，主服务通知克隆会被归到 1810，填入错误 primary_service_uuid。Dart 的主服务订阅收不到它；若 included service 下有同特征 UUID，还可能交给错误订阅。

实际 ETS helper 复现：设 sdkApiVersion=17，构造上述服务树，传入主服务特征的克隆；getPrimaryService 返回 1810。已有 included service 测试只有唯一 included owner，没有同 UUID 主服务竞争。

建议：无 handle 时把主服务和 included service 都纳入完整候选；无法证明唯一归属时明确失败并记录诊断，不猜测 included owner。可用 handle 时还要证明它属于当前服务快照。

## 验证及复现入口

修复前针对受影响部分重跑现有测试：Dart startup/lifecycle 7/7、OHOS 原生逻辑 mock 19/19 通过；它们未覆盖上述 5 种窗口。以下兼容入口已改为运行期望正确行为的正式回归测试，不再断言缺陷存在。正式源码分别是主包 test/transport_followup_test.dart、OHOS test/transport_regression.test.cjs 和 Android test/run_callback_tests.py。

```sh
# 在 packages/flutter_blue_plus 运行，覆盖问题 1、4
/Users/shingo/fvm/default/bin/flutter test --no-pub ../../docs/reviews/transport_audit/followup_review_probe_test.dart --reporter expanded

# 在仓库根目录运行，覆盖问题 3、5
FBP_TYPESCRIPT=/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript/lib/typescript.js node --test docs/reviews/transport_audit/followup_review_probe.cjs

# 在仓库根目录运行，抽取实际 Java 回调覆盖问题 2
python3 docs/reviews/transport_audit/followup_android_probe.py
```

未进行完整 Windows 构建、ArkTS 构建或 BLE 真机测试。Windows 命名协程修复消除了已确认的临时闭包问题，但既有请求协程仍持有裸 this 跨 await，完整 teardown/session 隔离仍是首次报告已列出的未验证范围；不能把语言模型 ASan 验证等同于 Windows 插件验收。

性能方面未增加新的实测结论。FIFO 与 Guid 的局部算法收益仍成立；集中事件路由、有界优先级队列、原生调度是否必要，仍应按首次报告的工作负载在 LiberLive 集成后测量。上述正确性缺口会污染成功率、延迟和重连数据，应优先修复后再建立可比较的性能基线。
