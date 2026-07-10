# Perf P3 收尾杂项 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 完成性能升级 v2 的最后阶段 P3（设计文档 `docs/superpowers/specs/2026-07-07-performance-fluidity-v2-design.md` §P3）：持久化写盘 250ms 防抖 + 后台编码（保留退出同步 flush）、主题加载 mtime 缓存 + 启动路径去重、图片后台解码 + 大图降采样、文本编码探测后台化、隐藏文件过滤后台化、不可见 surface 遮挡挂起（独立开关 + 量化）。

**Architecture:** 全部为「主线程重活搬后台 + 原子替换回主线程」与「重复 IO 去重/缓存」两类手术式改动，不改功能语义。持久化引入共享 `DebouncedSaver`（trailing debounce + 串行后台队列编码写盘 + 退出同步 flush）；文件查看器的解码/探测经 `Task.detached` 下沉，复用既有 `setOpenFile(expectingPath:)` 防陈旧闸门；隐藏文件过滤用世代计数防竞态后原子替换；surface 侧只接入 libghostty 已暴露的 `ghostty_surface_set_occlusion`，由设置开关门控、可整体回退。

**Tech Stack:** Swift 5（Swift 6 警告敏感）、SwiftUI + @Observable（P1b 后无 ObservableObject）、GCD/Swift Concurrency、ImageIO（新引入降采样）、Yams、libghostty XCFramework、XCTest。

## Global Constraints

- 主目录必须停在 `main`；全部开发在 `.worktrees/perf+p3-cleanup/`（分支 `perf/p3-cleanup`，基于 `f58ba5a`）。Bash cwd 会被重置回主目录，**每次提交前必须 `git branch --show-current` 确认在功能分支**。
- 每个任务结束时全量测试绿（当前基线 444/444）；非交互构建必须加 `-skipPackagePluginValidation`。
- 全量测试命令：`xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation`（单测过滤加 `-only-testing:TreemuxTests/<类名>`）。
- **P1b 约束（必须遵守）**：3 个 Combine 桥（activeTheme/locale/settings 的 didSet→PassthroughSubject）不得破坏——Task 1 中 `settingsSubject.send(settings)` 必须保留在 `didSet` 内同步执行，只有磁盘写入被防抖。非发布存储 var 一律 `@ObservationIgnored`。本计划不新增 memo 访问器；若实施中确需新增，必须复制 R4 触读三件套（顶部无条件触读全部输入 + 每输入 didSet 失效 + DEBUG compute-count seam，模板见 `FileBrowserTabController.visibleRows()`）。
- 侧栏冻结区架构不动；environment 注入仍全面禁止。
- i18n：新增用户可见字符串（Task 8 的设置开关）必须用 `LocalizedStringKey` 并在 `Treemux/Localizable.xcstrings` 同步添加 zh-Hans 条目。
- 颜色一律主题 token（本计划预计不新增可见颜色）。
- 性能改动不改变功能语义；每阶段提供改前/改后证据（Task 9 汇总）。
- 版本号源是 `project.yml`（0.0.19），本计划不动版本号。
- 实施台账在**主仓库目录** `.superpowers/sdd/progress.md`（`.superpowers/` 是 git-ignored，worktree 里没有）。

## 调研事实速查（写代码前先读这段）

- settings.json 写盘：`WorkspaceStore.settings` 的 `didSet`（`Treemux/App/WorkspaceStore.swift:42-47`）每次赋值主线程同步 `settingsPersistence.save(settings)` + `settingsSubject.send(settings)`。⌘= 连发逐键写盘的根因。`AppDelegate.swift:24` 的 150ms debounce 只挡菜单重建/更新器重配，不挡写盘。
- workspace-state.json：`WorkspaceStore.saveWorkspaceState()`（`WorkspaceStore.swift:605-630`）先清 `sidebarIconCache`/`remoteGroupsCache`（**这是 P1a Task 9 确立的 memo 单一失效点，必须保持同步**），再主线程同步构造 `PersistedWorkspaceState` + 写盘。14 个调用点（含侧栏折叠/展开 `SidebarCoordinator.swift:608/615`）。退出 flush：`TreemuxApp.shutdown()`（`TreemuxApp.swift:25-28`）→ `saveWorkspaceState()`。settings 无退出 flush（现状即时写盘故不需要；防抖后必须补）。
- 两个 persistence 的 `save()` 均为 `JSONEncoder` + `.prettyPrinted, .sortedKeys` + `.atomic` 写（`AppSettingsPersistence.swift:47-54`、`WorkspaceStatePersistence.swift:26-33`）。
- 主题：`ThemeLoader.load`（`Treemux/Domain/ThemeLoader.swift:23-63`）每次全目录逐文件 read+YAML decode，无缓存。`ensureInstalled`（`BuiltInThemes.swift:126-134`）3 个调用点：`ThemeManager.init`（`ThemeManager.swift:45`）、`WindowContext.init:29` 经 `ensureBuiltInThemesExist()`（`ThemeManager.swift:71-73`，纯冗余）、`TreemuxGhosttyRuntime.resolveActiveTerminalColors`（`TreemuxGhosttyRuntime.swift:79`）。settings.json 启动读 3 次：`WorkspaceStore.swift:188`、`TreemuxGhosttyRuntime.swift:37`、`TreemuxGhosttyRuntime.swift:80`（后两次在同一 init 路径内，可合并为 1 次）。`setActiveTheme` 本身不读盘（内存查表，`ThemeManager.swift:77-81`）；无条件重读盘的是 `reloadThemes()`（`ThemeManager.swift:63-69`，被 import/delete/resetBuiltIns 调用）。
- 文件查看器：`FileBrowserTabController`（`@MainActor`，`FileBrowserTabController.swift:26`）。图片 `NSImage(data:)` 主线程解码（`:743`，loadImage 内）、无降采样（`ImagePreviewView.swift:12` 全尺寸位图）；编码探测 `decode(_:)`（`:785-791`，UTF-8→GB18030→Latin-1）主线程跑最多 3 次全量转换（文本上限 5MB）。读盘/网络已后台（本地 `LocalFileBrowserDataSource.swift:9,56` 串行队列；远程 SFTP async）。防陈旧闸门：`setOpenFile(forSubTab:expectingPath:)` 已存在。大文件闸门：`largeFileThreshold=5MB`/`quickLookOnlyThreshold=100MB`（`:72-74`）。仓库无 ImageIO/CGImageSource 先例，全新引入。
- 隐藏文件过滤：`setShowsHiddenFiles`（`FileBrowserTabController.swift:362-374`）主线程同步遍历整个 `rawChildrenByPath` 逐目录 `filtered()`（`:389-391`，谓词 `!$0.isHidden`，`FileNode.swift:28-30`）后原子替换 `childrenByPath`。`rawChildrenByPath` 是 `@ObservationIgnored` 无 didSet（`:54`）；`childrenByPath`/`rootChildren` 的 didSet 失效 `visibleRowsCache`。回归护栏：`FileBrowserTabControllerTests.swift:10-25` `test_setShowsHiddenFiles_recoversHiddenAfterToggleOff`。
- surface：所有已打开 pane 的 surface 全部保活（`WorkspaceModels.swift:306` tabControllers 字典；`selectTab:489`/`switchToWorktree:772` 不 terminate），切 tab 只是 `removeFromSuperview`。libghostty 已暴露 `ghostty_surface_set_occlusion(ghostty_surface_t, bool)`（`Treemux/Vendor/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h:1087`），app 从未调用；也无任何 occlusion/miniaturize 监听。量化基线已有一手数据：5 surface 实例 footprint 791MB，其中 IOSurface 488MB + IOAccelerator 115MB（设计文档 `:29`）。surface 视图类 `TreemuxGhosttySurfaceView`（`TreemuxGhosttyController.swift:482`），`ghostty_surface_new :1180`、`_free :576`、`set_focus :565/:575/:623/:632/:1193`。
- 可复用防抖先例：`WorkspaceMetadataWatchService.swift:120-131`（DispatchWorkItem+asyncAfter+cancel）、`CompletionPopover.swift:255-268`（Task.sleep+cancel）。后台化先例：`persistTree` 用 `Task.detached(priority: .utility)`（`FileBrowserTabController.swift:307-325`）。once-guard 先例：P2 的 `SSHMultiplexing.ensuredDirectories`（NSLock+Set，失败不缓存）。

---

### Task 0: 建分支 + worktree + 提交计划

**Files:**
- Create: `.worktrees/perf+p3-cleanup/`（worktree）
- Add: `docs/superpowers/plans/2026-07-10-perf-p3-cleanup.md`（本文件）

- [ ] **Step 1: 从 main 建分支与 worktree**

```bash
cd /Users/yanu/Documents/code/Terminal/treemux
git worktree add -b perf/p3-cleanup .worktrees/perf+p3-cleanup main
```

- [ ] **Step 2: 把本计划复制进 worktree 并提交**

```bash
cp docs/superpowers/plans/2026-07-10-perf-p3-cleanup.md .worktrees/perf+p3-cleanup/docs/superpowers/plans/
cd .worktrees/perf+p3-cleanup
git add docs/superpowers/plans/2026-07-10-perf-p3-cleanup.md
git commit -m "docs(p3): add P3 cleanup implementation plan"
```

- [ ] **Step 3: 在主仓库 `.superpowers/sdd/progress.md` 追加 P3 台账段**（Plan 路径、分支、worktree、Base commit）。

---

### Task 1: DebouncedSaver + settings.json 防抖写盘 + 退出 flush

**Files:**
- Create: `Treemux/Persistence/DebouncedSaver.swift`
- Modify: `Treemux/App/WorkspaceStore.swift:42-47`（settings didSet）、`WorkspaceStore.swift`（新增 saver/queue/flush 成员）
- Modify: `Treemux/App/TreemuxApp.swift:25-28`（shutdown 补 flush）
- Test: `TreemuxTests/DebouncedPersistenceTests.swift`（新建）

**Interfaces:**
- Produces: `DebouncedSaver`（`@MainActor final class`；`init(interval: TimeInterval = 0.25, save: @escaping @MainActor (Mode) -> Void)`；`func schedule()`；`func flush()`（无条件同步保存）；`enum Mode { case debounced, flush }`；`var hasPendingSave: Bool`）——Task 2 复用。
- Produces: `WorkspaceStore.flushPendingPersistence()`（Task 2 会在其中追加 state flush）；`WorkspaceStore` 静态串行队列 `persistenceQueue`。
- Consumes: 既有 `AppSettingsPersistence.save(_:)`（不改）。

- [ ] **Step 1: 写失败测试**

新建 `TreemuxTests/DebouncedPersistenceTests.swift`：

```swift
import XCTest
@testable import Treemux

@MainActor
final class DebouncedPersistenceTests: XCTestCase {

    func testDebouncedSaverCoalescesBurstIntoSingleSave() async {
        var saves: [DebouncedSaver.Mode] = []
        let saver = DebouncedSaver(interval: 0.05) { mode in saves.append(mode) }
        for _ in 0..<5 { saver.schedule() }
        XCTAssertTrue(saves.isEmpty, "must not save before interval elapses")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(saves, [.debounced], "burst must coalesce into exactly one save")
    }

    func testFlushCancelsPendingAndSavesSynchronously() async {
        var saves: [DebouncedSaver.Mode] = []
        let saver = DebouncedSaver(interval: 0.05) { mode in saves.append(mode) }
        saver.schedule()
        saver.flush()
        XCTAssertEqual(saves, [.flush], "flush must save immediately")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(saves, [.flush], "cancelled debounce must not fire afterwards")
    }

    func testFlushWithoutPendingStillSaves() {
        var saves: [DebouncedSaver.Mode] = []
        let saver = DebouncedSaver(interval: 0.05) { mode in saves.append(mode) }
        saver.flush()
        XCTAssertEqual(saves, [.flush], "flush is unconditional so exit always writes latest state")
    }

    func testSettingsChangeIsDebouncedThenFlushPersists() {
        let store = WorkspaceStore()
        var draft = store.settings
        draft.terminal.fontSizeOffset = (draft.terminal.fontSizeOffset == 2) ? 3 : 2
        store.updateSettings(draft)
        store.flushPendingPersistence()
        let reloaded = AppSettingsPersistence().load()
        XCTAssertEqual(reloaded.terminal.fontSizeOffset, draft.terminal.fontSizeOffset,
                       "flush must persist the latest in-memory settings")
    }
}
```

（`fontSizeOffset` 的实际字段名/类型以 `AppSettings.swift`/`TerminalSettings` 为准，选一个既有可写字段；`WorkspaceStore()` 的可构造性以 `WorkspaceStoreBuiltInTests` 既有写法为准，照抄其构造方式。测试会写真实 `~/.treemux-debug/`，这是仓库既有先例。）

- [ ] **Step 2: 跑测试确认失败**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -skipPackagePluginValidation -only-testing:TreemuxTests/DebouncedPersistenceTests
```
预期：编译失败（`DebouncedSaver`/`flushPendingPersistence` 不存在）。

- [ ] **Step 3: 实现 DebouncedSaver**

新建 `Treemux/Persistence/DebouncedSaver.swift`：

```swift
import Foundation

/// Trailing-edge debouncer for persistence writes. Repeated `schedule()`
/// calls within `interval` coalesce into one save. `flush()` cancels any
/// pending timer and saves unconditionally — exit paths always write the
/// latest state, ordered after any in-flight background write.
@MainActor
final class DebouncedSaver {
    enum Mode: Equatable {
        /// Fired by the debounce timer; caller should encode + write on a
        /// background queue.
        case debounced
        /// Fired by `flush()`; caller must encode + write synchronously
        /// (the process may be about to exit).
        case flush
    }

    private let interval: TimeInterval
    private let save: @MainActor (Mode) -> Void
    private var pending: DispatchWorkItem?

    var hasPendingSave: Bool { pending != nil }

    init(interval: TimeInterval = 0.25, save: @escaping @MainActor (Mode) -> Void) {
        self.interval = interval
        self.save = save
    }

    func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.save(.debounced)
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: item)
    }

    func flush() {
        pending?.cancel()
        pending = nil
        save(.flush)
    }
}
```

- [ ] **Step 4: WorkspaceStore 接线**

`Treemux/App/WorkspaceStore.swift`——didSet 只保留 subject（Combine 桥不动），写盘改防抖：

```swift
var settings: AppSettings {
    didSet {
        settingsSaver.schedule()
        settingsSubject.send(settings)
    }
}
```

新增成员（与既有 `@ObservationIgnored` 存储放一起）：

```swift
/// Serial background queue for persistence encoding + IO. Flush paths use
/// `.sync` so the final write is ordered after any in-flight debounced
/// write to the same file.
private static let persistenceQueue = DispatchQueue(label: "treemux.persistence", qos: .utility)

@ObservationIgnored private lazy var settingsSaver = DebouncedSaver { [weak self] mode in
    guard let self else { return }
    let snapshot = self.settings
    let persistence = self.settingsPersistence
    switch mode {
    case .debounced:
        Self.persistenceQueue.async { try? persistence.save(snapshot) }
    case .flush:
        Self.persistenceQueue.sync { try? persistence.save(snapshot) }
    }
}

/// Synchronously writes any pending debounced state to disk. Call on app
/// termination; safe to call at any time.
func flushPendingPersistence() {
    settingsSaver.flush()
}
```

`Treemux/App/TreemuxApp.swift` shutdown 末尾追加：

```swift
windowContext?.store.flushPendingPersistence()
```

（保留既有 `saveWorkspaceState()` 调用，Task 2 再统一。）

- [ ] **Step 5: 跑新测试确认通过；跑全量测试**

单测命令同 Step 2，预期 4 个用例 PASS。然后全量：444+4 绿。若有既有测试依赖「settings 变更后立即落盘」，在该测试的断言前插入 `store.flushPendingPersistence()`。

- [ ] **Step 6: 提交**

```bash
git add -A && git commit -m "perf(p3): debounce settings.json writes with exit flush"
```

---

### Task 2: workspace-state.json 防抖写盘（memo 失效点保持同步）

**Files:**
- Modify: `Treemux/App/WorkspaceStore.swift:605-630`（saveWorkspaceState 拆分）
- Modify: `Treemux/App/TreemuxApp.swift:25-28`（shutdown 收敛为 flush）
- Test: `TreemuxTests/DebouncedPersistenceTests.swift`（追加用例）

**Interfaces:**
- Consumes: Task 1 的 `DebouncedSaver`、`persistenceQueue`、`flushPendingPersistence()`。
- Produces: `saveWorkspaceState()` 外部签名与调用点不变（14 处零改动）；语义变为「缓存失效同步 + 写盘防抖」。

- [ ] **Step 1: 写失败测试**

在 `DebouncedPersistenceTests.swift` 追加：

```swift
func testFlushPendingPersistenceWritesWorkspaceState() throws {
    let store = WorkspaceStore()
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("p3-ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    store.addWorkspaceFromPath(dir.path)   // triggers saveWorkspaceState (now debounced)
    store.flushPendingPersistence()
    let persisted = WorkspaceStatePersistence().load()
    XCTAssertTrue(persisted.workspaces.contains { $0.path == dir.path },
                  "flush must persist workspace added moments before exit")
}
```

（`addWorkspaceFromPath` 签名与 `PersistedWorkspaceState.workspaces` 的记录字段名以实际代码为准，参考 `WorkspaceStoreBuiltInTests` 与 `PersistenceTests.swift:46` 的既有用法调整。）

- [ ] **Step 2: 跑测试确认失败**（此时 flushPendingPersistence 还不含 state，若 saveWorkspaceState 仍同步写盘则该测试先天绿——先做 Step 3 改造，再回来确认「注释掉 flush 调用会红」的判别性，参考 P1a Task 9 oracle 教训。）

- [ ] **Step 3: 拆分 saveWorkspaceState**

```swift
/// Cache invalidation MUST stay synchronous here — this is the single
/// invalidation point for the sidebarIcon/remoteWorkspaceGroups memos
/// (P1a Task 9). Only snapshot building + encoding + disk IO moved to the
/// debounced path.
func saveWorkspaceState() {
    // ← 保留原函数开头的缓存清理行原样（sidebarIconCache / remoteGroupsCache）
    stateSaver.schedule()
}

/// Builds the persisted snapshot on the main actor (reads live models),
/// then encodes + writes off-main for `.debounced`, synchronously for
/// `.flush`.
@ObservationIgnored private lazy var stateSaver = DebouncedSaver { [weak self] mode in
    guard let self else { return }
    let state = self.buildPersistedWorkspaceState()   // ← 原 saveWorkspaceState 中构造 PersistedWorkspaceState 的代码原样搬入该私有方法
    let persistence = self.workspaceStatePersistence
    switch mode {
    case .debounced:
        Self.persistenceQueue.async { try? persistence.save(state) }
    case .flush:
        Self.persistenceQueue.sync { try? persistence.save(state) }
    }
}
```

`flushPendingPersistence()` 追加 `stateSaver.flush()`。

`TreemuxApp.shutdown()` 收敛为：

```swift
func shutdown() {
    windowContext?.store.saveWorkspaceState()      // capture latest live tab state + clear caches
    windowContext?.store.flushPendingPersistence() // synchronous final write of both files
}
```

- [ ] **Step 4: 判别性验证 + 全量测试**

临时注释 `flushPendingPersistence()` 里的 `stateSaver.flush()` → Step 1 测试必须变红；恢复后绿。跑全量：**`WorkspaceStoreIconCacheTests` 必须全绿**（缓存失效仍同步的回归护栏）。若有既有测试在 store 操作后立即读 workspace-state.json，插入 `store.flushPendingPersistence()`。

- [ ] **Step 5: 提交**

```bash
git add -A && git commit -m "perf(p3): debounce workspace-state writes, keep memo invalidation synchronous"
```

---

### Task 3: 启动路径去重（ensureInstalled once-guard + settings 单读）

**Files:**
- Modify: `Treemux/Domain/BuiltInThemes.swift:126-134`（once-guard）
- Modify: `Treemux/UI/Theme/WindowContext.swift:29`（删冗余调用）
- Modify: `Treemux/UI/Theme/ThemeManager.swift:71-73`（删 `ensureBuiltInThemesExist()`，确认无其他调用方）
- Modify: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyRuntime.swift:37,79-80`（settings 读一次、复用）
- Test: `TreemuxTests/BuiltInThemesTests.swift`（追加）

**Interfaces:**
- Produces: `BuiltInThemes.ensureInstalled` 签名不变，新增进程级 once-per-path 语义；DEBUG 测试 seam `BuiltInThemes._resetEnsuredDirectoriesForTesting()`。
- Consumes: P2 `SSHMultiplexing.ensuredDirectories` 的 NSLock+Set 模式（失败不缓存）。

- [ ] **Step 1: 写失败测试**

`TreemuxTests/BuiltInThemesTests.swift` 追加：

```swift
func testEnsureInstalledIsOncePerPathWithinProcess() throws {
    BuiltInThemes._resetEnsuredDirectoriesForTesting()
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("p3-themes-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try BuiltInThemes.ensureInstalled(in: dir)
    let installed = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    XCTAssertFalse(installed.isEmpty)
    // Delete one built-in, call again: the once-guard must skip the rescan,
    // proving the second call does no filesystem work.
    let victim = dir.appendingPathComponent(installed[0])
    try FileManager.default.removeItem(at: victim)
    try BuiltInThemes.ensureInstalled(in: dir)
    XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path),
                   "second ensureInstalled for the same path must be a no-op")
    // Reset seam restores rescan behavior.
    BuiltInThemes._resetEnsuredDirectoriesForTesting()
    try BuiltInThemes.ensureInstalled(in: dir)
    XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
}
```

- [ ] **Step 2: 跑测试确认失败**（`_resetEnsuredDirectoriesForTesting` 不存在 → 编译失败）

- [ ] **Step 3: 实现 once-guard**

`BuiltInThemes.swift`（保持既有函数体，外面包 guard；失败不缓存——throw 时不 insert）：

```swift
// Startup calls ensureInstalled from ThemeManager and the Ghostty runtime;
// only the first call per directory should pay the directory scan.
// Failures are not cached so a transient error is retried next call.
private static let ensuredLock = NSLock()
nonisolated(unsafe) private static var ensuredDirectories: Set<String> = []

#if DEBUG
static func _resetEnsuredDirectoriesForTesting() {
    ensuredLock.lock(); defer { ensuredLock.unlock() }
    ensuredDirectories.removeAll()
}
#endif

static func ensureInstalled(in directory: URL, ...既有参数...) throws {
    let key = directory.path
    ensuredLock.lock()
    let done = ensuredDirectories.contains(key)
    ensuredLock.unlock()
    if done { return }
    // ← 既有函数体原样（createDirectory + 逐内置主题 fileExists/写入）
    ensuredLock.lock()
    ensuredDirectories.insert(key)
    ensuredLock.unlock()
}
```

注意：`ThemeManagerOnAccentTests`/`ThemeManagerDerivedColorTests` 无参构造 `ThemeManager()` 会触真实目录——once-guard 对它们只是提速，不改行为。若其他既有主题测试假设「每次 ensureInstalled 都补齐缺失文件」，在其 setUp 加 `_resetEnsuredDirectoriesForTesting()`。

- [ ] **Step 4: 删冗余调用**

- `WindowContext.swift:29`：删除 `themeManager.ensureBuiltInThemesExist()` 一行（`ThemeManager.init:45` 已 ensure）。
- `ThemeManager.swift:71-73`：`grep -rn "ensureBuiltInThemesExist" Treemux/ TreemuxTests/` 确认仅 WindowContext 一个调用方后删除该方法。
- `TreemuxGhosttyRuntime.swift`：init 内改为读一次 `let loadedSettings = AppSettingsPersistence().load()`，`:37` 用 `loadedSettings.terminal`；`resolveActiveTerminalColors()` 增加参数 `activeThemeID: String`（或直接传整个 settings），`:80` 的第二次 `AppSettingsPersistence().load()` 删除。`grep -n "resolveActiveTerminalColors" Treemux/` 核对全部调用方并同步传参。`:79` 的 `ensureInstalled` 保留（once-guard 后免费）。

- [ ] **Step 5: 全量测试 + 提交**

```bash
git add -A && git commit -m "perf(p3): dedupe startup theme installs and settings reads"
```

---

### Task 4: 主题加载 mtime 缓存

**Files:**
- Modify: `Treemux/Domain/ThemeLoader.swift:23-63`（load 增加 cache 参数）
- Create: `ThemeFileCache`（放入 `ThemeLoader.swift` 同文件）
- Modify: `Treemux/UI/Theme/ThemeManager.swift:46,63-69`（持有 cache 并传入）
- Test: `TreemuxTests/ThemeLoaderTests.swift`（追加）

**Interfaces:**
- Produces: `final class ThemeFileCache`（`func cachedTheme(forPath: String, modificationDate: Date, fileSize: Int) -> Theme?`；`func store(theme: Theme, forPath: String, modificationDate: Date, fileSize: Int)`；DEBUG `private(set) var hitCount: Int`）。**主线程 confined（由 @MainActor ThemeManager 持有），内部不加锁。**
- Produces: `ThemeLoader.load(from:fileManager:cache:)`，`cache` 默认 `nil`（既有调用方零改动）。

- [ ] **Step 1: 写失败测试**（ThemeLoaderTests 既有临时目录惯例，`makeTempDir()`/`write(_:named:to:)` 直接复用）

```swift
func testMtimeCacheSkipsReparseAndInvalidatesOnChange() throws {
    let dir = try makeTempDir()
    try write(validThemeYAML(id: "t1", name: "Alpha"), named: "t1.yaml", to: dir)
    let cache = ThemeFileCache()
    let first = ThemeLoader.load(from: dir, cache: cache)
    XCTAssertEqual(first.themes.first?.name, "Alpha")
    #if DEBUG
    XCTAssertEqual(cache.hitCount, 0)
    #endif
    let second = ThemeLoader.load(from: dir, cache: cache)
    XCTAssertEqual(second.themes.first?.name, "Alpha")
    #if DEBUG
    XCTAssertEqual(cache.hitCount, 1, "unchanged file must be served from cache")
    #endif
    // Oracle: rewrite content with a bumped mtime — a wrong always-hit cache
    // would keep returning "Alpha" and fail here.
    try write(validThemeYAML(id: "t1", name: "Beta"), named: "t1.yaml", to: dir)
    let future = Date().addingTimeInterval(10)
    try FileManager.default.setAttributes([.modificationDate: future],
                                          ofItemAtPath: dir.appendingPathComponent("t1.yaml").path)
    let third = ThemeLoader.load(from: dir, cache: cache)
    XCTAssertEqual(third.themes.first?.name, "Beta", "changed mtime must force reparse")
}
```

（`validThemeYAML(id:name:)` 若无现成 helper，用既有测试里的合法主题 YAML 字面量改 name 字段；显式 setAttributes 未来 mtime 规避文件系统时间戳粒度 flake。）

- [ ] **Step 2: 跑测试确认失败**（`ThemeFileCache` 不存在 → 编译失败）

- [ ] **Step 3: 实现**

`ThemeLoader.swift` 追加：

```swift
/// Per-file parsed-theme cache keyed by absolute path. An entry is reused
/// when both mtime and byte size match, skipping read + YAML decode for
/// unchanged files on reloads (import/delete/reset rescans).
/// Confinement: held by @MainActor ThemeManager; not thread-safe by design.
final class ThemeFileCache {
    private struct Entry {
        let modificationDate: Date
        let fileSize: Int
        let theme: Theme
    }
    private var entries: [String: Entry] = [:]
    #if DEBUG
    private(set) var hitCount = 0
    #endif

    func cachedTheme(forPath path: String, modificationDate: Date, fileSize: Int) -> Theme? {
        guard let e = entries[path],
              e.modificationDate == modificationDate,
              e.fileSize == fileSize else { return nil }
        #if DEBUG
        hitCount += 1
        #endif
        return e.theme
    }

    func store(theme: Theme, forPath path: String, modificationDate: Date, fileSize: Int) {
        entries[path] = Entry(modificationDate: modificationDate, fileSize: fileSize, theme: theme)
    }
}
```

`load` 的每文件循环改造（错误不缓存；缓存命中的主题跳过 read+decode+validate，但**仍走既有 id 去重逻辑**）：

```swift
// per-file loop body:
let attrs = try? fileManager.attributesOfItem(atPath: file.path)
let mtime = attrs?[.modificationDate] as? Date
let size = attrs?[.size] as? Int
if let cache, let mtime, let size,
   let cached = cache.cachedTheme(forPath: file.path, modificationDate: mtime, fileSize: size) {
    appendDedupingByID(cached)   // ← 与既有去重分支同构
    continue
}
// ← 既有 read + decode + validate + 去重 append 原样
if let cache, let mtime, let size {
    cache.store(theme: theme, forPath: file.path, modificationDate: mtime, fileSize: size)
}
```

`ThemeManager`：新增 `@ObservationIgnored private let themeFileCache = ThemeFileCache()`，`init:46` 与 `reloadThemes:64` 的 `ThemeLoader.load(from: themesDirectory)` 都改为传 `cache: themeFileCache`。`TreemuxGhosttyRuntime` 的一次性 load 不传 cache（无重复加载收益）。

- [ ] **Step 4: 全量测试 + 提交**

```bash
git add -A && git commit -m "perf(p3): mtime-cache theme parsing across reloads"
```

---

### Task 5: 文本编码探测后台化（TextEncodingDetector 抽取）

**Files:**
- Create: `Treemux/Services/FileBrowser/TextEncodingDetector.swift`
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift:721-736`（loadText）、`:785-791`（删私有 decode）
- Test: `TreemuxTests/TextEncodingDetectorTests.swift`（新建）

**Interfaces:**
- Produces: `enum TextEncodingDetector { static func decode(_ data: Data) -> (text: String, encoding: String.Encoding) }`——纯函数、线程安全。
- Consumes: 既有 `setOpenFile(forSubTab:expectingPath:)` 防陈旧闸门（不改）。

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import Treemux

final class TextEncodingDetectorTests: XCTestCase {

    func testDetectsUTF8WithMultibyteContent() {
        let data = "中文 mixed ascii".data(using: .utf8)!
        let result = TextEncodingDetector.decode(data)
        XCTAssertEqual(result.text, "中文 mixed ascii")
        XCTAssertEqual(result.encoding, .utf8)
    }

    func testFallsBackToGB18030ForGBKBytes() {
        // "中文" in GB18030: D6 D0 CE C4 — invalid as UTF-8 (0xD0 is a lead
        // byte where a continuation byte is required).
        let data = Data([0xD6, 0xD0, 0xCE, 0xC4])
        let result = TextEncodingDetector.decode(data)
        XCTAssertEqual(result.text, "中文")
        XCTAssertNotEqual(result.encoding, .utf8)
        XCTAssertNotEqual(result.encoding, .isoLatin1)
    }

    func testFallsBackToLatin1ForBytesInvalidInBoth() {
        // 0xFF is not a valid GB18030 lead byte and not valid UTF-8.
        let data = Data([0xFF, 0xFE, 0xFF])
        let result = TextEncodingDetector.decode(data)
        XCTAssertEqual(result.encoding, .isoLatin1)
        XCTAssertEqual(result.text.count, 3)
    }

    func testEmptyDataIsUTF8EmptyString() {
        let result = TextEncodingDetector.decode(Data())
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.encoding, .utf8)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**（类型不存在 → 编译失败）

- [ ] **Step 3: 实现 + 接线**

新建 `TextEncodingDetector.swift`（函数体 = 原 `FileBrowserTabController.decode` 逐字搬移，`FileBrowserTabController.swift:785-791`）：

```swift
import Foundation

/// Detects text encoding by attempting UTF-8 → GB18030 → Latin-1 in order.
/// Pure function, safe on any thread; `loadText` runs it off the main
/// actor so multi-MB files don't stall the UI.
enum TextEncodingDetector {
    static func decode(_ data: Data) -> (text: String, encoding: String.Encoding) {
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8) }
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: data, encoding: gbk) { return (s, gbk) }
        return (String(data: data, encoding: .isoLatin1) ?? "", .isoLatin1)
    }
}
```

`loadText` 中原 `let (content, encoding) = decode(data)`（`:726` 附近）改为：

```swift
let decoded = await Task.detached(priority: .userInitiated) {
    TextEncodingDetector.decode(data)
}.value
```

后续使用 `decoded.text` / `decoded.encoding`，`setOpenFile(forSubTab:expectingPath:)` 调用原样。删除私有 `decode(_:)` 方法。

- [ ] **Step 4: 全量测试**（重点确认 `FileBrowserTabControllerStaleLoadTests` 全绿——新增 suspension point 的竞态由 expectingPath 闸门兜住，该套件是其护栏）

- [ ] **Step 5: 提交**

```bash
git add -A && git commit -m "perf(p3): move text encoding detection off the main thread"
```

---

### Task 6: 图片后台解码 + ImageIO 降采样

**Files:**
- Create: `Treemux/Services/FileBrowser/DownsampledImageDecoder.swift`
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift:738-754`（loadImage）
- Test: `TreemuxTests/DownsampledImageDecoderTests.swift`（新建）

**Interfaces:**
- Produces: `struct DecodedImage: @unchecked Sendable { let cgImage: CGImage; var pixelSize: CGSize }`；`enum DownsampledImageDecoder { static let maxPixelSize: Int; static func decode(_ data: Data) -> DecodedImage? }`——任意线程安全。
- Consumes: `OpenFileState.image(path:image:)`（NSImage 关联值不变）、`ImagePreviewView` 零改动。

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
import AppKit
@testable import Treemux

final class DownsampledImageDecoderTests: XCTestCase {

    private func pngData(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testOversizedImageIsDownsampledToMaxPixelSize() {
        // 5000×100: cheap to allocate, longest edge exceeds the 4096 cap.
        let decoded = DownsampledImageDecoder.decode(pngData(width: 5000, height: 100))
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded!.cgImage.width, DownsampledImageDecoder.maxPixelSize)
        XCTAssertTrue((78...84).contains(decoded!.cgImage.height),
                      "aspect ratio must be preserved (4096/5000 * 100 ≈ 82)")
    }

    func testSmallImageIsNotUpscaled() {
        let decoded = DownsampledImageDecoder.decode(pngData(width: 100, height: 50))
        XCTAssertEqual(decoded?.cgImage.width, 100)
        XCTAssertEqual(decoded?.cgImage.height, 50)
    }

    func testGarbageDataReturnsNil() {
        XCTAssertNil(DownsampledImageDecoder.decode(Data([0x00, 0x01, 0x02, 0x03])))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**（类型不存在 → 编译失败）

- [ ] **Step 3: 实现 decoder**

```swift
import Foundation
import ImageIO
import CoreGraphics

/// Decoded bitmap handed across the background-decode boundary. CGImage is
/// immutable and thread-safe; the wrapper documents the transfer.
struct DecodedImage: @unchecked Sendable {
    let cgImage: CGImage
    var pixelSize: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }
}

/// Decodes image data via ImageIO with forced downsampling: the produced
/// bitmap is capped at `maxPixelSize` on its longest edge and fully decoded
/// up front (no lazy decode on first draw). Safe on any thread.
enum DownsampledImageDecoder {
    /// Longest-edge cap for preview bitmaps. 4096 px covers a full Retina
    /// screen while bounding worst-case memory (~64 MB BGRA).
    static let maxPixelSize = 4096

    static func decode(_ data: Data) -> DecodedImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return DecodedImage(cgImage: cgImage)
    }
}
```

- [ ] **Step 4: loadImage 接线**

`FileBrowserTabController.swift:738-754`，`if let img = NSImage(data: data)` 分支替换为：

```swift
let decoded = await Task.detached(priority: .userInitiated) {
    DownsampledImageDecoder.decode(data)
}.value
if let decoded {
    let img = NSImage(cgImage: decoded.cgImage, size: decoded.pixelSize)
    setOpenFile(forSubTab: subTabID, expectingPath: path, .image(path: path, image: img))
} else {
    setOpenFile(forSubTab: subTabID, expectingPath: path, .error(path: path, message: "Cannot decode image"))
}
```

（错误串沿用既有 "Cannot decode image"，i18n 不新增。行为说明：>4096px 图片显示为降采样位图——`ImagePreviewView` 是 `.scaledToFit()` 全屏预览，视觉无差；动图 GIF 原本经 `Image(nsImage:)` 也只显示首帧，无行为回退。`DataURIImageProvider.swift:16` 的内嵌小图不在本任务范围，保持原样。）

- [ ] **Step 5: 全量测试**（`FileBrowserTabControllerTests` + `FileBrowserTabControllerStaleLoadTests` 必须全绿）

- [ ] **Step 6: 提交**

```bash
git add -A && git commit -m "perf(p3): decode images off-main with ImageIO downsampling"
```

---

### Task 7: 隐藏文件过滤后台化（世代守卫 + 原子替换）

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift:54`（rawChildrenByPath 加 didSet）、`:362-374`（setShowsHiddenFiles）
- Test: `TreemuxTests/FileBrowserTabControllerTests.swift:10-25`（既有用例 await 化）、`TreemuxTests/FileTreeRowModelTests.swift`（追加 memo 用例）

**Interfaces:**
- Produces: `FileBrowserTabController.pendingHiddenFilterTask: Task<Void, Never>?`（`private(set)`，测试用 `await ctrl.pendingHiddenFilterTask?.value` 等待过滤落地）。
- Consumes: `visibleRowsCache` 失效机制零改动（过滤结果仍写 `childrenByPath`/`rootChildren`，其 didSet 自动失效 memo；R4 触读块不动）。
- 前置检查：确认 `FileNode` 为全值类型 struct（隐式 Sendable）；若编译器要求，在声明处补 `Sendable` 显式标注。

- [ ] **Step 1: 改造既有测试为 await 版并新增用例（先红）**

`FileBrowserTabControllerTests.swift` 的 `test_setShowsHiddenFiles_recoversHiddenAfterToggleOff`：每次 `ctrl.setShowsHiddenFiles(...)` 后插入 `await ctrl.pendingHiddenFilterTask?.value`（断言结构不变）。追加：

```swift
func test_rapidHiddenToggleConvergesToLatestState() async {
    let mock = MockFileBrowserDataSource()
    mock.directoryListings["/r"] = [
        FileNode(name: ".hidden", path: "/r/.hidden", isDirectory: false),
        FileNode(name: "visible.txt", path: "/r/visible.txt", isDirectory: false),
    ]
    let state = FileBrowserTabState(rootPath: "/r", rootKind: .project, showsHiddenFiles: true)
    let ctrl = FileBrowserTabController(initial: state, dataSource: mock)
    await ctrl.loadRoot()
    ctrl.setShowsHiddenFiles(false)
    ctrl.setShowsHiddenFiles(true)   // immediately toggle back, no await between
    await ctrl.pendingHiddenFilterTask?.value
    XCTAssertEqual(ctrl.rootChildren.count, 2, "latest toggle (show=true) must win")
}
```

（`FileNode`/`MockFileBrowserDataSource`/`FileBrowserTabState` 构造参数以既有测试 `:10-25` 的写法为准照抄。）

`FileTreeRowModelTests.swift` "Task 8 Part B" 段追加 memo 用例：

```swift
func testVisibleRowsCacheInvalidatesOnHiddenFilterApply() async {
    // 构造含隐藏文件的树（照抄本文件既有用例的 controller 构造惯例）
    _ = ctrl.visibleRows()
    let before = ctrl.visibleRowsComputeCount
    ctrl.setShowsHiddenFiles(false)
    await ctrl.pendingHiddenFilterTask?.value
    let rows = ctrl.visibleRows()
    XCTAssertEqual(ctrl.visibleRowsComputeCount, before + 1, "filter apply must invalidate the memo")
    XCTAssertFalse(rows.contains { $0.id.hasSuffix("/.hidden") })
}
```

- [ ] **Step 2: 跑测试确认失败**（`pendingHiddenFilterTask` 不存在 → 编译失败）

- [ ] **Step 3: 实现**

`FileBrowserTabController.swift`。`rawChildrenByPath`（`:54`）加 didSet；新增两个 `@ObservationIgnored` 成员：

```swift
@ObservationIgnored private var rawChildrenByPath: [String: [FileNode]] = [:] {
    didSet { rawTreeGeneration += 1 }
}

/// Monotonic generation for rawChildrenByPath. The async hidden-file filter
/// compares it before applying, so a tree mutation that lands mid-filter
/// (expand/refresh completing) restarts the filter instead of clobbering
/// newer entries with a stale derived dictionary.
@ObservationIgnored private var rawTreeGeneration = 0

/// Test seam: awaiting this task guarantees the last toggle has been applied.
@ObservationIgnored private(set) var pendingHiddenFilterTask: Task<Void, Never>?
```

`setShowsHiddenFiles` 改为：

```swift
func setShowsHiddenFiles(_ show: Bool) {
    guard showsHiddenFiles != show else { return }
    showsHiddenFiles = show
    rederiveFilteredChildren()
    onPersistableStateChanged?()
}

/// Re-derives the filtered listings from the unfiltered cache off the main
/// actor, then applies the result atomically. The whole-tree O(n) filter
/// used to run synchronously here and stalled the main thread on large trees.
private func rederiveFilteredChildren() {
    let show = showsHiddenFiles
    let raw = rawChildrenByPath
    let generation = rawTreeGeneration
    pendingHiddenFilterTask?.cancel()
    pendingHiddenFilterTask = Task { [weak self] in
        let derived = await Task.detached(priority: .userInitiated) { () -> [String: [FileNode]] in
            var result: [String: [FileNode]] = [:]
            result.reserveCapacity(raw.count)
            for (path, nodes) in raw {
                result[path] = show ? nodes : nodes.filter { !$0.isHidden }
            }
            return result
        }.value
        guard let self, !Task.isCancelled else { return }
        guard self.rawTreeGeneration == generation, self.showsHiddenFiles == show else {
            self.rederiveFilteredChildren()   // inputs moved mid-filter; recompute fresh
            return
        }
        self.childrenByPath = derived
        self.rootChildren = derived[self.rootPath] ?? []
        self.pendingHiddenFilterTask = nil
    }
}
```

竞态论证（写进代码评审说明即可，不用注释）：`Task {}` 闭包继承 @MainActor，await 前后的代码与所有 toggle/树变更主线程串行；后到的 toggle 先 cancel 旧任务再起新任务，旧任务恢复时 `Task.isCancelled` 拦截；展开/刷新落在过滤窗口内则 generation 不等 → 用最新 raw 重算，有界收敛（每次重算都基于最新快照）。其余 6 个 `filtered()` 写入点（toggleExpand/refresh 等单目录小量）保持同步不动。

- [ ] **Step 4: 全量测试**（重点：`test_setShowsHiddenFiles_recoversHiddenAfterToggleOff` await 版、`FileTreeRowModelTests` 全部 memo 用例、`FileBrowserTreeAccelerationTests`）

- [ ] **Step 5: 提交**

```bash
git add -A && git commit -m "perf(p3): move hidden-file filtering off-main with generation guard"
```

---

### Task 8: 不可见 surface 遮挡挂起（独立开关 + footprint 量化）

**Files:**
- Modify: `Treemux/Domain/AppSettings.swift`（TerminalSettings 加开关 + decodeIfPresent）
- Modify: `Treemux/UI/Settings/SettingsSheet.swift`（终端区加 Toggle）
- Modify: `Treemux/Localizable.xcstrings`（新字符串 zh-Hans）
- Modify: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyRuntime.swift`（持有开关值）
- Modify: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift`（TreemuxGhosttySurfaceView 接线）
- Test: `TreemuxTests/PersistenceTests.swift`（追加设置编解码用例）

**Interfaces:**
- Produces: `TerminalSettings.suspendHiddenSurfaces: Bool`（默认 `true`）；`TreemuxGhosttyRuntime.shared.suspendHiddenSurfaces`（随 `.treemuxTerminalSettingsDidChange` 更新）；`TreemuxGhosttySurfaceView.updateSurfaceOcclusion()`。
- Consumes: `ghostty_surface_set_occlusion`（`ghostty.h:1087`）、既有 `.treemuxTerminalSettingsDidChange` 通知（`WorkspaceStore.swift:11,61`）、既有 surface 观察者注册点（`TreemuxGhosttyController.swift:709` registerAdaptiveFontObservers）。

- [ ] **Step 0: 核实 API 语义（先于一切代码）**

Read `ghostty.h:1080-1090` 附近的注释块，确认 `ghostty_surface_set_occlusion(surface, bool)` 的 bool 语义（上游 Ghostty macOS app 在 `windowDidChangeOcclusionState` 中以 `visible = window.occlusionState.contains(.visible)` 传参，即 **true = 可见**）。若头文件注释表明相反，下文所有 `visible` 传参取反。把核实结论写进任务报告。

- [ ] **Step 1: 写失败测试（设置编解码）**

`PersistenceTests.swift` 追加：

```swift
func testTerminalSettings_suspendHiddenSurfacesDefaultsTrueAndRoundTrips() throws {
    // Old settings.json without the key must default to true (backward compat).
    let legacy = #"{"terminal":{}}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
    XCTAssertTrue(decoded.terminal.suspendHiddenSurfaces)

    var settings = AppSettings()
    settings.terminal.suspendHiddenSurfaces = false
    let data = try JSONEncoder().encode(settings)
    let roundTripped = try JSONDecoder().decode(AppSettings.self, from: data)
    XCTAssertFalse(roundTripped.terminal.suspendHiddenSurfaces)
}
```

（legacy JSON 骨架按 `AppSettings.init(from:)` 对必填 key 的实际要求补齐，参考本文件既有兼容性用例的最小 JSON 写法。）

- [ ] **Step 2: 跑测试确认失败**（字段不存在 → 编译失败）

- [ ] **Step 3: 设置模型 + UI + i18n**

`AppSettings.swift` 的 `TerminalSettings`：

```swift
/// When true, surfaces detached from any window (hidden tabs/worktrees)
/// and surfaces in fully occluded windows report non-visible to libghostty
/// so its renderer can throttle them. Kill switch for the P3 occlusion
/// experiment — turning it off restores pre-P3 behavior at runtime.
var suspendHiddenSurfaces: Bool = true
```

`init(from:)` 按既有惯例（`AppSettings.swift:91-92` 样式）加 `decodeIfPresent(...) ?? true`；encode 侧照抄邻近字段。

`SettingsSheet.swift` 终端区（`:250` 起）按 `:184` 的 Toggle 样板加：

```swift
Toggle("Pause Rendering of Hidden Terminals", isOn: $draft.terminal.suspendHiddenSurfaces)
```

（绑定变量名以该文件实际草稿变量为准——终端区若绑定 `$draft.terminal.xxx` 就照抄。）`Treemux/Localizable.xcstrings` 添加 `"Pause Rendering of Hidden Terminals"` → zh-Hans `"暂停渲染隐藏的终端"`。

- [ ] **Step 4: Runtime 持有开关 + surface 接线**

`TreemuxGhosttyRuntime.swift`：新增 `private(set) var suspendHiddenSurfaces: Bool`，init 时从（Task 3 的）单次 settings 读取初始化；在既有 `.treemuxTerminalSettingsDidChange` 处理处（若 runtime 无该观察者则新增）更新该值。

`TreemuxGhosttyController.swift` 的 `TreemuxGhosttySurfaceView`：

```swift
private var occlusionObserver: NSObjectProtocol?

override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let occlusionObserver {
        NotificationCenter.default.removeObserver(occlusionObserver)
        self.occlusionObserver = nil
    }
    if let window {
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSurfaceOcclusion() }
        }
    }
    updateSurfaceOcclusion()
}

/// Reports visibility to libghostty. A view detached from any window
/// (hidden tab/worktree — TerminalViewContainer removes it from the
/// hierarchy) or in a fully occluded window reports non-visible so the
/// renderer can throttle. With the setting off, every surface reports
/// visible, matching pre-P3 behavior.
func updateSurfaceOcclusion() {
    guard let surface else { return }
    let featureOn = TreemuxGhosttyRuntime.shared.suspendHiddenSurfaces
    let visible = !featureOn || (window?.occlusionState.contains(.visible) ?? false)
    ghostty_surface_set_occlusion(surface, visible)
}
```

接线补齐：(a) `createSurface`（`:1180` 附近）成功后调 `updateSurfaceOcclusion()`；(b) `destroySurface`/`deinit` 里 removeObserver；(c) 设置开关运行时切换要立刻生效——在 surface 视图既有的 `.treemuxTerminalSettingsDidChange` 观察者（`registerAdaptiveFontObservers`，`:709`）回调里追加 `updateSurfaceOcclusion()`（开关关闭时全部 surface 立即回到 visible，这就是运行时回退路径）。

- [ ] **Step 5: 全量测试绿 + 提交实现**

```bash
git add -A && git commit -m "perf(p3): suspend occluded ghostty surfaces behind a setting"
```

- [ ] **Step 6: footprint 量化（研究交付物）**

Debug 构建跑真机场景：同一窗口开 2 个工作区共 5 个终端 pane，每个 pane 跑 `yes > /dev/null` 类持续输出后停止；切到只显示 1 个 pane 的 tab，稳定 30s。分别在开关 ON / OFF 下采集：

```bash
footprint <pid> | grep -E "IOSurface|IOAccelerator|phys_footprint"
ps -o rss= -p <pid>
```

各 3 次取均值，记入 `docs/perf/baseline.md`「P3 surface occlusion」小节：对照设计文档基线（5 surface：footprint 791MB / IOSurface 488MB / IOAccelerator 115MB），给出 ON vs OFF 的 IOSurface、IOAccelerator、phys_footprint、CPU（`top -pid` 采样）差值。**结论分支**：(a) 有可测收益 → 开关默认值维持 `true`，数据进台账；(b) 无收益或有渲染副作用（切回 tab 内容不刷新等）→ 开关默认值改 `false`（一行改动 + 测试同步），实施保留但默认关闭，交由用户在终审时定夺。把量化结果与建议写进任务报告。

- [ ] **Step 7: 提交量化结果**

```bash
git add docs/perf/baseline.md && git commit -m "docs(p3): record surface occlusion footprint measurements"
```

---

### Task 9: 终验（全量测试 + Scenario B 基准 + 收尾）

**Files:**
- Modify: `docs/perf/baseline.md`（P3 小节汇总）
- Modify: `TreemuxTests/EditorBufferIsolationTests.swift:69`（顺手清账）
- 主仓库 `.superpowers/sdd/progress.md`（台账收尾）

- [ ] **Step 1: 顺手修 P1b 遗留警告**

`EditorBufferIsolationTests.swift:69`：Swift-6 模式警告（@Sendable onChange 闭包里改捕获 var `fired`）——按 `ObservationChangeCounter` 同款模式改用 `MainActor.assumeIsolated`。跑该文件单测确认绿。

- [ ] **Step 2: 全量测试三连跑**

全量命令连续跑 2-3 次确认无 flake（P2 的教训：竞态往往只在全量跑时暴露）。用 xcresulttool 核对测试计数 ≥ 先前基线 444 + 本计划新增用例数。

- [ ] **Step 3: Scenario B 基准（回归守卫）**

`scripts/perf-baseline.sh` 同天交错跑 branch vs main 各 3 次（去首跑取均值）。P3 改动不在 Scenario B 热路径上，验收标准是**不回归**（方差窗口内持平）。记入 `docs/perf/baseline.md`「P3 完成」小节，附 ⌘= 防抖的定性证据：长按 ⌘= 连发 3 秒，`stat -f %m ~/.treemux-debug/settings.json` 前后对比确认松手后仅一次 mtime 变更（对照 main 的逐键变更）。

- [ ] **Step 4: 提交基准 + 终审**

```bash
git add docs/perf/baseline.md && git commit -m "docs(p3): record P3 baseline comparison"
```

发起最终全分支评审（opus 级），триage 各任务遗留 minor；0 Critical / 0 Important 后进入用户 GUI 冒烟。

- [ ] **Step 5: 用户 GUI 冒烟清单（合并前的用户闸门）**

编译后告知用户运行命令（DerivedData 编号见记忆 `feedback_deriveddata_path.md`，编译后核实实际编号）：
`rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<编号>/Build/Products/Debug/Treemux.app`

清单：
1. 长按 ⌘= / ⌘- 连发：界面流畅；退出重开后字号保留（退出 flush 生效）。
2. 改设置 → 直接 ⌘Q 快速退出 → 重开：设置与工作区/标签状态完整。
3. 设置面板导入/删除主题、恢复内置主题；切主题即时生效（App UI + 终端配色同步）。
4. 打开 >4096px 大图（本地 + 远程各一）：不卡顿、显示正确；损坏图片文件显示错误提示。
5. 打开 GBK 编码中文文本：显示正常、编辑保存后编码不变。
6. 1000+ 行大树切换「显示隐藏文件」：无卡顿；快速连点最终状态正确；远程工作区同验。
7. 多 tab 多 pane 终端：切走 30s 再切回，终端内容即时恢复刷新、无冻结/白屏；关闭设置开关后行为回到常驻渲染。
8. 侧栏折叠/展开分区、增删工作区后重启：状态保留（workspace-state 防抖未丢写）。

- [ ] **Step 6: 合并与清理（用户冒烟通过后）**

```bash
cd /Users/yanu/Documents/code/Terminal/treemux
git merge --no-ff perf/p3-cleanup -m "Merge perf/p3-cleanup: P3 cleanup — persistence debounce, theme mtime cache, off-main image/text decode, hidden-filter backgrounding, surface occlusion"
# 合并后全量测试绿 → 清理
git worktree remove .worktrees/perf+p3-cleanup
git branch -d perf/p3-cleanup
```

台账与记忆收尾：`.superpowers/sdd/progress.md` 记 P3 CLOSED；更新 `project_perf_upgrade_v2_status.md`（性能升级 v2 全部完成）。

---

## Self-Review 记录

- **Spec 覆盖**：§P3 五项全部映射——写盘防抖(T1/T2)、主题 mtime 缓存+启动去重(T3/T4)、大图后台解码+降采样+编码探测后台化(T5/T6)、隐藏文件过滤后台化(T7)、surface 挂起调研+独立开关(T8)。验收四条对应 T9 Step 3（⌘=）、T4（切主题）、T6（大图）、T9 Step 3（基准不回归）。设计文档「文本编码探测后台化」归在 §P3 图片条目内，T5 单列。
- **占位符**：任务中「以实际代码为准/照抄既有写法」仅限于构造参数与字段名对齐（实施者拥有代码可查），核心逻辑全部给出完整代码。
- **类型一致性**：`DebouncedSaver.Mode`（T1 定义，T2 消费）、`flushPendingPersistence`（T1 定义，T2 扩展）、`ThemeFileCache.cachedTheme/store`（T4 内一致）、`pendingHiddenFilterTask`（T7 定义与测试一致）、`suspendHiddenSurfaces`（T8 模型/运行时/视图三处同名）已核对。
