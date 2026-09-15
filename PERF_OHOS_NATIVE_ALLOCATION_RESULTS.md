# OHOS 原生分配归因结果

日期：2026-09-15。数据来自本仓库 `packages/flutter_blue_plus/example` 的 OHOS Flutter 宿主和 HUAWEI Mate 60 Pro 真机。测试使用 example-only 的 `echo` 控制通道模拟平台往返，不代表真实 BLE/GATT 或空口行为，也没有修改生产插件通信实现。

## 结论

7,000 次 4,096 B `Map + Uint8List` echo 调用后，原生分配跟踪和 ArkTS 堆快照共同指向：**Engine 的 OHOS 消息投递路径创建的 ArrayBuffer 被 N-API local handle 持有，完成调用后未在可观察时间内释放**。这是当前最强的内存增长归因证据。

这仍不是已确认的源码级修复点。设备上的 `libflutter.so` 为裁剪符号，调用栈只能定位到偏移，尚不能断言具体 C++ 函数或哪一个 scope 没有关闭。由于该问题属于 OHOS Flutter Engine 范围，本插件项目暂不跟进 Engine 修复，也不将其作为插件交付阻塞项。

## 真机证据

### 原生分配栈

有效运行 `2026-09-15-native-hook-run4`：2 轮 × 3,500 次，共 7,000 次，全部校验通过。关键 callchain 768：

```text
libuv.so
  -> libflutter.so +0x3d5228
  -> libflutter.so +0x3baf6c
  -> napi_create_arraybuffer
  -> panda::ecmascript::NativeAreaAllocator::AllocateBuffer
  -> alloc size(5120bytes)
```

该链累计申请 7,000 次、释放 0 次，申请/未释放统计均为 35,840,000 bytes（约 34.18 MiB）。这是 nativehook 的采样统计；小于采样阈值的分配可能按概率采样，不能把所有统计行当作穷尽清单。

ArkTS GC 探针运行 `2026-09-15-native-hook-arkgc` 后，ArkTS GC 次数由 20 增至 22，heapUsed 由 12,269 KB 降至 9,082 KB；关键 7,000 个分配仍为 0 次释放。其他 codec buffer 链出现了释放，说明探针确实触发了运行时回收，而不是只记录了请求。

### 堆快照持有者

GC 后导出的 ArkTS heap snapshot：

- `LocalHandleRoot`：14,579 个 local handles；
- 直接由该 root 引用的唯一 `ArrayBuffer`：7,020 个；
- 其中恰好 7,000 个通过 `ArrayBufferData` 指向 `JSNativePointer(native_size=4227)`；
- 其余 20 个是初始化/控制消息相关的小 buffer。

示例引用路径：

```text
LocalHandleRoot[14579]
  -- element[...] --> ArrayBuffer
  -- property "ArrayBufferData" --> JSNativePointer(native_size=4227)
```

`4227` 是堆快照记录的逻辑/native binding 大小，nativehook 中的 `5120 B` 是分配器采样大小；两者统计口径不同，不能相乘或宣称每次泄漏固定 4227/5120 字节。

## 如何解读

证据排除了“只有 Dart heap 没有回收”这一解释，也不符合 characteristic stream 缓存单独持有这些对象：测试没有真实 GATT 设备，且持有者在 Engine/N-API 的 local handle 根。若未来升级 OHOS Flutter Engine，可将该实验作为回归基线；当前插件侧不围绕该外部问题设计规避性协议改造。

Node-API 生命周期资料明确要求临时 `napi_value` 在 handle scope 结束时释放，scope 必须在 native 方法返回前关闭；长期保存对象应显式管理 `napi_ref`，并在不需要时删除。该规范支持上述检查方向，但不等于已证明 Engine 的具体实现违反了它。

## 限制与失败尝试

- `run`、`run2` 为 profiler 启动握手失败的 idle-only/无效采集；`run3` 在混合 JS stack 配置下未进入有效 baseline。它们不参与结论。
- 有效 run4 同时调整了初始化时机和 nativehook 配置（关闭 JS stack、降低采样干扰），因此不能归因于单一 workaround。
- nativehook 的 type 数字枚举尚未从 SDK 源码核实；报告只使用 callchain 和具体符号，不把 type 0/1/2 命名成未经证实的类别，也不把不同 type 的总量相加。
- PSS、malloc allocator、ArkTS heap 和 Dart heap 不是同一统计层，不能互相相加重建进程内存，也不能据此解释原始约 575 MiB PSS 的全部来源。
- 没有真实 BLE 外设，GATT 回调、无线链路、MTU、锁等待和空口吞吐未测量。

## 原始文件与复现

- [run4 原始目录](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus/example/perf_results/2026-09-15-native-hook-run4/)
- [GC 探针原始目录](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus/example/perf_results/2026-09-15-native-hook-arkgc/)
- [nativehook 配置](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus/example/tool/native_hook.pbtxt)
- [原生汇总器](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus/example/tool/summarize_native_hook.mjs)
- [堆快照汇总器](/Users/shingo/develop/hujie/flutter_blue_plus/packages/flutter_blue_plus/example/tool/summarize_ark_heap.mjs)

解析命令（在 `example` 目录）：

```sh
node tool/summarize_native_hook.mjs perf_results/2026-09-15-native-hook-run4/native.db /tmp/native_summary.json
node tool/summarize_ark_heap.mjs perf_results/2026-09-15-native-hook-arkgc/ark_after_gc.heapsnapshot /tmp/ark_heap_summary.json
node --test tool/summarize_memory_pair.test.mjs
```

该结果作为外部 Engine 风险基线保留。插件侧下一步验收应回到分段通信延时、事件分发开销、并发背压和 API 语义；不把二进制传输重做或 Engine 调试作为默认修复。
