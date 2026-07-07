# 性能升级 P0（基准与埋点）+ P1a（状态层外科手术）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 固化可复现的性能基准（P0），并落地不依赖 @Observable 迁移的高收益重渲染修复（P1a）：文件树行级解耦、编辑器击键隔离、终端回调发布去重。

**Architecture:** 三条互不依赖的改造线：① `os_signpost` 埋点 + 基准脚本；② 文件树由「每行观察整个 controller」改为「父视图单点观察 → 扁平化值模型按行下传 + Equatable 短路」；③ `ShellSession`/ghostty 回调链加相等性守卫与主线程快路径。@Observable 迁移（P1b）单独出计划。

**Tech Stack:** Swift 5 / SwiftUI / Combine（现状保留）、OSLog signpost、XCTest、zsh + python3 基准脚本。

**设计文档:** `docs/superpowers/specs/2026-07-07-performance-fluidity-v2-design.md`

## Global Constraints

- 所有开发在新分支 + `.worktrees/<branch-name>/` 内进行；主目录停在 `main`。建议分支名 `perf/p0-p1a-surgical`（worktree 路径 `.worktrees/perf+p0-p1a-surgical/`）。
- 构建/测试一律加 `-skipPackagePluginValidation`（SwiftLint 插件非交互校验）。
- 新增 `.swift` 文件后必须 `xcodegen generate` 并提交重新生成的 `Treemux.xcodeproj/project.pbxproj`（project.yml folder-glob）。
- 354 个既有测试保持全绿；本计划不新增任何用户可见字符串与颜色（无 i18n/主题工作）。
- 侧栏 `NSHostingView` 子树（`SidebarCellView`/`SidebarNodeRow`/`SidebarItemIconView`）**禁止**引入任何 `@EnvironmentObject`/`@Environment` 注入（678fda8 闪退史）。本计划不触碰这些文件。
- 全量测试命令：`xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -quiet`

---

### Task 1: PerfSignpost 埋点辅助层

**Files:**
- Create: `Treemux/Support/PerfSignpost.swift`
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift:345-356`（refreshGitStatus）
- Modify: `Treemux/App/WindowContext.swift:21` 附近（窗口构建区间）
- Test: `TreemuxTests/PerfSignpostTests.swift`

**Interfaces:**
- Produces: `enum PerfSignpost`，静态方法 `begin(_ name: StaticString) -> OSSignpostIntervalState`、`end(_ name: StaticString, _ state: OSSignpostIntervalState)`、`event(_ name: StaticString)`。后续任务与基准脚本按名字过滤：`git-status-refresh`、`window-construct`、`tree-generation-bump`。

- [ ] **Step 1: 写失败测试**

```swift
// TreemuxTests/PerfSignpostTests.swift
import XCTest
@testable import Treemux

final class PerfSignpostTests: XCTestCase {
    // Signpost emission is fire-and-forget; the contract we can test is that
    // the API is callable in any order without crashing and returns a state
    // token usable exactly once.
    func testBeginEndEventDoNotCrash() {
        let state = PerfSignpost.begin("git-status-refresh")
        PerfSignpost.event("tree-generation-bump")
        PerfSignpost.end("git-status-refresh", state)
    }
}
```

- [ ] **Step 2: 跑测试确认编译失败**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/PerfSignpostTests -quiet`
Expected: FAIL（`cannot find 'PerfSignpost'`）。注意：新增测试文件后先 `xcodegen generate`。

- [ ] **Step 3: 实现 PerfSignpost**

```swift
// Treemux/Support/PerfSignpost.swift
import OSLog

/// os_signpost wrappers used by the perf baseline (docs/perf/baseline.md).
/// Intervals/events are recorded under subsystem "com.batchzero.treemux",
/// category "perf" — filter with Instruments or `log stream`.
enum PerfSignpost {
    static let signposter = OSSignposter(subsystem: "com.batchzero.treemux", category: "perf")

    @discardableResult
    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }
}
```

- [ ] **Step 4: `xcodegen generate` 后跑测试确认通过**

Run: 同 Step 2。Expected: PASS。

- [ ] **Step 5: 接入两个埋点**

`FileBrowserTabController.refreshGitStatus`（当前 345-356 行）改为：

```swift
    func refreshGitStatus() async {
        guard let svc = gitDiffService, let root = repoRoot else { return }
        let sp = PerfSignpost.begin("git-status-refresh")
        defer { PerfSignpost.end("git-status-refresh", sp) }
        let result = (try? await svc.fileStatus(in: root)) ?? [:]
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var byPath: [String: FileStatus] = [:]
        for (rel, st) in result {
            // Renames are already keyed under the new (post-rename) path by
            // the porcelain parser, so a simple prefix join is sufficient.
            byPath[prefix + rel] = st
        }
        fileStatusByPath = byPath
    }
```

`WindowContext.init` 中，把「ThemeManager 构建 → makeKeyAndOrderFront」整段包进 `window-construct` 区间：在 `ThemeManager(activeThemeID:)` 调用前 `let sp = PerfSignpost.begin("window-construct")`，在 `makeKeyAndOrderFront` 之后 `PerfSignpost.end("window-construct", sp)`（以文件内实际语句为准，保持原逻辑不动）。

另外在 `FileBrowserTabController` 内每次 `treeContentGeneration += 1` 的位置（当前 `:220` 附近，grep `treeContentGeneration +=` 为准）前加一行 `PerfSignpost.event("tree-generation-bump")`。

- [ ] **Step 6: 编译 + 全量测试 + 提交**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -quiet
git add Treemux/Support/PerfSignpost.swift TreemuxTests/PerfSignpostTests.swift Treemux/UI/FileBrowser/FileBrowserTabController.swift Treemux/App/WindowContext.swift Treemux.xcodeproj/project.pbxproj
git commit -m "perf(p0): add os_signpost helper and instrument git refresh / window construct"
```

---

### Task 2: 基准脚本与 baseline.md

**Files:**
- Create: `scripts/perf-baseline.sh`
- Create: `docs/perf/baseline.md`

**Interfaces:**
- Produces: `bash scripts/perf-baseline.sh <path-to-Treemux.app>` → 输出 markdown 表格行（场景 / 主线程样本数 / ViewGraph / AttributeGraph / NSHostingView / RSS）。使用独立状态目录与合成 fixture 仓库，不触碰用户真实状态。

- [ ] **Step 1: 写脚本**

```bash
#!/bin/bash
# scripts/perf-baseline.sh — reproducible perf baseline for Treemux.
# Usage: bash scripts/perf-baseline.sh /path/to/Debug/Treemux.app
# Scenarios:
#   A. cold start with a pre-expanded ~1000-row file tree (10s sample)
#   B. git-status refresh with that tree visible (8s sample, touch .git/index)
# Prints a markdown table; paste rows into docs/perf/baseline.md.
set -euo pipefail

APP="${1:?usage: perf-baseline.sh <Treemux.app>}"
FIXTURE="$HOME/.treemux-perf-fixture"
STATE_DIR="$HOME/.treemux-debug"
OUT_DIR="$(mktemp -d)"

# --- 1. Synthetic repo: 10 dirs x 100 files = 1000 tree rows, deterministic.
if [ ! -d "$FIXTURE/.git" ]; then
  rm -rf "$FIXTURE"; mkdir -p "$FIXTURE"
  ( cd "$FIXTURE"
    git init -q
    for d in $(seq -w 1 10); do
      mkdir -p "dir$d"
      for f in $(seq -w 1 100); do echo "x" > "dir$d/file$f.txt"; done
    done
    git add -A && git -c user.email=perf@treemux -c user.name=perf commit -qm seed )
fi

# --- 2. Seed debug state: fileBrowser tab with all 10 dirs expanded.
pkill -f "$APP/Contents/MacOS/Treemux" 2>/dev/null || true; sleep 1
rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"
python3 - "$FIXTURE" "$STATE_DIR" <<'PY'
import json, sys, uuid
fixture, state_dir = sys.argv[1], sys.argv[2]
u = lambda: str(uuid.uuid4()).upper()
ws_id, tab_id = u(), u()
expanded = [f"{fixture}/dir{d:02d}" for d in range(1, 11)]
state = {"selectedWorkspaceID": ws_id, "version": 1, "workspaces": [{
  "id": ws_id, "isArchived": False, "isBuiltInDefaultTerminal": False,
  "isPinned": False, "kind": "repository", "name": "perf-fixture",
  "repositoryPath": fixture,
  "worktreeStates": [{"selectedTabID": tab_id, "worktreePath": fixture, "tabs": [{
    "id": tab_id, "isManuallyNamed": False, "kind": "fileBrowser",
    "layout": {"pane": {"_0": {"paneID": u()}}}, "panes": [], "title": "files",
    "fileBrowserState": {"rootPath": fixture, "rootKind": "project",
      "splitRatio": 0.28, "expandedDirs": expanded, "showsHiddenFiles": False,
      "subTabs": [], "activeSubTabID": None}}]}]}]}
json.dump(state, open(f"{state_dir}/workspace-state.json", "w"), indent=2)
PY

# --- 3. Scenario A: launch + 10s sample.
open "$APP"; sleep 1
PID=$(pgrep -nf "$APP/Contents/MacOS/Treemux")
sample "$PID" 10 -file "$OUT_DIR/a.txt" >/dev/null 2>&1
RSS_A=$(ps -o rss= -p "$PID" | tr -d ' ')

# --- 4. Scenario B: git refresh + 8s sample.
sleep 2
sample "$PID" 8 -file "$OUT_DIR/b.txt" >/dev/null 2>&1 &
SP=$!; sleep 1; touch "$FIXTURE/.git/index"; wait $SP
RSS_B=$(ps -o rss= -p "$PID" | tr -d ' ')
kill "$PID" 2>/dev/null || true

# --- 5. Parse main-thread SwiftUI-graph sample counts.
report() {
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
path, label, rss = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, errors="ignore").read().splitlines()
main, out, depth0 = [], None, None
for l in lines:
    m = re.match(r"^    (\d+) Thread_\d+.*(Main Thread|DispatchQueue_1)", l)
    if m: out = int(m.group(1)); main = []; continue
    if out is not None:
        if re.match(r"^    \d+ Thread_", l): break
        main.append(l)
body = "\n".join(main)
def count(pat):
    return sum(int(n) for n in re.findall(r"(\d+) [^\n]*" + pat, body))
print(f"| {label} | {out} | {count('ViewGraph')} | {count('AG::|AGGraph')} | "
      f"{count('NSHostingView')} | {int(rss)//1024}MB |")
PY
}
echo "| 场景 | 主线程样本 | ViewGraph | AttributeGraph | NSHostingView | RSS |"
echo "|---|---|---|---|---|---|"
report "$OUT_DIR/a.txt" "A 启动+1000行树(10s)" "$RSS_A"
report "$OUT_DIR/b.txt" "B git刷新(8s)" "$RSS_B"
echo "(raw samples: $OUT_DIR)"
```

- [ ] **Step 2: 对当前 main 构建跑一次，验证脚本可重复**

```bash
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -quiet
APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/Treemux-*/Build/Products/Debug/Treemux.app | head -1)
bash scripts/perf-baseline.sh "$APP"
bash scripts/perf-baseline.sh "$APP"   # 跑两次，主要计数波动应 < 20%
```
Expected: 两次输出表格，ViewGraph/AttributeGraph 计数同数量级。

- [ ] **Step 3: 写 baseline.md（把 Step 2 实测数字填入）**

```markdown
# 性能基线（docs/perf/baseline.md）

测量方法：`bash scripts/perf-baseline.sh <Debug/Treemux.app>`，Debug 构建，@1ms 采样。
判读：ViewGraph/AttributeGraph 列 ≈ 主线程花在 SwiftUI 视图图重算上的样本数，越低越好。

## 改前（main @ <commit>，日期）
<粘贴 Step 2 表格>

## 历史参考（2026-07-07 手工实测，cataclysm-dda 约 1000 行展开）
| 场景 | 结果 |
|---|---|
| 启动 15s 采样 | ViewGraph 3814 + AGGraph 2354 + NSHostingView 1272 样本；RSS 290MB |
| 空树对照 | RSS 141MB |
```

- [ ] **Step 4: 提交**

```bash
git add scripts/perf-baseline.sh docs/perf/baseline.md
git commit -m "perf(p0): add reproducible baseline script and initial numbers"
```

---

### Task 3: ShellSession 回调发布去重

**Files:**
- Modify: `Treemux/Services/Terminal/ShellSession.swift:102-121`（configureSurfaceCallbacks）
- Test: `TreemuxTests/ShellSessionPublishDedupTests.swift`

**Interfaces:**
- Consumes: `ManagedTerminalSessionSurfaceController`（`Treemux/Services/Terminal/TerminalSurface.swift:77`）、`ShellSession(id:backendConfiguration:preferredWorkingDirectory:surfaceController:)` 注入式初始化（`ShellSession.swift:82`）。
- Produces: 行为契约「回调值未变化时不触发 `objectWillChange`」。

- [ ] **Step 1: 写失败测试（含测试 fake）**

```swift
// TreemuxTests/ShellSessionPublishDedupTests.swift
import XCTest
import Combine
import AppKit
@testable import Treemux

/// Minimal surface fake: records callbacks, no real terminal.
@MainActor
private final class FakeSurfaceController: ManagedTerminalSessionSurfaceController {
    var resolvedEngine: TerminalEngineKind { .libghosttyPreferred }
    let view = NSView()
    var onResize: ((Int, Int) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onWorkingDirectoryChange: ((String?) -> Void)?
    var onFocus: (() -> Void)?
    var onStatusChange: ((TerminalSurfaceStatusSnapshot) -> Void)?
    var onDesktopNotification: ((String, String?) -> Void)?
    var onUserInput: (() -> Void)?
    var managedPID: Int32? { nil }
    var isManagedSessionRunning: Bool { false }
    var needsConfirmQuit: Bool { false }
    var onProcessExit: ((Int32?) -> Void)?
    func sendText(_ text: String) {}
    func focus() {}
    func setFocused(_ isFocused: Bool) {}
    func beginSearch(initialText: String?) {}
    func updateSearch(_ text: String) {}
    func searchNext() {}
    func searchPrevious() {}
    func endSearch() {}
    func toggleReadOnly() {}
    func updateLaunchConfiguration(_ configuration: TerminalLaunchConfiguration) {}
    func startManagedSessionIfNeeded() {}
    func restartManagedSession() {}
    func terminateManagedSession() {}
}

@MainActor
final class ShellSessionPublishDedupTests: XCTestCase {
    private func makeSession(surface: FakeSurfaceController) -> ShellSession {
        ShellSession(
            backendConfiguration: .localShell(shellPath: "/bin/zsh", arguments: ["--login"]),
            preferredWorkingDirectory: "/tmp",
            surfaceController: surface
        )
    }

    func testRepeatedIdenticalResizeDoesNotRepublish() {
        let surface = FakeSurfaceController()
        let session = makeSession(surface: surface)
        var publishes = 0
        let sub = session.objectWillChange.sink { _ in publishes += 1 }
        defer { sub.cancel() }

        surface.onResize?(120, 40)
        let afterFirst = publishes
        surface.onResize?(120, 40)   // same values: must be a no-op
        surface.onResize?(120, 40)
        XCTAssertEqual(publishes, afterFirst, "identical resize must not republish")
        surface.onResize?(121, 40)   // changed: must publish again
        XCTAssertGreaterThan(publishes, afterFirst)
    }

    func testIdenticalStatusSnapshotDoesNotRepublish() {
        let surface = FakeSurfaceController()
        let session = makeSession(surface: surface)
        var publishes = 0
        let sub = session.objectWillChange.sink { _ in publishes += 1 }
        defer { sub.cancel() }

        let snap = TerminalSurfaceStatusSnapshot()
        surface.onStatusChange?(snap)
        let afterFirst = publishes
        surface.onStatusChange?(snap)
        XCTAssertEqual(publishes, afterFirst)
    }

    func testIdenticalTitleAndCwdDoNotRepublish() {
        let surface = FakeSurfaceController()
        let session = makeSession(surface: surface)
        var publishes = 0
        let sub = session.objectWillChange.sink { _ in publishes += 1 }
        defer { sub.cancel() }

        surface.onTitleChange?("zsh")
        surface.onWorkingDirectoryChange?("/tmp")
        let afterFirst = publishes
        surface.onTitleChange?("zsh")
        surface.onWorkingDirectoryChange?("/tmp")
        XCTAssertEqual(publishes, afterFirst)
    }
}
```

注意：`backendConfiguration` 的具体构造以 `SessionBackendConfiguration` 实际 API 为准（grep `case localShell` / 工厂方法），测试意图不变。

- [ ] **Step 2: 跑测试确认失败**

Run: `xcodebuild test ... -only-testing:TreemuxTests/ShellSessionPublishDedupTests -quiet`
Expected: `testRepeatedIdenticalResizeDoesNotRepublish` 等 3 条 FAIL（当前无守卫，每次回调都发布）。

- [ ] **Step 3: 实现守卫**

`ShellSession.configureSurfaceCallbacks()`（当前 102-121 行）改为：

```swift
    private func configureSurfaceCallbacks() {
        surfaceController.onResize = { [weak self] cols, rows in
            guard let self else { return }
            // Resize callbacks fire per-frame during window drags even when
            // the grid did not change; skip no-op publishes.
            let c = max(cols, 2)
            let r = max(rows, 2)
            if self.cols != c { self.cols = c }
            if self.rows != r { self.rows = r }
        }
        surfaceController.onTitleChange = { [weak self] title in
            guard let self, !title.isEmpty, title != self.title else { return }
            self.title = title
            self.detectTmux(fromTitle: title)
        }
        surfaceController.onWorkingDirectoryChange = { [weak self] directory in
            guard let self, directory != self.reportedWorkingDirectory else { return }
            self.reportedWorkingDirectory = directory
        }
        surfaceController.onFocus = { [weak self] in
            self?.onFocus?()
        }
        surfaceController.onStatusChange = { [weak self] status in
            guard let self, status != self.surfaceStatus else { return }
            self.surfaceStatus = status
        }
        // …（onProcessExit 及后续保持原样）
    }
```

- [ ] **Step 4: 跑测试确认通过 + 全量测试**

Run: Task 专项 + 全量。Expected: 全 PASS。

- [ ] **Step 5: 提交**

```bash
git add Treemux/Services/Terminal/ShellSession.swift TreemuxTests/ShellSessionPublishDedupTests.swift Treemux.xcodeproj/project.pbxproj
git commit -m "perf(p1a): dedupe ShellSession surface-callback publishes"
```

---

### Task 4: ghostty 回调主线程快路径 + 去掉每键空转派发

**Files:**
- Modify: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift:369-373`（handleSurfaceResize）、`:431-436`（notifyStatusChange）、`:791` 与 `:897-899`（onUserInput 空转派发）

**Interfaces:**
- Consumes: Task 3 的值守卫（本任务只减少 hop 次数，语义不变）。

- [ ] **Step 1: 实现主线程快路径**

```swift
    fileprivate func handleSurfaceResize(cols: Int, rows: Int) {
        // setFrameSize already runs on the main thread; only hop when the
        // callback arrives from a libghostty background thread.
        if Thread.isMainThread {
            onResize?(cols, rows)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onResize?(cols, rows)
            }
        }
    }

    fileprivate func notifyStatusChange() {
        if Thread.isMainThread {
            onStatusChange?(terminalView.statusSnapshot)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onStatusChange?(self.terminalView.statusSnapshot)
            }
        }
    }
```

注意 `notifyStatusChange` 在类内的 `terminalView` 访问方式以现有代码为准（当前 `:434` 直接访问）。

- [ ] **Step 2: 去掉每键空转派发**

`keyDown`（`:897-899`）与 `mouseDown`（`:791`）中的
```swift
DispatchQueue.main.async { [weak self] in self?.controller?.onUserInput?() }
```
改为
```swift
if let onUserInput = controller?.onUserInput { onUserInput() }
```
（`onUserInput` 全仓库从未被赋值，恒为 nil；保留调用点语义，去掉无条件的 runloop 派发。keyDown/mouseDown 本就在主线程。）

- [ ] **Step 3: 编译 + 全量测试 + 手动冒烟**

全量测试 PASS 后，构建产物手动开一个终端敲键、拖拽窗口边缘 resize，确认回显与尺寸联动正常。

- [ ] **Step 4: 提交**

```bash
git add Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift
git commit -m "perf(p1a): main-thread fast path for resize/status callbacks; drop per-key no-op dispatch"
```

---

### Task 5: 文件树扁平化行模型（controller 侧）

**Files:**
- Create: `Treemux/UI/FileBrowser/FileTreeRowModel.swift`
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift`（新增 `visibleRows()`）
- Test: `TreemuxTests/FileTreeRowModelTests.swift`

**Interfaces:**
- Consumes: `FileBrowserTabController` 的 `rootChildren`、`childrenByPath`、`expandedDirs`、`fileStatusByPath`、`truncatedDirs`、`selectedFilePath`、`rootPath`（均为现有属性）。
- Produces:
  ```swift
  struct FileTreeRowModel: Equatable, Identifiable {
      enum Kind: Equatable { case node(FileNode), loadMore(parentPath: String) }
      let id: String            // node path, or "loadMore:<parentPath>"
      let kind: Kind
      let depth: Int
      let isSelected: Bool
      let isExpanded: Bool
      let status: FileStatus?
  }
  // FileBrowserTabController:
  func visibleRows() -> [FileTreeRowModel]
  ```
  Task 6 的视图层依赖以上签名。前提：`FileNode` 与 `FileStatus` 已是 `Equatable`（`FileNode` 用于 ForEach diff，若尚未遵循则在本任务补 `extension FileNode: Equatable`，按全字段比较）。

- [ ] **Step 1: 写失败测试**

```swift
// TreemuxTests/FileTreeRowModelTests.swift
import XCTest
@testable import Treemux

@MainActor
final class FileTreeRowModelTests: XCTestCase {
    /// Builds a controller over the stub data source used by existing
    /// FileBrowserTabControllerTests (reuse that fixture pattern: a temp
    /// directory tree on disk + LocalFileBrowserDataSource).
    private func makeController(root: String) -> FileBrowserTabController {
        FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: root, rootKind: .project),
            dataSource: LocalFileBrowserDataSource()
        )
    }

    private func makeTempTree() throws -> String {
        let root = NSTemporaryDirectory() + "rowmodel-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/sub", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/a.txt", contents: Data())
        fm.createFile(atPath: root + "/sub/b.txt", contents: Data())
        return root
    }

    func testFlattensExpandedDirsDepthFirst() async throws {
        let root = try makeTempTree()
        let c = makeController(root: root)
        await c.loadRoot()
        await c.toggleExpand(root + "/sub")

        let rows = c.visibleRows()
        let ids = rows.map(\.id)
        // Depth-first: sub, then its child, then the sibling file.
        XCTAssertEqual(ids, [root + "/sub", root + "/sub/b.txt", root + "/a.txt"])
        XCTAssertEqual(rows[0].depth, 0)
        XCTAssertEqual(rows[1].depth, 1)
        XCTAssertTrue(rows[0].isExpanded)
    }

    func testCollapsedDirHidesChildren() async throws {
        let root = try makeTempTree()
        let c = makeController(root: root)
        await c.loadRoot()
        XCTAssertFalse(c.visibleRows().map(\.id).contains(root + "/sub/b.txt"))
    }

    func testRowModelEqualityIsValueBased() async throws {
        let root = try makeTempTree()
        let c = makeController(root: root)
        await c.loadRoot()
        // Two computations with no state change must be element-wise equal —
        // this is what lets the view layer skip unchanged rows.
        XCTAssertEqual(c.visibleRows(), c.visibleRows())
    }
}
```

注意：`makeController`/`LocalFileBrowserDataSource` 的实际构造以 `TreemuxTests/FileBrowserTabControllerTests.swift` 既有 fixture 写法为准（复用它的 helper，不要另起炉灶）；目录排序为 naturalOrder、目录优先与否以 `buildNodes` 实际行为为准，断言的期望顺序据此调整（意图：深度优先 + 展开可见、折叠不可见、双算相等）。

- [ ] **Step 2: 跑测试确认失败**（`visibleRows()` 不存在，编译失败）

- [ ] **Step 3: 实现 FileTreeRowModel + visibleRows()**

```swift
// Treemux/UI/FileBrowser/FileTreeRowModel.swift
import Foundation

/// Value snapshot of one visible file-tree row. The tree view renders from
/// a flat `[FileTreeRowModel]` computed by the controller, so each row view
/// can be Equatable-skipped instead of observing the whole controller.
struct FileTreeRowModel: Equatable, Identifiable {
    enum Kind: Equatable {
        case node(FileNode)
        case loadMore(parentPath: String)
    }

    let id: String
    let kind: Kind
    let depth: Int
    let isSelected: Bool
    let isExpanded: Bool
    let status: FileStatus?
}
```

```swift
// FileBrowserTabController 内新增（放在 filtered(_:) 之后）：

    /// Flattens the expanded tree into visible rows, depth-first. This is the
    /// single source the tree view renders from; rows are pure values so
    /// SwiftUI can skip unchanged rows via Equatable.
    func visibleRows() -> [FileTreeRowModel] {
        var rows: [FileTreeRowModel] = []
        func emit(_ nodes: [FileNode], depth: Int) {
            for node in nodes {
                let expanded = node.isDirectory && expandedDirs.contains(node.path)
                rows.append(FileTreeRowModel(
                    id: node.path,
                    kind: .node(node),
                    depth: depth,
                    isSelected: selectedFilePath == node.path,
                    isExpanded: expanded,
                    status: fileStatusByPath[node.path]
                ))
                if expanded, let kids = childrenByPath[node.path] {
                    emit(kids, depth: depth + 1)
                    if truncatedDirs.contains(node.path) {
                        rows.append(FileTreeRowModel(
                            id: "loadMore:" + node.path,
                            kind: .loadMore(parentPath: node.path),
                            depth: depth + 1,
                            isSelected: false, isExpanded: false, status: nil
                        ))
                    }
                }
            }
        }
        emit(rootChildren, depth: 0)
        if truncatedDirs.contains(rootPath) {
            rows.append(FileTreeRowModel(
                id: "loadMore:" + rootPath, kind: .loadMore(parentPath: rootPath),
                depth: 0, isSelected: false, isExpanded: false, status: nil
            ))
        }
        return rows
    }
```

- [ ] **Step 4: `xcodegen generate` + 跑测试确认通过 + 提交**

```bash
git add Treemux/UI/FileBrowser/FileTreeRowModel.swift Treemux/UI/FileBrowser/FileBrowserTabController.swift TreemuxTests/FileTreeRowModelTests.swift Treemux.xcodeproj/project.pbxproj
git commit -m "perf(p1a): add flattened FileTreeRowModel and controller.visibleRows()"
```

---

### Task 6: NodeRow 改为值驱动 + Equatable 短路

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileTreePanelView.swift:43-65`（树体）、`:199-330`（NodeRow/LoadMoreRow）

**Interfaces:**
- Consumes: Task 5 的 `FileTreeRowModel` / `visibleRows()`。
- Produces: 视觉与交互行为不变（选中高亮、展开/折叠、双击 pin、右键复制路径、git 状态点、Load more、滚动恢复照旧）。

- [ ] **Step 1: 重写树体 ForEach**

`FileTreePanelView.body` 中 `ScrollView` 内（当前 56-63 行）改为：

```swift
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.visibleRows()) { row in
                        FileTreeRow(
                            row: row,
                            density: store.settings.fileTree.density,
                            controller: controller
                        )
                        .equatable()
                    }
                }
                .padding(.vertical, 4)
```

- [ ] **Step 2: 用值驱动的 FileTreeRow 取代 NodeRow**

删除现有 `NodeRow`（`:199-322`），新增（同文件内）：

```swift
/// One visible tree row, rendered purely from a FileTreeRowModel value.
/// `controller` is a plain (unobserved) reference used only for actions —
/// re-rendering is driven by the parent recomputing `visibleRows()`.
private struct FileTreeRow: View, Equatable {
    let row: FileTreeRowModel
    let density: TreeDensity
    let controller: FileBrowserTabController
    @EnvironmentObject private var theme: ThemeManager
    @State private var isHovered = false

    // Equality intentionally ignores `controller` (same instance for the
    // whole tree) and `theme` (rare, environment-driven).
    nonisolated static func == (lhs: FileTreeRow, rhs: FileTreeRow) -> Bool {
        lhs.row == rhs.row && lhs.density == rhs.density
    }

    var body: some View {
        switch row.kind {
        case .node(let node):
            nodeBody(node)
        case .loadMore(let parentPath):
            LoadMoreRow(path: parentPath, depth: row.depth, controller: controller)
        }
    }

    private func nodeBody(_ node: FileNode) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<row.depth, id: \.self) { _ in
                Rectangle()
                    .fill(theme.dividerColor)
                    .frame(width: 1, height: density.rowHeight)
                    .padding(.trailing, 13)
            }
            if node.isDirectory {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textMuted)
                    .frame(width: 12)
            } else {
                Spacer().frame(width: 12)
            }
            if let status = row.status {
                Circle()
                    .fill(color(for: status))
                    .frame(width: 4, height: 4)
            } else {
                Color.clear.frame(width: 4, height: 4)
            }
            iconView(node)
                .frame(width: density.fontSize + 3, height: density.fontSize + 3)
            Text(node.name)
                .font(DesignFonts.dataLayer(size: density.fontSize))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .frame(height: density.rowHeight)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(row.isSelected ? theme.sidebarSelection
                      : isHovered ? theme.textPrimary.opacity(0.06)
                      : Color.clear)
        )
        .overlay(alignment: .leading) {
            if row.isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.accentColor)
                    .frame(width: 2.5)
                    .padding(.vertical, 3)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .gesture(
            TapGesture(count: 2).onEnded {
                if !node.isDirectory {
                    Task { await controller.pinFile(node.path) }
                }
            }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                if node.isDirectory {
                    Task { await controller.toggleExpand(node.path) }
                } else {
                    Task { await controller.openInTree(node.path) }
                }
            }
        )
        .contextMenu {
            Button(LocalizedStringKey("Copy Absolute Path")) {
                controller.copyPath(node.path, mode: .absolute)
            }
            Button(LocalizedStringKey("Copy Relative Path")) {
                controller.copyPath(node.path, mode: .relative)
            }
            .disabled(node.path == controller.rootPath)
        }
    }

    @ViewBuilder
    private func iconView(_ node: FileNode) -> some View {
        let icon = FileIconCatalog.icon(for: node, isExpanded: row.isExpanded)
        Image(icon.asset)
            .resizable()
            .renderingMode(icon.isTemplate ? .template : .original)
            .scaledToFit()
            .foregroundStyle(icon.tintRole.map { theme.fileIconTint($0) } ?? theme.textSecondary)
    }

    private func color(for status: FileStatus) -> Color {
        switch status {
        case .untracked: return .gray
        case .modified, .renamed(_): return .orange
        case .added: return .green
        case .deleted: return .red
        }
    }
}
```

保留 `LoadMoreRow` 原实现不动（它行数少且只在截断目录出现）。`FileTreePanelView` 本身继续 `@ObservedObject controller` —— 它是**唯一**订阅者，负责在任何变化时重算 `visibleRows()`；未变化的行由 `.equatable()` 短路跳过 body。

注意：`.equatable()` 要求 View 遵循 Equatable 且 SwiftUI 在 POD 检查失败时（本视图含引用/闭包）使用自定义 `==`——这正是我们要的。若编译器对 `nonisolated static func ==` 报隔离错误，把 `FileTreeRow` 标注 `@MainActor` 并去掉 `nonisolated`（以能编译为准，语义相同）。

- [ ] **Step 3: 全量测试 + 手动验证**

全量测试 PASS。手动验证清单（用 `scripts/perf-baseline.sh` 的 fixture 或任意仓库）：展开/折叠、单击打开文件、双击 pin、右键复制路径、git 改动后状态点出现、Load more 出现与工作、切 tab 后滚动位置恢复。

- [ ] **Step 4: 跑基准对比**

```bash
APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/Treemux-*/Build/Products/Debug/Treemux.app | head -1)
bash scripts/perf-baseline.sh "$APP"
```
Expected: 场景 A/B 的 ViewGraph+AttributeGraph 计数相对 baseline.md「改前」显著下降（目标 ≥ 60%，设计文档验收）。把数字追加进 baseline.md 的「P1a 后」小节。

- [ ] **Step 5: 提交**

```bash
git add Treemux/UI/FileBrowser/FileTreePanelView.swift docs/perf/baseline.md
git commit -m "perf(p1a): value-driven Equatable file tree rows; stop per-row controller observation"
```

---

### Task 7: 编辑器击键与全局发布隔离

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift`（updateBuffer/saveCurrentFile/setActiveOpenFile 一带 + 新增 bufferByTab 存储）
- Modify: `Treemux/UI/FileBrowser/TextEditorView.swift:153-159`（language 的 utf8.count）
- Test: `TreemuxTests/EditorBufferIsolationTests.swift`

**Interfaces:**
- Consumes: `SubTabRuntime.openFile: OpenFileState`（`.text(path:content:encoding:dirty:)`）。
- Produces:
  ```swift
  // FileBrowserTabController:
  private(set) var liveBufferByTab: [UUID: String]   // NOT @Published
  func updateBuffer(content: String, forSubTab id: UUID)  // 签名不变
  func liveBuffer(for id: UUID) -> String?
  ```
  行为契约：击键只在 **dirty 首次翻转** 时发布一次；后续击键零发布。保存/读取一律以 `liveBuffer(for:) ?? openFile.content` 为准。

- [ ] **Step 1: 写失败测试**

```swift
// TreemuxTests/EditorBufferIsolationTests.swift
import XCTest
import Combine
@testable import Treemux

@MainActor
final class EditorBufferIsolationTests: XCTestCase {
    // Reuse the temp-tree + controller fixture pattern from
    // FileBrowserTabControllerTests: create a temp dir with one text file,
    // loadRoot, open the file so a .text sub-tab exists.
    private func makeControllerWithOpenFile() async throws -> (FileBrowserTabController, UUID) {
        let root = NSTemporaryDirectory() + "bufiso-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root + "/a.txt", contents: Data("hello".utf8))
        let c = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: root, rootKind: .project),
            dataSource: LocalFileBrowserDataSource()
        )
        await c.loadRoot()
        await c.openInTree(root + "/a.txt")
        let id = try XCTUnwrap(c.activeSubTabID)
        return (c, id)
    }

    func testKeystrokesPublishOnlyOnDirtyTransition() async throws {
        let (c, id) = try await makeControllerWithOpenFile()
        var publishes = 0
        let sub = c.objectWillChange.sink { _ in publishes += 1 }
        defer { sub.cancel() }

        c.updateBuffer(content: "hello1", forSubTab: id)   // dirty flips: 1 publish
        let afterFirst = publishes
        XCTAssertGreaterThan(afterFirst, 0)
        c.updateBuffer(content: "hello12", forSubTab: id)  // already dirty: no publish
        c.updateBuffer(content: "hello123", forSubTab: id)
        XCTAssertEqual(publishes, afterFirst, "subsequent keystrokes must not publish")
        XCTAssertEqual(c.liveBuffer(for: id), "hello123")
    }

    func testSavePersistsLiveBufferAndClearsDirty() async throws {
        let (c, id) = try await makeControllerWithOpenFile()
        c.updateBuffer(content: "changed", forSubTab: id)
        try await c.saveCurrentFile()
        if case .text(let path, let content, _, let dirty) = c.openFile {
            XCTAssertEqual(content, "changed")
            XCTAssertFalse(dirty)
            XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "changed")
        } else {
            XCTFail("expected .text open file")
        }
    }
}
```

`openInTree` 的实际方法名/签名以控制器现有 API 为准（存在 `openInTree(_:)` 与 `pinFile(_:)`，见 `FileTreePanelView` 调用点）。

- [ ] **Step 2: 跑测试确认失败**（`liveBuffer(for:)` 不存在，编译失败；第一条断言当前实现也不成立——每键都发布）

- [ ] **Step 3: 实现 buffer 隔离**

`FileBrowserTabController` 新增存储与访问器，并改写 `updateBuffer` / `saveCurrentFile`：

```swift
    /// Live (per-keystroke) editor buffers, keyed by sub-tab id. Intentionally
    /// NOT @Published: keystrokes must not fan out to every observer of this
    /// controller (tree rows, tab bars). The published `openFile` keeps the
    /// content it had when the tab was opened / last saved; `dirty` is the only
    /// flag that publishes, exactly once per dirty transition.
    private(set) var liveBufferByTab: [UUID: String] = [:]

    func liveBuffer(for id: UUID) -> String? { liveBufferByTab[id] }

    func updateBuffer(content: String, forSubTab id: UUID) {
        guard let idx = subTabs.firstIndex(where: { $0.id == id }) else { return }
        guard case .text(let path, let opened, let encoding, let dirty) = subTabs[idx].openFile else { return }
        guard subTabs[idx].path == path else { return }
        liveBufferByTab[id] = content
        if !dirty {
            // First divergence from the on-disk content: publish once so the
            // dirty dot and close-guard update.
            subTabs[idx].openFile = .text(path: path, content: opened, encoding: encoding, dirty: true)
        }
    }
```

`saveCurrentFile`（当前 682-698 行）改为以 live buffer 为准：

```swift
    func saveCurrentFile() async throws {
        guard let id = activeSubTabID,
              case .text(let path, let opened, let encoding, _) = activeOpenFile else {
            return
        }
        let content = liveBufferByTab[id] ?? opened
        let data = content.data(using: encoding) ?? Data()
        try await dataSource.writeFile(path, data: data)
        liveBufferByTab[id] = nil
        setActiveOpenFile(.text(path: path, content: content, encoding: encoding, dirty: false))
        Task { [weak self] in
            await self?.refreshDiffForActive()
            await self?.refreshGitStatus()
        }
    }
```

清理点：关闭/复用 sub-tab 的路径（close/repurpose 相关方法，grep `subTabs.remove` / `openFile = .empty`）要同步 `liveBufferByTab[id] = nil`；「放弃未保存修改」的现有流程语义不变（live buffer 直接丢弃即可）。dirty 判定（`dirtySubTabs`、`isDirty`）无需改——dirty 标志仍在 `openFile` 里。

外部重载（`.onChange(of: content)` 把编辑器缓冲重置为 `content`）语义保留：`openFile.content` 仅在打开/保存/显式 reload 时变化，与现状一致。

- [ ] **Step 4: 修 utf8.count 每帧重算**

`TextEditorView.language`（`:153-159`）把 `content.utf8.count` 换成一次性计算：`CodeEditorRepresentable` 已在 `init` 收到 `content`，将高亮决策上提为存储属性：

```swift
    // init 内新增（一次性，避免每次 body O(n) 重算 utf8.count）：
    self.highlightEligible = EditorHighlightPolicy.shouldHighlight(
        path: path, byteCount: content.utf8.count
    )
    // 属性:
    private let highlightEligible: Bool
    // language 计算属性首行改为:
    guard highlightEligible,
          let lang = FileTypeClassifier.language(forPath: path) else { return .default }
```

- [ ] **Step 5: 跑测试（专项 + 全量）确认通过**

- [ ] **Step 6: 手动验证 + 基准**

打开 fixture 里一个文件连续输入：文件树不应随击键闪烁（可用 Instruments SwiftUI 模板或肉眼观察 CPU）；保存后内容落盘、dirty 点消失；切 sub-tab 再切回，未保存内容仍在（live buffer 生命周期随 sub-tab）。

- [ ] **Step 7: 提交**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift Treemux/UI/FileBrowser/TextEditorView.swift TreemuxTests/EditorBufferIsolationTests.swift Treemux.xcodeproj/project.pbxproj
git commit -m "perf(p1a): isolate editor keystrokes from controller-wide publishes"
```

---

### Task 8: WorkspaceStore 手工失效改 generation 计数

**Files:**
- Modify: `Treemux/App/WorkspaceStore.swift:469`（objectWillChange.send）

**Interfaces:**
- Produces: `@Published private(set) var workspaceMetadataGeneration: Int = 0`。订阅方无需变化（任何 `@Published` 变化都会触发 `objectWillChange`，行为等价），但 P1b 迁移 @Observable 时该属性可被精确追踪。

- [ ] **Step 1: 替换**

`WorkspaceStore` 属性区（其余 `@Published` 旁）新增：

```swift
    /// Bumped whenever git worktree metadata for any workspace is refreshed.
    /// Replaces a bare objectWillChange.send() so the invalidation survives
    /// the @Observable migration (which has no objectWillChange).
    @Published private(set) var workspaceMetadataGeneration: Int = 0
```

`:469` 的
```swift
            // Notify SwiftUI that child model data changed so the sidebar rebuilds.
            objectWillChange.send()
```
改为
```swift
            // Notify SwiftUI that child model data changed so the sidebar rebuilds.
            workspaceMetadataGeneration += 1
```

- [ ] **Step 2: 全量测试 + 手动验证**

全量 PASS；手动：本地 git 仓库工作区里 `git checkout -b tmp && git checkout -` 后侧栏分支名正常刷新。

- [ ] **Step 3: 提交**

```bash
git add Treemux/App/WorkspaceStore.swift
git commit -m "perf(p1a): replace manual objectWillChange.send with metadata generation counter"
```

---

### Task 9: sidebarIcon O(N²) 与 remoteWorkspaceGroups 缓存

**Files:**
- Modify: `Treemux/App/WorkspaceStore.swift:566-590`（sidebarIcon）、`:137-145`（remoteWorkspaceGroups）
- Test: `TreemuxTests/WorkspaceStoreIconCacheTests.swift`

**Interfaces:**
- Produces: `sidebarIcon(for:)` / `remoteWorkspaceGroups` 签名与语义不变；新增私有缓存，随 `workspaces` 结构性变化失效。

- [ ] **Step 1: 写失败测试**

```swift
// TreemuxTests/WorkspaceStoreIconCacheTests.swift
import XCTest
@testable import Treemux

@MainActor
final class WorkspaceStoreIconCacheTests: XCTestCase {
    func testSidebarIconIsStableAcrossRepeatedCalls() {
        let store = WorkspaceStore()   // 以既有测试的构造方式为准（如需注入持久化 stub，复用现有 fixture）
        guard let ws = store.workspaces.first else { return }
        let first = store.sidebarIcon(for: ws)
        for _ in 0..<10 {
            XCTAssertEqual(store.sidebarIcon(for: ws), first,
                           "icon must be deterministic and cached")
        }
    }
}
```

（`WorkspaceStore()` 若在测试环境需要隔离持久化目录，参照 `TreemuxTests` 中现有 WorkspaceStore 相关测试的做法；没有则允许该测试直接用默认构造。）

- [ ] **Step 2: 实现缓存**

```swift
    // WorkspaceStore 属性区:
    /// Caches generated repository icons; invalidated whenever the workspace
    /// list mutates (add/remove/rename/icon change all call saveWorkspaceState).
    private var sidebarIconCache: [UUID: SidebarItemIcon] = [:]

    // sidebarIcon(for:) 的 .repository 分支改为:
        case .repository:
            if let cached = sidebarIconCache[workspace.id] { return cached }
            let existingIcons = workspaces
                .filter { $0.id != workspace.id && !$0.isArchived && $0.kind == .repository }
                .compactMap { $0.workspaceIcon ?? generatedRepositoryIcon(for: $0) }
            let iconSeed: String
            if let remotePath = workspace.sshTarget?.remotePath, !remotePath.isEmpty {
                iconSeed = (remotePath as NSString).lastPathComponent
            } else {
                iconSeed = workspace.repositoryRoot?.lastPathComponent ?? workspace.name
            }
            let icon = SidebarItemIcon.randomRepository(
                preferredSeed: iconSeed,
                avoiding: existingIcons
            )
            sidebarIconCache[workspace.id] = icon
            return icon
```

失效点：`saveWorkspaceState()` 开头加 `sidebarIconCache.removeAll()`（它已是全部结构性变更的汇聚点，含改图标/增删/重命名）。`remoteWorkspaceGroups` 同法：新增 `private var remoteGroupsCache: [(key: String, targets: [WorkspaceModel])]?`，getter 先查缓存，`saveWorkspaceState()` 同点失效（`remoteGroupsCache = nil`）。

- [ ] **Step 3: 专项 + 全量测试通过后提交**

```bash
git add Treemux/App/WorkspaceStore.swift TreemuxTests/WorkspaceStoreIconCacheTests.swift Treemux.xcodeproj/project.pbxproj
git commit -m "perf(p1a): cache sidebar repository icons and remote workspace groups"
```

---

### Task 10: 收尾——全量回归 + 基准定稿

**Files:**
- Modify: `docs/perf/baseline.md`

- [ ] **Step 1: 全量测试**

Run: 全量命令。Expected: 354+（含本计划新增）全绿。

- [ ] **Step 2: 基准终跑并记录**

```bash
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -quiet
APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/Treemux-*/Build/Products/Debug/Treemux.app | head -1)
bash scripts/perf-baseline.sh "$APP"
```
把结果写入 `baseline.md` 的「P1a 后（<commit>）」小节，与「改前」并排。验收线：场景 A/B 的 ViewGraph+AttributeGraph 合计下降 ≥ 60%；未达标时优先检查 `.equatable()` 是否生效（Instruments SwiftUI View Body 计数按行视图分组看）。

- [ ] **Step 3: 提交 + 汇报**

```bash
git add docs/perf/baseline.md
git commit -m "perf(p1a): record post-P1a baseline numbers"
```
合并回 `main` 走用户惯例流程（merge + 清理 worktree），合并信息附改前/改后基准表。

---

## 自审记录

- **Spec 覆盖**：设计文档 P0 两项（signpost、基准脚本+baseline.md）→ Task 1/2；P1 第 2 项（NodeRow 解耦）→ Task 5/6；第 3 项（击键隔离 + utf8.count）→ Task 7;第 4 项（发布去重 + hop 快路径）→ Task 3/4；第 5 项（generation 计数）→ Task 8；第 6 项（两个缓存）→ Task 9。P1 第 1 项（@Observable 迁移本体）**有意不在本计划**（P1b 单独出计划，前置于本计划合并后）。
- **类型一致性**：`FileTreeRowModel`/`visibleRows()`（Task 5 产出 = Task 6 消费）；`liveBuffer(for:)`（Task 7 内自洽）；`PerfSignpost`（Task 1 产出 = Task 2 脚本按 category 过滤，脚本实际用 sample 解析、signpost 供 Instruments 用，不冲突。
- **占位符扫描**：无 TBD;三处「以现有代码/既有 fixture 为准」的说明均给出了 grep 锚点与意图约束，属对既有 API 的引用而非留白。
