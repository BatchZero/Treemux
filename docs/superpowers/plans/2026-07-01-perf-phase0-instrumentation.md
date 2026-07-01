# Perf Phase 0 — Instrumentation & Baselines Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a testable `os_signpost` instrumentation layer, wire it into the five hot paths, and produce a repeatable baseline-measurement protocol — so every later phase has a metric to prove wins against.

**Architecture:** A tiny global facade `Perf` forwards signposts to a swappable `PerfRecorder`. Production uses `OSSignpostRecorder` (→ `OSSignposter`, visible in Instruments); tests install a spy recorder and assert instrumentation fires. Five existing hot paths get `begin`/`end` (or `event`) calls. A `docs/perf/baseline.md` document defines the scenarios and holds the captured numbers.

**Tech Stack:** Swift, `os` framework (`OSSignposter`), XCTest, xcodegen (folder-based sources), xcodebuild.

## Global Constraints

- **Deployment target:** macOS 15.0. `OSSignposter` is available (macOS 12+).
- **Worktree discipline:** main repo dir stays on `main`. All work happens in `.worktrees/perf+phase0-instrumentation/` on branch `perf+phase0-instrumentation`.
- **No behavior change:** Phase 0 only adds instrumentation; it must not alter functional semantics.
- **Tests stay green:** the existing 354-test suite must pass after every task.
- **New files need regeneration:** sources are folder-based in `project.yml` (`- path: Treemux`, `- path: TreemuxTests`). After creating any new `.swift` file, run `xcodegen generate` before building.
- **Build/test flag:** non-interactive `xcodebuild` requires `-skipPackagePluginValidation` (SwiftLint plugin).
- **Signpost identity (fixed, copy verbatim):** subsystem `com.batchzero.treemux`, category `perf`.
- **Signpost names (fixed, copy verbatim):** `input.keydown`, `render.tick`, `filetree.expand`, `workspace.switch`, `theme.load`.

---

## Pre-flight: worktree

Before Task 1, create the isolated workspace (via superpowers:using-git-worktrees at execution time, or directly):

```bash
git worktree add -b perf+phase0-instrumentation .worktrees/perf+phase0-instrumentation main
```

All subsequent paths are relative to that worktree.

---

## File Structure

- **Create** `Treemux/Support/Perf/PerfSignpost.swift` — the `Perf` facade, `PerfRecorder` protocol, `PerfToken`, `PerfSignpostAction`, `OSSignpostRecorder`, and the `interval` convenience helpers. One file, one responsibility: performance signposting.
- **Create** `TreemuxTests/PerfSignpostTests.swift` — spy recorder + unit tests for the facade and `interval` helpers.
- **Modify** `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift:896` — `keyDown` interval.
- **Modify** `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyRuntime.swift:101` — `tick` interval.
- **Modify** `Treemux/UI/FileBrowser/FileBrowserTabController.swift:274` — `toggleExpand` interval.
- **Modify** `Treemux/App/WorkspaceStore.swift:17` — `selectedWorkspaceID` didSet event.
- **Modify** `Treemux/Domain/ThemeLoader.swift:23` — `load(from:)` interval.
- **Create** `docs/perf/baseline.md` — measurement protocol + results tables.

---

### Task 1: Perf facade + recorder + spy

**Files:**
- Create: `Treemux/Support/Perf/PerfSignpost.swift`
- Test: `TreemuxTests/PerfSignpostTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum PerfSignpostAction: Equatable { case begin(String); case end(String); case event(String) }`
  - `struct PerfToken { let id: UInt64; let payload: Any? }`
  - `protocol PerfRecorder: AnyObject { func begin(_ name: StaticString) -> PerfToken; func end(_ name: StaticString, _ token: PerfToken); func event(_ name: StaticString) }`
  - `final class OSSignpostRecorder: PerfRecorder`
  - `enum Perf` with static `recorder`, `begin(_:) -> PerfToken`, `end(_:_:)`, `event(_:)`

- [ ] **Step 1: Write the failing test**

Create `TreemuxTests/PerfSignpostTests.swift`:

```swift
import XCTest
@testable import Treemux

final class SpyPerfRecorder: PerfRecorder {
    private(set) var actions: [PerfSignpostAction] = []
    private var counter: UInt64 = 0

    func begin(_ name: StaticString) -> PerfToken {
        actions.append(.begin("\(name)"))
        counter += 1
        return PerfToken(id: counter, payload: nil)
    }

    func end(_ name: StaticString, _ token: PerfToken) {
        actions.append(.end("\(name)"))
    }

    func event(_ name: StaticString) {
        actions.append(.event("\(name)"))
    }
}

final class PerfSignpostTests: XCTestCase {
    private var spy: SpyPerfRecorder!

    override func setUp() {
        super.setUp()
        spy = SpyPerfRecorder()
        Perf.recorder = spy
    }

    override func tearDown() {
        Perf.recorder = OSSignpostRecorder()
        spy = nil
        super.tearDown()
    }

    func testBeginThenEndAreRecordedInOrder() {
        let token = Perf.begin("unit.interval")
        Perf.end("unit.interval", token)
        XCTAssertEqual(spy.actions, [.begin("unit.interval"), .end("unit.interval")])
    }

    func testEventIsRecorded() {
        Perf.event("unit.event")
        XCTAssertEqual(spy.actions, [.event("unit.event")])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run (it should fail to compile — types not defined yet):
```bash
xcodegen generate
xcodebuild test -scheme Treemux -skipPackagePluginValidation \
  -destination 'platform=macOS' \
  -only-testing:TreemuxTests/PerfSignpostTests 2>&1 | tail -20
```
Expected: BUILD FAILED — `cannot find 'Perf' in scope` / `cannot find type 'PerfRecorder'`.

- [ ] **Step 3: Write minimal implementation**

Create `Treemux/Support/Perf/PerfSignpost.swift`:

```swift
import Foundation
import os

/// One recorded signpost action. Tests assert against these to prove
/// that an instrumented code path emitted the expected signposts.
enum PerfSignpostAction: Equatable {
    case begin(String)
    case end(String)
    case event(String)
}

/// Opaque handle returned by `begin`, handed back to `end`.
/// `payload` carries the production `OSSignpostIntervalState`; it is `nil` in tests.
struct PerfToken {
    let id: UInt64
    let payload: Any?
}

/// Sink for performance signposts. Production forwards to `OSSignposter`
/// (visible in Instruments); tests install a spy to assert instrumentation fires.
protocol PerfRecorder: AnyObject {
    func begin(_ name: StaticString) -> PerfToken
    func end(_ name: StaticString, _ token: PerfToken)
    func event(_ name: StaticString)
}

/// Production recorder: forwards to os_signpost so intervals/events show up
/// under the "com.batchzero.treemux" / "perf" subsystem in Instruments.
final class OSSignpostRecorder: PerfRecorder {
    static let signposter = OSSignposter(
        subsystem: "com.batchzero.treemux",
        category: "perf"
    )

    func begin(_ name: StaticString) -> PerfToken {
        let state = Self.signposter.beginInterval(name)
        return PerfToken(id: 0, payload: state)
    }

    func end(_ name: StaticString, _ token: PerfToken) {
        guard let state = token.payload as? OSSignpostIntervalState else { return }
        Self.signposter.endInterval(name, state)
    }

    func event(_ name: StaticString) {
        Self.signposter.emitEvent(name)
    }
}

/// Global performance-signpost facade. Callers use `Perf.begin/end/event`.
/// Swap `recorder` from the main thread in tests.
enum Perf {
    /// Not synchronized: swap only from the main thread (tests do this in setUp).
    nonisolated(unsafe) static var recorder: PerfRecorder = OSSignpostRecorder()

    @discardableResult
    static func begin(_ name: StaticString) -> PerfToken {
        recorder.begin(name)
    }

    static func end(_ name: StaticString, _ token: PerfToken) {
        recorder.end(name, token)
    }

    static func event(_ name: StaticString) {
        recorder.event(name)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodegen generate
xcodebuild test -scheme Treemux -skipPackagePluginValidation \
  -destination 'platform=macOS' \
  -only-testing:TreemuxTests/PerfSignpostTests 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, both tests pass.

- [ ] **Step 5: Commit**

```bash
git add Treemux/Support/Perf/PerfSignpost.swift TreemuxTests/PerfSignpostTests.swift project.yml Treemux.xcodeproj
git commit -m "feat(perf): add signpost facade with swappable recorder"
```

---

### Task 2: `interval` convenience helpers (sync + async)

**Files:**
- Modify: `Treemux/Support/Perf/PerfSignpost.swift`
- Test: `TreemuxTests/PerfSignpostTests.swift`

**Interfaces:**
- Consumes: `Perf.begin/end` from Task 1.
- Produces:
  - `static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T`
  - `static func interval<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T`

- [ ] **Step 1: Write the failing test**

Append to `TreemuxTests/PerfSignpostTests.swift` inside `PerfSignpostTests`:

```swift
    func testSyncIntervalReturnsBodyValueAndRecordsBeginEnd() {
        let value = Perf.interval("unit.sync") { 42 }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(spy.actions, [.begin("unit.sync"), .end("unit.sync")])
    }

    func testAsyncIntervalReturnsBodyValueAndRecordsBeginEnd() async {
        let value = await Perf.interval("unit.async") { () async -> Int in 7 }
        XCTAssertEqual(value, 7)
        XCTAssertEqual(spy.actions, [.begin("unit.async"), .end("unit.async")])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -scheme Treemux -skipPackagePluginValidation \
  -destination 'platform=macOS' \
  -only-testing:TreemuxTests/PerfSignpostTests 2>&1 | tail -20
```
Expected: BUILD FAILED — `type 'Perf' has no member 'interval'`.

- [ ] **Step 3: Write minimal implementation**

Append to `Treemux/Support/Perf/PerfSignpost.swift` (after the `enum Perf { … }` block):

```swift
extension Perf {
    /// Times a synchronous body as a signpost interval and returns its value.
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let token = begin(name)
        defer { end(name, token) }
        return try body()
    }

    /// Times an asynchronous body as a signpost interval and returns its value.
    static func interval<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let token = begin(name)
        defer { end(name, token) }
        return try await body()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild test -scheme Treemux -skipPackagePluginValidation \
  -destination 'platform=macOS' \
  -only-testing:TreemuxTests/PerfSignpostTests 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, all four tests pass.

- [ ] **Step 5: Commit**

```bash
git add Treemux/Support/Perf/PerfSignpost.swift TreemuxTests/PerfSignpostTests.swift
git commit -m "feat(perf): add sync/async interval helpers"
```

---

### Task 3: Wire signposts into the five hot paths

**Files:**
- Modify: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift:896`
- Modify: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyRuntime.swift:101`
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift:274`
- Modify: `Treemux/App/WorkspaceStore.swift:17`
- Modify: `Treemux/Domain/ThemeLoader.swift:23`

**Interfaces:**
- Consumes: `Perf.begin/end/event` from Task 1.
- Produces: no new symbols; five instrumented call sites.

**Verification note:** These sites live on the input/render/UI paths and require a live ghostty surface or full app, so they are verified by **compilation + the existing suite staying green + a manual Instruments trace** (Task 4 documents the trace), not by new unit tests. The signpost *mechanism* is already unit-tested in Tasks 1–2.

- [ ] **Step 1: Instrument `keyDown`**

In `TreemuxGhosttyController.swift`, at the top of `keyDown(with event: NSEvent)` (line 896), insert the first two lines so the `defer` covers every early return:

```swift
override func keyDown(with event: NSEvent) {
    let perfToken = Perf.begin("input.keydown")
    defer { Perf.end("input.keydown", perfToken) }
    // …existing body unchanged…
```

- [ ] **Step 2: Instrument `tick`**

In `TreemuxGhosttyRuntime.swift`, at the top of `tick()` (line 101):

```swift
func tick() {
    let perfToken = Perf.begin("render.tick")
    defer { Perf.end("render.tick", perfToken) }
    // …existing body unchanged…
```

- [ ] **Step 3: Instrument `toggleExpand`**

In `FileBrowserTabController.swift`, at the top of `toggleExpand(_ path: String) async` (line 274):

```swift
func toggleExpand(_ path: String) async {
    let perfToken = Perf.begin("filetree.expand")
    defer { Perf.end("filetree.expand", perfToken) }
    // …existing body unchanged…
```

- [ ] **Step 4: Instrument `selectedWorkspaceID` switch**

In `WorkspaceStore.swift`, inside the `didSet` of `selectedWorkspaceID` (starting line 17), add as the first line of the `didSet` body:

```swift
    @Published var selectedWorkspaceID: UUID? {
        didSet {
            Perf.event("workspace.switch")
            // …existing didSet body unchanged…
```

- [ ] **Step 5: Instrument `ThemeLoader.load`**

In `ThemeLoader.swift`, at the top of `load(from directory: URL, fileManager: FileManager = .default) -> ThemeLoadResult` (line 23):

```swift
    static func load(from directory: URL, fileManager: FileManager = .default) -> ThemeLoadResult {
        let perfToken = Perf.begin("theme.load")
        defer { Perf.end("theme.load", perfToken) }
        // …existing body unchanged…
```

- [ ] **Step 6: Build and run the full suite**

Run:
```bash
xcodebuild test -scheme Treemux -skipPackagePluginValidation \
  -destination 'platform=macOS' 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **`, full suite green (no behavior change).

- [ ] **Step 7: Commit**

```bash
git add Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift \
        Treemux/Services/Terminal/Ghostty/TreemuxGhosttyRuntime.swift \
        Treemux/UI/FileBrowser/FileBrowserTabController.swift \
        Treemux/App/WorkspaceStore.swift \
        Treemux/Domain/ThemeLoader.swift
git commit -m "feat(perf): wire signposts into 5 hot paths"
```

---

### Task 4: Baseline measurement protocol document

**Files:**
- Create: `docs/perf/baseline.md`

**Interfaces:**
- Consumes: the signpost names + subsystem/category from Global Constraints.
- Produces: a repeatable protocol + empty results tables the user (卡皮巴拉) fills by running Instruments.

- [ ] **Step 1: Create the document**

Create `docs/perf/baseline.md`:

````markdown
# 性能基线 (Performance Baseline)

本文件是 Phase 0 的产出：可复现的测量协议 + 改前/改后数据。后续每个阶段都以这里的数字为验收标尺。

## 如何采集

1. 用 Xcode 打开 Treemux，`Product > Profile`（⌘I）以 **Release** 构建启动 Instruments。
2. 模板：**os_signpost** + **Time Profiler** + **Animation Hitches**（新建 Blank，逐个加 instrument）。
3. 在 os_signpost instrument 里按 subsystem 过滤：`com.batchzero.treemux`，category：`perf`。
4. 每个场景重复 3 次，记录 signpost interval 的 **中位数 (median)** 与 **p90**（单位 ms）。

## Signpost 名称对照

| 名称 | 位置 | 含义 |
|------|------|------|
| `input.keydown` | `TreemuxGhosttyController.keyDown` | 单次按键的主线程处理耗时 |
| `render.tick` | `TreemuxGhosttyRuntime.tick` | 一次渲染 tick 耗时 |
| `filetree.expand` | `FileBrowserTabController.toggleExpand` | 展开一个目录的端到端耗时 |
| `workspace.switch` | `WorkspaceStore.selectedWorkspaceID.didSet` | 工作区切换触发点（event） |
| `theme.load` | `ThemeLoader.load` | 扫描+解析全部主题 YAML 耗时 |

## 场景与结果

> `commit` 填被测构建的短哈希；数值单位 ms；表格随每个阶段追加新行。

### 场景 1：本地打字延迟（`input.keydown`）
重复步骤：打开一个本地终端，连续快速输入 `ls -la\n` 20 次。
读数：`input.keydown` interval。

| 日期 | commit | median | p90 | 备注 |
|------|--------|--------|-----|------|
|      |        |        |     |      |

### 场景 2：SSH 打字延迟（`input.keydown`）
重复步骤：连上一台 SSH 主机，连续快速输入 `ls -la\n` 20 次。
读数：`input.keydown` interval。

| 日期 | commit | median | p90 | 备注 |
|------|--------|--------|-----|------|
|      |        |        |     |      |

### 场景 3：展开大目录（`filetree.expand`）
重复步骤：在文件浏览里展开一个含 1000+ 条目的目录（本地各一次、远程各一次）。
读数：`filetree.expand` interval。

| 日期 | commit | 本地 median | 远程 median | 备注 |
|------|--------|-------------|-------------|------|
|      |        |             |             |      |

### 场景 4：切工作区/切主题（`workspace.switch` / `theme.load`）
重复步骤：在 3 个工作区间来回切换 10 次；再切换主题 5 次。
读数：`workspace.switch` 事件间隔的主线程尖峰（Time Profiler）；`theme.load` interval。

| 日期 | commit | theme.load median | 切换主线程尖峰 | 备注 |
|------|--------|-------------------|----------------|------|
|      |        |                   |                |      |

### 场景 5：滚动大文件树帧率（Animation Hitches）
重复步骤：在含 500+ 可见行的展开树里上下快速滚动 10 秒。
读数：Animation Hitches 的 hitch time ratio 与掉帧数。

| 日期 | commit | hitch ratio | 掉帧数 | 备注 |
|------|--------|-------------|--------|------|
|      |        |             |        |      |
````

- [ ] **Step 2: Commit**

```bash
git add docs/perf/baseline.md
git commit -m "docs(perf): add baseline measurement protocol"
```

---

## Post-plan: capture the baseline

After merging Phase 0, 卡皮巴拉 runs the five scenarios once under Instruments and fills the first row of each table. Those numbers are the reference the Phase 1–3 plans will be measured against. (This capture is manual — it needs a real machine, SSH host, and interactive scrolling — and is intentionally not a code task.)

## Self-Review

- **Spec coverage:** Phase 0 spec asks for (a) a signpost helper on key paths, (b) 5 repeatable scenarios + how to measure, (c) numbers recorded in `docs/perf/baseline.md`, (d) no behavior change. → Tasks 1–2 build+test the helper; Task 3 wires the 5 paths named in the spec (keystroke→surface_key, wakeup→tick, directory expand, tab/workspace switch, theme load); Task 4 defines the 5 scenarios + tables. No gaps.
- **Placeholder scan:** No TBD/TODO in code steps; every code step shows full code. `baseline.md` intentionally ships empty result rows — that is a data-capture artifact, not a plan placeholder, and is called out explicitly.
- **Type consistency:** `PerfToken`, `PerfRecorder`, `PerfSignpostAction`, `Perf.begin/end/event/interval`, `OSSignpostRecorder` are used identically across Tasks 1–3. Signpost name strings match the Global Constraints list verbatim.
