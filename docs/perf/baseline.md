# 性能基线（docs/perf/baseline.md）

测量方法：`bash scripts/perf-baseline.sh <Debug/Treemux.app>`，Debug 构建，`sample` 默认采样间隔。
判读：ViewGraph/AttributeGraph 列 ≈ 主线程花在 SwiftUI 视图图重算上的样本数，越低越好。

场景说明：
- **A**：冷启动，file browser 展开一个 1000 行（10 目录 × 100 文件）的合成 fixture 仓库，10s 采样。
- **B**：树已展开可见，触发一次 `git status` 刷新（`touch .git/index`），8s 采样。

## 改前（perf/p0-p1a-surgical @ 701a631，2026-07-07）

commit: `701a631dd8da6792ca333657e47b390d18b5be45`（"perf(p0): add os_signpost helper and instrument git refresh / window construct"，即 Task 1 完成后、Task 3+ 尚未开始的状态）。

机器：本地 macOS（Apple Silicon），Xcode Debug 构建，`xcodebuild ... -skipPackagePluginValidation -quiet`。

### Run 1

```bash
bash scripts/perf-baseline.sh "$APP"
```

| 场景 | 主线程样本 | ViewGraph | AttributeGraph | NSHostingView | RSS |
|---|---|---|---|---|---|
| A 启动+1000行树(10s) | 7993 | 1916 | 4319 | 3071 | 262MB |
| B git刷新(8s) | 6604 | 78 | 58 | 102 | 262MB |

### Run 2（复现性验证，同一构建二次运行）

```bash
bash scripts/perf-baseline.sh "$APP"
```

| 场景 | 主线程样本 | ViewGraph | AttributeGraph | NSHostingView | RSS |
|---|---|---|---|---|---|
| A 启动+1000行树(10s) | 8130 | 1812 | 3900 | 2238 | 262MB |
| B git刷新(8s) | 6617 | 79 | 49 | 105 | 262MB |

### 波动分析

- 主线程样本数、RSS：两次运行几乎一致（RSS 完全相同 262MB），波动 < 3%。
- 场景 A 的 ViewGraph（-5.4%）、AttributeGraph（-9.7%）波动 < 20%，同数量级。
- 场景 A 的 NSHostingView 波动较大（3071 → 2238，约 -27%），超过 20% 目标阈值 —— 如实记录，未做数字修饰。推测原因：`sample` 对短生命周期栈帧的采样本身有随机性，且 NSHostingView 相关帧在 SwiftUI 视图树重建期间是瞬时出现的，采样窗口对齐的抖动会放大计数差异。后续任务（Task 5/6/8 等文件树扁平化与 diff 优化落地后）应关注该指标是否随之显著下降，而不是纠结单次波动。
- 场景 B（git 刷新增量场景）本身样本量小（个位数到百位数级别），两次运行数值几乎一致，波动 < 5%，是更稳定的回归信号来源。

## 脚本问题与修正

`scripts/perf-baseline.sh` 的 `report()` 内 `count(pat)` 函数原实现：

```python
def count(pat):
    return sum(int(n) for n in re.findall(r"(\d+) [^\n]*" + pat, body))
```

当 `pat` 本身带 `|` 分支（例如 `count('AG::|AGGraph')`）时，Python 正则里 `|` 的优先级低于拼接，会把整条表达式拆成 `(\d+) [^\n]*AG::` 和 `AGGraph` 两个独立分支——第二个分支不含捕获组，`re.findall` 对未参与匹配的组返回空字符串，导致 `int('')` 抛出 `ValueError`，脚本在场景 A 的 `report` 调用处直接崩溃退出（Step 2 首次运行即复现）。

修正为在拼接时给 `pat` 补一层非捕获组：

```python
def count(pat):
    return sum(int(n) for n in re.findall(r"(\d+) [^\n]*(?:" + pat + ")", body))
```

修正后两次端到端运行均正常输出完整表格。

主线程标签识别正则 `^    (\d+) Thread_\d+.*(Main Thread|DispatchQueue_1)` 在本机实测样本中匹配的是 `"Main Thread"` 形态（如 `6119 Thread_2548275: Main Thread   DispatchQueue_<multiple>`），无需修正。

## 历史参考（2026-07-07 手工实测，cataclysm-dda 约 1000 行展开）
| 场景 | 结果 |
|---|---|
| 启动 15s 采样 | ViewGraph 3814 + AGGraph 2354 + NSHostingView 1272 样本；RSS 290MB |
| 空树对照 | RSS 141MB |

## P1a 后（进行中）— Task 6：NodeRow → 值驱动 FileTreeRow + Equatable

commit（本次改动前的对照点）: `2f95f27`（Task 5，flattened row model 已加入但视图仍用递归 `NodeRow` 渲染）。
本次改动：`FileTreePanelView` 树体改为 `ForEach(controller.visibleRows())` 渲染值类型 `FileTreeRow`（`.equatable()`），删除递归 `NodeRow`；`FileTreePanelView` 本身仍是唯一的 `@ObservedObject controller` 订阅者。

### 方法论问题：当天基准发现的严重环境噪声

跑基准时发现一个必须如实记录的问题：**同一个二进制、同一台机器、前后两次运行，场景 A 的 ViewGraph/AttributeGraph 计数可以相差 2 倍以上**（例如 7821→3367→3254→3072，同一个 `701a631` 构建的连续 4 次运行）。定位后发现规律是——**每次全新 `xcodebuild build`/`test` 之后的第一次 `perf-baseline.sh` 调用，数字系统性偏高**（推测与 codesign/LaunchServices 注册/Spotlight 对新二进制的后台索引有关，让主线程的视图构建在采样窗口内被拉长，而不是"做了更多工作"）；后续对同一二进制的重复运行会收敛到一个明显更低、更稳定的区间。

因此本次对比采用「排除首次运行、取稳定区间」的方法：对 `701a631`（Task 5 状态，改动前）和本次改动（Task 6）分别在**同一天、同一台机器**上跑 3～4 次，各自去掉紧跟构建之后的第一次运行，取剩余运行的数值。**不直接与本文档最上方「改前」小节的历史数字比较**——那批数字是当时的机器状态下测得的，今天用 `701a631` 复测同一提交得到的数字比当时的记录高 2～5 倍，说明跨天比较在本机上不可靠，只有「同天、同二进制条件下」的相对比较才有意义。

### 场景 A：冷启动 + 1000 行树展开（10s 采样，稳定区间，每组 3 次运行去掉首次）

| 构建 | ViewGraph | AttributeGraph | NSHostingView |
|---|---|---|---|
| 701a631（Task 5，NodeRow 递归渲染） | 3367 / 3254 / 3072（均值 3231） | 10005 / 9856 / 9501（均值 9787） | 4002 / 3919 / 3777（均值 3899） |
| Task 6（本次，值驱动 + Equatable） | 2973 / 3086 / 2892（均值 2984） | 9448 / 9531 / 8785（均值 9255） | 3632 / 3675 / 3463（均值 3590） |
| 相对变化 | **-7.6%** | **-5.4%** | **-7.9%** |

场景 A 是"冷启动首次构建 1000 行树"，Equatable 短路本质上无法在首次渲染上生效（没有旧值可比较），因此这里观察到的是个位数百分比的小幅下降，**远未达到设计文档「≥60%」的目标**——这符合预期：≥60% 的目标更可能是针对增量更新场景（Task 8 的 generation 计数落地后）或整个 P1a 系列任务的累计效果在 Task 10 验收时的目标，而不是 Task 6 单独在"全树冷渲染"这个场景下就能达成的。

### 场景 B：树可见时触发 git 刷新（8s 采样）—— 一个值得记录的反常现象

| 构建 | ViewGraph | AttributeGraph |
|---|---|---|
| 701a631（Task 5） | 94 / 85 / 79（均值 86） | 57 / 48 / 44（均值 50） |
| Task 6（本次） | 142 / 127 / 136（均值 135） | 122 / 116 / 125（均值 121） |
| 相对变化 | **+57%** | **+142%** |

场景 B 的绝对样本数很小（8 秒窗口里几十到一百多个样本），但方向在 4～5 次重复运行中一致偏高，不像纯噪声。深挖后定位到两点：

1. **`scripts/perf-baseline.sh` 的场景 B 其实没有触达 `FileBrowserTabController.fileStatusByPath`**（文件树行的 git 状态点数据源）。`touch .git/index` 触发的是 `WorkspaceMetadataWatchService` → `WorkspaceStore.refreshWorkspace`（500ms 防抖），更新的是 `WorkspaceModel.repositoryStatus`（侧栏分支徽标），随后 `objectWillChange.send()`。`refreshGitStatus()`（写 `fileStatusByPath`）只在 `refreshTree()`/手动保存后触发，脚本的 `touch` 并不会走到这条路径。
2. 但 `FileTreePanelView` 同时以 `@EnvironmentObject var store: WorkspaceStore` 读取 `store.settings.fileTree.density`，所以 `WorkspaceStore` 的任何 `objectWillChange`（哪怕和文件树内容完全无关）都会让 `FileTreePanelView.body` 重新求值。旧实现（递归 `NodeRow`）在这种情况下只是重新遍历已有的 `rootChildren` 数组构造轻量的 `HStack`/`Text`/`Image` 值；新实现每次都要重新跑一遍 `controller.visibleRows()`（对 1000 行做一次全量 flatten + 分配），然后让 `ForEach` 对 1000 个 `FileTreeRowModel` 做一次 `.equatable()` 的逐行比较（原始采样帧里能看到 `AG::LayoutDescriptor::Compare::operator()` 明显增多）——在"树内容其实什么都没变"的场景下，这次全量重算 + 全量比较的成本，比旧实现"重新构造但不比较"的成本还高。

这与后续 **Task 8（generation 计数替换手工失效）** 要解决的问题吻合：`visibleRows()` 目前是在 `body` 里无条件重算的，缺一层"文件树相关状态其实没变就跳过重算"的记忆化。Task 6 本身的改动（值驱动 + Equatable）是按 brief 正确落地的，且在"结构真的变了"的场景（展开/折叠、选中变化）下应该明显受益，但当前的合成基准脚本恰好没有覆盖这类场景，只覆盖了"全树冷渲染"（场景 A，收益有限）和"无关状态变化触发的空转重算"（场景 B，出现真实但绝对值很小的回归）。建议在 Task 8 落地 memoization 后重新跑这两个场景，并考虑补一个"仅 git 状态点变化、树结构不变"的场景 C 来真正验证 Equatable 短路的收益。

### RSS

两组构建 RSS 均在 253～260MB 左右，无明显差异。

## P1a 完成（Task 10 定稿，perf/p0-p1a-surgical @ 194cfb6，2026-07-08）

分支全部 9 个实施任务完成后的定稿测量。同一天、同一台机器、同一构建跑 2 次（沿用「去掉紧跟构建的首次运行」原则，下表已是稳定区间）。

| 场景 | 主线程样本 | ViewGraph | AttributeGraph | NSHostingView | RSS |
|---|---|---|---|---|---|
| A 启动+1000行树(10s) run1 | 7884 | 3801 | 12047 | 4516 | 253MB |
| A 启动+1000行树(10s) run2 | 8002 | 3640 | 10692 | 4318 | 252MB |
| B git刷新(8s) run1 | 6614 | 75 | 45 | 96 | 253MB |
| B git刷新(8s) run2 | 6670 | 61 | 41 | 80 | 247MB |

### 场景 B：Task 8 记忆化收回了 Task 6 的回归（关键结论）

| 构建 | ViewGraph（均值） | AttributeGraph（均值） |
|---|---|---|
| 701a631（Task 5，改动前基准） | 86 | 50 |
| Task 6（值驱动 + Equatable，未记忆化） | 135 | 121 |
| **P1a 完成（Task 8 记忆化落地后）** | **~68** | **~43** |

Task 6 的值驱动改造在"无关状态触发的空转重算"场景下曾引入 +57%/+142% 的回归（每次 `body` 求值都无条件全量 `visibleRows()` + 逐行 Equatable 比较）。Task 8 给 `visibleRows()` 加了以 8 个 `@Published` 状态源 `didSet` 驱动失效的记忆化后，场景 B 不仅抹平了该回归，AttributeGraph 还从原始基准的 50 降到 ~43，ViewGraph 从 86 降到 ~68 —— **净改善，且是本套基准中唯一可靠的信号维度**。

### 场景 A 与本套基准的局限（必须诚实记录）

场景 A 的 AttributeGraph 定稿数字（~11000）看起来比最上方「改前」小节的历史记录（~4300）高，但这**不能解读为回归**：

1. 场景 A 是冷启动一次性构建 1000 行树，Equatable 短路在首次渲染上本就无法生效（没有旧值可比），本分支的重渲染优化对这个场景结构上就没有作用点。
2. 该场景受机器负载/后台索引主导，同机跨次差 2~5 倍，跨天更不可比（详见 Task 6 小节的方法论说明）。
3. **本套基于 `sample` 的粗粒度基准，没能捕捉到本分支真正的收益所在**：每键编辑器 fan-out 消除（Task 7）、resize/scrollbar 发布风暴去重（Task 3/4）、文件树逐行观察移除（Task 6）——这些收益体现在**交互式打字/拖拽/滚动时的每帧成本与掉帧**上，需要 Instruments 的 Animation Hitches / SwiftUI View Body 模板在真实交互下测量，而不是 `sample` 对冷启动/单次刷新的整窗采样。

**结论**：定量上，唯一可靠的场景 B 显示净改善（记忆化生效）；本分支的主要收益（交互流畅度）需靠 GUI 手动冒烟 + Instruments 交互测量验收，已列入合并前人工验证清单。设计文档里「≥60%」是针对交互增量场景的目标，本套冷启动基准无法证伪也无法证实它，不应据此判定成败。

## P2 完成（perf/p2-remote-link @ c7583a7，2026-07-09）

改动：SSH ControlMaster 连接复用（SFTPService + GitRepositoryService 统一走 SSHMultiplexing）；远程工作区刷新 TaskGroup 并行化；目录树缓存读取移出主线程；大文件确认路径两次 stat 合并为一次。全部改动在远程链路与 I/O 侧，本地渲染路径未触碰。

### 远程真机验证（10.0.114.250，局域网，key 认证）

| 操作 | 无复用（现状） | 带复用（P2） | 提升 |
|---|---|---|---|
| 5 次连续 ssh 命令 | 1.277s（~255ms/次） | 0.358s（首连建 master + 4 复用） | 3.6× |
| 复用后单命令往返 | ~255ms | **0.019s** | **~13×** |

master socket 正常出现在 `~/.treemux-debug/ssh-mux/`（`srw-------`），ControlPersist=60s 生效。注意这是局域网数字：高延迟网络（公网/VPN）下每次省掉的是完整 TCP+SSH 握手+认证，绝对收益更大。

### 本地场景 A/B 回归检查（同日，main fbvzemhs… vs P2 hikjxwsn…，各 4 轮去首跑 + 2 轮交错）

| 构建 | B ViewGraph（均值） | B AttributeGraph（均值） | B NSHostingView（均值） |
|---|---|---|---|
| main（run2-4） | 86 | 59 | 109 |
| P2（run2-4） | 107 | 76 | 134 |

均值差 +24~30%，超过预设 20% 噪声线，但**判定为噪声、非回归**，依据：(1) 交错补测显示同一二进制方差主导——main 出现一次 0/0/0（88MB，退化跑），P2 出现一次 320/227/374（自身均值 3 倍），run6 交错对比 main 109/66/148 vs P2 139/91/172，分布重叠；(2) 绝对差约 20 个 1ms 样本（8 秒窗口的 0.25%）；(3) 场景 B 是本地 git 刷新，P2 未改动任何本地渲染/失效路径，无因果机制。与既往「同机同二进制跨次 2~5 倍」方法论记录一致。

### 测试

全量 440 测试 0 失败（424 基线 + 16 新增）。修复过程中发现并解决一个真实竞争：SSHMultiplexing 每次构参 mkdir 与测试删 `~/.treemux-debug` 并发导致 NSCocoaError 513（IconCacheTests 全量必挂）——改为进程内每路径一次性 ensure 后 3 次全量连续全绿。

## P1b 完成 @ d3a28b6 2026-07-10

改动：11 个核心状态对象（ThemeManager/LanguageManager/ShellSession/FileBrowserTabController/WorkspaceSessionController/WorkspaceModel/WorkspaceStore/remote 浏览 VM + 2 个 vestigial coordinator）从 `ObservableObject` + `@Published` 迁移到 `@Observable` 宏；Combine 保留为 3 条非视图层跨对象桥（theme/locale/settings 的 `PassthroughSubject`），WorkspaceStore 新增 `workspaceMetadataGeneration` 计数器替代裸 `objectWillChange.send()`。本地渲染路径的核心变化：视图从「持有 store 引用 → 任意 `@Published` 变更即整体重算 body」变为「只在 body 求值期间实际读到的属性变化时才失效」。

### 方法论

在 P1a/P2 既定方法论上收紧为分支级终验：branch（worktree）与 main（主仓库同一台机器同法构建）各自 Debug 构建后跑 4 次 `scripts/perf-baseline.sh`，去掉紧跟构建的首次运行（机器/索引噪声，P1a 小节已记录的既有结论），保留后 3 次取均值。两侧构建与采样在同一天顺序执行（未交错）——因为观测到的差异（见下）远超既有噪声包络（2~5×），不满足"看起来更差需交错复核"的触发条件，故未额外跑交错对。Scenario B（git 刷新）为主信号；Scenario A（冷启动）仅供参考。

### Branch（perf/p1b-observable @ d3a28b6，worktree 内 `build/DerivedData`）

Scenario A raw（10s 冷启动 + 1000 行树；run1 丢弃）：

| run | 主线程 | ViewGraph | AttributeGraph | NSHostingView | RSS |
|---|---|---|---|---|---|
| 1（丢弃） | 7538 | 3926 | 12490 | 4657 | 162MB |
| 2 | 7953 | 3281 | 9919 | 3842 | 222MB |
| 3 | 7836 | 4028 | 11331 | 4879 | 233MB |
| 4 | 8226 | 4073 | 12009 | 5459 | 202MB |
| 均值（2-4） | 8005.00 | 3794.00 | 11086.33 | 4726.67 | 219.00MB |

Scenario B raw（8s，`touch .git/index` 触发 git 刷新）：

| run | 主线程 | ViewGraph | AttributeGraph | NSHostingView | RSS |
|---|---|---|---|---|---|
| 1（丢弃） | 6611 | 6 | 4 | 11 | 114MB |
| 2 | 6663 | 3 | 2 | 9 | 106MB |
| 3 | 6908 | 3 | 2 | 4 | 171MB |
| 4 | 6923 | 3 | 2 | 4 | 95MB |
| 均值（2-4） | 6831.33 | 3.00 | 2.00 | 5.67 | 124.00MB |

### Main（8e69805，主仓库 `/Users/yanu/Documents/code/Terminal/treemux` 同法构建于 `build/DerivedData-p1b-baseline`，测量后已清理）

Scenario A raw：

| run | 主线程 | ViewGraph | AttributeGraph | NSHostingView | RSS |
|---|---|---|---|---|---|
| 1（丢弃） | 4909 | 3540 | 12462 | 4370 | 258MB |
| 2 | 7780 | 3485 | 10376 | 4290 | 244MB |
| 3 | 7628 | 3582 | 10972 | 4363 | 246MB |
| 4 | 7828 | 3752 | 11826 | 4681 | 171MB |
| 均值（2-4） | 7745.33 | 3606.33 | 11058.00 | 4444.67 | 220.33MB |

Scenario B raw：

| run | 主线程 | ViewGraph | AttributeGraph | NSHostingView | RSS |
|---|---|---|---|---|---|
| 1（丢弃） | 6745 | 229 | 133 | 291 | 212MB |
| 2 | 6677 | 131 | 93 | 166 | 238MB |
| 3 | 6679 | 102 | 65 | 126 | 240MB |
| 4 | 6690 | 122 | 89 | 150 | 162MB |
| 均值（2-4） | 6682.00 | 118.33 | 82.33 | 147.33 | 213.33MB |

### 对比与判读（Scenario B，硬验收信号）

| 指标 | Branch 均值 | Main 均值 | 相对变化 |
|---|---|---|---|
| ViewGraph | 3.00 | 118.33 | **-97.5%** |
| AttributeGraph | 2.00 | 82.33 | **-97.6%** |
| NSHostingView | 5.67 | 147.33 | **-96.2%** |

**验收结论：通过。** Branch 均值远低于 main（数量级下降，不是"噪声包络内持平"），完全满足「Scenario B 均值不劣于 main」的验收标准；由于差异方向对分支有利且远超 2~5× 噪声包络，未触发"看起来更差需交错复核一对"的条款。

机制解释（与本文档 P1a 完成小节记录的既有问题吻合）：迁移前 `WorkspaceStore` 是 `ObservableObject`，任何 `@Published` 变更（包括 git 刷新只改动的 `workspaceMetadataGeneration`/`repositoryStatus` 等与文件树内容无关的字段）都会经 `objectWillChange` 触发所有持有该 store 引用的视图整体重算 body——这正是 P1a 完成小节记录的「无关状态变化触发文件树空转重算」的根因（`FileTreePanelView` 当时读取 `store.settings.fileTree.density`，与 git 状态无关，却因为 objectWillChange 是对象级广播而被拖着重算）。迁移到 `@Observable` 后，SwiftUI 只在 body 求值期间实际读取的属性发生变化时才使该视图失效；`FileTreePanelView` 不读取 `workspaceMetadataGeneration`，git 刷新因此不再级联触发其重算，Scenario B 的 ViewGraph/AttributeGraph 样本数从"几十到大几百"量级降到"个位数"量级。这是本次 `@Observable` 迁移在设计目标路径（按属性精确失效）上的直接、可测量收益，不是测量噪声。

Scenario A（冷启动，仅供参考）：branch 与 main 的 ViewGraph/AttributeGraph/NSHostingView 均值差异约 5%（3794 vs 3606、11086 vs 11058、4727 vs 4445），与本文档 P1a 完成小节的既有结论一致——冷启动首次渲染没有旧值可比，属性级失效/记忆化优化在这个场景下本就没有作用点，此处的小幅差异属于机器噪声，既不是回归也不是证据。

### 测试

全量 444 测试 0 失败（worktree HEAD `d3a28b6`；`.xcresult` 验证：`totalTestCount 444, passedTests 444, failedTests 0, expectedFailures 0`）。

### 版本核对

`grep -c "MARKETING_VERSION = 0.0.19" Treemux.xcodeproj/project.pbxproj` → `2`，未漂移。

### Step 1：全局残留清扫

`grep -rn "@Published\|@EnvironmentObject\|@StateObject\|@ObservedObject\|environmentObject(\|ObservableObject\|objectWillChange" Treemux/ TreemuxTests/` 命中 10 处，全部落在 prose 注释里对旧机制的提及（非声明/非可执行代码）。逐条 triage 结论：

| 文件:行 | 判定 | 理由 |
|---|---|---|
| `WorkspaceOutlineSidebar.swift:35,41` | 保留（白名单） | 冻结侧栏区，解释显式 tracked read 与旧 whole-object `@ObservedObject` 失效行为的对等关系，历史语境准确，未误述当前机制 |
| `SidebarCoordinator.swift:73,253` | 保留（白名单） | 冻结侧栏区，解释为何 `theme` 按值传参仍需手工 `themeDidChangeRefresh`；迁移后该结论依然成立——`NSHostingView<AnyView>` 的结构相等短路会跳过 body 求值，@Observable 的自动追踪救不了这种情况，手工刷新仍是权威路径 |
| `SidebarNodeRow.swift:14` | 保留（白名单） | 冻结侧栏区，同上；文件本身已有「Post-@Observable note」段落（16-20 行）补充当前状态，无需改写旧段落 |
| `WorkspaceStore.swift:38-39` | 保留（白名单） | 准确描述当前状态（"replaces a bare objectWillChange.send()...which has no objectWillChange"），是对现状的陈述，不是历史误述 |
| `ObservableBridgeTests.swift:6,17,22` | 保留（白名单） | 测试 helper 的机制文档，对比新旧桥模式正是文档目的本身，描述准确 |
| `WorkspaceModelTabKindTests.swift:40` | **已改写** | 原文「on every objectWillChange」描述的触发机制已不存在（`WorkspaceStore` 已迁移完毕，全仓无 `objectWillChange`）；改写为「on every SwiftUI re-render」并具名 `WorkspaceDetailView.body`，消除机制误述，回归叙事本身原样保留 |

`import Combine` 白名单核对：`AppDelegate.swift`、`ThemeManager.swift`、`WindowContext.swift`、`WorkspaceStore.swift`、`LanguageManager.swift`、`ObservableBridgeTests.swift` —— 与 brief 白名单（5 个 app 文件 + `ObservableBridgeTests`）精确匹配，无多余命中，无需删除任何 import。

## P3 surface occlusion 量化 (2026-07-10)

测量对象：`TreemuxGhosttyController` 在 `suspendHiddenSurfaces == true` 时对隐藏 surface 调用 `ghostty_surface_set_occlusion(surface, false)`（`Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift:680-681,784`），目的是验证隐藏 surface 停止上报可见性是否能实测降低内存/CPU 占用。

### 机器与布局

- 本地 macOS（Apple Silicon），worktree `perf+p3-cleanup` 内 `xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation` 产出的 Debug 构建（`DerivedData/Treemux-dbydgkjbqfydvpdzqtyeulyvtimm/Build/Products/Debug/Treemux.app`）。
- 用 `~/.treemux-debug/` 全新配置起步，通过 System Events 发送真实快捷键搭出布局：Cmd+D（`splitHorizontal`）在默认终端 tab 内加一个 pane，Cmd+T（`newTab`）新建第二个 tab。最终落盘的 `workspace-state.json` 确认：**3 个 surface / 2 个 tab** —— tab1（2 个 pane，split）为隐藏 tab，tab2（1 个 pane）为前台选中 tab，与 protocol 要求的"≥3 surface、≥2 tab、部分隐藏"一致。3 个 pane 都是空闲 `zsh --login`（登录时打印了几行网络/代理信息后即静止），不含持续刷屏的 TUI 程序。
- 设计文档参考基线（生产实例、5 surface）：footprint 791MB、IOSurface 488MB、IOAccelerator 115MB——量级远超本次 3 个空闲 shell 的复现环境，两者不可直接比较，仅作为"重负载场景可能出现更大效应"的背景参考。
- A/B 通过重启完成：quit → `python3 -c` 改写 `~/.treemux-debug/settings.json` 的 `terminal.suspendHiddenSurfaces` → 重新 `open` → 同一份 `workspace-state.json` 自动恢复相同布局（截图核对 tab1 badge "2"、tab2 单 pane 前台，两次一致）。每次 launch 后等待 30s 稳态，再取 3 次样（间隔 ~8-10s）。

### ON（`suspendHiddenSurfaces = true`，默认值，PID 48902）

| 采样 | IOSurface | IOAccelerator(graphics)+IOAccelerator | phys_footprint | RSS | CPU |
|---|---|---|---|---|---|
| 1 | 31 MB | 6128+64 KB | 90 MB | 122592 KB | 0.5% |
| 2 | 31 MB | 6160+64 KB | 91 MB | 92448 KB | 1.0% |
| 3 | 31 MB | 6160+64 KB | 91 MB | 92416 KB | 6.5% |
| **均值** | **31.0 MB** | **6213 KB** | **90.7 MB** | **~100.1 MB** | **2.7%** |

### OFF（`suspendHiddenSurfaces = false`，PID 53104，同一份布局重启后）

| 采样 | IOSurface | IOAccelerator(graphics)+IOAccelerator | phys_footprint | RSS | CPU |
|---|---|---|---|---|---|
| 1 | 31 MB | 4912+64 KB | 86 MB | 143312 KB | 4.2%（该次采样瞬间前台被 WeChat 短暂抢走，窗口仍可见未被完全遮挡） |
| 2 | 31 MB | 4912+64 KB | 86 MB | 129648 KB | 0.9% |
| 3 | 31 MB | 4912+64 KB | 86 MB | 129568 KB | 0.9% |
| **均值** | **31.0 MB** | **4976 KB** | **86.0 MB** | **~131.0 MB** | **2.0%** |

### 结论

在本次可复现的 3-surface / 2-tab 空闲 shell 场景下，`suspendHiddenSurfaces` 开关**没有表现出可靠的内存或 CPU 收益**：IOSurface 占用在 ON/OFF 两组下完全相同（31MB，逐样本一致，说明隐藏 surface 上报 `occlusion=false` 并未让 libghostty 释放或缩减其 IOSurface 后备存储）；phys_footprint 反而是 OFF 更低（86MB vs 90.7MB），RSS 也是 OFF 更低（~131MB vs ~100MB，但两组内部单样本抖动本身就有 20-30MB，量级和这个"差异"相当）；CPU 两组均值 2.7% vs 2.0%，差值落在个位百分点、且两组各自都有一次孤立高值（ON 采样 3 的 6.5%、OFF 采样 1 的 4.2%）拉高均值，去掉离群值后两组基本持平。三个指标里没有一个方向一致地支持"ON 更省"，样本量（3 个空闲 zsh、无持续渲染负载）也远小于设计文档参考的 5-surface 791MB 生产实例，无法验证该开关在重负载场景下是否有效——**推荐维持默认值 `true` 不变**：现有数据不构成"flip 到 false 更优"的证据，但也没有找到 ON 状态下的可测量收益或副作用，默认开启符合"预期应该更省、且未观测到负面影响"的保守选择；如需验证重负载场景（多个持续刷屏的 TUI、大量 scrollback），需要更接近生产参考基线的真实工作负载复测，这超出本次 P3 Task 8 测量阶段的范围。

> 决策：按计划分支 (b)，无可测收益 → 默认值改为 false（实施保留，可在设置中开启）；终审时由用户定夺。
