# 性能与流畅度大升级 — 设计文档 (Design Spec)

- **日期**: 2026-07-01
- **状态**: 已批准骨架，待用户复核
- **技术路线**: 路线 A —— 分阶段、测量驱动、以 `@Observable` 迁移为主干
- **主攻方向**: ① UI 响应/重渲染 ② 终端/SSH 输入手感 ③ 文件浏览/编辑流畅（启动/主题切换降级为可选 Phase 4）

---

## 1. 背景与问题定义

目标是对 treemux 的本地与远程使用体验做一次系统性的流畅度升级，覆盖软件本身操作、文件编辑、SSH 输入、UI 反馈等。

通过三路代码调查（终端输入路径 / 文件浏览本地+远程 / SwiftUI 架构与响应性），得到的核心画像：

**底层 I/O 已经较健康**：文件树 I/O 全部离主线程；远程大目录有 5 万条硬上限（`find … | head -n 50000`）；管道用 `readabilityHandler` 增量排空防死锁；目录树磁盘缓存可秒开；git 元数据监听有 0.5s 防抖。

**真正拖累流畅度的三个系统性问题**：

1. **SwiftUI「上帝对象」导致的重渲染风暴（影响面最大）**
   - 全项目 10 个 `ObservableObject` + 67 个 `@Published`，全部是老式粗粒度写法。
   - `WorkspaceStore`、`WorkspaceModel`（13 个 `@Published`）、`FileBrowserTabController`（13 个 `@Published`）、`ShellSession`、`WorkspaceSessionController` 均为粗粒度对象。
   - 老式 `ObservableObject` 只要**任意** `@Published` 变化就通知**所有**订阅视图。
   - 具体表现：终端 title/pwd/resize 回调 → `ShellSession` 发布 → `TerminalPaneView` 整棵重算；文件树任意变化 → `NodeRow` 全量（数百行）重渲染；`WorkspaceStore.swift:469` 一句 `objectWillChange.send()` 广播给所有订阅者。
   - 这是「一处动全局抖」「越用越卡」的根因。

2. **主线程上的重活（影响启动 + 交互瞬卡）**
   - 主题 YAML **同步读盘 + 解析、无缓存**，且**阻塞窗口显示**；切换/导入主题会全量重解析（`ThemeLoader.swift:43-45`、`ThemeManager`）。
   - 切换语言会**整棵根视图重建**（`WindowContext` 把新的 `MainWindowView()` 赋给 `host.rootView`，状态丢失）。
   - 「显示隐藏文件」开关在主线程过滤整棵树（`FileBrowserTabController.setShowsHiddenFiles`）；选中大图片时 `NSImage(data:)` 同步解码（`FileBrowserTabController.swift:~609`）。

3. **远程/SSH 的轮询与输入开销**
   - 30 秒定时器跑在 `.common` runloop（拖拽窗口时也触发），每次对所有 SSH 工作区做 git 检查，且最终跳回主线程（`WorkspaceStore.swift:483-518`）。
   - 终端输入路径每次按键都走 AppKit `interpretKeyEvents()`（IME 组字系统），对纯 ASCII 打字是可省的开销（`TreemuxGhosttyController.swift:917`）。

### 前提确认

- **部署目标 macOS 15.0** → Observation 框架（`@Observable` 宏）完全可用。
- 目前**尚未使用** `@Observable`。
- `@Observable` 按「视图实际读取了哪个属性」做精确追踪，视图只在其真正用到的属性变化时才重渲染 —— 这是解决重渲染风暴的最高杠杆，且迁移相对机械、风险可控。

---

## 2. 技术路线选择

| 路线 | 描述 | 结论 |
|------|------|------|
| **A（选定）** | 分阶段 + 测量驱动，以 `@Observable` 迁移为主干，每阶段独立可发布 | 收益大、风险可控、契合小步发布节奏 |
| B | 只做外科手术，保留 `ObservableObject`，手工拆分 + 抽 Equatable 子视图 | 架构改动小，但覆盖不彻底、长期维护负担重 |
| C | 一次性重写整个状态层 | 最彻底但风险最高、无法分步验证、与 worktree/小步发布冲突 |

**验收方式**: 测量优先 —— 先建立可复现的基准，改前改后对比数据，每一步改动都有铁证。

---

## 3. 分阶段设计

每个阶段 = 独立分支 + worktree（`.worktrees/<branch>/`）、独立重测基准、可独立随 `scripts/deploy.sh` 发布。

### Phase 0 —— 埋点与基准（地基，必须先做）

**目的**：没有基准就无法证明后续每步是否有效、是否引入回归。

**范围**：
- 封装一个 `os_signpost` 辅助层，在关键路径打点：
  - 按键 → `ghostty_surface_key`（输入延迟）
  - `wakeup` → `tick`（渲染调度）
  - 目录展开、切标签、主题加载
  - 视图 body 重算计数（配合 Instruments 的 SwiftUI 模板）
- 用 Instruments（Time Profiler + os_signpost + SwiftUI View Body + Animation Hitches）定义可复现场景：
  1. 本地打字 / SSH 打字的「按键→回显」延迟
  2. 展开一个大目录（本地 1k+ / 远程）
  3. 切换终端标签 / 工作区
  4. 切主题
  5. 滚动大文件树的帧率
- 把基线数字记入 `docs/perf/baseline.md`。

**验收**：signpost 工具就位；`baseline.md` 有 5 个场景的初始数据。**此阶段不改行为，风险≈0。**

### Phase 1 —— UI 重渲染主干：`@Observable` 迁移（收益最大）

**范围**：
- 把上帝对象从 `ObservableObject/@Published` 迁到 `@Observable`：`WorkspaceStore`、`WorkspaceModel`、`FileBrowserTabController`、`ShellSession`、`WorkspaceSessionController`、`ThemeManager` 等（覆盖 10 个对象 / 67 个 `@Published`）。
- 视图侧相应改造：`@StateObject/@ObservedObject`→`@State`、`@EnvironmentObject`→`@Environment`、双向绑定用 `@Bindable`。
- 删除手工的 `objectWillChange.send()`（`WorkspaceStore.swift:469`）。

**迁移顺序：叶子对象优先**（`ThemeManager` → `ShellSession` → `FileBrowserTabController` → `WorkspaceSessionController` → `WorkspaceModel` → `WorkspaceStore`）。每迁一个：跑 354 测试全绿 + 重测基线的 body 计数。

**验收**：目标场景视图重算次数显著下降（例：终端 title 变化不再触发整棵 pane 重算；文件树单节点变化不再全树重渲染）。

**风险与缓解**：迁移会触及大量视图属性包装器；靠「叶子优先 + 每步测试 + 每步基线」把风险切碎；`@Environment` 注入需保证对象生命周期与原 `@EnvironmentObject` 一致。

### Phase 2 —— 终端 / SSH 输入手感

**范围**：
- **纯 ASCII 快路径**：无修饰键、无 IME/dead-key/marked-text 时跳过 `interpretKeyEvents()`，直接 `sendRawKeyEvent`；仅在真正组字时回落 AppKit 文本系统。
- ghostty 回调（title/pwd/resize）**合并 + 节流**；借 Phase 1 的精确追踪，让其只驱动面板头部而非整棵终端视图。
- 30 秒远程刷新 + git 检查**彻底移出主线程**；重新评估 `.common` runloop 模式（避免拖拽时触发）；保留窗口获焦时的即时刷新。

**验收**：signpost 量到「按键→surface_key」延迟下降；主线程无 git 尖峰；快速连打不丢帧。

**风险与缓解**：快路径必须严格保证不破坏中文/日文输入法与死键行为 —— 以「保守判定，拿不准就回落原路径」为原则，并补输入相关测试。

### Phase 3 —— 文件浏览 / 编辑流畅

**范围**：
- 「显示隐藏文件」过滤**移到后台**，算好后原子替换 `childrenByPath`。
- 大目录**排序优化**（源端预排序 / 增量排序），针对远程 5 万条场景。
- 图片**异步解码 + 大图降采样**（`NSImage(data:)` 移出主线程）。
- **NodeRow 细粒度失效**（借 Phase 1）：抽 Equatable 行视图，避免数百行全量重渲染。
- 文本文件编码探测（UTF-8→GBK→Latin-1）移出主线程。

**验收**：展开大目录帧率、隐藏开关卡顿、开大图三项相对基线改善；滚动大树帧率达标。

**风险与缓解**：后台过滤/排序后的原子替换需保证与滚动恢复状态机（`treeContentGeneration`）协调，避免恢复目标错位。

### Phase 4 —— 启动与主题切换（本次降级为可选 / 机会性）

若前三阶段顺利可顺手做：
- 主题解析**加缓存 + 异步首绘**（先默认主题显示窗口，再热切换到目标主题）。
- 切语言**不再整棵重建根视图**，改用 Environment 驱动局部刷新。
- 状态 JSON **异步加载**，不阻塞启动。

**验收**：冷启动到窗口可见时间下降；切主题/切语言无整屏白闪或状态丢失。

---

## 4. 贯穿全程的约束

- **worktree 纪律**：主目录始终停在 `main`；每阶段在 `.worktrees/<branch-name>/` 内开发、编译、提交，完成后合并回 `main` 并清理 worktree。
- **主题 token**：新增任何可见颜色必须接入主题 token（`~/.treemux/themes/*.yaml`），不得写死色值。
- **i18n**：新增可见字符串用 `LocalizedStringKey` 并补 `zh-Hans`（本项目预计极少新增字符串）。
- **测试红线**：354 个既有测试每步保持全绿；性能改动不改变功能语义。
- **每阶段一个可发布节点**：以 `baseline.md` 的改前/改后对比作为验收证据（呼应「测量优先」）。
- **编译验证**：非交互 `xcodebuild` 需加 `-skipPackagePluginValidation`（SwiftLint 插件）；发布默认 `SKIP_SIGN=1 SKIP_NOTARIZE=1`（有意不签名）。

---

## 5. 交付顺序与依赖

```
Phase 0 (地基) ──► Phase 1 (@Observable 主干) ──► Phase 2 (终端/SSH)
                                              └──► Phase 3 (文件浏览/编辑)
                                                          └──► Phase 4 (可选：启动/主题)
```

- Phase 0 是所有后续阶段的前置（提供验收标尺）。
- Phase 1 是 Phase 2/3 中「细粒度失效」相关优化的前置（先有精确追踪，才能让节流/单节点失效真正生效）。
- Phase 2 与 Phase 3 在 Phase 1 之后可并行推进（各自独立 worktree）。
- Phase 4 可选，依赖前三阶段的稳定性。

---

## 6. 非目标 (Out of Scope)

- 不重写 libghostty 内部渲染 / PTY 读循环（其 I/O 在 C 层，事件驱动已合理）。
- 不引入新的 SSH 库替换系统 `/usr/bin/ssh`。
- 不做与流畅度无关的功能重构或视觉改版。
- Phase 4 之外不承诺启动时间的激进优化。
