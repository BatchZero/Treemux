# Perf P1b — @Observable Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate all 11 ObservableObject classes (66 `@Published` properties — the design doc's "67" over-counts by one, verified by grep) to the Swift `@Observable` macro, so SwiftUI invalidates views per-property instead of per-object, completing design-doc P1 item 1.

**Architecture:** Leaf-first, one-class-per-task migration (ThemeManager → LanguageManager → ShellSession → FileBrowserTabController → WorkspaceSessionController → WorkspaceModel → WorkspaceStore → stragglers). Mixed mode (ObservableObject + @Observable coexisting) is supported by SwiftUI, so every task ends with a fully working app and a green 440-test suite. The 3 production Combine `$property` subscriptions (AppDelegate settings-debounce, WindowContext theme/locale) are each replaced by a `PassthroughSubject` bridge fired from the property's `didSet` — identical operator semantics, no replay. The 4 tests pinning `objectWillChange` dedup semantics are rewritten on `withObservationTracking` with synchronous re-arm.

**Tech Stack:** Swift 5 language mode (unchanged), Observation framework (macOS 15 target, Xcode 16), Combine (residual bridges only), XCTest, xcodegen.

**Design doc:** `docs/superpowers/specs/2026-07-07-performance-fluidity-v2-design.md` §3 P1 条目 1（其余条目已随 P1a 落地）。P2 遗留事项 `SSHMultiplexing.ensuredDirectories` 的 Swift-6 注解在 Task 8 顺手处理。

## Global Constraints

- 主仓库目录必须始终停在 `main`；本计划所有开发、构建、提交都在 `.worktrees/perf+p1b-observable/` 内进行（分支 `perf/p1b-observable`，基线 `8e69805`）。Bash cwd 可能被重置回主目录——**每次提交前必须 `git branch --show-current` 确认在 `perf/p1b-observable`**。
- 每个任务结束时全部测试必须绿（基线 440 个 + 新增）。测试命令（在 worktree 根目录运行，Bash timeout 设 600000）：
  `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -quiet`
  （迭代时可加 `-only-testing:TreemuxTests/<ClassName>` 提速；任务收尾必须跑全量。`** TEST SUCCEEDED **` 后的 2 行 SwiftLint plugin "failed" 日志是已知噪声。）
- 每个迁移任务（Task 1–7）收尾后跑一次 Scenario B 基准并把数字记入 `.superpowers/sdd/progress.md`（信号记录，不做硬门槛——同机同二进制方差 2~5 倍是既有结论；硬验收在 Task 9 做多次取均值对比）。跑法见 Task 9 Step 2。
- 语言模式保持 `SWIFT_VERSION = 5`，**禁止**顺手开 Swift 6 / strict concurrency。
- 本阶段不引入任何新的用户可见字符串或颜色；纯行为保持迁移。
- 侧栏 NSHostingView 冻结区红线（678fda8 崩溃史）：`SidebarCellView`/`SidebarNodeRow`/`SidebarItemIconView` 子树**禁止**注入任何 environment（`.environmentObject` 和 `.environment` 一样禁止），按值传参 + fingerprint 手工刷新 + `.id(theme)` 强刷机制原样保留。@Observable 迁移后，island 内 body 对 `store`/`theme`/`workspace` 引用属性的读取会被自动追踪（新增的合法刷新通道，机制与 EnvironmentObject 缺祖先崩溃无关）；手动刷新机制仍是权威路径，只更新注释、不改架构。
- 禁止复活 2026-07-01 的旧 perf+overhaul 分支（dangling 50ba57e）。
- 提交信息 conventional 风格：`perf(p1b): …` / `test(p1b): …` / `docs(p1b): …`。
- xcodegen 仅 Task 1 需要（新增 `TreemuxTests/ObservableBridgeTests.swift`）。运行 `xcodegen generate` 后必须核对 pbxproj 里 `MARKETING_VERSION = 0.0.19` / `CURRENT_PROJECT_VERSION = 19` 未被改动（project.yml 当前同步为 0.0.19/19），并将 `Treemux.xcodeproj/project.pbxproj` 变更一并提交。其余任务不新增文件、不跑 xcodegen。

### 统一迁移规则（每个任务隐含引用；下文以 R1…R6 指代）

**R1 — 类声明变换**（对每个迁移类精确执行）：

```swift
// BEFORE
@MainActor
final class X: ObservableObject, OtherProtocol {
    @Published var a: T
    @Published private(set) var b: T { didSet { /* ... */ } }
    private var cache: C?
    var callback: (() -> Void)?
}
// AFTER
@MainActor
@Observable
final class X: OtherProtocol {
    var a: T
    private(set) var b: T { didSet { /* ... */ } }   // didSet 原样保留（宏支持属性观察器）
    @ObservationIgnored private var cache: C?
    @ObservationIgnored var callback: (() -> Void)?
}
```

- 删除 `: ObservableObject`（其余协议保留）；删除全部 `@Published`；文件顶部加 `import Observation`。
- **迁移前非 `@Published` 的每一个存储 `var`（含 `weak`/`lazy`/`private(set)`/闭包属性）一律加 `@ObservationIgnored`**——观察面必须与迁移前完全一致，不许静默扩大。`let` 不用加。
- `import Combine` 若在该文件里只服务于 `@Published` 则删除；若该类新增 PassthroughSubject 桥（R3）则保留/新增。
- 访问控制、属性名、didSet 体一字不动。

**R2 — 视图包装器变换**：

| 旧 | 新 | 适用场景 |
|---|---|---|
| `@EnvironmentObject private var x: X` | `@Environment(X.self) private var x` | 环境消费（保留原访问控制） |
| `.environmentObject(x)` | `.environment(x)` | 注入点 |
| `@ObservedObject var x: X` | `let x: X` | body 无 `$x.…` 绑定 |
| `@ObservedObject var x: X` | `@Bindable var x: X` | body 有 `$x.prop` 绑定 |
| `@StateObject private var x = X(…)` | `@State private var x = X(…)` | 直接初始化 |
| `_x = StateObject(wrappedValue: X(…))` | `_x = State(initialValue: X(…))` | init 内初始化（注意 @State 初值表达式会在每次 view init 求值、只保留首个实例——本项目涉及的构造器都是轻量的，可接受） |
| 环境对象需要绑定 | body 首行 `@Bindable var x = x` 再用 `$x.prop` | MainWindowView / WorkspaceSidebarView |

**R3 — Combine 桥模式**（didSet + PassthroughSubject，替代 `$property`）：

```swift
@ObservationIgnored private let fooSubject = PassthroughSubject<FooType, Never>()
/// Bridge for non-SwiftUI observers. @Observable has no projected
/// publishers; this fires on every post-init assignment (didSet does not
/// run during init) and never replays a value, matching the old
/// `$foo.dropFirst()` semantics — so subscribers drop their `.dropFirst()`.
var fooPublisher: AnyPublisher<FooType, Never> { fooSubject.eraseToAnyPublisher() }

var foo: FooType {
    didSet { fooSubject.send(foo) }   // 若已有 didSet，追加 send 到末尾
}
```

订阅侧保留原有 `.debounce` / `.receive(on:)` 操作符，删除 `.dropFirst()`。

**R4 — memo 缓存命中必须触读观察输入**：@Observable 下 SwiftUI 只追踪 body 求值期间**实际读到**的属性。任何「命中缓存就只读 `@ObservationIgnored` 存储」的访问器都会让调用方 body 零依赖、从此不再刷新。凡 memo 访问器（`visibleRows()`、`sidebarIcon(for:)`、`remoteWorkspaceGroups`）必须在查缓存**之前**无条件触读全部观察输入（`_ = prop`，CoW 引用零拷贝）。具体代码在 Task 4 / Task 7。

**R5 — 测试观察计数器模式**（替代 `objectWillChange.sink { publishes += 1 }`）：`withObservationTracking` 的 onChange 在 willSet 时于变更线程**同步**触发且一次性；在 onChange 里**同步重挂**才能逐次计数（异步重挂会漏掉同一同步调用里的连续变更）。计数器读取该类**全部**观察属性，保真旧的对象级计数语义。完整代码在 Task 3 / Task 4。注意：`withObservationTracking` 对未迁移的 ObservableObject 类**不生效**（onChange 永不触发）——因此「先改测试→红，再迁移类→绿」构成天然 TDD 循环。

**R6 — 任务收尾核查**：`git branch --show-current` 确认分支 → 全量测试绿 → Scenario B 单跑记录 → 该类残留检查 `grep -rn "@Published\|ObservableObject\|objectWillChange" <该类文件>` 为零、全仓 `grep -rn "@EnvironmentObject var <名>\|@ObservedObject var <名>: <类>\|environmentObject(<实例名>)" Treemux/` 对该类为零 → 提交。

---

### Task 1: ThemeManager → @Observable（26 个 @EnvironmentObject 消费点 + WindowContext 主题桥 + 新建桥测试文件）

**Files:**
- Modify: `Treemux/UI/Theme/ThemeManager.swift:19-24`（类声明 + 桥）
- Modify: `Treemux/App/WindowContext.swift:38,68-73,83`（注入 + sink 换桥）
- Modify: `Treemux/UI/Sidebar/WorkspaceOutlineSidebar.swift:11,33-44`（@ObservedObject→let + 显式触读）
- Modify: `Treemux/UI/Settings/SettingsSheet.swift:305`（@ObservedObject→let）
- Modify: `Treemux/UI/Sidebar/WorkspaceSidebarView.swift:94`（.environmentObject(theme)→.environment(theme)）
- Modify（@EnvironmentObject→@Environment，26 处）: `OpenProjectSheet.swift:11`、`RemoteDirectoryBrowser.swift:10`、`MainWindowView.swift:10`、`EmptyTabStateView.swift:10`、`TerminalPaneView.swift:11`、`WorkspaceSidebarView.swift:11`、`WorkspaceTabBarView.swift:10,128`、`SidebarIconCustomizationSheet.swift:12,95`、`CommandPaletteView.swift:25`、`SettingsSheet.swift:13`、`RenderedMarkdownView.swift:28`、`SSHRawConfigSheet.swift:11`、`SSHServerEditSheet.swift:12`、`SplitDivider.swift:11`、`Hairline.swift:12`、`ImagePreviewView.swift:8`、`FileSubTabBarView.swift:13,102`、`FileTreePanelView.swift:10,215,338`、`BatchUnsavedChangesSheet.swift:13`、`FileViewerPanelView.swift:8`、`TextEditorView.swift:27`
- Modify（冻结区注释更新，不改代码）: `Treemux/UI/Sidebar/SidebarNodeRow.swift:9-15`、`Treemux/UI/Sidebar/SidebarItemIconView.swift:88-92`
- Create: `TreemuxTests/ObservableBridgeTests.swift`
- Modify: `Treemux.xcodeproj/project.pbxproj`（xcodegen generate 产物，勿手改）

**Interfaces:**
- Produces（Task 2/7 以同构模式复制；WindowContext 依赖，签名必须一字不差）:
  - `var activeThemePublisher: AnyPublisher<Theme, Never>`（on ThemeManager）
- 迁移后 ThemeManager 仍为 `@MainActor final class`，全部既有方法/计算属性签名不变。

- [ ] **Step 1: 写失败的桥测试（新文件 + xcodegen）**

创建 `TreemuxTests/ObservableBridgeTests.swift`：

```swift
//
//  ObservableBridgeTests.swift
//  TreemuxTests
//
//  Pins the PassthroughSubject bridges that replace Combine's projected
//  @Published publishers after the @Observable migration. Non-SwiftUI
//  observers (WindowContext, AppDelegate) rely on: fires on every post-init
//  assignment, never replays an initial value.

import XCTest
import Combine
import Observation
@testable import Treemux

/// Counts Observation change notifications over the properties read by the
/// `reading` closure — the faithful replacement for the old object-level
/// `objectWillChange.sink { publishes += 1 }` counting (used by
/// ShellSessionPublishDedupTests and EditorBufferIsolationTests; internal on
/// purpose so those files share it). onChange fires synchronously at willSet
/// on the mutating (main) actor and is one-shot, so it re-arms synchronously;
/// back-to-back mutations inside one callback are each counted. NOTE: fires
/// only for @Observable types — against a not-yet-migrated ObservableObject
/// it never fires, which is what makes rewrite-test-first runs red.
@MainActor
final class ObservationChangeCounter {
    private(set) var count = 0
    private var stopped = false
    private let read: () -> Void
    init(reading read: @escaping () -> Void) {
        self.read = read
        arm()
    }
    func stop() { stopped = true }
    private func arm() {
        withObservationTracking(read) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.count += 1
                self.arm()
            }
        }
    }
}

@MainActor
final class ObservableBridgeTests: XCTestCase {

    func testActiveThemePublisherFiresOnSetActiveThemeAndReload() {
        let manager = ThemeManager(activeThemeID: "treemux-dark")
        var received: [String] = []
        let sub = manager.activeThemePublisher.sink { received.append($0.id) }
        defer { sub.cancel() }

        XCTAssertEqual(received, [], "bridge must not replay the initial theme")
        guard let other = manager.availableThemes.first(where: { $0.id != manager.activeTheme.id }) else {
            return XCTFail("expected at least two available themes")
        }
        manager.setActiveTheme(other.id)
        XCTAssertEqual(received.last, other.id)
        let countAfterSet = received.count
        manager.reloadThemes()   // also assigns activeTheme -> must fire too
        XCTAssertEqual(received.count, countAfterSet + 1,
                       "reloadThemes assigns activeTheme and must fire the bridge")
    }
}
```

然后 `xcodegen generate`；核对 `grep -c "MARKETING_VERSION = 0.0.19" Treemux.xcodeproj/project.pbxproj` 仍为 2。

- [ ] **Step 2: 跑新测试确认编译失败**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/ObservableBridgeTests -quiet`
Expected: FAIL — `value of type 'ThemeManager' has no member 'activeThemePublisher'`。

- [ ] **Step 3: 迁移 ThemeManager 类**

`ThemeManager.swift:19-24` 按 R1 + R3 改为：

```swift
@MainActor
@Observable
final class ThemeManager {

    private(set) var activeTheme: Theme {
        didSet { activeThemeSubject.send(activeTheme) }
    }
    private(set) var availableThemes: [Theme] = []
    private(set) var loadErrors: [ThemeLoadError] = []

    @ObservationIgnored private let activeThemeSubject = PassthroughSubject<Theme, Never>()
    /// Bridge for non-SwiftUI observers (WindowContext window chrome).
    /// Fires on every post-init activeTheme assignment (setActiveTheme AND
    /// reloadThemes); never replays — subscribers need no `.dropFirst()`.
    var activeThemePublisher: AnyPublisher<Theme, Never> { activeThemeSubject.eraseToAnyPublisher() }
```

文件顶部 import 区加 `import Combine` 与 `import Observation`。`themesDirectory` 是 `let`，不动。其余方法不动（init 内赋值不触发 didSet，语义正确）。

- [ ] **Step 4: 全仓消费点变换**

- 上面 Files 列出的 26 处 `@EnvironmentObject … ThemeManager` → `@Environment(ThemeManager.self) …`（R2，保留访问控制与属性名）。
- `SettingsSheet.swift:305`：`@ObservedObject var themeManager: ThemeManager` → `let themeManager: ThemeManager`。
- `WorkspaceSidebarView.swift:94`：`.environmentObject(theme)` → `.environment(theme)`。
- `WindowContext.swift:38` 与 `:83`：`.environmentObject(themeManager)` → `.environment(themeManager)`。
- `WindowContext.swift:68-73` sink 换桥（删 `.dropFirst()`，保留 `.receive(on:)`）：

```swift
        themeCancellable = themeManager.activeThemePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateAppearance()
            }
```

- `WorkspaceOutlineSidebar.swift:11`：`@ObservedObject var theme: ThemeManager` → `let theme: ThemeManager`；并在 `updateNSView`（:33）函数体首行加：

```swift
        // Explicit tracked read: keeps updateNSView re-firing on theme
        // switches (parity with the old whole-object @ObservedObject
        // invalidation). The sidebar island refreshes via .themeDidChange,
        // but the coordinator's re-apply pass still expects this update.
        _ = theme.activeTheme
```

- [ ] **Step 5: 冻结区注释更新（只改注释）**

`SidebarNodeRow.swift:9-15` 注释块末尾追加一行说明；`SidebarItemIconView.swift:88-92` 的崩溃警告保留并补充：

```swift
// (Post-@Observable note: reads of theme/store/workspace reference props in
// these bodies are now auto-tracked by Observation — a benign extra refresh
// channel. The coordinator's manual fingerprint/.themeDidChange refresh
// remains the authoritative path. Environment injection of ANY kind is
// still forbidden here — see crash 678fda8.)
```

- [ ] **Step 6: 全量测试 + 收尾核查（R6）**

Run: 全量测试命令。Expected: 441 tests, 0 failures（440 基线 + 1 新增）。
残留检查：`grep -rn "EnvironmentObject.*ThemeManager\|ObservedObject.*ThemeManager\|environmentObject(theme" Treemux/` → 0 hits。
Scenario B 单跑记录进度台账。

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "perf(p1b): migrate ThemeManager to @Observable with PassthroughSubject window-chrome bridge"
```

---

### Task 2: LanguageManager → @Observable（locale 桥 + 根视图重建闭包）

**Files:**
- Modify: `Treemux/Support/LanguageManager.swift:11-16`
- Modify: `Treemux/App/WindowContext.swift:39,76-86,84`
- Modify（@EnvironmentObject→@Environment，4 处）: `OpenProjectSheet.swift:12`、`MainWindowView.swift:12`、`WorkspaceSidebarView.swift:12`、`SettingsSheet.swift:14`
- Test: `TreemuxTests/ObservableBridgeTests.swift`（追加）

**Interfaces:**
- Produces: `var localePublisher: AnyPublisher<Locale, Never>`（on LanguageManager；WindowContext 依赖，sink 需要 payload 值）。

- [ ] **Step 1: 追加失败测试**

`ObservableBridgeTests.swift` 追加（注意保存/恢复 UserDefaults 副作用）：

```swift
    func testLocalePublisherDeliversNewLocaleWithoutReplay() {
        let saved = UserDefaults.standard.object(forKey: "AppleLanguages")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "AppleLanguages") }
            else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        }
        let manager = LanguageManager(languageCode: "en")
        var received: [Locale] = []
        let sub = manager.localePublisher.sink { received.append($0) }
        defer { sub.cancel() }

        XCTAssertEqual(received, [], "bridge must not replay the initial locale")
        manager.apply(languageCode: "zh-Hans")
        XCTAssertEqual(received.last?.identifier, "zh-Hans",
                       "bridge must deliver the NEW locale as payload")
    }
```

- [ ] **Step 2: 跑测试确认编译失败**（`-only-testing:TreemuxTests/ObservableBridgeTests`，Expected: no member 'localePublisher'）

- [ ] **Step 3: 迁移 LanguageManager**

`LanguageManager.swift:11-16` 按 R1 + R3：

```swift
@MainActor
@Observable
final class LanguageManager {

    /// The active locale derived from the language setting.
    /// Bind this to `.environment(\.locale)` on the root view.
    private(set) var locale: Locale {
        didSet { localeSubject.send(locale) }
    }

    @ObservationIgnored private let localeSubject = PassthroughSubject<Locale, Never>()
    /// Bridge for WindowContext's root-view rebuild. Delivers the new locale
    /// as payload; never replays — subscriber needs no `.dropFirst()`.
    var localePublisher: AnyPublisher<Locale, Never> { localeSubject.eraseToAnyPublisher() }
```

import 区加 `import Combine`、`import Observation`。

- [ ] **Step 4: 消费点变换**

- 4 处 `@EnvironmentObject … LanguageManager` → `@Environment(LanguageManager.self) …`。
- `WindowContext.swift:39` 与 `:84`：`.environmentObject(languageManager)` → `.environment(languageManager)`。
- `WindowContext.swift:76-86` sink 换桥（删 `.dropFirst()`，payload 语义保留）：

```swift
        localeCancellable = languageManager.localePublisher
            .receive(on: RunLoop.main)
            .sink { [weak host, weak self] newLocale in
                guard let self, let host else { return }
                host.rootView = MainWindowView()
                    .environmentObject(self.store)
                    .environment(self.themeManager)
                    .environment(self.languageManager)
                    .environment(\.locale, newLocale)
            }
```

（`.environmentObject(self.store)` 保留——store 到 Task 7 才迁移。）

- [ ] **Step 5: 全量测试 + R6 核查**（Expected: 442 tests 0 failures；`grep -rn "EnvironmentObject.*LanguageManager\|environmentObject(languageManager" Treemux/` → 0）

- [ ] **Step 6: Commit** — `perf(p1b): migrate LanguageManager to @Observable with locale rebuild bridge`

---

### Task 3: ShellSession → @Observable（发布去重测试改写为 Observation 计数器）

**Files:**
- Modify: `Treemux/Services/Terminal/ShellSession.swift:7,30-53`
- Modify: `Treemux/UI/Workspace/TerminalPaneView.swift:12`、`Treemux/UI/Components/TerminalHostView.swift:14`（@ObservedObject→let）
- Test: `TreemuxTests/ShellSessionPublishDedupTests.swift`（改写 3 个测试）

**Interfaces:**
- Consumes: 无（叶子类）。Produces: ShellSession 全部属性/方法签名不变；`configureSurfaceCallbacks` 的值不变则不赋值的去重守卫（:102-138）一字不动——它们从「防 objectWillChange 风暴」变为「防 Observation 无谓 willSet 通知」，语义继续成立。

- [ ] **Step 1: 先改写测试（TDD 红）**

`ShellSessionPublishDedupTests.swift`：删除 `import Combine`；使用 Task 1 落地的共享 `ObservationChangeCounter`（定义在 `ObservableBridgeTests.swift`，同 target 内可见），在本文件加一个便捷工厂读取 ShellSession **全部** 10 个观察属性（R5）：

```swift
/// All-property counter for a ShellSession (see ObservationChangeCounter in
/// ObservableBridgeTests.swift) — faithful to the old object-level counting.
@MainActor
private func makeCounter(for session: ShellSession) -> ObservationChangeCounter {
    ObservationChangeCounter {
        _ = session.title
        _ = session.preferredWorkingDirectory
        _ = session.reportedWorkingDirectory
        _ = session.lifecycle
        _ = session.exitCode
        _ = session.pid
        _ = session.rows
        _ = session.cols
        _ = session.surfaceStatus
        _ = session.detectedTmuxSession
    }
}
```

三个测试体等价替换，断言结构不变。以第一个为例（其余两个同构替换 sink 部分）：

```swift
    func testRepeatedIdenticalResizeDoesNotRepublish() {
        let surface = FakeSurfaceController()
        let session = makeSession(surface: surface)
        let counter = makeCounter(for: session)
        defer { counter.stop() }

        surface.onResize?(120, 40)
        let afterFirst = counter.count
        surface.onResize?(120, 40)   // same values: must be a no-op
        surface.onResize?(120, 40)
        XCTAssertEqual(counter.count, afterFirst, "identical resize must not republish")
        surface.onResize?(121, 40)   // changed: must publish again
        XCTAssertGreaterThan(counter.count, afterFirst)
    }
```

`testIdenticalStatusSnapshotDoesNotRepublish` / `testIdenticalTitleAndCwdDoNotRepublish` 同样把 `var publishes = 0; let sub = session.objectWillChange.sink…; defer { sub.cancel() }` 替换为 `let counter = makeCounter(for: session); defer { counter.stop() }`，`publishes`→`counter.count`。

- [ ] **Step 2: 跑该类测试确认失败**

Run: `…-only-testing:TreemuxTests/ShellSessionPublishDedupTests -quiet`
Expected: FAIL — ShellSession 尚未 @Observable，`withObservationTracking` 的 onChange 永不触发，`XCTAssertGreaterThan(counter.count, afterFirst)` 三个测试全红（0 > 0 不成立）。

- [ ] **Step 3: 迁移 ShellSession**

`ShellSession.swift` 按 R1：`:31` 改 `@MainActor @Observable final class ShellSession: Identifiable`；`:35-46` 十个 `@Published` 前缀删除；`:48-49` `onWorkspaceAction`/`onFocus`、`:52-53` `launchConfiguration`/`isFocusedInWorkspace` 加 `@ObservationIgnored`（`surfaceController` 是 let 不动）；`:7` `import Combine` 删除、加 `import Observation`。`configureSurfaceCallbacks` 守卫一字不动。全类扫一遍：其余非 @Published 存储 var（如有遗漏）一律 `@ObservationIgnored`。

- [ ] **Step 4: 视图消费点**

`TerminalPaneView.swift:12`、`TerminalHostView.swift:14`：`@ObservedObject var session: ShellSession` → `let session: ShellSession`。

- [ ] **Step 5: 跑该类测试确认绿，再全量 + R6 核查**（Expected: 442 tests 0 failures；`grep -n "objectWillChange" TreemuxTests/ShellSessionPublishDedupTests.swift` → 0）

- [ ] **Step 6: Commit** — `perf(p1b): migrate ShellSession to @Observable; rewrite publish-dedup tests on withObservationTracking`

---

### Task 4: FileBrowserTabController → @Observable（visibleRows 缓存命中触读修复 + 击键隔离测试改写）

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift:6,26-120,400 附近,786-830`
- Modify（@ObservedObject→let，8 处）: `FileBrowserTabContentView.swift:8`、`FileSubTabBarView.swift:14`、`FileTreePanelView.swift:8,112,143,337`、`FileViewerPanelView.swift:9`、`TextEditorView.swift:18`
- Test: `TreemuxTests/EditorBufferIsolationTests.swift`（改写 1 个测试）

**Interfaces:**
- Consumes: 无新依赖。Produces: 全部方法/属性签名不变；`visibleRows()` 行为不变但**每次调用（含缓存命中）都触读 8 个观察输入**（下游 FileTreePanelView 依赖此追踪才能刷新）。

- [ ] **Step 1: 先改写击键隔离测试（TDD 红）**

`EditorBufferIsolationTests.swift`：删除 `import Combine`；使用共享 `ObservationChangeCounter`（Task 1 落地于 `ObservableBridgeTests.swift`），加控制器版便捷工厂，读取 FileBrowserTabController **全部** 15 个观察属性（R5）：

```swift
/// All-property counter for a FileBrowserTabController (see
/// ObservationChangeCounter in ObservableBridgeTests.swift).
@MainActor
private func makeCounter(for c: FileBrowserTabController) -> ObservationChangeCounter {
    ObservationChangeCounter {
        _ = c.rootPath; _ = c.rootKind; _ = c.splitRatio
        _ = c.expandedDirs; _ = c.showsHiddenFiles
        _ = c.rootChildren; _ = c.childrenByPath
        _ = c.subTabs; _ = c.activeSubTabID
        _ = c.loadingPaths; _ = c.loadError
        _ = c.diffHunksByPath; _ = c.fileStatusByPath
        _ = c.truncatedDirs; _ = c.treeContentGeneration
    }
}
```

`testKeystrokesPublishOnlyOnDirtyTransition`（:28-41）中 `var publishes = 0; let sub = c.objectWillChange.sink…` 替换为 `let counter = makeCounter(for: c); defer { counter.stop() }`，`publishes`→`counter.count`，断言结构不变。

- [ ] **Step 2: 跑该文件测试确认目标测试红**（`-only-testing:TreemuxTests/EditorBufferIsolationTests`；`XCTAssertGreaterThan(afterFirst, 0)` 失败，其余 5 个状态型测试应仍绿）

- [ ] **Step 3: 迁移 FileBrowserTabController**

按 R1：`:27` 改 `@MainActor @Observable final class FileBrowserTabController`；15 个 `@Published` 前缀删除（**8 个 didSet 失效体一字不动**）；以下存储 var 加 `@ObservationIgnored`：`rawChildrenByPath`(:53)、`visibleRowsCache`(:96)、`visibleRowsComputeCount`(:102, DEBUG 块内)、`treeScrollOffset`(:109)、`liveBufferByTab`(:791)、`pendingLargeFileMeta`(:797)，以及全类扫描出的其余全部非 @Published 存储 var（含闭包属性、wordIndex 类字段——规则一刀切）；`:6` `import Combine` 删、加 `import Observation`。注释 `:105-108`「NOT @Published」措辞更新为「@ObservationIgnored — must not trigger re-render」。

- [ ] **Step 4: visibleRows() 缓存命中触读修复（R4，正确性关键）**

`visibleRows()`（:400 附近）函数体最顶部、查 `visibleRowsCache` **之前**插入：

```swift
        // Touch every input on EVERY call — including cache hits. Under
        // @Observable, SwiftUI only tracks properties actually read during
        // body evaluation; a cache hit that read nothing observable would
        // leave the calling view with zero tracked dependencies, and the
        // tree would never re-render again.
        _ = rootChildren
        _ = childrenByPath
        _ = expandedDirs
        _ = truncatedDirs
        _ = fileStatusByPath
        _ = activeSubTabID
        _ = subTabs
        _ = showsHiddenFiles
```

- [ ] **Step 5: 视图消费点**

8 处 `@ObservedObject var controller: FileBrowserTabController` → `let controller: FileBrowserTabController`（无 `$controller` 绑定，已核实）。`FileTreeRow`（FileTreePanelView.swift:205, `View, Equatable`）的 `==` 成员保持一字不动。

- [ ] **Step 6: 跑目标测试绿 → 全量 + R6 核查**（Expected: 442 tests 0 failures。重点确认 `FileBrowserTreeAccelerationTests`、`FileBrowserTabController*Tests` 全绿——visibleRows 缓存语义测试靠 `visibleRowsComputeCount` 测缝，@ObservationIgnored 不影响直读）

- [ ] **Step 7: Commit** — `perf(p1b): migrate FileBrowserTabController to @Observable; tracked reads on visibleRows cache hits`

---

### Task 5: WorkspaceSessionController → @Observable

**Files:**
- Modify: `Treemux/Services/Terminal/WorkspaceSessionController.swift:11-23`
- Modify: `Treemux/UI/Workspace/SplitNodeView.swift:12`、`Treemux/UI/Workspace/WorkspaceDetailView.swift:71`（@ObservedObject→let）

- [ ] **Step 1: 迁移类**：按 R1 —— `sessions`/`layout`/`focusedPaneID`（didSet 调 `updateSessionFocusStates()` 保留）/`zoomedPaneID` 去 `@Published`；`onPaneStateChanged`(:23) 加 `@ObservationIgnored`；加 `import Observation`；若 `import Combine` 仅服务 @Published 则删。
- [ ] **Step 2: 视图消费点**：`SplitNodeView.swift:12` `@ObservedObject var sessionController:` → `let sessionController:`；`WorkspaceDetailView.swift:71` `@ObservedObject var controller:` → `let controller:`。
- [ ] **Step 3: 全量测试 + R6 核查**（Expected: 442 tests 0 failures，重点 `PaneLayoutTests`/`SessionBackendTests`）
- [ ] **Step 4: Commit** — `perf(p1b): migrate WorkspaceSessionController to @Observable`

---

### Task 6: WorkspaceModel → @Observable（@Bindable 承接 pendingBatchClose sheet）

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift:266-330`
- Modify: `Treemux/UI/Workspace/WorkspaceTabBarView.swift:11`（→let）、`Treemux/UI/Settings/SettingsSheet.swift:694,719`（→let）
- Modify: `Treemux/UI/Workspace/WorkspaceDetailView.swift:23`（→@Bindable）

- [ ] **Step 1: 迁移类**：按 R1 —— `:267` 改 `@MainActor @Observable final class WorkspaceModel`（保留既有其他协议）；14 个 `@Published` 前缀删除；非发布存储 var 全部 `@ObservationIgnored`：`tabControllers`(:304)、`fileBrowserControllers`(:306)、`worktreeTabStates`(:308)、`activeWorktreePath`(:310, private(set)——迁移前非发布，**必须** ignored 以保持「current 徽章靠 fingerprint 手工刷新」的冻结区语义)、`sharedSFTPService_`(:315，若为 `lazy var` 则 @ObservationIgnored 同时是宏的硬性要求) 及全类扫描的其余非发布 var；加 `import Observation`。
- [ ] **Step 2: 视图消费点**：`WorkspaceTabBarView.swift:11`、`SettingsSheet.swift:694,719` 的 `@ObservedObject var workspace:` → `let workspace:`；`WorkspaceDetailView.swift:23` 的 `@ObservedObject var workspace: WorkspaceModel` → `@Bindable var workspace: WorkspaceModel`（:57 的 `$workspace.pendingBatchClose` sheet 绑定原样可用）。
- [ ] **Step 3: 全量测试 + R6 核查**（Expected: 442 tests 0 failures，重点 `WorkspaceModelsTests`/`WorkspaceModelTabKindTests`/`TabGroupingTests`。`WorkspaceModelTabKindTests.swift:39-45` 那条回归测试是直接触碰 `sessionController` 模拟观察者副作用的，不依赖 objectWillChange，应原样绿。）
- [ ] **Step 4: Commit** — `perf(p1b): migrate WorkspaceModel to @Observable`

---

### Task 7: WorkspaceStore → @Observable（AppDelegate 设置桥 + @Bindable×3 + 侧栏 representable 触读 + memo 访问器触读）

**Files:**
- Modify: `Treemux/App/WorkspaceStore.swift:14-41,137-165,566-590 附近`
- Modify: `Treemux/AppDelegate.swift:8,23-30`
- Modify: `Treemux/App/WindowContext.swift:37,82`
- Modify: `Treemux/UI/MainWindowView.swift:11,body 首行`、`Treemux/UI/Sidebar/WorkspaceSidebarView.swift:10,93,body 首行`
- Modify（@EnvironmentObject→@Environment，13 处）: `OpenProjectSheet.swift:10`、`SidebarIconCustomizationSheet.swift:94`、`CommandPaletteView.swift:24`、`SettingsSheet.swift:12,655,693,718`、`WorkspaceDetailView.swift:10,22`、`FileTreePanelView.swift:9`、`TextEditorView.swift:26`（+ MainWindowView/WorkspaceSidebarView 见上）
- Modify: `Treemux/UI/Sidebar/WorkspaceOutlineSidebar.swift:10,33-44`
- Test: `TreemuxTests/ObservableBridgeTests.swift`（追加）

**Interfaces:**
- Produces: `var settingsPublisher: AnyPublisher<AppSettings, Never>`（on WorkspaceStore；AppDelegate 依赖）。

- [ ] **Step 1: 追加失败的桥测试**

`ObservableBridgeTests.swift` 追加（构造方式对齐既有 `WorkspaceStoreBuiltInTests` 的 fixture 写法——实现时先读该文件，如其用特殊初始化参数则照抄）：

```swift
    func testSettingsPublisherFiresOnMutationWithoutReplay() {
        let store = WorkspaceStore()
        var fires = 0
        let sub = store.settingsPublisher.sink { _ in fires += 1 }
        defer { sub.cancel() }

        XCTAssertEqual(fires, 0, "bridge must not replay initial settings")
        var s = store.settings
        s.showDefaultTerminal.toggle()
        store.settings = s
        XCTAssertEqual(fires, 1, "one assignment -> exactly one bridge fire")
    }
```

- [ ] **Step 2: 跑 ObservableBridgeTests 确认编译失败**（no member 'settingsPublisher'）

- [ ] **Step 3: 迁移 WorkspaceStore 类**

按 R1 + R3：`:15` 改 `@MainActor @Observable final class WorkspaceStore`；8 个 `@Published` 前缀删除（`selectedWorkspaceID`/`settings` 的 didSet 保留）；`settings` didSet 追加桥并新增 subject：

```swift
    var settings: AppSettings {
        didSet {
            try? settingsPersistence.save(settings)
            settingsSubject.send(settings)
        }
    }

    @ObservationIgnored private let settingsSubject = PassthroughSubject<AppSettings, Never>()
    /// Bridge for AppDelegate's debounced menu/updater rebuild. Fires on
    /// every post-init settings assignment; never replays — the subscriber
    /// keeps its debounce but drops `.dropFirst()`.
    var settingsPublisher: AnyPublisher<AppSettings, Never> { settingsSubject.eraseToAnyPublisher() }
```

非发布存储 var 全部 `@ObservationIgnored`：`settingsPersistence`… 等 `let` 不动；`remoteRefreshTimer`(:76)、`remoteWindowObserver`(:81)、`isRefreshingRemotes`(:85)、`sidebarIconCache`(:89)、`remoteGroupsCache`(:93) 及全类扫描其余非发布 var。`workspaceMetadataGeneration` 保持观察属性（:34-37 注释就是为本迁移写的，兑现它）。`:16-22` 缓存契约注释中「`didSet`/`@Published`」措辞同步微调。加 `import Observation`（`import Combine` 因 subject 保留/新增）。

- [ ] **Step 4: memo 访问器触读（R4）**

`remoteWorkspaceGroups`（:157）与 `sidebarIcon(for:)`（:566-590 两个重载都要）在查各自缓存**之前**插入：

```swift
        // Tracked reads on cache hits (see FileBrowserTabController.visibleRows
        // rationale): a hit must still register the observable inputs, or the
        // calling SwiftUI body ends up with zero tracked dependencies.
        _ = workspaces
        _ = workspaceMetadataGeneration
```

- [ ] **Step 5: AppDelegate 桥接换订阅**

`AppDelegate.swift:23-29`（删 `.dropFirst()`，debounce 注释保留）：

```swift
            settingsCancellable = store.settingsPublisher
                .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.buildMainMenu()
                    self?.configureUpdater(checkInBackground: false)
                }
```

- [ ] **Step 6: 视图消费点**

- 15 处 `@EnvironmentObject … WorkspaceStore` → `@Environment(WorkspaceStore.self) …`。
- 绑定承接：`MainWindowView` body 首行加 `@Bindable var store = store`（:95 `$store.showSettings`、:101 `$store.showCommandPalette` 原样可用）；`WorkspaceSidebarView` body 首行加 `@Bindable var store = store`（:91 `$store.sidebarIconCustomizationRequest`）。
- `WindowContext.swift:37,82`：`.environmentObject(store)` → `.environment(store)`（至此 rootView 两处闭包内三个注入全部为 `.environment`）。
- `WorkspaceSidebarView.swift:93`：`.environmentObject(store)` → `.environment(store)`。
- `WorkspaceOutlineSidebar.swift:10`：`@ObservedObject var store:` → `let store:`；`updateNSView` 首行（Task 1 的 theme 触读之后）追加：

```swift
        // Explicit tracked reads: parity with the old whole-object
        // @ObservedObject invalidation. apply() reads workspaces/groups/
        // collapsedSections within this call stack (auto-tracked); the
        // generation counter is the designated invalidation signal for
        // metadata refreshes, and selection drives the highlight sync.
        _ = store.workspaceMetadataGeneration
        _ = store.selectedWorkspaceID
```

- [ ] **Step 7: 跑桥测试绿 → 全量 + R6 核查**（Expected: 443 tests 0 failures，重点 `WorkspaceStore*Tests`/`SidebarContextMenuTests`/`PersistenceTests`。全仓此时 `grep -rn "@EnvironmentObject\|environmentObject(" Treemux/` 应为 0——三大环境对象已全部迁完。）

- [ ] **Step 8: Commit** — `perf(p1b): migrate WorkspaceStore to @Observable with debounced settings bridge`

---

### Task 8: 尾款 — Remote 浏览器 VM、两个 vestigial coordinator、死 import、SSHMultiplexing Swift-6 注解

**Files:**
- Modify: `Treemux/UI/Sheets/RemoteDirectoryBrowserViewModel.swift:10-35`
- Modify: `Treemux/UI/Sheets/RemoteDirectoryBrowser.swift:12,17-22,215`
- Modify: `Treemux/UI/FileBrowser/TextEditorView.swift:9,110,114,313`
- Modify: `Treemux/UI/FileBrowser/CompletionPopover.swift:214-221`
- Modify: `Treemux/Services/SFTP/SSHMultiplexing.swift:43`

- [ ] **Step 1: DirectoryNode + RemoteDirectoryBrowserViewModel → @Observable**：按 R1（两类均非 final，保持现状；DirectoryNode 保留 `Identifiable`）。两类各 4/7 个 `@Published` 前缀删除；其余存储属性按规则处理；加 `import Observation`、删仅存的 `import Combine`（如有）。
- [ ] **Step 2: 视图承接**：`RemoteDirectoryBrowser.swift:12` `@StateObject private var viewModel:` → `@State private var viewModel:`；`:18-20` `_viewModel = StateObject(wrappedValue: …)` → `_viewModel = State(initialValue: …)`（VM 构造轻量，@State 的 eager 求值可接受）；`:62/:113/:159` 的 `$viewModel.pathBarText`/`$viewModel.password`/`$viewModel.selectedPath` 经 @State 投影 Binding 原样可用，不改。`:215` `DirectoryNodeRow` 的 `@ObservedObject var node:` → `let node:`。
- [ ] **Step 3: 两个 vestigial coordinator 去 ObservableObject**：`TextEditorView.swift:313` `DiffStripeCoordinator` 与 `CompletionPopover.swift:215` `WordCompletionCoordinator` 均为 0 个 @Published 的挂名 ObservableObject——直接删 `: ObservableObject`（**不加** @Observable，诚实语义：纯持有对象）；`TextEditorView.swift:110,114` 两个 `@StateObject` → `@State`（:114 若在 init 里赋值则 `State(initialValue:)`）。
- [ ] **Step 4: 死 import 清理**：`TextEditorView.swift:9` 的 `import Combine`（盘点确认无 Combine 符号使用）删除。
- [ ] **Step 5: SSHMultiplexing Swift-6 前瞻注解**（P2 遗留事项）：`SSHMultiplexing.swift:43` 改为：

```swift
    // NSLock-guarded (see ensureLock); the annotation documents that guard
    // for future Swift 6 strict-concurrency mode, where a bare mutable
    // `static var` on a nonisolated type is a compile error.
    nonisolated(unsafe) private static var ensuredDirectories = Set<String>()
```

- [ ] **Step 6: 全量测试 + R6 核查**（Expected: 443 tests 0 failures，重点 `SSHMultiplexingTests`/`SFTPServiceTests`）
- [ ] **Step 7: Commit** — `perf(p1b): finish @Observable stragglers (remote browser VM, coordinators); annotate SSHMultiplexing for Swift 6`

---

### Task 9: 全局清扫、基准对比、台账与收尾

**Files:**
- Modify: `docs/perf/baseline.md`（追加 P1b 小节）
- Modify: `.superpowers/sdd/progress.md`（追加 P1b 台账）

- [ ] **Step 1: 全局残留清扫（必须全零/白名单精确匹配）**

```bash
grep -rn "@Published\|@EnvironmentObject\|@StateObject\|@ObservedObject\|environmentObject(\|ObservableObject\|objectWillChange" Treemux/ TreemuxTests/
```

Expected: 0 hits（注释中的历史措辞若残留则一并更新）。`grep -rn "import Combine" Treemux/ TreemuxTests/` 白名单核对：仅 `AppDelegate.swift`、`WindowContext.swift`、`ThemeManager.swift`、`LanguageManager.swift`、`WorkspaceStore.swift`、`ObservableBridgeTests.swift`（bridge 订阅/subject）。多出的逐个核查删除。

- [ ] **Step 2: 基准对比（合并证据）**

```bash
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -configuration Debug \
  -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/DerivedData -quiet
bash scripts/perf-baseline.sh build/DerivedData/Build/Products/Debug/Treemux.app
```

方法论（baseline.md 既有结论）：Scenario B 为主信号；同天、去首跑、branch/main 交错各跑 ≥3 次取均值。main 侧在主仓库目录同法构建对照。验收：Scenario B 均值不劣于 main 超出方差包络（2~5×内视为噪声需交错复核）；Scenario A 记录仅供参考。把两侧原始数字 + 均值写入 `docs/perf/baseline.md` 新小节「P1b 完成 @ <commit> 2026-07-XX」。

- [ ] **Step 3: 全量测试终跑**（Expected: 443 tests 0 failures）+ 核对 `MARKETING_VERSION = 0.0.19` 未漂移。

- [ ] **Step 4: 台账 + 提交**

`.superpowers/sdd/progress.md` 追加 P1b 小节（沿用 P2 格式：Plan/Branch/Worktree/Base + 每任务一行）。

```bash
git add -A && git commit -m "docs(p1b): record @Observable migration baseline comparison and progress ledger"
```

- [ ] **Step 5: 终审与合并前置**：整分支 final review（对照本计划 + 设计文档硬约束）→ 用户 GUI 冒烟（见下）→ 通过后 `main` 上 `git merge --no-ff perf/p1b-observable` + worktree 清理。

**用户 GUI 冒烟清单**（合并前必须由用户确认）：主题切换（含侧栏配色/window chrome/Ghostty 终端配色三通道同步）；语言切换（根视图重建）；终端窗格拖拽 resize/标题变化（无每帧重算回归）；文件树展开/收起 + `touch .git/index` git 刷新（行级失效仍生效）；编辑器连续打字 + ⌘S 保存（击键隔离仍生效）；设置面板改字号（⌘= 连发菜单不卡）+ 图标定制 sheet；远程目录浏览 sheet（含密码输入）；命令面板开关；批量关闭脏标签 sheet；侧栏活动指示环 + current 徽章；侧栏右键菜单（rename/delete/图标定制）。

## 已知偏差与决策记录（评审对照用）

1. 设计文档写「11 个对象 / 67 个 @Published」，实测 66 个 @Published（逐类清点：4+7+3+15+8+1+14+10+4+0+0）；差 1 为文档笔误，不影响范围。
2. 设计顺序「ThemeManager → ShellSession → …」中插入 LanguageManager（Task 2）：它与 ThemeManager 同属 WindowContext 三注入对象，桥模式相同，紧随其后成本最低；不改变叶子优先原则。
3. 「每迁一个：基准回归」落地为：每任务 Scenario B 单跑记录（信号），Task 9 多次取均值硬验收——单跑方差 2~5× 是 baseline.md 记录在案的既有结论，逐任务硬门槛没有统计意义。
4. Combine 未清零：3 个跨对象桥（theme/locale/settings）保留 PassthroughSubject——它们是非视图层管道，不在「视图按属性失效」的设计目标路径上；操作符语义（debounce/receive-on）原样保留风险最低。
5. 两个 vestigial coordinator 转纯 class 而非 @Observable：0 个观察属性，挂宏是纯仪式。
6. 冻结区新增「引用读自动追踪」通道：机制上无法在保留按引用传参的前提下关闭（除非把 island 全改成值快照——那才是违反「维持现状架构」）。保留手动刷新为权威路径、注释记录、GUI 冒烟覆盖。
