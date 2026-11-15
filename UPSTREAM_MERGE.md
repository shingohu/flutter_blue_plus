# 上游同步指南

本文档记录本仓库的两条上游线、检查与合并流程,以及每次同步的实际结果。目的:在不改动 `remote` 配置、不污染工作区的前提下,快速判断上游是否有值得合并的更新。

> 本仓库是 fork,`origin` = `shingohu/flutter_blue_plus`。**上游 ≠ origin**:上游是别人维护的源仓库,你对它没有写权限,不要尝试向上游推送或删除分支/tag。

## 1. 上游仓库清单

本项目的上游分成两条互不相干的线,必须分开检查——GitHub 主线至今没有 OHOS 代码。

| 线 | 平台 | 仓库 | 关键分支 | 连接方式 |
|---|---|---|---|---|
| 主线 | iOS / Android / Linux / Windows / Web | `chipweinberger/flutter_blue_plus` (GitHub) | `master`、`feature/native-bluetooth-packages`、`feature/semi-federated`、`fix/ios-mtu-poll-lifecycle` | ⚠️ 本机代理下 HTTPS 会超时,**必须用 SSH**:`git@github.com:chipweinberger/flutter_blue_plus.git` |
| OHOS | HarmonyOS | `CPF-Flutter/fluttertpc_flutter_blue_plus` (AtomGit) | `br_2.1.0_ohos`(合入基线)、`br_v2.3.14_ohos_dev`、`br_3.41_dev` | HTTPS 正常:`https://atomgit.com/CPF-Flutter/fluttertpc_flutter_blue_plus` |

OHOS 线的详细合入记录见 `packages/flutter_blue_plus_ohos/UPSTREAM_MERGE.md`。

## 2. 检查流程(非侵入)

不需要恢复 `remote` 配置。用 URL 直接 `fetch` 到临时命名空间,对比后删除临时引用。全程不改 remote、不改工作区、不产生提交。

```sh
REPO=/path/to/flutter_blue_plus

# 1) 拉主线(SSH)到临时命名空间
git -C "$REPO" fetch --no-tags git@github.com:chipweinberger/flutter_blue_plus.git \
  'refs/heads/master:refs/check-gh/master' \
  'refs/heads/feature/native-bluetooth-packages:refs/check-gh/feature/native-bluetooth-packages' \
  'refs/heads/feature/semi-federated:refs/check-gh/feature/semi-federated' \
  'refs/heads/fix/ios-mtu-poll-lifecycle:refs/check-gh/fix/ios-mtu-poll-lifecycle'

# 2) 拉 OHOS 线(HTTPS)到临时命名空间
git -C "$REPO" fetch --no-tags https://atomgit.com/CPF-Flutter/fluttertpc_flutter_blue_plus.git \
  'refs/heads/br_2.1.0_ohos:refs/check-atomgit/br_2.1.0_ohos' \
  'refs/heads/br_v2.3.14_ohos_dev:refs/check-atomgit/br_v2.3.14_ohos_dev' \
  'refs/heads/br_3.41_dev:refs/check-atomgit/br_3.41_dev'

# 3) 对比更新量
git -C "$REPO" log --oneline origin/master..refs/check-gh/master          # 主线领先提交
git -C "$REPO" rev-list --count origin/master..refs/check-gh/master       # 主线领先数量
git -C "$REPO" log --oneline <OHOS基线>..refs/check-atomgit/br_2.1.0_ohos # OHOS 更新

# 4) 清理临时引用(务必执行)
git -C "$REPO" for-each-ref --format='delete %(refname)' refs/check-gh refs/check-atomgit \
  | git -C "$REPO" update-ref --stdin

# 5) 确认仓库未被改动
git -C "$REPO" status -sb
```

### 常见坑

- **GitHub HTTPS fetch 超时**:本机代理下报 `curl 28 ... after 75000 ms`,改用 SSH 即可。
- **zsh 批量 push 参数展开**:`git push $url $args`($args 为空格拼接字符串)在 zsh 下不会拆词,整串被当成一个 refspec,报 `src refspec does not match any`。要用数组:`typeset -a args; args+=(":refs/tags/$t"); git push "$url" "${args[@]}"`。
- **管道退出码陷阱**:`git push ... | grep -v` 拿到的是 `grep` 的退出码,会误判成功。检查 `$?` 要直接跟在 `git push` 后。
- **tag 与依赖**:各 federated 子包的 `pubspec.yaml` 通过 git ref 引用 `2.0.4`。删除 tag 前先确认没有 pubspec 引用它,否则会破坏依赖解析。

## 3. 同步结果

### 2026-11-16 深度代码对比

基线:本地 `master` / `origin/master` = `6e9d847e`(tag `2.0.4`);共同祖先 `70134845`(上游 2.3.11);OHOS 合入基线 = `83185cfa`。上游 commit 与 11-15 检查一致,无新提交。上游 23 个提交已逐个 `git show` 审查实际 diff,并用代码 grep 验证本地实现。

#### 3.1 最重要的结论:实质修复本地已全部移植

本地提交 `69ca9dcb`(2026-10-18 `fix: harden BLE transport lifecycle and callback isolation`)已把上游 2.3.x 的关键 bugfix **手工移植**进来,提交说明明确写着 "Integrate upstream fixes **without license changes**"。逐项核对:

| 上游提交 | 修复内容 | 本地状态 |
|---|---|---|
| `23469211` / `0bee5040` | Darwin MTU 只在未稳定时轮询 | ✅ 已有 `peripheralMtuStableTicks` / `kMtuPollInterval` / 自适应慢轮询 |
| `e750e798` | Android 无 BLUETOOTH_CONNECT 读设备名不崩溃 | ✅ 已有 `safeDeviceName()` + `ensurePermissions` 拒绝时返回空名 |
| `6f3960e5` | 忽略重复 connected 回调 | ✅ 已有 duplicate connection 守卫 |
| `fcf66c06` | 忽略过期连接状态回调 | ✅ 已有 `handleUnexpectedConnectionEvents` 按 GATT 对象匹配 |
| `8da57955` | Darwin 遇受限 UUID 继续发现 | ✅ 已有 `CBErrorUUIDNotAllowed` 跳过逻辑 |
| `2a0079e1` | mutex 只唤醒下一个排队操作 | ✅ 本地已用 `Queue<_MutexWaiter>` FIFO 实现 |
| `ec2d2572` | write 去掉多余 `Future.value()` | 上游 Dart 层微优化,本地无(无实质影响) |

> 注意:patch-id 对比显示 23 个提交全部"不匹配",但这是**假阴性**——本地是从 AtomGit OHOS 线移植的等价实现,代码细节不同。以代码 grep 为准,不要据 patch-id 判定落后。

#### 3.2 明确不合并:授权 / license 部分

这是用户要求**明确排除**的类别,本地有意与上游分道扬镳:

| 上游提交 | 内容 | 原因 |
|---|---|---|
| `3a2c0606` `license(1.6): add global tier` | 许可证升至 1.6,新增 Global 企业档 | 授权条款,本地 `69ca9dcb` 明确 "without license changes" |
| AtomGit 线上大量 `[License]` 提交 | 商业授权分层、license ping、tier 调整 | 同上 |
| 本地 `flutter_blue_plus_permission` 包及 `7b8455e3` 等 | iOS 受限蓝牙授权拒绝逻辑 | 本地定制,上游主线无此包,不会被覆盖 |

**主线 23 个提交中无任何提交触及 permission / authorization 文件**,授权部分天然不会被合并进来。

#### 3.3 主线其余提交评估

| 提交 | 类别 | 处理 | 理由 |
|---|---|---|---|
| `42da544a` `e5ec4ba4` `e9a3b45e` | Linux 修复(重复 UUID、发现阻塞断连、重复事件) | 不合并 | 上游 Linux 后端已大重构(拆 `src/linux_*`),本地 Linux 是旧结构,cherry-pick 无干净基线 |
| `5ebfd259` `1e3bd095` | Linux 后端重构(1155+/1131-) | 不合并 | 纯结构重组,无新功能,风险大于收益 |
| `d04db72f` `49154276` `23261064` | Windows 依赖版本约束 | 不合并 | 本地目标平台排除 Windows |
| `50eabf44` | `setLogLevel({bool color})` 类型标注 | 可选 | 1 行类型收紧,价值极低 |
| `af251490` `65494c2b` | 注释精简 | 不合并 | 无功能影响 |
| `9d3c2180` `b9078b40` `e6174b33` `f8bcf30a` | Release 2.3.12~2.3.15 | 不合并 | 版本提交,本地走自己的 2.0.x 线 |

#### 3.4 Feature 分支

| 分支 | 独有提交 | 处理 | 理由 |
|---|---|---|---|
| `fix/ios-mtu-poll-lifecycle` | 1(`0bee5040`) | 不合并 | 与主线的 MTU 修复相同,本地已移植 |
| `feature/semi-federated` | 1(`2b8bfc78`) | 不合并 | 整个仓库目录重构(文件大迁移),破坏本地布局 |
| `feature/native-bluetooth-packages` | 27 | 不合并 | 新增 `android_bluetooth` / `core_bluetooth` 两个全新包,API 大改,需专项评估 |

#### 3.5 OHOS(AtomGit)

| 分支 | 相对基线 `83185cfa` | 处理 | 理由 |
|---|---|---|---|
| `br_2.1.0_ohos` | 0 提交,`.ets` 无改动 | 无需合并 | 本地已与合入基线持平 |
| `br_v2.3.14_ohos_dev` | 178 提交,但 `.ets` 仅 `c78bc9b4` 一个实质提交 | 暂不合并 | 该提交为 Flutter 3.41/3.44 兼容 + `requestConnectionPriority`/`setPreferredPhy` 新 API + 大量单测;178 提交其余为 GitHub 主线同步/license/文档,且含授权改动,需单独 cherry-pick `.ets` 部分并跑转译测试 |
| `br_3.41_dev` | 0 提交 | 无需合并 | 与基线持平 |

#### 3.6 总结论

**当前没有必须合并的内容。** 实质 bugfix 本地已通过 `69ca9dcb` 全部移植;剩余上游更新要么是本地明确不要的**授权/license 改动**,要么是跨大版本的结构重构、Windows 修复、版本提交,合并风险大于收益。

唯一潜在有价值但需专项评估的是 OHOS `c78bc9b4` 的 Flutter 3.41/3.44 兼容与新 API——如确实需要,应只 cherry-pick `.ets` 部分并验证,不带入授权改动。本次仅检查,**未做任何合并**。

## 4. 合并策略

- **授权 / license 改动一律不合并**(用户明确要求):上游 `license(1.6)` 及 AtomGit `[License]` 系列、本地 `flutter_blue_plus_permission` 定制均保持独立。
- 合并前先用代码 grep(而非 patch-id)核对本地是否已有等价实现——本地 2.0.4 是从 AtomGit 移植的定制线,patch-id 对比会产生假阴性。
- 上游 2.3.x 相对本地 2.0.4 已跨大版本,整体合并不可行;若只要单个修复,确认本地确实没有等价实现后再 cherry-pick。
- OHOS 原生管理器改动需配合 `packages/flutter_blue_plus_ohos/test/native_integration.test.cjs` 的转译测试验证,不能只看 Dart 层测试。
- 任何合并前先按第 2 节流程重新 fetch 一次最新状态,不要依据本文档的旧结果直接操作。
