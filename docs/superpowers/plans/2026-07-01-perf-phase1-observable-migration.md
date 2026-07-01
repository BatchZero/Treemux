# Perf Phase 1 — `@Observable` Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Migrate all 11 legacy `ObservableObject`/`@Published` state classes to the Observation framework (`@Observable`), so SwiftUI tracks reads per-property and stops the "one change invalidates every observer" re-render storms.

**Architecture:** Each class's migration is **atomic**: the class conversion + every SwiftUI consumer (`@StateObject`/`@ObservedObject`/`@EnvironmentObject`) + every `.environmentObject(...)` injection + any Combine `$`-publisher bridge for that class all change together, because `@EnvironmentObject`/`@ObservedObject` require `ObservableObject` conformance while `@Environment(T.self)`/`@Bindable` require `@Observable`. Objects migrate leaf-first (fewest consumers / no Combine bridge first); the three environment-injected + Combine-bridged classes (`LanguageManager`, `ThemeManager`, `WorkspaceStore`) go last.

**Tech Stack:** Swift, SwiftUI, Observation framework (`@Observable`, `@Bindable`, `@ObservationIgnored`), a small amount of Combine retained only for imperative AppKit glue, xcodegen, xcodebuild.

## Global Constraints

- **Deployment target macOS 15.0** — Observation (`@Observable`, macOS 14+) fully available.
- **Worktree:** all work on branch `perf+overhaul` in `.worktrees/perf+overhaul/`. Main repo stays on `main`.
- **No new .swift files** are expected; if any are added, run `xcodegen generate` before building. Editing existing files needs no regeneration.
- **Non-interactive `xcodebuild` requires `-skipPackagePluginValidation`.**
- **Behavior must not change.** This is a mechanical framework migration; the app must look and behave identically. The gate for every task: the project compiles AND the full existing suite stays green (**403 tests, 0 failures**).
- **Version:** `project.yml` and pbxproj are at `0.0.19`/`19`; do not let any regeneration regress them.
- **Colors/i18n:** no new user-visible strings or colors are introduced by this migration; theme tokens and `LocalizedStringKey` usage are preserved as-is.
- Full suite command: `xcodebuild test -scheme Treemux -skipPackagePluginValidation -destination 'platform=macOS' 2>&1 | tail -30`

---

## Migration Patterns (referenced by every task as **P-A / P-B / P-C**)

### P-A — Convert a class to `@Observable`
1. Add `@Observable` immediately above the class declaration (keep `@MainActor` and `final`).
2. Remove the `ObservableObject` conformance (and `Identifiable` stays if present).
3. Remove `@Published` from every stored property (the property keeps its type, default, and any `didSet`/`willSet`).
4. Add `@ObservationIgnored` to any stored property that must NOT participate in view tracking (only known case: `FileBrowserTabController.treeScrollOffset`).
5. If the file's only use of Combine was `ObservableObject`, remove `import Combine`. If a Combine bridge (P-C) is added, keep it.
6. `private(set)` visibility is preserved as-is (it is orthogonal to `@Observable`).

### P-B — Update SwiftUI consumers of a migrated class
Apply at every site listed in the task:
- `@StateObject private var x = X()` → `@State private var x = X()`
- `_x = StateObject(wrappedValue: …)` → `_x = State(wrappedValue: …)`
- `@ObservedObject var x: X` → `var x: X` (plain). If that view derives a `$x.…` binding, use `@Bindable var x: X` instead.
- `@EnvironmentObject var x: X` → `@Environment(X.self) private var x`
- `.environmentObject(x)` → `.environment(x)`
- Binding derivation:
  - When `x` is owned via `@State` (an `@Observable`): `$x.prop` continues to work directly.
  - When `x` comes from `@Environment(X.self)`: add `@Bindable var x = x` as the first line of the `body` (or the relevant computed subview), then use `$x.prop`.
- Plain `let x: X` passed-in properties (e.g. `SidebarNodeRow`): leave as plain `let`/`var`; under `@Observable` a body that reads `x.someProp` is tracked automatically (this is the desired fine-grained behavior).

### P-C — Replace a Combine `$`-publisher bridge (imperative AppKit glue)
For the 3 classes whose `@Published` property is consumed by a non-SwiftUI `.sink`, add an explicit change signal fired from a `didSet`, and subscribe to that instead of `$prop`:
1. In the class, add `@ObservationIgnored let <prop>DidChange = PassthroughSubject<Void, Never>()` and keep `import Combine`.
2. Add/extend a `didSet { <prop>DidChange.send() }` on the property that drives the bridge.
3. In the consumer, replace `object.$prop.dropFirst()…` with `object.<prop>DidChange…` (drop `.dropFirst()` — the subject only fires on change, never emits an initial value).

---

## Migration order & task map

| Task | Class(es) | Consumers to update | Combine bridge |
|------|-----------|---------------------|----------------|
| 1 | WordCompletionCoordinator, DiffStripeCoordinator | TextEditorView `@StateObject`×2 | none |
| 2 | ShellSession | TerminalPaneView, TerminalHostView | none |
| 3 | WorkspaceSessionController | WorkspaceDetailView, SplitNodeView | none |
| 4 | FileBrowserTabController | 10 sites (see task) + `@ObservationIgnored treeScrollOffset` | none |
| 5 | RemoteDirectoryBrowserViewModel, DirectoryNode | RemoteDirectoryBrowser (`@StateObject`, `@ObservedObject`, bindings) | none |
| 6 | LanguageManager | 4 `@EnvironmentObject` + injections | `$locale` → `localeDidChange` (P-C) |
| 7 | ThemeManager | ~25 `@EnvironmentObject`/`@ObservedObject` + injections | `$activeTheme` → `activeThemeDidChange` (P-C) |
| 8 | WorkspaceModel | WorkspaceDetailView, WorkspaceTabBarView, SettingsSheet, SidebarNodeRow(let) | none |
| 9 | WorkspaceStore | ~15 `@EnvironmentObject`/`@ObservedObject` + bindings + remove `objectWillChange` | `$settings` → `settingsDidChange` (P-C) |
| 10 | Cleanup & verification | remove dead `import Combine`; full suite; re-baseline | — |

---

### Task 1: Migrate the two stateless editor coordinators

**Files:**
- Modify: `Treemux/UI/FileBrowser/CompletionPopover.swift:215` (`WordCompletionCoordinator`)
- Modify: `Treemux/UI/FileBrowser/TextEditorView.swift:285` (`DiffStripeCoordinator`), `:84`, `:88` (the two `@StateObject` sites)

**Interfaces:** No new symbols. `WordCompletionCoordinator` and `DiffStripeCoordinator` become `@Observable` classes still conforming to `TextViewCoordinator`.

**Context:** Both classes have ZERO `@Published` properties — they conform to `ObservableObject` only to satisfy `@StateObject`. This is the lowest-risk task and validates the P-A/P-B pattern end to end.

- [ ] **Step 1: Convert both classes (P-A)**
  - `WordCompletionCoordinator`: `final class WordCompletionCoordinator: ObservableObject, TextViewCoordinator` → `@Observable final class WordCompletionCoordinator: TextViewCoordinator`. Keep `@MainActor`. No `@Published` to remove.
  - `DiffStripeCoordinator`: `private final class DiffStripeCoordinator: ObservableObject, TextViewCoordinator` → `@Observable private final class DiffStripeCoordinator: TextViewCoordinator`. **Verify/add `@MainActor`** (investigation flagged it may be missing; it is used only from the `@MainActor` `TextEditorView`, so annotate `@MainActor` if absent).
  - Remove `import Combine` from each file if unused after conversion (check TextEditorView.swift still needs Combine for anything else first; if unsure, leave the import).

- [ ] **Step 2: Update the `@StateObject` sites (P-B)**
  In `TextEditorView.swift`: `@StateObject private var stripeCoordinator = …` (line 84) and `@StateObject private var completionCoordinator = …` (line 88) → `@State private var …`. If they use `StateObject(wrappedValue:)` in an initializer, switch to `State(wrappedValue:)`.

- [ ] **Step 3: Build + full suite**
  Run the full-suite command. Expected: `** TEST SUCCEEDED **`, 403 passing.

- [ ] **Step 4: Commit**
  ```bash
  git add Treemux/UI/FileBrowser/CompletionPopover.swift Treemux/UI/FileBrowser/TextEditorView.swift
  git commit -m "perf(phase1): migrate editor coordinators to @Observable"
  ```

---

### Task 2: Migrate `ShellSession`

**Files:**
- Modify: `Treemux/Services/Terminal/ShellSession.swift:31`
- Modify: `Treemux/UI/Workspace/TerminalPaneView.swift:12` (`@ObservedObject var session`)
- Modify: `Treemux/UI/Components/TerminalHostView.swift:14` (`@ObservedObject var session`)

**Interfaces:** `ShellSession` becomes `@Observable`, still `Identifiable`, still `@MainActor final`. Its 9 properties (`title`, `preferredWorkingDirectory`, `reportedWorkingDirectory`, `lifecycle`, `exitCode`, `pid`, `rows`, `cols`, `surfaceStatus`, `detectedTmuxSession`) keep their types/defaults/access; `import Combine` can be dropped (unused beyond conformance).

**Context:** Leaf object, no Combine bridge, no nesting. Its two consumers read `session.*` in their bodies, so fine-grained tracking attaches automatically after converting `@ObservedObject var session: ShellSession` → `var session: ShellSession`.

- [ ] **Step 1: Convert the class (P-A).** Add `@Observable`, remove `ObservableObject`, remove `@Published` from all 9 properties, drop `import Combine` if now unused.
- [ ] **Step 2: Update consumers (P-B).** `TerminalPaneView.swift:12` and `TerminalHostView.swift:14`: `@ObservedObject var session: ShellSession` → `var session: ShellSession`. Neither derives a `$session.…` binding (verify: if one does, use `@Bindable` instead).
- [ ] **Step 3: Build + full suite.** Expected 403 passing.
- [ ] **Step 4: Commit**
  ```bash
  git add Treemux/Services/Terminal/ShellSession.swift Treemux/UI/Workspace/TerminalPaneView.swift Treemux/UI/Components/TerminalHostView.swift
  git commit -m "perf(phase1): migrate ShellSession to @Observable"
  ```

---

### Task 3: Migrate `WorkspaceSessionController`

**Files:**
- Modify: `Treemux/Services/Terminal/WorkspaceSessionController.swift:12`
- Modify: `Treemux/UI/Workspace/WorkspaceDetailView.swift:71` (`@ObservedObject var controller`)
- Modify: `Treemux/UI/Workspace/SplitNodeView.swift:12` (`@ObservedObject var sessionController`)

**Interfaces:** becomes `@Observable @MainActor final`. Properties: `sessions: [UUID: ShellSession]` (private(set)), `layout`, `focusedPaneID` (keeps its `didSet { updateSessionFocusStates() }`), `zoomedPaneID`.

**Context:** Holds `[UUID: ShellSession]` (a dict of now-`@Observable` children after Task 2). Reassigning the dict is tracked; individual `ShellSession` mutations are tracked at the view sites that read them (already handled in Task 2). Keep the `focusedPaneID` `didSet` as-is.

- [ ] **Step 1: Convert (P-A).** `@Observable`, remove `ObservableObject`/`@Published` (all 4 props), keep the `focusedPaneID` didSet.
- [ ] **Step 2: Update consumers (P-B).** Both sites `@ObservedObject` → plain `var` (no `$` bindings derived; verify).
- [ ] **Step 3: Build + full suite.** Expected 403 passing.
- [ ] **Step 4: Commit**
  ```bash
  git add Treemux/Services/Terminal/WorkspaceSessionController.swift Treemux/UI/Workspace/WorkspaceDetailView.swift Treemux/UI/Workspace/SplitNodeView.swift
  git commit -m "perf(phase1): migrate WorkspaceSessionController to @Observable"
  ```

---

### Task 4: Migrate `FileBrowserTabController`

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift:27`
- Modify consumers (`@ObservedObject controller` → plain `var`, unless a `$` binding is derived → `@Bindable`):
  - `FileBrowser/FileViewerPanelView.swift:9`
  - `FileBrowser/TextEditorView.swift:18`
  - `FileBrowser/FileBrowserTabContentView.swift:8`
  - `FileBrowser/FileSubTabBarView.swift:14` (and the plain `let controller` at `:73` — leave plain)
  - `FileBrowser/FileTreePanelView.swift:8, 109, 140, 203, 327` (5 nested view structs)
  - `FileBrowser/DocumentViewerView.swift:16` (already plain `let` — leave)

**Interfaces:** becomes `@Observable @MainActor final`. **Critical:** add `@ObservationIgnored` to `var treeScrollOffset: CGFloat` (line 73) — its comment says it must never trigger a re-render; under `@Observable` all stored properties are tracked by default, so it MUST be `@ObservationIgnored` to preserve behavior. `treeContentGeneration` (line 81) stays a normal tracked property (it exists to signal views, so tracking is correct).

**Context:** 14 `@Published` props, no Combine bridge, no nested ObservableObject. `rawChildrenByPath` is already `private` and unread by views, so leaving it tracked is harmless, but mark it `@ObservationIgnored` too since it is an internal shadow cache that should never drive UI.

- [ ] **Step 1: Convert (P-A).** `@Observable`, remove `ObservableObject`/`@Published` (14 props). Add `@ObservationIgnored` to `treeScrollOffset` (line 73) and to the private `rawChildrenByPath` shadow cache. Drop `import Combine` (line 6) — investigation says it is unused beyond conformance (verify no other Combine use in the file first).
- [ ] **Step 2: Update consumers (P-B).** Convert each `@ObservedObject var controller: FileBrowserTabController` site listed above to plain `var controller`. For any site that derives `$controller.…` (search the file for `$controller`), use `@Bindable var controller` instead. Leave the already-plain `let controller` sites (`FileSubTabBarView.swift:73`, `DocumentViewerView.swift:16`) unchanged.
- [ ] **Step 3: Build + full suite.** Expected 403 passing. (Note: `FileBrowserTabControllerTests`, `…StaleLoadTests`, `…SubTabTests`, `…CopyPathTests`, `…SnapshotViewModeTests` exercise this class heavily — they must stay green.)
- [ ] **Step 4: Commit**
  ```bash
  git add Treemux/UI/FileBrowser/FileBrowserTabController.swift Treemux/UI/FileBrowser/FileViewerPanelView.swift Treemux/UI/FileBrowser/TextEditorView.swift Treemux/UI/FileBrowser/FileBrowserTabContentView.swift Treemux/UI/FileBrowser/FileSubTabBarView.swift Treemux/UI/FileBrowser/FileTreePanelView.swift
  git commit -m "perf(phase1): migrate FileBrowserTabController to @Observable (@ObservationIgnored scroll offset)"
  ```

---

### Task 5: Migrate `RemoteDirectoryBrowserViewModel` + `DirectoryNode`

**Files:**
- Modify: `Treemux/UI/Sheets/RemoteDirectoryBrowserViewModel.swift:11` (`DirectoryNode`), `:28` (`RemoteDirectoryBrowserViewModel`)
- Modify: `Treemux/UI/Sheets/RemoteDirectoryBrowser.swift:12` (`@StateObject viewModel`), `:215` (`@ObservedObject node`), and bindings at `:62`, `:113`, `:159`

**Interfaces:** Both classes become `@Observable`. They are currently **not `final`** — keep them non-final only if subclassed (they are not; make them `final` for clarity is optional — do NOT change finality if it risks behavior; leaving as-is is fine, `@Observable` works on non-final classes).

**Context:** These two migrate together — `RemoteDirectoryBrowserViewModel.rootNodes: [DirectoryNode]` and `DirectoryNode.children: [DirectoryNode]?` form a recursive observable tree. `DirectoryNodeRow` binds `@ObservedObject var node` per level; under `@Observable`, a row body reading `node.children`/`node.isExpanded`/`node.isLoading`/`node.error` tracks per-node automatically.

- [ ] **Step 1: Convert both classes (P-A).** `@Observable` on each; remove `ObservableObject` + `@Published` (VM has 7 props, DirectoryNode has 4). No `@ObservationIgnored` needed (no non-reactive stored state beyond `let` constants and the `private let` services, which are untracked constants anyway).
- [ ] **Step 2: Update `RemoteDirectoryBrowser.swift` (P-B).**
  - `:12` `@StateObject private var viewModel` → `@State private var viewModel`; if built via `StateObject(wrappedValue:)` switch to `State(wrappedValue:)`.
  - `:215` `@ObservedObject var node: DirectoryNode` → since the row derives bindings, use `@Bindable var node: DirectoryNode` (this preserves `$node` if used; if the row only reads and passes `$viewModel.selectedPath`, plain `var` suffices — inspect and choose).
  - Bindings `$viewModel.pathBarText` (:62), `$viewModel.password` (:113), `$viewModel.selectedPath` (:159): with `viewModel` now `@State`-owned `@Observable`, `$viewModel.prop` works directly — no change needed beyond the wrapper swap in step. Verify they compile.
- [ ] **Step 3: Build + full suite.** Expected 403 passing.
- [ ] **Step 4: Commit**
  ```bash
  git add Treemux/UI/Sheets/RemoteDirectoryBrowserViewModel.swift Treemux/UI/Sheets/RemoteDirectoryBrowser.swift
  git commit -m "perf(phase1): migrate RemoteDirectoryBrowser view models to @Observable"
  ```

---

### Task 6: Migrate `LanguageManager` (+ locale Combine bridge)

**Files:**
- Modify: `Treemux/Support/LanguageManager.swift:12`
- Modify: `Treemux/App/WindowContext.swift:65-75` (the `$locale` pipeline) and `:32`, `:73` (`.environmentObject(languageManager)` injections)
- Modify `@EnvironmentObject languageManager` consumers: `MainWindowView.swift:12`, `Sidebar/WorkspaceSidebarView.swift:12`, `Settings/SettingsSheet.swift:14`, `Sheets/OpenProjectSheet.swift:12`

**Interfaces:** `LanguageManager` becomes `@Observable @MainActor final`; keeps `locale: Locale` (`private(set)`). Adds `@ObservationIgnored let localeDidChange = PassthroughSubject<Void, Never>()` (P-C) and a `didSet` firing it.

**Context:** `WindowContext.swift:65` subscribes `languageManager.$locale` to rebuild `host.rootView` on language change (this whole rebuild is what Phase 4 will later improve; Phase 1 only preserves it via the P-C bridge). The pipeline's sink reads `newLocale` — with a `PassthroughSubject<Void,Never>` the sink must read `languageManager.locale` itself instead of a passed value.

- [ ] **Step 1: Convert `LanguageManager` (P-A + P-C).** Add `@Observable`; remove `ObservableObject`/`@Published`. Add `@ObservationIgnored let localeDidChange = PassthroughSubject<Void, Never>()` and `var locale: Locale { didSet { localeDidChange.send() } }` (keep `private(set)`). Keep `import Combine`.
- [ ] **Step 2: Rewrite the bridge in `WindowContext.swift` (P-C).** Replace
  ```swift
  localeCancellable = languageManager.$locale
      .dropFirst()
      .receive(on: RunLoop.main)
      .sink { [weak host, weak self] newLocale in
          guard let self, let host else { return }
          host.rootView = MainWindowView()
              .environmentObject(self.store)
              .environmentObject(self.themeManager)
              .environmentObject(self.languageManager)
              .environment(\.locale, newLocale)
      }
  ```
  with a subscription to `languageManager.localeDidChange` whose sink reads `self.languageManager.locale` for the new value. (Leave the `.environmentObject(self.store)`/`.environmentObject(self.themeManager)` calls in this closure UNCHANGED for now — those classes migrate in Tasks 7 and 9, which will update these lines then. Only `languageManager` injection semantics change here — but note `MainWindowView()`'s environment for languageManager must switch to `.environment(self.languageManager)` since it is now `@Observable`.)
- [ ] **Step 3: Update injections + consumers (P-B).** `WindowContext.swift:32` and the rebuild closure: `.environmentObject(languageManager)` → `.environment(languageManager)`. The 4 `@EnvironmentObject var languageManager: LanguageManager` sites → `@Environment(LanguageManager.self) private var languageManager`. Note `MainWindowView.swift:96`, `WorkspaceSidebarView.swift:89/92` read `languageManager.locale` into `.environment(\.locale, …)` — these reads are fine under `@Observable`.
- [ ] **Step 4: Build + full suite.** Expected 403 passing. Manually confirm the file still compiles with `import Combine` retained.
- [ ] **Step 5: Commit**
  ```bash
  git add Treemux/Support/LanguageManager.swift Treemux/App/WindowContext.swift Treemux/UI/MainWindowView.swift Treemux/UI/Sidebar/WorkspaceSidebarView.swift Treemux/UI/Settings/SettingsSheet.swift Treemux/UI/Sheets/OpenProjectSheet.swift
  git commit -m "perf(phase1): migrate LanguageManager to @Observable (locale change via PassthroughSubject)"
  ```

---

### Task 7: Migrate `ThemeManager` (+ activeTheme Combine bridge)

**Files:**
- Modify: `Treemux/UI/Theme/ThemeManager.swift:20`
- Modify: `Treemux/App/WindowContext.swift:57-62` (the `$activeTheme` pipeline) and `:31`, `:72`, plus `Sidebar/WorkspaceSidebarView.swift:94` (`.environmentObject(theme)` injections)
- Modify the `@ObservedObject`/`@EnvironmentObject theme` consumers (full list below).

**Interfaces:** `ThemeManager` becomes `@Observable @MainActor final`; keeps `activeTheme` (private(set)), `availableThemes`, `loadErrors`. Adds `@ObservationIgnored let activeThemeDidChange = PassthroughSubject<Void, Never>()` (P-C). If `activeTheme` is set only via a method (`setActiveTheme`), fire `activeThemeDidChange.send()` there; otherwise add a `didSet`.

**Consumers to convert (P-B):**
- `@ObservedObject`: `WorkspaceOutlineSidebar.swift:11`, `Settings/SettingsSheet.swift:305`.
- `@EnvironmentObject theme`/`themeManager` (25 sites): `MainWindowView.swift:10`, `Sheets/RemoteDirectoryBrowser.swift:10`, `Sheets/SSHServerEditSheet.swift:12`, `Workspace/SplitDivider.swift:11`, `Sidebar/WorkspaceSidebarView.swift:11`, `Workspace/WorkspaceTabBarView.swift:10,128`, `Workspace/TerminalPaneView.swift:11`, `Sheets/OpenProjectSheet.swift:11`, `Components/Hairline.swift:12`, `Sheets/SidebarIconCustomizationSheet.swift:12,95`, `Settings/SettingsSheet.swift:13`, `Sheets/SSHRawConfigSheet.swift:11`, `Workspace/EmptyTabStateView.swift:10`, `FileBrowser/FileViewerPanelView.swift:8`, `FileBrowser/RenderedMarkdownView.swift:28`, `FileBrowser/BatchUnsavedChangesSheet.swift:13`, `FileBrowser/TextEditorView.swift:20`, `FileBrowser/ImagePreviewView.swift:8`, `Components/CommandPaletteView.swift:25`, `FileBrowser/FileSubTabBarView.swift:13,102`, `FileBrowser/FileTreePanelView.swift:10,204,328`.
- Plain `let theme: ThemeManager` (leave unchanged): `Sidebar/SidebarNodeRow.swift:18,53,124,186`, `Components/CommandPaletteView.swift:253`.
- `SidebarCoordinator.swift:17` `var theme: ThemeManager?` (AppKit NSObject) — leave as plain optional property.

- [ ] **Step 1: Convert `ThemeManager` (P-A + P-C).** `@Observable`, remove `ObservableObject`/`@Published` (3 props), add `@ObservationIgnored let activeThemeDidChange = PassthroughSubject<Void, Never>()`, fire it where `activeTheme` changes. Keep `import Combine`.
- [ ] **Step 2: Rewrite the bridge in `WindowContext.swift:57` (P-C).** Replace `themeManager.$activeTheme.dropFirst().receive(on: RunLoop.main).sink { self?.updateAppearance() }` with a subscription to `themeManager.activeThemeDidChange.receive(on: RunLoop.main).sink { self?.updateAppearance() }`.
- [ ] **Step 3: Update injections (P-B).** `WindowContext.swift:31` and `:72`, and `WorkspaceSidebarView.swift:94`: `.environmentObject(themeManager/theme)` → `.environment(...)`.
- [ ] **Step 4: Update consumers (P-B).** Convert the 2 `@ObservedObject` and 25 `@EnvironmentObject` sites listed above (`@EnvironmentObject var theme: ThemeManager` → `@Environment(ThemeManager.self) private var theme`, preserving the local variable name — some use `theme`, some `themeManager`). Leave plain-`let` sites unchanged.
- [ ] **Step 5: Build + full suite.** Expected 403 passing. Watch for any `$theme.…` binding needing `@Bindable` (search the touched files for `$theme`/`$themeManager`).
- [ ] **Step 6: Commit** (stage `ThemeManager.swift`, `WindowContext.swift`, and every consumer file touched)
  ```bash
  git commit -am "perf(phase1): migrate ThemeManager to @Observable (appearance update via PassthroughSubject)"
  ```
  (Use `git add -A` within the worktree after reviewing `git status` to ensure only intended files are staged.)

---

### Task 8: Migrate `WorkspaceModel`

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift:267`
- Modify consumers: `Workspace/WorkspaceDetailView.swift:23`, `Workspace/WorkspaceTabBarView.swift:11`, `Settings/SettingsSheet.swift:694,719`, and the `.sheet(item: $workspace.pendingBatchClose)` binding at `WorkspaceDetailView.swift:57`.
- Leave plain-`let workspace: WorkspaceModel` sites unchanged: `Sidebar/SidebarNodeRow.swift:53,124`, `Workspace/WorkspaceTabBarView.swift:288` (`TabDropDelegate`).

**Interfaces:** `WorkspaceModel` becomes `@Observable @MainActor final`, still `Identifiable`. 14 `@Published` props → tracked. `worktrees: [WorktreeModel]` is a struct array (fine). `private(set) var activeWorktreePath` (line 310) becomes tracked — this is a latent fix (it was silently non-reactive before); acceptable and desirable.

**Context:** `WorkspaceModel` is nested inside `WorkspaceStore.workspaces` (still `ObservableObject` until Task 9). After this task, views reading `workspace.currentBranch` etc. re-render on child mutation automatically — which is exactly what the manual `objectWillChange.send()` at `WorkspaceStore.swift:472` was faking. Do NOT remove that line yet (WorkspaceStore is still `ObservableObject`); it is removed in Task 9.

- [ ] **Step 1: Convert (P-A).** `@Observable`, remove `ObservableObject`/`@Published` (14 props). No `@ObservationIgnored` needed (private controller dicts are untracked internal state, but since they're `private` and unread by views, leaving them tracked is harmless; mark them `@ObservationIgnored` only if a build warning or behavior issue appears).
- [ ] **Step 2: Update consumers (P-B).** `@ObservedObject var workspace` sites → plain `var workspace`. The `.sheet(item: $workspace.pendingBatchClose)` at `WorkspaceDetailView.swift:57` needs `@Bindable`: add `@Bindable var workspace = workspace` in the body before that `.sheet` (or change the stored property to `@Bindable var workspace` if it is passed in and the view derives the binding).
- [ ] **Step 3: Build + full suite.** Expected 403 passing. (`WorkspaceModelTabKindTests` documents a timing-sensitive re-render behavior — confirm it stays green.)
- [ ] **Step 4: Commit**
  ```bash
  git commit -am "perf(phase1): migrate WorkspaceModel to @Observable"
  ```

---

### Task 9: Migrate `WorkspaceStore` (+ settings debounce bridge, remove manual objectWillChange)

**Files:**
- Modify: `Treemux/App/WorkspaceStore.swift:15` (class) and `:472` (remove `objectWillChange.send()`)
- Modify: `Treemux/AppDelegate.swift:8,36-42` (the `$settings` debounce pipeline + its `AnyCancellable`)
- Modify: `Treemux/App/WindowContext.swift:30,71` (`.environmentObject(store)` injections)
- Modify consumers: `WorkspaceOutlineSidebar.swift:10` (`@ObservedObject`), and `@EnvironmentObject store` sites: `MainWindowView.swift:11`, `Sidebar/WorkspaceSidebarView.swift:10`, `Sheets/OpenProjectSheet.swift:10`, `Settings/SettingsSheet.swift:12,655,693,718`, `Sheets/SidebarIconCustomizationSheet.swift:94`, `Workspace/WorkspaceDetailView.swift:10,22`, `Components/CommandPaletteView.swift:24`, `FileBrowser/TextEditorView.swift:19`, `FileBrowser/FileTreePanelView.swift:9`.
- Bindings needing `@Bindable`: `MainWindowView.swift:95` (`$store.showSettings`), `:101` (`$store.showCommandPalette`), `Sidebar/WorkspaceSidebarView.swift:91` (`$store.sidebarIconCustomizationRequest`).
- Plain-`let store: WorkspaceStore` sites (leave): `Sidebar/SidebarNodeRow.swift:18,53,124`. `SidebarCoordinator.swift:16` `weak var store` — leave.

**Interfaces:** `WorkspaceStore` becomes `@Observable @MainActor final`. 7 `@Published` props → tracked; keep the `selectedWorkspaceID` didSet (Perf.event + handleWorktreeSelectionIfNeeded) and the `settings` didSet (persist). Add `@ObservationIgnored let settingsDidChange = PassthroughSubject<Void, Never>()` (P-C) fired from the `settings` didSet (alongside the existing persist call). Keep `import Combine`.

**Context:** This is the largest consumer set and the last migration. The AppDelegate debounce pipeline (`store.$settings.dropFirst().debounce(150ms).sink { rebuild menu + reconfigure updater }`) becomes a subscription to `store.settingsDidChange.debounce(150ms).sink { … }`. The `.dropFirst()` is removed (the subject only fires on real changes).

- [ ] **Step 1: Convert (P-A + P-C).** `@Observable`; remove `ObservableObject`/`@Published` (7 props); keep both didSets; in the `settings` didSet add `settingsDidChange.send()` (keep the existing `settingsPersistence.save(settings)`); add `@ObservationIgnored let settingsDidChange = PassthroughSubject<Void, Never>()`. Keep `import Combine`.
- [ ] **Step 2: Remove the manual bridge.** Delete `objectWillChange.send()` at line 472 and its now-stale comment (child `WorkspaceModel` mutations are tracked directly after Task 8).
- [ ] **Step 3: Rewrite AppDelegate debounce (P-C).** Replace `store.$settings.dropFirst().debounce(for: .milliseconds(150), scheduler: RunLoop.main).sink { … }` with `store.settingsDidChange.debounce(for: .milliseconds(150), scheduler: RunLoop.main).sink { … }`. Keep `settingsCancellable: AnyCancellable?` and `import Combine` in AppDelegate.
- [ ] **Step 4: Update injections + consumers (P-B).** `WindowContext.swift:30,71` `.environmentObject(store)` → `.environment(store)`. Convert `WorkspaceOutlineSidebar.swift:10` `@ObservedObject` and all `@EnvironmentObject var store: WorkspaceStore` sites listed → `@Environment(WorkspaceStore.self) private var store`. For the 3 `$store.…` binding sites, add `@Bindable var store = store` in the relevant body before the binding is used.
- [ ] **Step 5: Build + full suite.** Expected 403 passing.
- [ ] **Step 6: Commit**
  ```bash
  git commit -am "perf(phase1): migrate WorkspaceStore to @Observable; drop manual objectWillChange"
  ```

---

### Task 10: Cleanup & verification

**Files:** any file still importing `Combine` without using it; `docs/perf/baseline.md`.

- [ ] **Step 1: Dead-import sweep.** Grep the touched files for `import Combine`; remove it from any file that no longer references Combine (`PassthroughSubject`, `AnyCancellable`, `.sink`, etc.). The three bridge classes + AppDelegate + WindowContext KEEP `import Combine`.
  Run: `grep -rl 'import Combine' Treemux` then verify each remaining file still uses a Combine symbol.
- [ ] **Step 2: Grep for stragglers.** Confirm zero remaining legacy wrappers on migrated types:
  ```bash
  grep -rn '@Published\|: ObservableObject\|@ObservedObject\|@StateObject\|@EnvironmentObject\|\.environmentObject(' Treemux
  ```
  Expected: no matches (every one migrated). If any remain, they are either a missed site (fix it) or intentional — justify in the commit.
- [ ] **Step 3: Full suite.** Run the full-suite command; expect 403 passing.
- [ ] **Step 4: Re-run the Phase 0 baseline harness** to confirm no regression on the measured paths (typing / expand). Rebuild Debug, then:
  ```bash
  APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/Treemux-*/Build/Products/Debug/Treemux.app | head -1)
  TREEMUX_PERF_LOG=/tmp/p1-typing.csv TREEMUX_PERF_DRIVE=typing "$APP/Contents/MacOS/Treemux"
  ```
  Append a post-Phase-1 row to the scenario tables in `docs/perf/baseline.md` (typing input.keydown; expand-local). These paths shouldn't regress; re-render wins are qualitative (fine-grained tracking) and validated by an optional Instruments SwiftUI "View Body" pass, noted for later.
- [ ] **Step 5: Commit**
  ```bash
  git add -A
  git commit -m "perf(phase1): cleanup dead Combine imports; record post-migration baseline"
  ```

---

## Self-Review

- **Spec coverage:** Phase 1 spec requires migrating the god objects to `@Observable`, updating view wrappers (`@StateObject`/`@ObservedObject`→`@State`/`@Bindable`, `@EnvironmentObject`→`@Environment`), removing the manual `objectWillChange.send()` (WorkspaceStore:472, Task 9), and leaf-first ordering with tests after each. → Tasks 1–9 cover all 11 classes leaf-first (coordinators → ShellSession → WorkspaceSessionController → FileBrowserTabController → RemoteDir models → LanguageManager → ThemeManager → WorkspaceModel → WorkspaceStore); Task 10 verifies. The 3 Combine `$` hazards are handled by P-C in Tasks 6/7/9. No gap.
- **Placeholder scan:** No TBD/TODO. Patterns P-A/P-B/P-C carry the concrete mechanics; per-task steps list exact files/lines/sites from the investigation. Where an exact binding site could go two ways (`@Bindable` vs plain), the step instructs to inspect for `$`-derivation and choose — this is a genuine per-site check, not a placeholder.
- **Type consistency:** `activeThemeDidChange`, `localeDidChange`, `settingsDidChange` are the three P-C subjects; each is referenced consistently between its class (Tasks 6/7/9 step 1) and its consumer (same task's bridge step). `@ObservationIgnored treeScrollOffset` appears only in Task 4.
- **Risk note:** Nested-observable dictionaries (`WorkspaceSessionController.sessions`, `WorkspaceStore.workspaces`, recursive `DirectoryNode.children`) rely on fine-grained tracking attaching at the view sites that read child properties — those sites are converted in the same or earlier tasks, so tracking is preserved. The full suite after each task is the guard.
