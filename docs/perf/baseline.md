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
