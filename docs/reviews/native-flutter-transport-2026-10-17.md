# native ↔ Flutter 传输审查（2026-10-17）

复审及后续修复：首次修复后发现的 5 项缺口现已按用户要求继续修复，并再次审查，详见[复审报告](native-flutter-transport-followup-2026-10-17.md)。包括连接超时后的重试隔离、Android 旧 GATT 数据回调、OHOS 服务变更与路由边界，以及 turnOn 超时清理。下表保留首次修复记录，最新实现和验证范围以复审报告开头的状态说明为准。

首次修复记录：下列 10 项审查问题已在工作区实施修复，并补充回归覆盖。Dart 改为 FIFO 等待队列、共享初始化和可取消操作等待；OHOS 增加连接代次隔离、共享且串行的服务加载、精确实例路由；Windows 修复临时协程闭包、included service 通知身份及描述符缓存键。当前仍使用标准 MethodChannel，未恢复历史上已回退的二进制协议。

## 修复状态

| 审查项 | 本轮修复 | 验证 |
|---|---|---|
| 1 Windows 临时协程闭包 | 四处事件处理改为命名协程，参数、共享存活标记和 UI context 按值进入协程帧 | 安全模式 C++ ASan 模型通过；Windows 插件尚未构建验证 |
| 2 OHOS 通知查询风暴 | 同一 session 共用服务加载 Future，底层查询进入 GATT 串行队列，缓存命中仍直接分发 | 20 条并发通知只查询一次；忙队列回归通过 |
| 3 OHOS 旧连接结果污染 | session 校验覆盖入队、执行和 await 后；重连隔离缓存和队列，旧写入不能清理新数据；RSSI 成功与失败均隔离 | 旧查询、旧排队读取、挂起旧 GATT、旧写入及 RSSI 回归通过 |
| 4 OHOS 实例路由冲突 | 跨同 UUID 服务聚合候选；优先精确 handle，歧义/失效实例明确失败；保留 included service 身份 | 重复服务及 included service 回归通过 |
| 5 并发初始化 | Android/Darwin/OHOS 重启和 Linux 初始化共享进行中的 Future；失败可重试 | 8 项启动回归通过 |
| 6 请求监听残留 | 操作 scope 在 finally 取消响应、连接、适配器订阅及计时器 | 拒绝、超时、断连、适配器关闭、初始化异常及成功路径回归通过 |
| 7 native invoke 不受超时约束 | 期限覆盖 native 调用和响应；排队单独计时；已提交操作超时后要求重连以隔离迟到响应 | 挂起调用、迟到拒绝及排队超时回归通过 |
| 8 广播锁放大成本 | FIFO 每次唤醒一个等待者；超时移除等待者；空闲 mutex 回收并保留队列模式限制 | 200 次 FIFO 公开读回归及实际实现 AOT 微基准通过 |
| 9 Windows included service 通知 | 通知注册与派发携带 primary_service_uuid | 源码契约检查；待 Windows 验证 |
| 10 Windows 描述符缓存 | 存取统一为设备+父特征 handle+规范化描述符 UUID；发现服务清除旧快照 | 源码数据流检查；待 Windows 验证 |

**行为变化**：排队和执行各有独立 timeout 预算；requestMtu 的既有 predelay 在执行预算之外。已提交的 GATT 请求超时后，须断开并重连再继续 GATT 操作，可用 `disconnect(queue: false)` 中断当前操作。Dart Future 超时并不能取消底层 BLE 请求，因此不能直接放行下一次请求去接收旧响应。此约束已写入主包 README 和 changelog。

本轮解决已复现缺陷；有界通知缓冲、集中事件路由、批处理和二进制通道仍属于后续优化。OHOS 缓存加载等待期间的通知尚无显式数量上限；旧 API 遇到无法精确区分的克隆特征事件会明确失败。Windows 其他已有异步路径的完整 teardown/session 重构仍需在 Windows 环境继续审查。

审查基线为上游共同祖先 `7013484533902f5e830ffd511e070245a098ee67`，对象为 fork 的 `0a519e58` 加当前工作区已合入的上游补丁与 MTU 修复。检查了 Dart 主包、platform interface、Android、Darwin、OHOS、Windows、Linux、Web 的相关差异及读写、通知、扫描路径。授权/许可不是此次传输效率审查的重点。首次审查后已按用户授权修复生产代码，保留此前合入的上游补丁和 MTU 修复；未改动授权、许可或版本。

证据分三类：直接运行现有 Dart/ETS 生产逻辑的复现、独立算法/编码微基准、源码静态判断。OHOS 使用仓库现有 TypeScript 转译与 mock 框架，不代表 ArkTS 编译或设备实测；Windows 使用源码检查及相同 C++ 生命周期模式的 ASan 复现，未在 Windows 构建或运行插件。以下指标不代表真实 BLE 吞吐率。

## 原始审查问题与证据（修复前）

本节记录修复前的触发条件和证据；位置行号对应当时源码，当前实现及验证结果以上方修复状态为准。

### 1. [P1] Windows 临时协程闭包在切换线程后访问已销毁的捕获对象

位置：[扫描回调](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_winrt/windows/flutter_blue_plus_winrt_plugin.cpp:537)、[连接回调](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_winrt/windows/flutter_blue_plus_winrt_plugin.cpp:1065)、[通知回调](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_winrt/windows/flutter_blue_plus_winrt_plugin.cpp:1226)、[MTU 回调](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_winrt/windows/flutter_blue_plus_winrt_plugin.cpp:1245)。来源：fork 新增 Windows 实现。

这些路径立即调用一个捕获 `this`、事件参数、`alive` 的临时 coroutine lambda。`co_await ui_thread_` 从 BLE 工作线程切换到 UI 线程时会挂起；调用表达式结束后闭包销毁，恢复后读取的捕获成员仍属于闭包，而非自动复制到协程帧。即使捕获的是 shared_ptr，也不能解决闭包自身的生命周期问题。

[coroutine_lifetime.cpp](/Users/shingo/develop/hujie/flutter_blue_plus/docs/reviews/transport_audit/coroutine_lifetime.cpp) 对相同写法得到 `AddressSanitizer: stack-use-after-scope`。这是语言层面的复现，尚非插件在 Windows 上的崩溃实测。应改成命名协程或无捕获协程，把事件参数、共享状态、UI context 按值作为协程参数保存；插件销毁后仍须在访问 `this` 前验证生命状态。其他 read/write/discovery 命名协程也应补完整的 teardown 检查。

### 2. [P1] OHOS 通知缓存 miss 绕过 GATT 串行队列，产生查询风暴并丢数据

位置：[BleNotifyManager.ets:102](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_ohos/ohos/src/main/ets/components/plugin/BleNotifyManager.ets:102)。来源：fork 的 OHOS 通知/缓存实现。

通知回调直接 `await gatt.getServices()`，既不经过 `runGatt`，也不共享进行中的查询。服务变更事件会主动删除该缓存，因此 miss 是正常生命周期的一部分。复现中，20 条同时到达的通知触发 20 次查询；另一个复现让通知与持有 GATT 锁的操作重叠，模拟平台 busy 错误后，本条通知被 catch 吞掉，Dart 收到 0 条事件。

应按设备和连接代次共享一次服务加载，并将底层查询纳入同一个 GATT 调度器。缓存未就绪时需要有界、保序的通知缓冲与可观察的溢出策略，避免每条通知发查询。不要在已持有 GATT 锁的操作内部再次等待同一把锁。

### 3. [P1] OHOS 清理缓存不能隔离旧连接的异步结果和排队操作

位置：[通知查询后的回写](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_ohos/ohos/src/main/ets/components/plugin/BleNotifyManager.ets:106)、[读请求捕获 GATT](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_ohos/ohos/src/main/ets/components/plugin/BleCharacteristicManager.ets:74)、[写请求捕获 GATT](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_ohos/ohos/src/main/ets/components/plugin/BleCharacteristicManager.ets:269)。来源：fork 的 OHOS 生命周期实现。

两个直接复现均成立：旧通知正在等待服务查询时，注销回调、清理缓存并替换连接对象，查询完成后仍把旧服务写回缓存并发出通知；读请求在 GATT 队列中等待时替换连接，它最终仍调用旧 GATT 并回报 success。`isDetached` 在回调入口的检查不覆盖 await 之后的连接变化。

应引入每设备 session generation；入队、开始执行、每个 await 返回后、缓存回写和发事件前均验证代次及 GATT 对象。断连使旧操作失败；新连接只使用自己的缓存和队列状态。保留旧队列尾防止并发绕锁的思路是合理的，但还需要阻止旧代次执行和污染新代次。

### 4. [P1] OHOS 重复服务 UUID 的实例标识冲突，可读写到错误特征

位置：[getInstanceId](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_ohos/ohos/src/main/ets/components/plugin/BleGattShared.ets:125)、[只返回首个服务](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_ohos/ohos/src/main/ets/components/plugin/BleGattShared.ets:213)、[locateCharacteristic](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_ohos/ohos/src/main/ets/components/plugin/BleGattShared.ets:278)。来源：fork 新增 OHOS 路由实现。

复现使用两个同 UUID 的服务，各含一个同 UUID 的特征，value handle 分别为 7 和 17。两个特征都得到 `instance_id=0`，定位第二个特征时实际返回第一个。两个通知也拥有相同的 Dart 路由身份。API<18 的 properties.toString()+描述符数量近似匹配，以及无效 instanceId 回退到首个特征，进一步放大误路由风险。

发现服务时为完整服务树建立稳定、无歧义的实例映射，覆盖重复服务 UUID、重复特征 UUID 和 included services。可用 handle 的平台优先用 handle 标识；找不到精确实例时明确失败，不能静默回退写入第一个特征。

### 5. [P2] 移除全局调用锁后缺少共享初始化 Future

位置：[主包调用入口](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus/lib/src/flutter_blue_plus.dart:624)、[Android 重启判断](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_android/lib/flutter_blue_plus_android.dart:425)、[Linux 初始化](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_linux/lib/flutter_blue_plus_linux.dart:1071)。Darwin/OHOS 适配器存在同类 `_didRestart` 判断。来源：fork 去掉 invoke mutex，以及 Linux 失败后重试的改动。

通过公开 `FlutterBluePlus.isSupported` 和 `adapterName` 并发首次调用，已复现两次 native `flutterRestart`。该方法包含停止扫描、断连与清理缓存，并非无副作用查询。当前验证确认了重复清理入口，未将其表述为已实测丢连接。平台初始化与重启等待应由同一个进行中的 Future 承担，失败后允许重试，正常读写继续按设备并行。

Linux 把 `_initialized=true` 移到 `await _client.connect()` 之后，修复了失败后无法重试，但并发首次调用会同时通过初始判断，重复连接并重复注册尾部 `.listen(null)`；这是源码判断，未连接 BlueZ 复现。也应共享初始化 Future。

### 6. [P2] 请求拒绝、超时和断连后的监听未清理，持续放大事件分发成本

位置：[read 的 .first 监听](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus/lib/src/bluetooth_characteristic.dart:153)、[Future 保护扩展](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus/lib/src/utils.dart:44)。来源：上游遗留，缓存过滤 Stream 的 fork 优化没有消除此问题。

在 native invoke 前创建 `.first`，但 invoke 抛错时没有取消；`Future.timeout` 也不会取消底层 `.first`。保护扩展在断连/关闭时 completeError，却没有取消自己的监听，后续原 Future 完成时还会因 `isCompleted` 跳过清理。

使用生产公开 read 复现：20 次 native 拒绝、5 次响应超时、随后断连，残留 25 个响应监听、5 个连接监听、5 个适配器监听。这些监听不一定永久存在，但在匹配事件到来前会保留并参与分发，部分保护监听还会继续残留。

应使用显式可取消的操作等待对象，所有终止路径统一在 finally 中取消响应、断连、适配器、定时器监听。修复要覆盖 read/write/descriptor/discovery/MTU 等采用同一模式的操作；仅缓存 `.where` 包装器无效。

### 7. [P2] timeout 不覆盖 native invoke，native Future 卡住时会长期占用设备队列

位置：[先 await invoke、再创建 timeout](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus/lib/src/bluetooth_characteristic.dart:165)、[OHOS 等待底层读取](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_ohos/ohos/src/main/ets/components/plugin/BleCharacteristicManager.ets:101)。来源：主包等待结构来自上游，OHOS 等待 native 操作完成后才返回的契约使问题更突出。

复现给公开 read 传入 1ms timeout，让平台方法 Future 保持 pending；20ms 后 read 仍未完成。计时器直到 native invoke 返回后才创建，finally 也无法释放设备 mutex，后续同设备请求继续等待。排队等待时间同样不在当前 timeout 内。

需要明确并实现排队期限、调用期限与 BLE 响应期限。不能仅在外层加 timeout 就放行下一次 GATT 操作：Dart 超时不等于底层已取消，应配合 native 操作代次、隔离迟到回调，必要时重建连接，避免并发撞栈。

### 8. [P2] Dart mutex 每次广播唤醒全部等待者，积压时接近平方成本

位置：[mutex_factory.dart:14](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus/lib/src/mutex_factory.dart:14)。来源：上游遗留；fork 默认 perDevice 减少跨设备竞争，但单设备大量并发写仍使用原算法。

每次 give 都唤醒所有 `.first` 等待者，除下一位外，其余任务再次注册监听。N 个积压请求的唤醒数可达 N(N−1)/2。首次审查的 AOT 微基准中，1,000 个空操作原广播实现 3,563µs，FIFO promise 链模型 156µs；2,000 个分别为 46,601µs、733µs。这里是纯调度成本，不含 BLE I/O，不能推导无线吞吐能提升同样倍数。

改成 FIFO Completer 队列，每次只唤醒下一位；队列设上限、支持取消并统计积压。`_MutexFactory._all` 也不删除已空闲设备项，perDevice 下会随历史设备数增长；回收必须同时保留 setOperationQueueMode 的“已开始工作”状态，不能简单删除 map 项改变 API 约束。

### 9. [P2] Windows included service 通知遗漏主服务身份，Dart 无法匹配

位置：[发现时填写 primary_service_uuid](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_winrt/windows/flutter_blue_plus_winrt_plugin.cpp:1197)、[通知事件](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_winrt/windows/flutter_blue_plus_winrt_plugin.cpp:1231)、[Dart 过滤条件](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus/lib/src/bluetooth_characteristic.dart:108)。来源：fork 新增 Windows 实现；证据为静态契约对照。

发现 included service 时会生成非空 `primary_service_uuid` 的特征对象，但通知事件始终没有这个字段。Dart 要求 primaryServiceUuid 相等，因此该对象的 onValueReceived/lastValueStream 不会收到对应通知。应在发现时保存完整路由身份，读写和通知统一使用。

### 10. [P2] Windows 描述符缓存的存取键不同，公开 API 几乎必然 miss

位置：[按 descriptor handle 存储](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_winrt/windows/flutter_blue_plus_winrt_plugin.cpp:417)、[对外 instance_id 是 characteristic handle](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_winrt/windows/flutter_blue_plus_winrt_plugin.cpp:427)、[read 查询](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_winrt/windows/flutter_blue_plus_winrt_plugin.cpp:1505)、[write 查询](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus_winrt/windows/flutter_blue_plus_winrt_plugin.cpp:1578)。来源：fork 新增 Windows 缓存；证据为静态数据流。

同一 GATT 数据库内，描述符和父特征的 attribute handle 不相同。Dart 把父特征 instanceId 原样传回，无法命中按描述符 handle 保存的缓存。read 随后还把父特征 handle 当 descriptor handle 遍历查找，失败后才执行真正的父特征定位；因此“加了缓存”反而保留对象并增加无效搜索。

保持公共 instanceId 含义，内部改用 `(session, characteristic handle, descriptor UUID)` 索引。重复 discoverServices 目前还不断向 `service_cache_[remote_id]` push 而不替换旧快照，建议一并改成发现成功后按代次原子替换，释放已淘汰资源。

## 优化收益与局限

已确认值得保留的改动：Guid 避免字符串往返；DeviceIdentifier 直接比较字符串（原行为也区分大小写）；请求序列化只写存在的字段；已为 Uint8List 时少复制一次；扫描缺省字段减少空容器；过滤条件合并；Android 复用 Handler、日志格式化前判断等级、复用已查出的主服务；OHOS 按设备绑定回调和缓存服务。

缓存 `.where` 只减少 Stream 包装对象，不会合并订阅，也不会把广播改成按 key 分发。直接运行公开通知流：100 条事件在 10/100/500 个订阅下分别执行 1,000/10,000/50,000 次首级路由比较。Guid 更快能降低每次比较成本，但不改变 O(事件数×订阅数) 的分发方式。

Uint8List 复用减少一次 Dart 拷贝，不是 native ↔ Dart 零拷贝；StandardMethodCodec 仍需编码数据与元信息。Guid.bytes 当前允许外部修改，不宜直接永久缓存其 hash/字符串或将可变 Guid 作为长期路由索引键；内部索引应保存不可变的规范化身份。

Darwin 的 MTU 修复保留连接期间低频兜底：快速阶段 100ms、稳定后 1s、无连接停止，避免上游补丁稳定后完全停止导致漏掉晚到协商。三组实际 Objective-C 插件测试通过；代价是稳定期 MTU 变更检测最多约 1 秒加系统调度延迟。若要进一步优化，优先研究实际传输前刷新可写长度，不应把“短期稳定”等同于“协商永久结束”。

## 微基准

环境：macOS arm64，Dart 3.11.5，Flutter 3.41.10-ohos-1.0.0。Guid 与 mutex 编译成 AOT 可执行文件，预热后取 7 轮中位数；Guid 每轮 100,000 次、256 个变化输入。基准只覆盖所列工作负载。

| Guid 操作 | 上游基线 µs（短/全 UUID） | 当前 µs（短/全 UUID） |
|---|---:|---:|
| parse | 4,814 / 35,574 | 1,628 / 10,299 |
| str128 | 13,985 / 63,431 | 5,591 / 7,303 |
| hash | 17,789 / 66,030 | 5,765 / 7,536 |
| equality | 28,037 / 126,537 | 1,122 / 2,698 |

| 同时排队的空操作数 | 修复前广播 mutex µs | 初审 FIFO 链模型 µs |
|---|---:|---:|
| 100 | 70 | 23 |
| 500 | 1,033 | 110 |
| 1,000 | 3,563 | 156 |
| 2,000 | 46,601 | 733 |

修复后另用脚本抽取仓库中**实际旧 mutex 与实际新 FIFO mutex** 编译比较：1,000 个空操作为 3,563µs → 184µs，2,000 个为 42,565µs → 402µs。上述链模型仅保留作初审历史数据；修复收益以实际实现对比为准。单次结果随主机负载波动，仅代表队列调度开销。

标准 MethodCodec 实测帧长度如下。短身份为 Android MAC+16bit服务/特征，全身份为36字符设备ID+128bit服务/特征。字节数是通道编码长度，不是 ATT 空口包长。

| payload | 当前 MethodChannel 字节（短/全） | 相同字段改位置列表字节（短/全） | 假设预注册 route、16字节帧头 |
|---|---:|---:|---:|
| 20 B | 211 / 294 | 84 / 167 | 36 |
| 244 B | 435 / 518 | 308 / 391 | 260 |
| 512 B | 705 / 788 | 578 / 661 | 528 |

位置列表列使用 StandardMessageCodec，省去字段名和方法名，尚未实现；route 列还要求预先交换映射表，表格不计握手、错误、控制消息和迁移成本。不能直接将字节节省比例当吞吐收益。

保留每条 map 全部元信息的 16 条批量 MethodCall：20B 短身份场景从 3,376B 降至 2,985B（约 11.6%），244B 从 6,960B 降至 6,569B（约 5.6%）。收益主要是把 16 次通道调用减到 1 次；仅把 map 装入数组不会省掉重复 UUID 和字段名。Codec 在 flutter test 进程中的每条编码/解码约微秒量级，受 JIT、预热和调度影响，不用于断言真机瓶颈。

## 下一轮优化顺序

1. **平台验收**：本轮已完成生命周期、取消和 FIFO 修复；下一步在 Windows 构建插件、使用 DevEco 完整 ArkTS 检查，并真机验证断连重连、超时后迟到回调、服务变化和重复 UUID。
2. **算法**：FIFO 队列已替换广播锁；后续可让 Dart 建立一个按不可变完整身份分发的路由器，单事件只投递给匹配监听者，并统一完成操作等待；native 在发现时建立 characteristic 对象/handle → 路由身份索引，通知回调不再扫描服务树、分配匹配数组和重复构造 UUID。连接/服务代次变化时使索引失效。
3. **减少高频事件工作量**：主包每条事件还会拼 UUID 字符串更新 lastValue，适合复用不可变路由 key。扫描列表目前 indexOf 更新 O(N)，每次发出 List.from 快照仍 O(N)；用 device→index 映射减少查找，再为需要设备列表的 UI 提供可选 16–50ms 快照节流，保留 oneByOne 行为。
4. **可选批处理与流控**：通知以“达到 N 条/字节上限，或达到延迟预算”触发批量，带 session、序号、长度校验和队列上限，保证保序且不静默丢数据。批窗口可从 1–4ms 测起；追求延迟的用户仍可逐条。扫描可以配置降采样，数据通知不能照搬 continuousDivisor 丢包。
5. **大量写入**：提供单次平台调用入队多个 payload 的可选路径，native 按 BLE 栈能力逐个提交；无响应写入按 canSend/write回调或平台等价能力流控，有响应写入仍遵守 ATT 顺序。小写入不宜为了“提高并发”直接绕过 GATT 串行化。
6. **最后评估紧凑二进制通道**：高频 payload 可单独使用 BasicMessageChannel + BinaryCodec，低频控制维持现有协议。先比较位置列表和批处理，只有 profile 数据证明 codec/元信息构造占比高时，再承担自定义协议的兼容成本。BasicMessageChannel 本身不保证零拷贝。

真机验收应使用 profile/release、实际 BLE 外设，记录收发序号、丢失/重复/乱序、有效 payload B/s、端到端 p50/p95/p99、native/Dart CPU、分配/GC、UI 帧耗时、积压长度和内存上界。覆盖 20/244/512B、1/多设备、1/多特征、单向/双向、持续扫描、重连和 Service Changed；同一硬件分别跑基线、当前、候选版本。原有试验性二进制实现已经回退，不能引用其历史数字作为当前收益。

## 验证与复现

修复后 Flutter 全量测试 **85/85**、OHOS 生产管理器 mock 测试 **19/19**、Darwin 完整插件 native 场景 **3/3** 通过。最后补充的适配器关闭场景另重跑生命周期测试通过。主包、三个通道适配器和 Linux 的 Dart 分析无问题；18 个 ETS 文件进行 TypeScript 语法/语义检查，排除不可用 native SDK 导入后无其他诊断。这些检查不能替代 ArkTS SDK 编译、Windows 原生构建或 BLE 真机测试。

正式回归入口：

- `packages/flutter_blue_plus/test/transport_startup_test.dart`：三个适配器并发首次调用及失败重试。
- `packages/flutter_blue_plus/test/transport_lifecycle_test.dart`：拒绝、响应和 native 调用超时、迟到错误、断连/适配器关闭、FIFO、排队取消和空闲回收。
- `packages/flutter_blue_plus_linux/test/startup_test.dart`：共享初始化与失败重试。
- `packages/flutter_blue_plus_ohos/test/transport_regression.test.cjs`：真实 ETS 管理器的缓存/队列/session/路由回归。

审查目录的启动、监听、OHOS 入口现已委托到安全行为回归断言。C++ ASan 用例默认验证安全的命名协程参数模型，预期正常退出；仅加 `-DFBP_REPRODUCE_OLD_CLOSURE` 才启用原临时闭包的故障复现。公开事件分发计数和 Codec 用例仍是优化空间的观察工具，不代表已实现集中路由或新协议。

仓库根目录执行：

```sh
FBP_TYPESCRIPT=/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript/lib/typescript.js \
  node --test packages/flutter_blue_plus_ohos/test/*.test.cjs
python3 docs/reviews/transport_audit/run_benchmarks.py
python3 packages/flutter_blue_plus_darwin/test/run_native_tests.py
clang++ -std=c++20 -O1 -g -fsanitize=address -fsanitize-address-use-after-scope \
  docs/reviews/transport_audit/coroutine_lifetime.cpp -o /tmp/fbp-coroutine-audit
/tmp/fbp-coroutine-audit
```

在 `packages/flutter_blue_plus` 执行：

```sh
flutter test --no-pub ../../docs/reviews/transport_audit/startup_observation_test.dart \
  ../../docs/reviews/transport_audit/listener_observation_test.dart \
  ../../docs/reviews/transport_audit/fanout_observation_test.dart \
  ../../docs/reviews/transport_audit/codec_benchmark_test.dart --reporter expanded
flutter test --no-pub test ../flutter_blue_plus_linux/test ../flutter_blue_plus_platform_interface/test \
  ../flutter_blue_plus_android/test ../flutter_blue_plus_darwin/test ../flutter_blue_plus_ohos/test
```

OperationQueueMode 默认值文档已同步为 perDevice。Linux 的真实 BlueZ 初始化和 Windows 路径仍需各自系统的集成测试；当前没有真机无线吞吐、功耗或丢包率测量结果。


## 复测与 LiberLive 实际交互要求

本节为用户指出旧端位置后补充的性能分析。仅定向读取 `/Users/shingo/develop/LiberLive/liberlive-flutter` 的设备实现，未修改该项目、安装 App 或连接外设。Android `23400d470b34fa70d7758c153f63aeaf5db3ca04`、iOS `dc9fb3ace4f0fe607eb0da5f5f6c782c0bbe756e` 与其迁移基线一致；旧 Flutter module 当前为 `1faae38f35c1f9ac4d83ae343870d18b72a57bcf`。HarmonyOS 当前 `3862f2f1ae9e9c8928c76f0dfd1fec124813c2e7` 比迁移基线新，以下明确作为当前 checkout 的补充事实，不替代冻结基线。

### 最新实测：算法与编码

环境仍为 macOS arm64、Dart 3.11.5。mutex/Guid 使用 AOT，预热后取 7 轮中位数；两种 mutex 都由脚本抽取真实源码，旧版来自共同祖先，新版来自当前工作区。表内为整批排队空操作的完成时间，没有 BLE、native engine hop、业务协议或新操作 scope；不是某一条设备命令的延迟，也没有 p99 结论。

| 同时排队的空操作数 | 原广播 mutex | 当前 FIFO mutex | 原耗时/当前耗时 |
|---:|---:|---:|---:|
| 100 | 74µs | 25µs | 2.96× |
| 500 | 1,204µs | 146µs | 8.25× |
| 1,000 | 3,694µs | 200µs | 18.47× |
| 2,000 | 50,024µs | 400µs | 125.06× |

Guid 对比是“上游共同祖先 → 当前 fork”，不是“本轮修复前 → 本轮修复后”。以 128bit UUID、100,000 次操作为例：parse 35,106µs → 10,532µs；str128 62,020µs → 6,381µs；hash 67,689µs → 7,549µs；equality 125,982µs → 3,048µs。能证明局部算法收益，不能推导相同比例的链路收益。

按旧端业务数据区尺寸补跑 Codec 场景：

| 送入通道的 value 长度 | 当前帧字节：短身份/全身份 | 位置列表候选：短身份/全身份 | 当前 Dart 编码+解码平均耗时：短身份/全身份 |
|---:|---:|---:|---:|
| 3B | 194 / 277 | 67 / 150 | 1.257 / 1.008µs |
| 4B | 195 / 278 | 68 / 151 | 0.970 / 0.999µs |
| 6B | 197 / 280 | 70 / 153 | 0.915 / 1.032µs |
| 7B | 198 / 281 | 71 / 154 | 0.938 / 0.991µs |
| 490B | 683 / 766 | 556 / 639 | 1.120 / 1.070µs |

耗时由各 2,000 次编码和解码的批次中位数相加后除以 2,000，运行于 flutter test；不是单条采样的 p50/p99，也不包含 native 编码、跨线程调度、engine、业务反序列化和 OS/BLE。帧字节沿用 `OnCharacteristicReceived` 的元信息结构；写入的消息结构不同。旧端 3–7B 指的是协议解码后的业务数据，实际 BLE value 还包含 TLVC/命令封装；这里是对应小数据区尺寸的合成测试，不冒充旧端抓包。位置列表仅是实验候选，生产协议未修改。

公开通知流复测仍为：100 条事件 × 10/100/500 个监听者，对应 1,000/10,000/50,000 次首级路由比较。这是实际生产流的分发计数，提示下一步应优化集中路由；不是通信延迟数据。

原始运行入口为本报告中的 `run_benchmarks.py`、`fanout_observation_test.dart` 和 `codec_benchmark_test.dart`，后者已补充 3/4/6/7/490B 场景。最新本机原始输出位于 `/tmp/fbp-transport-benchmark-20261017.log`、`/tmp/fbp-codec-liberlive-20261017.log`；临时文件不作为长期结果的唯一来源，关键数值已列于本节。

### 从旧端确认的要求

| 旧端场景 | 源码事实与依据 | 对插件性能验证的要求 |
|---|---|---|
| C1 自动单音 | [playRhythmByC1](/Users/shingo/develop/LiberLive/liberlive-flutter/references/ios/Project/Main/playAndConfig/Play/tool/PlayTracksSongTool+.swift:18) 使用独立 userInteractive 队列上的 DispatchSourceTimer；[定时器](/Users/shingo/develop/LiberLive/liberlive-flutter/references/ios/Project/Main/playAndConfig/Play/tool/PlayTracksSongTool+.swift:44) 设置 2ms leeway，按 BPM/音符偏移安排发送 | 要测计划发送时间到实际提交及发音的抖动；2ms 是定时器配置容差，不是已证明的端到端 SLA，不能直接翻译为 Dart Timer 等价 |
| 实时演奏上报 | Android [onNotiChord](/Users/shingo/develop/LiberLive/liberlive-flutter/references/android/m_machine/src/main/java/com/ll/machine/core/receiver/C2NotifyReceiver.kt:348) 读取 6B 和弦业务字段；同文件单音读取 4B、鼓机读取 3B；已看的字段不携带设备采样时间戳 | 小包迟到、重复、乱序都可能改变行为；应在原生回调入口尽早记录单调时钟和连接代次/序号，不能只在 Dart 收到后开始计时 |
| U1 输入与评分 | [输入观察](/Users/shingo/develop/LiberLive/liberlive-flutter/references/android/m_music/src/main/java/com/ll/music/gameguide/activity/GameGuidePlayActivity.kt:170) 对相邻成功输入做 50ms 过滤；[ScoreUtils](/Users/shingo/develop/LiberLive/liberlive-flutter/references/android/m_music/src/main/java/com/ll/music/gameguide/utils/ScoreUtils.kt:65) 采用整数拍长/8 的完美窗口，BPM 50/70/90 对应 ±150/107/83ms | 50ms 是防重复规则，评分窗口也是业务判定范围，两者均非允许的通信延迟。变动的传递延迟会改变边界结果，应比较事件间隔误差及 p99/p99.9 |
| 实时播放命令优先级 | Android [CmdPriority](/Users/shingo/develop/LiberLive/liberlive-flutter/references/android/m_machine/src/main/java/com/ll/machine/enums/CmdPriority.kt:10) 把 PLAY_NOTE 放在 CREATE_MUSIC 和 NORMAL 之上；[playNote](/Users/shingo/develop/LiberLive/liberlive-flutter/references/android/m_machine/src/main/java/com/ll/machine/core/cmd/C2Cmd.kt:1400) 为 6B 业务数据 | FIFO 解决唤醒成本，不提供业务优先级；上层应在有界调度器中选择下一条，再提交插件，不能把大量低优先级 Future 预先塞满插件队列。已有大块复合任务也不一定可抢占 |
| 曲谱 bulk 与 seek | Android [MusicSenderV1](/Users/shingo/develop/LiberLive/liberlive-flutter/references/android/m_machine/src/main/java/com/ll/machine/core/MusicSenderV1.kt:380) 使用最多 490B 片段顺序发送；[CmdSender](/Users/shingo/develop/LiberLive/liberlive-flutter/references/android/m_machine/src/main/java/com/ll/machine/core/cmd/CmdSender.kt:190) 对部分完整指令拒绝 ≥500B；[MTU 请求](/Users/shingo/develop/LiberLive/liberlive-flutter/references/android/m_api/api_machine/src/main/java/com/up/machinecontrol/api/BluetoothManager.kt:528) 为 512；V2 预填数据并在 seek 时优先补目标位置 | 需要真实 MTU/可写长度、持续有效 B/s、bulk 期间控制延迟；490B 是旧端实现选择，不能忽略 MTU−3 和平台返回的可写长度照搬 |
| 多轨定位与准备完成 | Android [CmdMusicPositionBean](/Users/shingo/develop/LiberLive/liberlive-flutter/references/android/m_machine/src/main/java/com/ll/machine/model/cmd/CmdMusicPositionBean.kt:12) 为 5+2×轨道数 B；V2 有 5s 跳转就绪兜底 | 测“收到固件 ready”及用户操作到生效；5s 是失败兜底，不能解释为交互性能目标 |
| 不同写入确认语义 | Android CmdSender 无响应指令调用 writeNoRsp，读取指令为先 write 后 read；iOS [sendA1Data](/Users/shingo/develop/LiberLive/liberlive-flutter/references/ios/Project/Device/BLE/UKBLEManager+A01.m:511) 使用 WithResponse | WriteWithoutResponse/ATT 写成功/业务 ready/外设已执行是不同终点。旧端与 Flutter 对比必须先统一终点与写类型 |
| HarmonyOS 当前普通队列 | [bleQueue.ts](/Users/shingo/develop/LiberLive/liberlive-flutter/references/harmonyos/commons/bluetooth/src/main/ets/ble/bleQueue.ts:39) 默认任务启动间隔 100ms，支持 High 优先级，当前 bluetooth 源码未找到 setInterval 调用；写路径由 helper 入队 | 是这一旧端实现的人为启动间隔，不是 BLE 或 flutter_blue_plus 的固有限制。不能机械移植，也不能据此声称 Flutter 实测提升 100ms |

新 Flutter App 的 Instrument Device 当前仍是内存 mock，旧 module 中确认的 DeviceCapabilityChannel 只读宿主能力快照，因此现有新 App/mock 测试不能代表这个插件已接入真实演奏链路。

### 对精确交互的判断与后续验证

现有数据足以确认 FIFO 在积压时大幅减少调度浪费、Guid 局部算法有效、通知分发仍有 O(事件数×监听数) 空间；**不足以确认比原生旧端更快、满足某个设备交互截止时间，或证明本轮新增 scope 在正常单次请求路径没有额外开销**。完整公开请求路径的前后 A/B、native→Dart engine 调度 p99、外设执行精度仍缺数据。

推荐按以下顺序推进，并保持协议兼容：

1. 优先建立单调时间戳和完整路由的观测边界：请求入队/出队、native 提交、native 回调、Dart 分发及业务 ready。跨 native/Dart 时钟须校准，不能直接相减不同时间基准；没有设备采样时间戳或外部测量时，不能从主机通知推断实体触发到通知的真实延迟。
2. 优化 Dart 集中事件路由，减少每条演奏通知遍历全部订阅；读取/写入等待和订阅共享路由底座，仍保证连接/服务代次隔离。
3. 在设备能力 Owner 建立有界的业务优先级调度，bulk 按小批次逐次提交，实时 play/seek/stop 能在批次边界进入；同设备 GATT 仍须遵守串行化和 native 流控。
4. 对 C1 等由主机定时的关键路径，先比较“原生调度保留”与“Flutter 发单次命令”的 p99 抖动；若后者不满足回归要求，应保持有界原生时间表/发送器，Flutter 负责提前提交和控制。设备支持预加载和固件节拍时继续使用该能力，避免把每个节拍变成即时 Dart 往返。
5. 在证据确认之前，演奏事件不做 debounce/降采样，也不默认加入通知批窗口；不要为吞吐增加固定 1–4ms 延迟。对 bulk 可另测可选批提交，保留低延迟逐条路径。

验收矩阵：Android/iOS/OHOS × C1/C2/C2N/U1 的适用功能，固定手机、OS、固件、距离、MTU/PHY/连接参数及写类型，比较原生旧端、修复前 fork、当前修复版。单次和真实峰值负载都测；分别覆盖空闲、曲谱持续填充、UI 动画/音频、GC、切换设备和重连。记录 p50/p95/p99/p99.9/max、抖动、deadline miss、丢失/重复/乱序、有效 payload B/s、队列长度、CPU/GC。声称外设按时执行须有设备回执时间戳，必要时用音频/逻辑分析仪测量。p99.9 需要足够样本且按负载场景分组，不能把热身或不同设备合并掩盖尾部。

没有找到可直接作为产品验收门槛的“桥接 p99 ≤ Xms / 固件执行抖动 ≤ Yms”正式要求；旧端源码给出工作负载与敏感点，绝不补造 SLA。下一轮性能改动应先记录上述基线，再决定目标与是否需要原生调度支持。
