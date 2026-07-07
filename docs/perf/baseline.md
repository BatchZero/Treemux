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
