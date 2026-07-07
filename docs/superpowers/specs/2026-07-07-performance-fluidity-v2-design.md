# 性能与流畅度升级 v2 — 设计文档

- **日期**: 2026-07-07
- **状态**: 已获用户批准（路线 A）
- **取代**: 2026-07-01 的三份性能文档（已随 11d43f1 移除；本文基于新一轮调查 + 真机实测，结论有多处修正）

---

## 1. 背景：这次调查与 7 月 1 日的差异

7 月 1 日的设计只做了代码审读；本次在四路代码深查之外补齐了真机实测（调试构建 + 生产实例采样），**修正了旧文档的优先级判断**：

### 1.1 实测推翻/降级的旧判断

| 旧判断 | 实测结果 | 处置 |
|---|---|---|
| 每键 `interpretKeyEvents()` 是输入延迟来源 | 连续打字场景主线程约 50% 时间在空等事件，单键开销几十微秒级 | **移出范围**（非目标） |
| 输出滚屏/渲染压力大 | `seq 1 300000` 刷屏时进程 CPU 93%，但全部在 ghostty io/renderer 后台线程，主线程 97.5% 空闲 | 无需处理 |
| 启动需要激进优化 | 全新状态冷启动 0.63s 窗口可见（调试构建） | 降为 P3 顺手项 |

### 1.2 实测坐实的真瓶颈（基线数字）

测试环境：Debug 构建，macOS 26.5.1，测试仓库 cataclysm-dda（约 24k 文件）。

| 场景 | 数字 | 根因 |
|---|---|---|
| 文件树预置展开约 1000 行后启动 | 15s 采样中主线程约 5~6s 耗在视图图重算（ViewGraph 3814 + AttributeGraph 2354 + NSHostingView 1272 样本 @1ms）；RSS 290MB（收起树时 141MB） | NodeRow `@ObservedObject` 观察整个 controller（15 个 `@Published`）× 非懒加载 `VStack` 全行常驻 |
| touch `.git/index` 触发 git 状态刷新 | 主线程出现成百毫秒级 AttributeGraph 传播 + posix_spawn | `fileStatusByPath` 整体替换 → 全树失效 |
| 生产实例（5 个终端 surface） | footprint 791MB，其中 IOSurface 488MB + IOAccelerator 115MB（42 块 IOSurface） | 每 surface 持全尺寸缓冲；后台 surface 不挂起 |
| 远程文件操作 | 每次操作 spawn 全新 `/usr/bin/ssh`（完整 TCP+SSH 握手+认证），无 ControlMaster | `SFTPService.swift:403-418`、`GitRepositoryService.swift:205-225` |

### 1.3 其余确认的问题（代码级）

- **编辑器击键 fan-out**：`SourceEditor` Binding 每键写 `@Published subTabs`（`FileBrowserTabController.swift:672-677`）→ 文件树全部 NodeRow 连带失效；`text != content` 每键 O(文件长度) 比较；`content.utf8.count` 每次 body O(n)（`TextEditorView.swift:156`）。
- **resize/scrollbar 发布风暴**：`setFrameSize` → 多余 main-async hop → `cols/rows` 值未变也无条件写 `@Published`（`TreemuxGhosttyController.swift:369-372`、`ShellSession.swift:104-106`）；scrollbar action 同链路（`Controller.swift:233/476/431`）。拖拽/重输出期间每帧每 pane 触发。
- **主线程同步 I/O**：主题 YAML 无缓存、首帧前同步读盘解析（`ThemeLoader.swift:43-44`，经 `WindowContext.swift:21`）；`settings.json` 每次变更同步编码写盘、⌘= 连发每键一写（`WorkspaceStore.swift:28-29`）；`workspace-state.json` 每次切工作区全量 pretty-print 同步写（`WorkspaceStore.swift:543-561`）；目录树磁盘缓存读取侧主线程同步解码（`DirectoryTreeCachePersistence.swift:30-33`）；settings.json 启动至少读 3 次。
- **远程刷新串行**：30s 定时器 + 窗口获焦触发，对所有远程工作区**串行** ssh（`WorkspaceStore.swift:483-518`）。
- **`WorkspaceStore.swift:469`** 手工 `objectWillChange.send()` 广播全体订阅者。
- 次要：`sidebarIcon(for:)` 行 body 内 O(N²)（`WorkspaceStore.swift:566-590`）；`remoteWorkspaceGroups` 每次访问 group+sort（`:137-145`）；远程大文件确认路径两次 stat；远程下载/保存无进度反馈。

### 1.4 确认健康、无需动的部分

所有 git/SSH/tmux 子进程已 actor/async 化，主线程无子进程阻塞；Combine 管道防抖覆盖良好；文件监听 0.5s 防抖到位；本地/远程目录排序均在后台；ghostty wakeup→tick 单 hop 设计合理。

---

## 2. 路线选择

| 路线 | 描述 | 结论 |
|---|---|---|
| **A（选定）** | 分阶段测量驱动，双主干 = 状态层细粒度化 + SSH 连接复用 | 收益大、风险可切碎、每阶段可发布 |
| B | 保留 ObservableObject 只做外科手术 | 见效快但病根仍在，长期维护成本高 |
| C | 状态层一次性重写 | 与小步发布节奏冲突，回归风险大 |

---

## 3. 分阶段设计

每阶段 = 独立分支 + `.worktrees/<branch-name>/`、354 测试全绿、基准对比验收、可独立随 `scripts/deploy.sh` 发布。

### P0 — 基准固化与埋点（不改行为）

- `os_signpost` 辅助层，打点：按键→`ghostty_surface_key`、目录展开、git 刷新→树重算完成、启动各阶段、主题切换。
- 脚本化基准（复用本次手法）：预置 1000 行展开树的 `workspace-state.json` → 启动采样；touch `.git/index` → 刷新采样；`sample` 输出自动解析主线程 ViewGraph/AttributeGraph 占比。
- 基线数字（含本文 1.2 的第一版数据）记入 `docs/perf/baseline.md`。

**验收**：基准脚本可重复运行，两次运行结果波动 < 20%。

### P1 — 状态层细粒度化（收益最大）

1. `@Observable` 迁移，叶子优先：`ThemeManager` → `ShellSession` → `FileBrowserTabController` → `WorkspaceSessionController` → `WorkspaceModel` → `WorkspaceStore`（11 个对象 / 67 个 `@Published`）。每迁一个：全测试 + 基准回归。
2. **NodeRow 解耦（本阶段最关键项，可先于迁移落地）**：`NodeRow` 不再 `@ObservedObject` 整个 controller，改为父级预计算 `isSelected/isExpanded/children/status` 按值下传（对齐侧栏 `SidebarNodeRow` 既有模式），把失效范围缩到真正变化的行。保持 `VStack`（滚动记忆的既有取舍不动）。
3. 编辑器击键隔离：`updateBuffer` 不再触发 `@Published subTabs` 广播（缓冲内容移出发布路径，仅 dirty 标志发布）；移除每 body 的 `content.utf8.count` 重算（缓存字节数）。
4. 发布去重与合并：`cols/rows/scrollbarState/surfaceStatus` 值未变不写；已在主线程时不再 async hop（`handleSurfaceResize`、`SET_TITLE`/`PWD` 双跳）。
5. `WorkspaceStore.swift:469` 手工失效改 generation 计数属性（参照 `treeContentGeneration` 模式）。
6. 顺手项：`sidebarIcon(for:)` 加缓存；`remoteWorkspaceGroups` 缓存。

**硬约束（闪退雷区）**：侧栏 `NSHostingView` 子树（`SidebarCellView`/`SidebarNodeRow`/`SidebarItemIconView`）维持「不注入任何 EnvironmentObject + 按值传参 + fingerprint 手工刷新 + `.id(theme)` 强刷」的现状架构，禁止改为 `@Environment` 自动观察（678fda8 崩溃史）。

**验收**：基准场景「1000 行树启动」主线程视图图耗时下降 ≥ 60%；「git 刷新」不再全树失效（signpost 计数）；编辑器单键不再触发文件树重算；窗口拖拽时 pane header 不再每帧重算。

### P2 — 远程链路

1. **SSH 连接复用**：`SFTPService.sshArgs` 与远程 git 调用统一加 `ControlMaster=auto`、`ControlPath=~/.treemux/ssh-mux/%C`（目录随 app 状态目录，debug 用 `~/.treemux-debug/`）、`ControlPersist=60s`。首连建立 master，后续操作复用；master 不可用/服务器禁用时静默退化为现状（每次新连）。
2. 30s 轮询改 TaskGroup 并行（保留 `isRefreshingRemotes` 重入保护与获焦触发）。
3. 目录树磁盘缓存读取移出主线程（写侧已后台，对齐即可）。
4. 远程大文件确认路径两次 `stat` 合并为一次。

**验收**：远程目录展开/文件打开的往返次数与耗时显著下降（基准：同一远程仓库操作序列计时）；多远程工作区轮询总耗时约等于最慢单个而非求和。

### P3 — 收尾杂项

- `settings.json`/`workspace-state.json` 写盘 250ms 防抖 + 后台编码（保留退出时同步 flush）。
- 主题加载 mtime 缓存；启动路径去重（`ensureInstalled` 调 2 次、settings.json 读 3 次）；切主题不再无条件重读盘。
- 图片 `NSImage(data:)` 后台解码 + 大图降采样；文本编码探测（UTF-8→GBK→Latin-1）后台化。
- 「显示隐藏文件」过滤后台化，算好原子替换。
- 内存机会项（独立开关、可回退）：不可见 pane 的 surface 降频/挂起调研——先量化单 surface 缓冲占用，再决定是否实施。

**验收**：⌘= 连发无逐键写盘；切主题无全量重解析；打开大图不卡主线程；上述各项基准不回归。

---

## 4. 贯穿约束

- worktree 纪律：主目录停在 `main`，所有开发在 `.worktrees/<branch-name>/`。
- 主题 token / i18n 红线照旧（本升级预计不新增可见字符串与颜色）。
- 354 个既有测试每步全绿；性能改动不改变功能语义。
- 非交互构建加 `-skipPackagePluginValidation`。
- 每阶段提供改前/改后基准对比作为合并证据。

## 5. 交付顺序

```
P0 ──► P1（状态层）──► P2（远程）──► P3（收尾）
```

P2 与 P1 技术上独立，若远程痛感优先可对调；默认按上序（P1 的失效收敛能让 P2 的验收数字更干净）。

## 6. 非目标

- 不动 libghostty 内部渲染/PTY；不替换系统 ssh。
- 不做纯 ASCII 键入快路径（实测非瓶颈）。
- 不做激进冷启动优化（已 0.63s）。
- 不改滚动记忆的 `VStack` 取舍（P1 靠行级解耦收敛成本；若未来仍不足再单独立项）。
- 切语言整树重建（低频，暂不处理）。
