# Detach Sidebar Node to New Window — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let any sidebar node (project / worktree / remote server group) be torn off into its own independent app window via drag or right-click, with the node hidden in the main sidebar while detached and restored when the child window closes.

**Architecture:** Single process, multiple `NSWindow`s sharing one `WorkspaceStore`. A new `WindowManager` replaces the single `WindowContext`. Each detached node is recorded as a `DetachedNodeRef` in the store (persisted to `workspace-state.json`), driving main-sidebar filtering and child-window reconstruction on launch.

**Tech Stack:** Swift, SwiftUI, AppKit (`NSOutlineView`, `NSDraggingSource`, `NSWindow`), `@Observable` macro, JSON persistence, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-12-detach-to-new-window-design.md`

## Global Constraints

- macOS-only; Swift; AppKit-first (no SwiftUI `WindowGroup`).
- All UI strings via `LocalizedStringKey` / `String(localized:)`; add `zh-Hans` to `Treemux/Localizable.xcstrings`.
- Colors via theme tokens — no hardcoded colors.
- Code comments in English; user-facing strings localized (en source + zh-Hans).
- TDD: write failing test → implement → green → commit. Each task is independently testable.
- Worktree: `.worktrees/feat+detach-to-new-window/` on branch `feat+detach-to-new-window`.

---

## File Structure

**New files:**
- `Treemux/Domain/DetachedNodeRef.swift` — enum identifying a detached node.
- `Treemux/App/WindowManager.swift` — multi-window coordinator (replaces single `WindowContext` ownership in `TreemuxApp`).
- `Treemux/UI/Detached/SingleWorkspaceWindowView.swift` — child window root for a workspace.
- `Treemux/UI/Detached/SingleWorktreeWindowView.swift` — child window root for a worktree.
- `Treemux/UI/Detached/RemoteGroupWindowView.swift` — child window root for a remote section.
- `Treemux/UI/Detached/DetachedRootView.swift` — dispatcher that picks one of the three by `DetachedNodeRef`.
- `Treemux/UI/Sidebar/DetachPasteboardItem.swift` — `NSPasteboardWriting` carrying a `DetachedNodeRef`.
- `TreemuxTests/DetachedNodeRefTests.swift`
- `TreemuxTests/WindowManagerTests.swift`
- `TreemuxTests/SidebarDetachTests.swift` (extend existing `SidebarContextMenuTests.swift` file if pattern fits)

**Modified files:**
- `Treemux/Domain/WorkspaceModels.swift` — add `detachedNodes` to `PersistedWorkspaceState`; coding keys.
- `Treemux/App/WorkspaceStore.swift` — `detachedNodes` field, `isDetached`, `workspacesInRemoteGroup`, validity helper.
- `Treemux/App/WindowContext.swift` — add `Kind` enum (`main` / `detached`), root-view dispatch, `setFrameAutosaveName`.
- `Treemux/App/TreemuxApp.swift` — replace `windowContext: WindowContext?` with `windowManager: WindowManager`; `restoreChildWindows` on launch.
- `Treemux/AppDelegate.swift` — `applicationShouldTerminateAfterLastWindowClosed` → `false`; main-window close cascade hook.
- `Treemux/UI/Sidebar/SidebarCoordinator.swift` — `NSDraggingSource` impl, worktree pasteboard writer, "Open in New Window" menu item, `onDetachNode` closure, sidebar filtering by `detachedNodes`.
- `Treemux/UI/Sidebar/WorkspaceSidebarView.swift` — wire `onDetachNode` closure.
- `Treemux/UI/Sidebar/SidebarNodeItem.swift` — (if needed) no struct change, filtering is in coordinator.
- `Treemux/UI/Workspace/WorkspaceDetailView.swift` — prefer injected `@Environment(WorkspaceModel.self)`.
- `Treemux/Localizable.xcstrings` — "Open in New Window", "Already in New Window" (zh-Hans).

---

## Task 1: `DetachedNodeRef` type

**Files:**
- Create: `Treemux/Domain/DetachedNodeRef.swift`
- Test: `TreemuxTests/DetachedNodeRefTests.swift`

**Interfaces:**
- Produces: `enum DetachedNodeRef: Hashable, Codable` with cases `.workspace(UUID)`, `.worktree(workspaceID: UUID, worktreeID: UUID)`, `.remoteGroup(String)`.

- [ ] **Step 1: Write the failing test**

```swift
// TreemuxTests/DetachedNodeRefTests.swift
import XCTest
@testable import Treemux

final class DetachedNodeRefTests: XCTestCase {
    func testWorkspaceCodableRoundTrip() throws {
        let id = UUID()
        let ref = DetachedNodeRef.workspace(id)
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(DetachedNodeRef.self, from: data)
        XCTAssertEqual(decoded, ref)
    }

    func testWorktreeCodableRoundTrip() throws {
        let wsID = UUID()
        let wtID = UUID()
        let ref = DetachedNodeRef.worktree(workspaceID: wsID, worktreeID: wtID)
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(DetachedNodeRef.self, from: data)
        XCTAssertEqual(decoded, ref)
    }

    func testRemoteGroupCodableRoundTrip() throws {
        let ref = DetachedNodeRef.remoteGroup("my-server|root")
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(DetachedNodeRef.self, from: data)
        XCTAssertEqual(decoded, ref)
    }

    func testHashableDistinguishesCases() {
        let id = UUID()
        let a = DetachedNodeRef.workspace(id)
        let b = DetachedNodeRef.remoteGroup("x")
        XCTAssertNotEqual(a, b)
    }

    func testWorktreeWithSameWorkspaceButDifferentWorktreeNotEqual() {
        let wsID = UUID()
        let a = DetachedNodeRef.worktree(workspaceID: wsID, worktreeID: UUID())
        let b = DetachedNodeRef.worktree(workspaceID: wsID, worktreeID: UUID())
        XCTAssertNotEqual(a, b)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/DetachedNodeRefTests`
Expected: FAIL — `cannot find 'DetachedNodeRef' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Treemux/Domain/DetachedNodeRef.swift
import Foundation

/// Identifies a sidebar node that has been detached into its own window.
/// Persisted in `workspace-state.json` so child windows can be rebuilt on launch.
enum DetachedNodeRef: Hashable, Codable {
    /// A whole workspace torn off into its own window.
    case workspace(UUID)
    /// A single worktree torn off; parent workspace stays in the main sidebar.
    case worktree(workspaceID: UUID, worktreeID: UUID)
    /// An entire remote server section torn off.
    case remoteGroup(String)
}
```

Add the new file to the Xcode project (`Treemux` target). If the project uses file-system synchronized groups (Xcode 16+), no explicit `project.pbxproj` edit is needed — verify with a build.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/DetachedNodeRefTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Treemux/Domain/DetachedNodeRef.swift TreemuxTests/DetachedNodeRefTests.swift
git commit -m "feat: add DetachedNodeRef type for sidebar tear-off"
```

---

## Task 2: `detachedNodes` on `WorkspaceStore` + persistence

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift` (extend `PersistedWorkspaceState`)
- Modify: `Treemux/App/WorkspaceStore.swift` (add `detachedNodes` field + helpers)
- Test: `TreemuxTests/DetachedNodeRefTests.swift` (extend) or new `TreemuxTests/WorkspaceStoreDetachTests.swift`

**Interfaces:**
- Consumes: `DetachedNodeRef` from Task 1.
- Produces: `WorkspaceStore.detachedNodes: Set<DetachedNodeRef>`, `WorkspaceStore.isDetached(_:) -> Bool`, `WorkspaceStore.workspacesInRemoteGroup(_:) -> [WorkspaceModel]`, `WorkspaceStore.isValid(_ ref:) -> Bool`.
- Produces: `PersistedWorkspaceState.detachedNodes: Set<DetachedNodeRef>`.

- [ ] **Step 1: Write the failing test**

```swift
// TreemuxTests/WorkspaceStoreDetachTests.swift
import XCTest
@testable import Treemux

final class WorkspaceStoreDetachTests: XCTestCase {
    @MainActor
    func testIsDetachedReturnsFalseByDefault() {
        let store = WorkspaceStore()
        let ref = DetachedNodeRef.workspace(UUID())
        XCTAssertFalse(store.isDetached(ref))
    }

    @MainActor
    func testInsertAndQueryDetached() {
        let store = WorkspaceStore()
        let ref = DetachedNodeRef.workspace(UUID())
        store.detachedNodes.insert(ref)
        XCTAssertTrue(store.isDetached(ref))
    }

    @MainActor
    func testRemoveDetachedRestoresVisibility() {
        let store = WorkspaceStore()
        let ref = DetachedNodeRef.workspace(UUID())
        store.detachedNodes.insert(ref)
        store.detachedNodes.remove(ref)
        XCTAssertFalse(store.isDetached(ref))
    }

    @MainActor
    func testIsValidReturnsFalseForUnknownWorkspace() {
        let store = WorkspaceStore()
        let ref = DetachedNodeRef.workspace(UUID())
        XCTAssertFalse(store.isValid(ref))
    }

    @MainActor
    func testIsValidReturnsFalseForUnknownRemoteGroup() {
        let store = WorkspaceStore()
        let ref = DetachedNodeRef.remoteGroup("nonexistent|user")
        XCTAssertFalse(store.isValid(ref))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/WorkspaceStoreDetachTests`
Expected: FAIL — `cannot find 'isDetached'` / `'isValid'`.

- [ ] **Step 3: Implement on `WorkspaceStore`**

In `Treemux/App/WorkspaceStore.swift`, add to the `WorkspaceStore` class (near existing `var workspaces`):

```swift
/// Nodes currently torn off into their own windows. Persisted across launches
/// so child windows can be rebuilt. Drives main-sidebar filtering.
var detachedNodes: Set<DetachedNodeRef> = []

func isDetached(_ ref: DetachedNodeRef) -> Bool {
    detachedNodes.contains(ref)
}
```

Add the validity + remote-group helpers (place near existing `remoteGroupKey(for:)` around line 378):

```swift
/// Workspaces belonging to a remote group key (used by RemoteGroupWindowView).
func workspacesInRemoteGroup(_ key: String) -> [WorkspaceModel] {
    workspaces.filter { remoteGroupKey(for: $0) == key }
}

/// Returns true if the referenced node still exists in the store.
/// Stale refs (e.g. worktree deleted on disk) are dropped during restore.
func isValid(_ ref: DetachedNodeRef) -> Bool {
    switch ref {
    case .workspace(let id):
        return workspaces.contains { $0.id == id }
    case .worktree(let wsID, let wtID):
        guard let ws = workspaces.first(where: { $0.id == wsID }) else { return false }
        return ws.worktrees.contains { $0.id == wtID }
    case .remoteGroup(let key):
        return workspaces.contains { remoteGroupKey(for: $0) == key }
    }
}
```

> Note: if `WorktreeModel.id` is not `UUID` but `String`, adjust the `wtID` type in `DetachedNodeRef.worktree` accordingly. Verify in `WorkspaceModels.swift:222-228` — currently `WorktreeModel.id` — check its actual type and keep `DetachedNodeRef` consistent. (If `WorktreeModel.id` is `String`, change Task 1's case to `worktree(workspaceID: UUID, worktreeID: String)` and update tests.)

- [ ] **Step 4: Extend `PersistedWorkspaceState`**

In `Treemux/Domain/WorkspaceModels.swift`, find `struct PersistedWorkspaceState: Codable` (around line 211-217) and add:

```swift
struct PersistedWorkspaceState: Codable {
    var version: Int
    var selectedWorkspaceID: UUID?
    var workspaces: [WorkspaceRecord]
    var collapsedSections: Set<String>
    var remoteGroupOrder: [String]
    var detachedNodes: Set<DetachedNodeRef> = []     // NEW; default for backward-compat on decode

    // CodingKeys must include detachedNodes. If using Swift synthesized
    // CodingKeys, add the key. If decoding an older file lacking the key,
    // decode `detachedNodes` as empty set (default value handles this if
    // you implement a custom init(from:) OR use Optional + ??).
}
```

To preserve backward compatibility with existing `workspace-state.json` files (which lack `detachedNodes`), the safest approach is a custom `init(from decoder:)` that decodes `detachedNodes` with `.decodeIfPresent(...)?.isEmpty == false ? decoded : []`, OR declare the field as `Set<DetachedNodeRef>?` and expose a computed `var detachedNodes: Set<DetachedNodeRef> { _detachedNodes ?? [] }`. Inspect the existing `PersistedWorkspaceState` coding strategy — if it already uses a custom `init(from:)`, mirror that pattern.

- [ ] **Step 5: Wire persistence load/save**

In `WorkspaceStore`, the existing load path (around `WorkspaceStatePersistence.load()` + hydration in `init`/`reload`) must populate `self.detachedNodes` from the decoded `PersistedWorkspaceState.detachedNodes`. The existing save path (`saveWorkspaceState` / `DebouncedSaver`) must encode `detachedNodes` back. Locate where `PersistedWorkspaceState` is constructed for saving and add `detachedNodes: self.detachedNodes`.

- [ ] **Step 6: Run test to verify it passes**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/WorkspaceStoreDetachTests`
Expected: PASS (5 tests).

- [ ] **Step 7: Commit**

```bash
git add Treemux/Domain/WorkspaceModels.swift Treemux/App/WorkspaceStore.swift TreemuxTests/WorkspaceStoreDetachTests.swift
git commit -m "feat: persist detachedNodes in WorkspaceStore and workspace-state.json"
```

---

## Task 3: `WindowContext.Kind` + root-view dispatch + frame autosave

**Files:**
- Modify: `Treemux/App/WindowContext.swift`

**Interfaces:**
- Consumes: `WorkspaceStore` (existing), `DetachedNodeRef` (Task 1).
- Produces: `WindowContext.Kind` enum; `WindowContext.init(store:themeManager:languageManager:kind:)`; `WindowContext.show()` dispatches root view by `kind`; `WindowContext.closeImmediately()`.

This task ONLY refactors `WindowContext` to support a `Kind`. It does not yet introduce `WindowManager` or the three detached root views (those come later). For now, the `.detached` case uses a placeholder `Text` view so the window can be shown; subsequent tasks swap in real views.

- [ ] **Step 1: Write the failing test**

```swift
// TreemuxTests/WindowContextKindTests.swift
import XCTest
@testable import Treemux

final class WindowContextKindTests: XCTestCase {
    @MainActor
    func testMainKindPersists() {
        let store = WorkspaceStore()
        let ctx = WindowContext(store: store, kind: .main)
        if case .main = ctx.kind {} else { XCTFail("expected .main") }
    }

    @MainActor
    func testDetachedKindPersists() {
        let store = WorkspaceStore()
        let ref = DetachedNodeRef.workspace(UUID())
        let ctx = WindowContext(store: store, kind: .detached(ref))
        guard case .detached(let stored) = ctx.kind else {
            return XCTFail("expected .detached")
        }
        XCTAssertEqual(stored, ref)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/WindowContextKindTests`
Expected: FAIL — `cannot find 'kind'` / extra-arg error.

- [ ] **Step 3: Refactor `WindowContext`**

In `Treemux/App/WindowContext.swift`:

```swift
@MainActor
final class WindowContext {
    enum Kind {
        case main
        case detached(DetachedNodeRef)
    }

    let store: WorkspaceStore
    let themeManager: ThemeManager
    let languageManager: LanguageManager
    let kind: Kind
    private var window: NSWindow?
    private var themeCancellable: AnyCancellable?
    private var localeCancellable: AnyCancellable?

    init(store: WorkspaceStore, kind: Kind = .main) {
        self.store = store
        self.kind = kind
        self.themeManager = ThemeManager(activeThemeID: store.settings.activeThemeID)
        self.languageManager = LanguageManager(languageCode: store.settings.language)
    }

    /// Stable per-window autosave key for frame persistence.
    private var frameAutosaveName: String {
        switch kind {
        case .main:
            return "treemux.main"
        case .detached(let ref):
            return "treemux.detach." + ref.autosaveKeySuffix
        }
    }

    func show() {
        let rootView = makeRootView()
        let host = NSHostingController(
            rootView: rootView
                .environment(store)
                .environment(themeManager)
                .environment(languageManager)
                .environment(\.locale, languageManager.locale)
        )

        let window = NSWindow(contentViewController: host)
        window.title = windowTitle
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.setFrameAutosaveName(frameAutosaveName)   // NEW: system-managed frame persistence
        // setFrameAutosaveName returns true if it restored a saved frame;
        // if not (first launch), center the window.
        window.center()
        applyThemeAppearance(to: window)
        window.makeKeyAndOrderFront(nil)

        self.window = window
        // ... existing theme/locale observers (unchanged) ...
    }

    /// Closes the window WITHOUT triggering detached-node restore side-effects.
    /// Used during cascade shutdown.
    func closeImmediately() {
        window?.close()
        window = nil
    }

    private func makeRootView() -> some View {
        switch kind {
        case .main:
            return AnyView(MainWindowView())
        case .detached(let ref):
            // Placeholder until Task 7 swaps in DetachedRootView.
            return AnyView(Text("Detached: \(String(describing: ref))"))
        }
    }

    private var windowTitle: String {
        switch kind {
        case .main:
            return "Treemux"
        case .detached:
            return "Treemux"     // refined in Task 7 with the node name
        }
    }

    // existing applyThemeAppearance / updateAppearance unchanged
}
```

Add a helper on `DetachedNodeRef` (in `DetachedNodeRef.swift`) for the autosave suffix:

```swift
extension DetachedNodeRef {
    var autosaveKeySuffix: String {
        switch self {
        case .workspace(let id): return "workspace.\(id.uuidString)"
        case .worktree(let wsID, let wtID): return "worktree.\(wsID.uuidString).\(wtID)"
        case .remoteGroup(let key): return "remotegroup.\(key)"
        }
    }
}
```

> Note on `center()` vs restored frame: `setFrameAutosaveName` synchronously applies the saved frame if one exists. Calling `center()` afterward overrides the restored position. To respect the saved frame, check the return value of `setFrameAutosaveName`; if it returns `true` (frame was restored), skip `center()`:

```swift
let restored = window.setFrameAutosaveName(frameAutosaveName)
if !restored {
    window.center()
}
```

- [ ] **Step 4: Update `TreemuxApp.launch()` to pass `.main` explicitly**

In `Treemux/App/TreemuxApp.swift`, the existing `WindowContext(store: store)` call now defaults to `.main` — no change needed for now (default arg). This keeps Task 3 self-contained.

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/WindowContextKindTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Manually smoke-test the main window still launches**

```bash
xcodebuild build -scheme Treemux -destination 'platform=macOS'
```
Then run the app (see Global Constraints / AGENTS.md for the `open` command) and verify the main window opens normally.

- [ ] **Step 7: Commit**

```bash
git add Treemux/App/WindowContext.swift Treemux/Domain/DetachedNodeRef.swift TreemuxTests/WindowContextKindTests.swift
git commit -m "refactor: WindowContext gains Kind enum and frame autosave"
```

---

## Task 4: `WindowManager` (multi-window coordinator)

**Files:**
- Create: `Treemux/App/WindowManager.swift`
- Test: `TreemuxTests/WindowManagerTests.swift`

**Interfaces:**
- Consumes: `WindowContext` (Task 3), `WorkspaceStore.detachedNodes` (Task 2), `WorkspaceStore.isValid` (Task 2).
- Produces: `WindowManager` class with `launchMain()`, `detach(_:)`, `closeChild(_:)`, `handleMainWindowWillClose()`, `restoreChildWindows()`, `isShuttingDown`.

- [ ] **Step 1: Write the failing test**

```swift
// TreemuxTests/WindowManagerTests.swift
import XCTest
@testable import Treemux

final class WindowManagerTests: XCTestCase {
    @MainActor
    func testDetachInsertsRefIntoStore() {
        let store = WorkspaceStore()
        // Seed a workspace so isValid passes.
        let ws = WorkspaceModel(repositoryPath: "/tmp/repo", name: "repo")
        store.workspaces.append(ws)
        let mgr = WindowManager(store: store)
        let ref = DetachedNodeRef.workspace(ws.id)
        mgr.detach(ref)
        XCTAssertTrue(store.isDetached(ref))
        XCTAssertEqual(mgr.childContexts.count, 1)
    }

    @MainActor
    func testCloseChildRemovesRefFromStore() {
        let store = WorkspaceStore()
        let ws = WorkspaceModel(repositoryPath: "/tmp/repo", name: "repo")
        store.workspaces.append(ws)
        let mgr = WindowManager(store: store)
        let ref = DetachedNodeRef.workspace(ws.id)
        mgr.detach(ref)
        guard let ctx = mgr.childContexts.first else { return XCTFail() }
        mgr.closeChild(ctx)
        XCTAssertFalse(store.isDetached(ref))
        XCTAssertTrue(mgr.childContexts.isEmpty)
    }

    @MainActor
    func testCloseChildDuringShutdownDoesNotRestoreRef() {
        let store = WorkspaceStore()
        let ws = WorkspaceModel(repositoryPath: "/tmp/repo", name: "repo")
        store.workspaces.append(ws)
        let mgr = WindowManager(store: store)
        let ref = DetachedNodeRef.workspace(ws.id)
        mgr.detach(ref)
        mgr.isShuttingDown = true
        guard let ctx = mgr.childContexts.first else { return XCTFail() }
        mgr.closeChild(ctx)
        // Ref stays because we're cascading — no per-node restore.
        XCTAssertTrue(store.isDetached(ref))
    }

    @MainActor
    func testRestoreChildWindowsSkipsInvalidRefs() {
        let store = WorkspaceStore()
        // Detached ref for a workspace that does NOT exist.
        let stale = DetachedNodeRef.workspace(UUID())
        store.detachedNodes.insert(stale)
        let mgr = WindowManager(store: store)
        mgr.restoreChildWindows()
        XCTAssertTrue(mgr.childContexts.isEmpty)
        XCTAssertFalse(store.isDetached(stale))   // cleaned up
    }
}
```

> Note: the `WorkspaceModel(repositoryPath:name:)` initializer signature must match the actual one in `WorkspaceModels.swift`. Inspect lines 270-300 for the real init; adjust test accordingly. If the init requires more params (e.g. `kind:`), pass them.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/WindowManagerTests`
Expected: FAIL — `cannot find 'WindowManager'`.

- [ ] **Step 3: Implement `WindowManager`**

```swift
// Treemux/App/WindowManager.swift
import AppKit
import SwiftUI

/// Owns the main window and any detached child windows. Replaces the single
/// `WindowContext` ownership previously held by `TreemuxApp`.
@MainActor
final class WindowManager {
    let store: WorkspaceStore
    private(set) var mainWindowContext: WindowContext?
    private(set) var childContexts: [WindowContext] = []

    /// True during cascade shutdown; suppresses per-node detached-state restore.
    var isShuttingDown = false

    init(store: WorkspaceStore) {
        self.store = store
    }

    func launchMain() {
        let ctx = WindowContext(store: store, kind: .main)
        ctx.show()
        mainWindowContext = ctx
    }

    /// Tears off `ref` into its own window and hides it in the main sidebar.
    func detach(_ ref: DetachedNodeRef) {
        guard store.isValid(ref) else { return }
        store.detachedNodes.insert(ref)
        let ctx = WindowContext(store: store, kind: .detached(ref))
        childContexts.append(ctx)
        ctx.show()
    }

    /// Called when a child window is closed by the user. Restores the node's
    /// visibility in the main sidebar (unless we're cascading shutdown).
    func closeChild(_ ctx: WindowContext) {
        if !isShuttingDown, case .detached(let ref) = ctx.kind {
            store.detachedNodes.remove(ref)
        }
        childContexts.removeAll { $0 === ctx }
    }

    /// Main window is closing: close all children, then terminate the app.
    func handleMainWindowWillClose() {
        isShuttingDown = true
        for ctx in childContexts {
            ctx.closeImmediately()
        }
        childContexts.removeAll()
        NSApp.terminate(nil)
    }

    /// Rebuilds child windows from persisted `detachedNodes`. Called on launch.
    func restoreChildWindows() {
        let refs = store.detachedNodes
        for ref in refs {
            guard store.isValid(ref) else {
                store.detachedNodes.remove(ref)
                continue
            }
            let ctx = WindowContext(store: store, kind: .detached(ref))
            childContexts.append(ctx)
            ctx.show()
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/WindowManagerTests`
Expected: PASS (4 tests).

> The `detach` / `restoreChildWindows` tests call `ctx.show()` which creates a real `NSWindow`. In unit tests this requires `NSApp` to exist. If tests crash because `NSApp == nil`, wrap the test in `@MainActor` (already done) and ensure a minimal `NSApplication.shared` is instantiated — XCUITest/test hosts usually provide one. If not, gate the `show()` call behind a flag or extract window-creation into an injectable factory. Pragmatic fallback: test the store-state side-effects (`detachedNodes.insert/remove`, `childContexts.count`) and stub `show()` via a protocol. Decide based on whether the existing `SidebarContextMenuTests` already instantiate `NSApp`.

- [ ] **Step 5: Commit**

```bash
git add Treemux/App/WindowManager.swift TreemuxTests/WindowManagerTests.swift
git commit -m "feat: add WindowManager for multi-window coordination"
```

---

## Task 5: Wire `WindowManager` into `TreemuxApp` + `AppDelegate`

**Files:**
- Modify: `Treemux/App/TreemuxApp.swift`
- Modify: `Treemux/AppDelegate.swift`

**Interfaces:**
- Consumes: `WindowManager` (Task 4).
- Produces: `TreemuxApp.windowManager`; `TreemuxApp.store` still accessible (delegated to `windowManager.store`); `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` → `false`; main-window close cascade.

No new unit tests here (integration wiring). Verify via smoke test.

- [ ] **Step 1: Refactor `TreemuxApp`**

```swift
// Treemux/App/TreemuxApp.swift
@MainActor
final class TreemuxApp {
    private(set) var windowManager: WindowManager?

    var store: WorkspaceStore? { windowManager?.store }

    func launch() {
        let store = WorkspaceStore()
        let mgr = WindowManager(store: store)
        mgr.launchMain()
        mgr.restoreChildWindows()        // NEW: rebuild detached child windows
        self.windowManager = mgr
    }

    func shutdown() {
        // Existing save logic, now via windowManager.
        windowManager?.store.saveWorkspaceState()
        windowManager?.store.flushPendingPersistence()
    }

    /// Called when the main window is about to close. Triggers cascade shutdown.
    func handleMainWindowWillClose() {
        windowManager?.handleMainWindowWillClose()
    }
}
```

- [ ] **Step 2: Update `AppDelegate`**

In `Treemux/AppDelegate.swift`:

Change `applicationShouldTerminateAfterLastWindowClosed` (line 52-54) to return `false`:

```swift
func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
}
```

> With multi-window, "last window closed" fires when the final child (not main) closes. We do NOT want that to quit the app — the user may still be interacting with the main window or want to reopen via Dock. However, per the spec, **closing the MAIN window** cascades to all children and quits. That cascade is driven by `handleMainWindowWillClose`, not by this delegate method.

To detect main-window close and trigger the cascade, observe `NSWindow.willCloseNotification`:

In `applicationDidFinishLaunching`, after `app.launch()`, register an observer:

```swift
NotificationCenter.default.addObserver(
    self,
    selector: #selector(windowWillClose(_:)),
    name: NSWindow.willCloseNotification,
    object: nil
)
```

Add the handler:

```swift
@objc private func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    // Identify the main window by its autosave name ("treemux.main").
    guard window.frameAutosaveName == "treemux.main" else { return }
    treemuxApp?.handleMainWindowWillClose()
}
```

> Identification by `frameAutosaveName` is the lightest option since Task 3 already assigns `"treemux.main"`. Alternative: keep a `weak var mainWindow` ref on `WindowManager` and compare identity. Use the autosave-name approach to avoid extra state.

- [ ] **Step 3: Build**

```bash
xcodebuild build -scheme Treemux -destination 'platform=macOS'
```
Expected: BUILD SUCCEEDS.

- [ ] **Step 4: Smoke test**

Run the app. Verify:
1. Main window opens.
2. Closing the main window quits the app (cascade).
3. Closing any other window (none yet, but the path is wired) does not quit.

- [ ] **Step 5: Commit**

```bash
git add Treemux/App/TreemuxApp.swift Treemux/AppDelegate.swift
git commit -m "feat: wire WindowManager, main-window close cascade, multi-window lifecycle"
```

---

## Task 6: Sidebar filtering by `detachedNodes`

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarCoordinator.swift` (in `buildNodes`, around lines 163-202)

**Interfaces:**
- Consumes: `WorkspaceStore.detachedNodes` / `isDetached` (Task 2).
- Produces: main sidebar omits detached workspace/worktree/remote-section nodes.

- [ ] **Step 1: Write the failing test**

Extend `TreemuxTests/SidebarContextMenuTests.swift` or add a focused test file. The test drives `SidebarCoordinator.buildNodes` indirectly — but since `buildNodes` is private and depends on `NSOutlineView`, a pure unit test is hard. Pragmatic approach: extract the filtering into a pure function `filterRootNodes(_ nodes: [SidebarNodeItem], detached: Set<DetachedNodeRef>) -> [SidebarNodeItem]` and test that.

```swift
// TreemuxTests/SidebarDetachFilterTests.swift
import XCTest
@testable import Treemux

final class SidebarDetachFilterTests: XCTestCase {
    @MainActor
    func testDetachedWorkspaceIsFilteredOut() {
        let ws = WorkspaceModel(repositoryPath: "/tmp/a", name: "a")
        let node = SidebarNodeItem(kind: .workspace(ws))
        let filtered = SidebarCoordinator.filterRootNodes(
            [node],
            detached: [.workspace(ws.id)]
        )
        XCTAssertTrue(filtered.isEmpty)
    }

    @MainActor
    func testNonDetachedWorkspaceStays() {
        let ws = WorkspaceModel(repositoryPath: "/tmp/a", name: "a")
        let node = SidebarNodeItem(kind: .workspace(ws))
        let filtered = SidebarCoordinator.filterRootNodes([node], detached: [])
        XCTAssertEqual(filtered.count, 1)
    }

    @MainActor
    func testDetachedRemoteGroupFiltersWholeSection() {
        let section = SidebarNodeItem(kind: .section(.remote(groupKey: "srv|u", displayTitle: "srv")))
        let filtered = SidebarCoordinator.filterRootNodes(
            [section],
            detached: [.remoteGroup("srv|u")]
        )
        XCTAssertTrue(filtered.isEmpty)
    }

    @MainActor
    func testDetachedWorktreeFiltersChildOnlyParentStays() {
        let ws = WorkspaceModel(repositoryPath: "/tmp/a", name: "a")
        // Build a workspace node with one worktree child manually via SidebarNodeItem API.
        // (Depends on SidebarNodeItem's children API — see SidebarNodeItem.swift.)
        // If SidebarNodeItem is immutable with children set at init, construct accordingly.
        // This test may need adjustment based on actual SidebarNodeItem shape.
        // Pseudocode:
        // let wt = WorktreeModel(id: UUID(), path: URL(fileURLWithPath: "/tmp/a-wt"), ...)
        // let parent = SidebarNodeItem(kind: .workspace(ws), children: [SidebarNodeItem(kind: .worktree(ws, wt))])
        // let filtered = SidebarCoordinator.filterRootNodes([parent], detached: [.worktree(ws.id, wt.id)])
        // XCTAssertEqual(filtered.count, 1)            // parent stays
        // XCTAssertEqual(filtered[0].children.count, 0) // child removed
    }
}
```

> The worktree-child test is sketched because `SidebarNodeItem`'s exact children API must be confirmed by reading `SidebarNodeItem.swift`. The implementer should fill in the real construction. If `SidebarNodeItem` is a class with mutable `children` (the coordinator uses `===` identity, suggesting class), filter in place or rebuild.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/SidebarDetachFilterTests`
Expected: FAIL — `cannot find 'filterRootNodes'`.

- [ ] **Step 3: Implement the filter**

In `SidebarCoordinator.swift`, extract a static pure function and call it from `buildNodes`:

```swift
/// Pure filter: removes detached nodes from the sidebar tree.
/// - Workspaces with `.workspace(id)` in `detached` are dropped.
/// - Remote sections with `.remoteGroup(key)` in `detached` are dropped.
/// - Worktree children with `.worktree(wsID, wtID)` in `detached` are dropped,
///   but the parent workspace remains.
static func filterRootNodes(
    _ nodes: [SidebarNodeItem],
    detached: Set<DetachedNodeRef>
) -> [SidebarNodeItem] {
    guard !detached.isEmpty else { return nodes }
    return nodes.compactMap { node in
        switch node.kind {
        case .section(.remote(let key, _)):
            if detached.contains(.remoteGroup(key)) { return nil }
            return node
        case .section(.local):
            return node
        case .workspace(let ws):
            if detached.contains(.workspace(ws.id)) { return nil }
            // Filter worktree children but keep the parent.
            let filteredChildren = node.children.filter { child in
                if case .worktree(let parentWS, let wt) = child.kind,
                   detached.contains(.worktree(workspaceID: parentWS.id, worktreeID: wt.id)) {
                    return false
                }
                return true
            }
            // If filtering left the workspace with 1 child and it was originally
            // expanded only because >1 worktree, the coordinator's buildNodes
            // already decided expansion. Here we only drop children; the next
            // buildNodes pass will re-evaluate expansion. For safety, mutate
            // children only if SidebarNodeItem allows it.
            node.children = filteredChildren
            return node
        case .worktree:
            // Top-level worktree (no parent) — unusual, keep as-is.
            return node
        }
    }
}
```

Then in `buildNodes` (around line 163-202), after constructing `rootNodes`, apply:

```swift
let detached = store?.detachedNodes ?? []
rootNodes = Self.filterRootNodes(rootNodes, detached: detached)
```

> ⚠️ `SidebarNodeItem` mutability: the coordinator code uses `===` on nodes (e.g. line 569), implying `SidebarNodeItem` is a `class`. If it's a `class` with `var children`, the in-place mutation above works. If it's a `struct`, return a new copy. The implementer must read `SidebarNodeItem.swift` and adapt — the filter logic is the same either way.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/SidebarDetachFilterTests`
Expected: PASS (3-4 tests).

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/Sidebar/SidebarCoordinator.swift TreemuxTests/SidebarDetachFilterTests.swift
git commit -m "feat: filter detached nodes from main sidebar"
```

---

## Task 7: Detached child window root views (`DetachedRootView` + 3 subviews)

**Files:**
- Create: `Treemux/UI/Detached/DetachedRootView.swift`
- Create: `Treemux/UI/Detached/SingleWorkspaceWindowView.swift`
- Create: `Treemux/UI/Detached/SingleWorktreeWindowView.swift`
- Create: `Treemux/UI/Detached/RemoteGroupWindowView.swift`
- Modify: `Treemux/App/WindowContext.swift` (swap placeholder for `DetachedRootView`)
- Modify: `Treemux/UI/Workspace/WorkspaceDetailView.swift` (prefer injected workspace)

**Interfaces:**
- Consumes: `WorkspaceStore`, `WorkspaceModel`, `WorktreeModel`, `WorkspaceDetailView`, `WorkspaceSessionDetailView`.
- Produces: `DetachedRootView(ref:store:)` used by `WindowContext.makeRootView()`.

- [ ] **Step 1: Read `WorkspaceDetailView` to confirm its environment dependencies**

Read `Treemux/UI/Workspace/WorkspaceDetailView.swift` lines 1-90. Confirm how it currently obtains its `WorkspaceModel` (likely via `store.selectedWorkspace`). Plan the change: add `@Environment(WorkspaceModel.self)` lookup that, if present, overrides the store-selection path.

- [ ] **Step 2: Write the three views**

```swift
// Treemux/UI/Detached/SingleWorkspaceWindowView.swift
import SwiftUI

/// Child window body showing a single workspace's detail (no sidebar).
struct SingleWorkspaceWindowView: View {
    let workspace: WorkspaceModel
    var body: some View {
        WorkspaceDetailView()
            .environment(workspace)
    }
}
```

```swift
// Treemux/UI/Detached/SingleWorktreeWindowView.swift
import SwiftUI

/// Child window body showing a single worktree's terminal session (no tab bar).
struct SingleWorktreeWindowView: View {
    let workspace: WorkspaceModel
    let worktree: WorktreeModel
    var body: some View {
        WorkspaceSessionDetailView()
            .environment(workspace)
            .onAppear {
                workspace.switchToWorktree(path: worktree.path)
            }
    }
}
```

> Verify `WorkspaceSessionDetailView` is the correct type name and that it's accessible (not nested in another view). If it's a nested struct, either hoist it or call the outer container. Confirm by reading `WorkspaceDetailView.swift` around lines 70-86.

```swift
// Treemux/UI/Detached/RemoteGroupWindowView.swift
import SwiftUI

/// Child window body showing a single remote server section with its workspaces.
struct RemoteGroupWindowView: View {
    let groupKey: String
    @Environment(WorkspaceStore.self) private var store
    @State private var localSelection: UUID?

    private var workspaces: [WorkspaceModel] {
        store.workspacesInRemoteGroup(groupKey)
    }

    private var selectedWorkspace: WorkspaceModel? {
        if let id = localSelection, let ws = workspaces.first(where: { $0.id == id }) {
            return ws
        }
        return workspaces.first
    }

    var body: some View {
        NavigationSplitView {
            List(workspaces, selection: $localSelection) { ws in
                SidebarNodeRow(node: SidebarNodeItem(kind: .workspace(ws)))
            }
            .navigationTitle(store.remoteGroupDisplayTitle(forKey: groupKey) ?? groupKey)
        } detail: {
            if let ws = selectedWorkspace {
                WorkspaceDetailView()
                    .environment(ws)
            } else {
                ContentUnavailableView("No Project Selected")
            }
        }
    }
}
```

> `remoteGroupDisplayTitle(forKey:)` — confirm it exists on `WorkspaceStore` (the brainstorm noted `remoteGroupDisplayTitle` at line 384, but its signature may differ). If it's computed differently, call the actual API. If `SidebarNodeRow` requires additional context (theme), inject via environment — it already reads `ThemeManager` from environment in the main window.

```swift
// Treemux/UI/Detached/DetachedRootView.swift
import SwiftUI

/// Dispatches to the correct detached window body based on the ref.
struct DetachedRootView: View {
    let ref: DetachedNodeRef
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        switch ref {
        case .workspace(let id):
            if let ws = store.workspaces.first(where: { $0.id == id }) {
                SingleWorkspaceWindowView(workspace: ws)
            } else {
                missingNodeView
            }
        case .worktree(let wsID, let wtID):
            if let ws = store.workspaces.first(where: { $0.id == wsID }),
               let wt = ws.worktrees.first(where: { $0.id == wtID }) {
                SingleWorktreeWindowView(workspace: ws, worktree: wt)
            } else {
                missingNodeView
            }
        case .remoteGroup(let key):
            RemoteGroupWindowView(groupKey: key)
        }
    }

    private var missingNodeView: some View {
        ContentUnavailableView(
            String(localized: "This project is no longer available.")
        )
    }
}
```

- [ ] **Step 3: Swap `WindowContext.makeRootView()` placeholder**

In `Treemux/App/WindowContext.swift`, replace the placeholder branch:

```swift
case .detached(let ref):
    return AnyView(DetachedRootView(ref: ref))
```

Also refine the window title in `windowTitle`:

```swift
case .detached(let ref):
    switch ref {
    case .workspace(let id):
        return store.workspaces.first(where: { $0.id == id })?.name ?? "Treemux"
    case .worktree(let wsID, _):
        return store.workspaces.first(where: { $0.id == wsID })?.name ?? "Treemux"
    case .remoteGroup(let key):
        return store.remoteGroupDisplayTitle(forKey: key) ?? key
    }
```

- [ ] **Step 4: Modify `WorkspaceDetailView` to prefer injected workspace**

In `Treemux/UI/Workspace/WorkspaceDetailView.swift`, locate where it reads the current workspace (likely `@Environment(WorkspaceStore.self)` + `store.selectedWorkspace`). Add an optional environment override:

```swift
struct WorkspaceDetailView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(WorkspaceModel.self) private var injectedWorkspace?   // may not compile as Optional; see note

    private var workspace: WorkspaceModel? {
        injectedWorkspace ?? store.selectedWorkspace
    }
    // ... rest unchanged, using `workspace` instead of `store.selectedWorkspace`
}
```

> Note: `@Environment(WorkspaceModel.self)` does not natively support optionals the way `@EnvironmentObject` did. If `WorkspaceModel` is not always in the environment (main window path doesn't inject it), you need a different strategy:
> - Option A: Always inject `WorkspaceModel` into the environment in `MainWindowView` (read from `store.selectedWorkspace` and inject). Then `WorkspaceDetailView` reads `@Environment(WorkspaceModel.self)` unconditionally.
> - Option B: Use a wrapper `EnvironmentKey` for "optional selected workspace".
>
> **Recommended: Option A** — in `MainWindowView`, inject the selected workspace:
> ```swift
> if let ws = store.selectedWorkspace {
>     WorkspaceDetailView().environment(ws)
> }
> ```
> This makes `WorkspaceDetailView` read `@Environment(WorkspaceModel.self)` directly, unifying both paths. The implementer should verify this doesn't break the existing no-selection `ContentUnavailableView` fallback (it shouldn't — that fallback is in `MainWindowView`, not `WorkspaceDetailView`).

- [ ] **Step 5: Build**

```bash
xcodebuild build -scheme Treemux -destination 'platform=macOS'
```
Expected: BUILD SUCCEEDS.

- [ ] **Step 6: Commit**

```bash
git add Treemux/UI/Detached/ Treemux/App/WindowContext.swift Treemux/UI/Workspace/WorkspaceDetailView.swift
git commit -m "feat: detached child window root views (workspace/worktree/remote-group)"
```

---

## Task 8: `DetachPasteboardItem` + worktree drag source

**Files:**
- Create: `Treemux/UI/Sidebar/DetachPasteboardItem.swift`
- Modify: `Treemux/UI/Sidebar/SidebarCoordinator.swift` (`pasteboardWriterForItem` around line 528-541)

**Interfaces:**
- Consumes: `DetachedNodeRef` (Task 1).
- Produces: `DetachPasteboardItem` (`NSPasteboardWriting`); pasteboard type `com.treemux.detach.ref`; updated `pasteboardWriterForItem` that writes both the existing reorder payload AND the detach payload (and makes worktree draggable).

- [ ] **Step 1: Implement `DetachPasteboardItem`**

```swift
// Treemux/UI/Sidebar/DetachPasteboardItem.swift
import AppKit
import Foundation

/// Wraps a pasteboard item that carries both the legacy reorder payload
/// (workspace IDs / remote-group key) AND a `DetachedNodeRef` for tear-off.
/// The two coexist so in-list reordering keeps working while drag-out-to-
/// new-window can read the same drag session.
final class DetachPasteboardItem: NSObject, NSPasteboardWriting {
    static let detachType = NSPasteboard.PasteboardType("com.treemux.detach.ref")

    let ref: DetachedNodeRef
    /// Optional legacy payload to ALSO write (for reorder compatibility).
    let legacyReorderPayload: [(NSPasteboard.PasteboardType, String)]

    init(ref: DetachedNodeRef,
         legacyReorderPayload: [(NSPasteboard.PasteboardType, String)] = []) {
        self.ref = ref
        self.legacyReorderPayload = legacyReorderPayload
    }

    func writableTypes(for pasteboard: NSPasteboard?) -> [NSPasteboard.PasteboardType] {
        var types = [Self.detachType]
        types.append(contentsOf: legacyReorderPayload.map { $0.0 })
        return types
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == Self.detachType {
            guard let data = try? JSONEncoder().encode(ref) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return legacyReorderPayload.first(where: { $0.0 == type })?.1
    }
}
```

- [ ] **Step 2: Update `pasteboardWriterForItem` in `SidebarCoordinator`**

```swift
func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
    guard let node = item as? SidebarNodeItem else { return nil }

    switch node.kind {
    case .section(.remote(let groupKey, _)):
        // Existing reorder payload + detach ref.
        return DetachPasteboardItem(
            ref: .remoteGroup(groupKey),
            legacyReorderPayload: [(Self.remoteGroupDragType, groupKey)]
        )

    case .section(.local):
        return nil

    case .workspace(let ws):
        return DetachPasteboardItem(
            ref: .workspace(ws.id),
            legacyReorderPayload: [(Self.workspaceDragType, ws.id.uuidString)]
        )

    case .worktree(let ws, let wt):
        // NEW: worktree now draggable (only for tear-off; validateDrop still
        // returns [] for worktree drop targets, so in-list reorder stays off).
        return DetachPasteboardItem(ref: .worktree(workspaceID: ws.id, worktreeID: wt.id))
    }
}
```

- [ ] **Step 3: Verify in-list reorder still works**

The existing `validateDrop` / `acceptDrop` read `Self.workspaceDragType` / `Self.remoteGroupDragType` from the pasteboard. Since `DetachPasteboardItem.pasteboardPropertyList(forType:)` returns the legacy payload for those types, the reorder path is unaffected. Build and smoke-test: drag a workspace within the sidebar to reorder — should still work.

- [ ] **Step 4: Build**

```bash
xcodebuild build -scheme Treemux -destination 'platform=macOS'
```
Expected: BUILD SUCCEEDS.

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/Sidebar/DetachPasteboardItem.swift Treemux/UI/Sidebar/SidebarCoordinator.swift
git commit -m "feat: DetachPasteboardItem carries tear-off ref alongside reorder payload"
```

---

## Task 9: `NSDraggingSource` — detect drag-out and trigger detach

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarCoordinator.swift` (add `NSDraggingSource` conformance + `onDetachNode` closure)

**Interfaces:**
- Consumes: `DetachPasteboardItem` (Task 8), `DetachedNodeRef` (Task 1).
- Produces: `SidebarCoordinator.onDetachNode: ((DetachedNodeRef) -> Void)?`; conformance to `NSDraggingSource`.

- [ ] **Step 1: Add the closure property**

In `SidebarCoordinator.swift`, near the existing `requestRename` / `requestDelete` closures (around line 21-22):

```swift
/// Called when a node is dragged outside the outline view to tear it off
/// into its own window. Wired to `WindowManager.detach(_:)`.
var onDetachNode: ((DetachedNodeRef) -> Void)?
```

- [ ] **Step 2: Add `NSDraggingSource` conformance**

At the end of `SidebarCoordinator.swift`:

```swift
extension SidebarCoordinator: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Allow move within the app (for both reorder and tear-off).
        return .move
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        // Only tear off if NO in-list operation occurred (operation == [])
        // AND the release point is outside the outline view's frame.
        guard operation == [] else { return }

        guard let outlineView = container?.outlineView,
              let window = outlineView.window else { return }

        let viewRectInScreen = window.convertToScreen(
            outlineView.convert(outlineView.bounds, to: nil)
        )
        guard !viewRectInScreen.contains(screenPoint) else { return }

        // Decode the detached ref from the pasteboard.
        guard let payload = session.draggingPasteboard.string(forType: DetachPasteboardItem.detachType),
              let data = payload.data(using: .utf8),
              let ref = try? JSONDecoder().decode(DetachedNodeRef.self, from: data) else {
            return
        }

        onDetachNode?(ref)
    }
}
```

- [ ] **Step 3: Wire `onDetachNode` in `WorkspaceSidebarView` (or its parent)**

In `Treemux/UI/Sidebar/WorkspaceSidebarView.swift`, where the `SidebarCoordinator` is configured (find where `requestRename` / `requestDelete` are set), add:

```swift
coordinator.onDetachNode = { [weak store] ref in
    // The WindowManager is accessed via the environment or a shared ref.
    // Determine how MainWindowView / WorkspaceSidebarView obtains the
    // WindowManager — likely via @Environment or a property on the store.
    // If WindowManager is not yet in the environment, add it (see Task 5 note).
    WindowManager Detach = ...
    detach.detach(ref)
}
```

> ⚠️ **Plumbing decision:** `WindowManager` must be reachable from `WorkspaceSidebarView`. Two options:
> 1. Add `WindowManager` as an `@Observable` injected into the environment alongside `WorkspaceStore` (cleanest).
> 2. Store a `weak var windowManager` ref on `WorkspaceStore` (lighter, slightly coupled).
>
> **Recommended: Option 1.** In `TreemuxApp.launch()`, after creating the `WindowManager`, inject it into the environment. Since `WindowContext.show()` builds the root view, pass `windowManager` through to the environment chain. Update `WindowContext.makeRootView()` to inject `.environment(windowManager)` (requires `WindowManager` to be `@Observable` — add `@Observable` to it in Task 4 if not already). Then `WorkspaceSidebarView` reads `@Environment(WindowManager.self)` and wires `coordinator.onDetachNode = { [weak wm] ref in wm?.detach(ref) }`.
>
> The implementer should update Task 4's `WindowManager` to be `@Observable` (it currently isn't marked) and add the environment injection in Task 5/3. Revisit Tasks 3-5 if needed to thread this through — or add the `@Observable` + environment injection as part of THIS task (Task 9) since it's where the dependency materializes.

- [ ] **Step 4: Build and smoke test**

```bash
xcodebuild build -scheme Treemux -destination 'platform=macOS'
```

Run the app. Manually test:
1. Drag a workspace from the sidebar to the desktop / outside the window → a new window opens showing that workspace.
2. The workspace disappears from the main sidebar.
3. Close the new window → the workspace reappears in the main sidebar.

> Note: `SidebarCoordinator` is an `NSObject` that's the `dataSource`/`delegate`. For `NSDraggingSource` callbacks to fire, the **same object** that initiated the drag must be the dragging source. Since `pasteboardWriterForItem` is on the coordinator and returns the `DetachPasteboardItem`, AppKit queries the outline view's `dataSource` (the coordinator) as the dragging source. The extension above should be invoked. Verify with a breakpoint.

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/Sidebar/SidebarCoordinator.swift Treemux/UI/Sidebar/WorkspaceSidebarView.swift
# + any environment-threading edits from the plumbing decision
git commit -m "feat: drag sidebar node outside window to tear off into new window"
```

---

## Task 10: Right-click "Open in New Window" menu item

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarCoordinator.swift` (`workspaceContextMenuItems`, `contextMenu(forRow:)`)
- Modify: `Treemux/Localizable.xcstrings`
- Test: `TreemuxTests/SidebarContextMenuTests.swift` (extend)

**Interfaces:**
- Consumes: `DetachedNodeRef`, `WorkspaceStore.isDetached`, `onDetachNode` (Task 9).
- Produces: "Open in New Window" / "Already in New Window" menu items on workspace, worktree, and remote-section nodes.

- [ ] **Step 1: Add i18n strings**

In `Treemux/Localizable.xcstrings`, add:
- `"Open in New Window"` → zh-Hans: `"在新窗口中打开"`
- `"Already in New Window"` → zh-Hans: `"已在独立窗口中打开"`

(Use the existing xcstrings format; the file is JSON with a `strings` object.)

- [ ] **Step 2: Write the failing test**

Extend `TreemuxTests/SidebarContextMenuTests.swift`:

```swift
func testWorkspaceContextMenuIncludesOpenInNewWindow() {
    // Build a coordinator + a workspace model (mirror existing test setup
    // in SidebarContextMenuTests.swift).
    // ...
    let items = coordinator.workspaceContextMenuItems(for: ws)
    let titles = items.map { $0.title }
    XCTAssertTrue(titles.contains(String(localized: "Open in New Window")))
}

func testWorkspaceContextMenuShowsAlreadyWhenDetached() {
    store.detachedNodes.insert(.workspace(ws.id))
    let items = coordinator.workspaceContextMenuItems(for: ws)
    let alreadyItem = items.first { $0.title == String(localized: "Already in New Window") }
    XCTAssertNotNil(alreadyItem)
    XCTAssertEqual(alreadyItem?.isEnabled, false)
}
```

> Mirror the existing test-setup pattern in `SidebarContextMenuTests.swift` for constructing the coordinator/store/workspace.

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/SidebarContextMenuTests`
Expected: FAIL — menu item not found.

- [ ] **Step 4: Add menu item to `workspaceContextMenuItems`**

In `SidebarCoordinator.swift`, `workspaceContextMenuItems(for:)` (line 372), insert AFTER the icon item, BEFORE rename:

```swift
// Open in New Window (disabled + retitled if already detached).
let isDetached = store?.isDetached(.workspace(ws.id)) ?? false
let newWindowItem = NSMenuItem(
    title: isDetached
        ? String(localized: "Already in New Window")
        : String(localized: "Open in New Window"),
    action: #selector(openWorkspaceInNewWindow(_:)),
    keyEquivalent: ""
)
newWindowItem.target = self
newWindowItem.representedObject = ws.id
newWindowItem.isEnabled = !isDetached
items.append(newWindowItem)
```

Add the action:

```swift
@objc private func openWorkspaceInNewWindow(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID else { return }
    onDetachNode?(.workspace(id))
}
```

- [ ] **Step 5: Add worktree menu item**

In `contextMenu(forRow:)`, the `.worktree(let ws, let wt)` branch (line 354-363), currently only adds "Change Icon". Add "Open in New Window" there too:

```swift
case .worktree(let ws, let wt):
    let iconItem = NSMenuItem(...)           // existing
    iconItem.target = self
    iconItem.representedObject = [...]
    menu.addItem(iconItem)

    let wtDetached = store?.isDetached(.worktree(workspaceID: ws.id, worktreeID: wt.id)) ?? false
    let wtNewItem = NSMenuItem(
        title: wtDetached
            ? String(localized: "Already in New Window")
            : String(localized: "Open in New Window"),
        action: #selector(openWorktreeInNewWindow(_:)),
        keyEquivalent: ""
    )
    wtNewItem.target = self
    wtNewItem.representedObject = ["workspaceID": ws.id, "worktreeID": wt.id] as [String: Any]
    wtNewItem.isEnabled = !wtDetached
    menu.addItem(wtNewItem)
```

> ⚠️ `WorktreeModel.id` type: confirm whether it's `UUID` or `String` (Task 2 note). Adjust `representedObject` and the action accordingly.

Action:

```swift
@objc private func openWorktreeInNewWindow(_ sender: NSMenuItem) {
    guard let dict = sender.representedObject as? [String: Any],
          let wsID = dict["workspaceID"] as? UUID,
          let wtID = dict["worktreeID"] as? UUID else { return }   // or String
    onDetachNode?(.worktree(workspaceID: wsID, worktreeID: wtID))
}
```

- [ ] **Step 6: Add remote-section menu item**

In `contextMenu(forRow:)`, the `.section` branch (line 346-347) currently returns `nil` for all sections. Change to handle `.remote`:

```swift
case .section(.remote(let groupKey, _)):
    let menu = NSMenu()
    let isDetached = store?.isDetached(.remoteGroup(groupKey)) ?? false
    let item = NSMenuItem(
        title: isDetached
            ? String(localized: "Already in New Window")
            : String(localized: "Open in New Window"),
        action: #selector(openRemoteGroupInNewWindow(_:)),
        keyEquivalent: ""
    )
    item.target = self
    item.representedObject = groupKey
    item.isEnabled = !isDetached
    menu.addItem(item)
    return menu

case .section(.local):
    return nil
```

Action:

```swift
@objc private func openRemoteGroupInNewWindow(_ sender: NSMenuItem) {
    guard let key = sender.representedObject as? String else { return }
    onDetachNode?(.remoteGroup(key))
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/SidebarContextMenuTests`
Expected: PASS (existing + new tests).

- [ ] **Step 8: Commit**

```bash
git add Treemux/UI/Sidebar/SidebarCoordinator.swift Treemux/Localizable.xcstrings TreemuxTests/SidebarContextMenuTests.swift
git commit -m "feat: right-click 'Open in New Window' for workspace/worktree/remote-group"
```

---

## Task 11: Restart restoration end-to-end + edge cases

**Files:**
- No new files; verification + fixes across `WindowManager`, `WorkspaceStore`, `WindowContext`.

**Interfaces:**
- Consumes: all prior tasks.

This task validates the full lifecycle and fixes anything surfaced by integration testing.

- [ ] **Step 1: Verify persistence round-trip**

Manually (or via test):
1. Launch app, tear off a workspace (drag or right-click).
2. Quit the app (close main window → cascade).
3. Inspect `workspace-state.json` — confirm `detachedNodes` contains the ref.
4. Relaunch — confirm the child window reopens at the same frame, the node is hidden in the main sidebar.

If the child window doesn't reopen: check that `TreemuxApp.launch()` calls `mgr.restoreChildWindows()` AFTER the store has loaded from disk. The store's `init`/`reload` must complete before `restoreChildWindows`. Verify ordering in `TreemuxApp.launch()`.

- [ ] **Step 2: Verify stale-ref cleanup**

1. Edit `workspace-state.json` by hand to add a `detachedNodes` entry for a workspace UUID that doesn't exist in `workspaces`.
2. Launch — confirm no crash, no empty window; the stale entry is removed from `detachedNodes` and the next save writes a clean file.

- [ ] **Step 3: Verify worktree-stale cleanup**

1. Tear off a worktree.
2. Quit.
3. Delete that worktree on disk (`git worktree remove`).
4. Relaunch — confirm the child window doesn't open for it, and `detachedNodes` no longer contains it.

- [ ] **Step 4: Verify close-child restores visibility**

1. Tear off a workspace.
2. Close the child window (red ×).
3. Confirm the workspace reappears in the main sidebar immediately.
4. Confirm `workspace-state.json` no longer lists it in `detachedNodes` (after debounce save).

- [ ] **Step 5: Verify main-window-close cascade does NOT restore-then-quit**

1. Tear off 2 workspaces.
2. Close the main window.
3. Confirm: no visible "flash" of workspaces reappearing in the sidebar before quit; app quits cleanly.

If a flash occurs, the `isShuttingDown` guard in `closeChild` isn't being honored — check that `handleMainWindowWillClose` sets `isShuttingDown = true` BEFORE iterating children, and that `NSWindow.willCloseNotification` fires before the window actually disappears.

- [ ] **Step 6: Build + full test suite**

```bash
xcodebuild test -scheme Treemux -destination 'platform=macOS'
```
Expected: ALL TESTS PASS.

- [ ] **Step 7: Commit any fixes**

```bash
git add -A
git commit -m "fix: restoration edge cases and cascade-shutdown guard"
```

(Only if changes were needed; otherwise skip.)

---

## Self-Review Notes

**Spec coverage:**
- §3.1 `DetachedNodeRef` → Task 1.
- §3.2–3.4 store + persistence → Task 2.
- §4.1–4.6 WindowManager + WindowContext.Kind + frame autosave → Tasks 3, 4, 5.
- §5.1–5.5 drag-to-detach → Tasks 8, 9.
- §6.1–6.4 right-click menu → Task 10.
- §7.1–7.3 three child root views → Task 7.
- §8.1–8.4 lifecycle + restoration → Tasks 4, 5, 11.

**Type consistency:**
- `DetachedNodeRef` used identically across Tasks 1, 2, 4, 6, 7, 8, 9, 10.
- `WindowContext.Kind` introduced Task 3, consumed Tasks 4, 5, 7.
- `onDetachNode: ((DetachedNodeRef) -> Void)?` introduced Task 9, consumed Task 10.
- `WindowManager.detach(_:)` / `closeChild(_:)` / `restoreChildWindows()` defined Task 4, called Tasks 5, 9, 10.

**Open item flagged inline:** `WorktreeModel.id` type (UUID vs String) — the implementer must confirm in `WorkspaceModels.swift:222-228` and keep `DetachedNodeRef.worktree` consistent. This is called out in Tasks 2 and 10.
