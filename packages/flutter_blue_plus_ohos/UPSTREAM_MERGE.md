# OHOS 上游合并记录（2026-09-15）

## 来源与范围

- 仓库：https://atomgit.com/CPF-Flutter/fluttertpc_flutter_blue_plus
- 分支：`br_2.1.0_ohos`（远端 HEAD，已重新查询确认）
- 提交：`83185cfaa2f0920ebf4955633e2c2c7ebb9b4feb`
- `master` 最新提交为 `9267f87fa28327a5d658664006337af7c68e0a1c`，但仍为旧的 1.32.8 单包结构；选用与本仓库匹配的默认分包分支。
- 合入 OHOS 插件全部原生管理器、共享工具、上游 Dart 通道测试及许可证、分析配置。
- 保留当前 9.0.3 包版本、平台接口依赖和本地路径覆盖。上游 Dart 适配器与本地相同，无需替换。未引入上游旧版本的其他平台或示例宿主配置。

## 合入的主要行为

1. 拆分扫描、连接、配对、GATT、通知、MTU、权限和方法分发模块。
2. 为读写、服务发现等操作增加按设备串行队列，避免同设备操作交叠；不同设备可独立执行。OHOS 官方 BLE API 文档要求等待读写回调完成后再发起下一次操作，忙状态对应 `2900011`。
3. 读写复用已发现的服务，服务重置时失效缓存。原实现每次写特征都会调用 `getServices()`；合入后的管理器测试中，两次写操作仅调用一次。
4. 通知回调绑定设备 ID，消除原实现遍历所有已连接设备、按 UUID 猜测来源的行为；相同 UUID 的多设备事件仍归属各自设备。
5. 精确取消监听、释放临时 GATT 对象，并加强引擎/Ability 生命周期清理。
6. 保留上游连接失败 `UNKNOWN_HCI_ERROR(1)` 上报、通道布尔返回值修正及通用 GATT 错误不盲目重试的处理。

## 本地兼容修正

- `BleNotifyManager`：保留本地缺少 CCCD 时返回明确错误的契约，避免上游的 `success(false)` 让 Dart 层静默完成。
- `GattCacheHolder`：队尾完成后删除对应锁条目；`clearAll()` 保留仍在等待或执行的队列，直到队尾自行释放。合入原代码时测试复现了已完成条目残留，以及清空缓存后新操作越过旧队列的问题，修正后均通过。
- 标准 MethodChannel 和 Uint8Array 数据协议不变，没有恢复此前回退的独立二进制通道。

## 验证与边界

- Flutter 3.47.3 / Dart 3.13.3：81 个 Android/Darwin/OHOS 公共 API/适配器回归测试及 56 个上游 OHOS 通道测试，共 137 个通过。
- OHOS 包 `dart analyze lib test` 无问题；公共 Dart 层仍有原有的 `unawaited_return_in_try_block` 告警，本次未更改该行为。
- 8 个原生管理器测试通过：直接转译生产 `.ets` 源码后执行，替换 OHOS 系统 API，覆盖队列顺序与异常恢复、队列清理、多设备事件归属、通知缓存与失效、CCCD 错误、字节子视图写入、失败不重试及通道返回类型。它们验证逻辑，不测量 ArkTS/BLE 实际延时。
- OHOS Flutter 3.41.10-ohos-1.0.0：`flutter build hap --debug --no-pub` 成功，编译缓存包含新管理器及修正后的 `GattCacheHolder`。
- 已签名 HAP 安装到 HUAWEI Mate 60 Pro 并成功启动，随后确认应用进程仍在运行。日志查询未返回可用应用日志，未据此声称无运行时错误。
- 没有 BLE 外设：真实连接、GATT 读写/通知、MTU、配对、断线重连及无线链路性能未验证。不能以模拟逻辑测试代替真机 BLE 性能或保证所有场景无副作用。

复现管理器测试（仓库根目录，使用 DevEco 自带 TypeScript，无需安装依赖）：

```sh
FBP_TYPESCRIPT=/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js \
  node --test packages/flutter_blue_plus_ohos/test/native_integration.test.cjs
```

在 `packages/flutter_blue_plus/` 下运行跨平台 Dart 回归：

```sh
flutter test --no-pub test ../flutter_blue_plus_ohos/test/flutter_blue_plus_ohos_test.dart
```
