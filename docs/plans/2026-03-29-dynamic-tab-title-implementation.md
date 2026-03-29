# Dynamic Tab Title Update Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make tab titles update dynamically on pane operations (split, close, focus, zoom, resize), matching Liney's behavior.

**Architecture:** Add an `onPaneStateChanged` callback on `WorkspaceSessionController` that fires at the end of every public pane-mutating method. `WorkspaceModel` sets this callback to call `saveActiveTabState()`, which recomputes the tab title via `suggestedTitle()`.

**Tech Stack:** Swift, SwiftUI, @MainActor

**Important:** The callback must be on individual public methods (not just `handleWorkspaceAction`), because `AppDelegate` and other callers invoke `focusNext()`, `toggleZoom()`, etc. directly.

---

### Task 1: Add `onPaneStateChanged` callback to WorkspaceSessionController

**Files:**
- Modify: `Treemux/Services/Terminal/WorkspaceSessionController.swift`

**Step 1: Add the callback property**

After `zoomedPaneID` (line 20), add:

```swift
/// Called after pane operations to notify the workspace model of state changes.
var onPaneStateChanged: (() -> Void)?
```

**Step 2: Add `onPaneStateChanged?()` call at the end of every public pane-mutating method**

Add `onPaneStateChanged?()` as the last line in each of these methods:
- `splitPane(_:axis:placement:)` (line 129)
- `closePane(_:)` (line 139) — after the guard, before method end
- `focusNext()` (line 161)
- `focusPrevious()` (line 167)
- `focusDirection(_:)` (line 173)
- `focus(_:)` (line 181)
- `toggleZoom()` (line 189)
- `resizeFocusedSplit(direction:amount:)` (line 210)
- `equalizeSplits()` (line 206)

Do NOT add it to `handleWorkspaceAction` — that method delegates to the public methods above, so the callback already fires from within them.

**Step 3: Run existing tests**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing TreemuxTests 2>&1 | tail -20`
Expected: All existing tests PASS (callback is nil by default)

**Step 4: Commit**

```bash
git add Treemux/Services/Terminal/WorkspaceSessionController.swift
git commit -m "feat: add onPaneStateChanged callback to WorkspaceSessionController"
```

---

### Task 2: Wire the callback in WorkspaceModel

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift:446-468` (`controller(forTabID:worktreePath:)`)

**Step 1: Set the callback after creating the controller**

In `controller(forTabID:worktreePath:)`, after the `WorkspaceSessionController(...)` init call and before storing in `tabControllers`, add:

```swift
ctrl.onPaneStateChanged = { [weak self] in
    self?.saveActiveTabState()
}
```

The full method becomes:

```swift
private func controller(forTabID tabID: UUID, worktreePath: String) -> WorkspaceSessionController {
    if let existing = tabControllers[worktreePath]?[tabID] {
        return existing
    }

    let tabState = tabs.first(where: { $0.id == tabID })

    let ctrl = WorkspaceSessionController(
        workingDirectory: worktreePath,
        sshTarget: sshTarget,
        savedLayout: tabState?.layout,
        paneSnapshots: tabState?.panes ?? [],
        focusedPaneID: tabState?.focusedPaneID,
        zoomedPaneID: tabState?.zoomedPaneID
    )

    ctrl.onPaneStateChanged = { [weak self] in
        self?.saveActiveTabState()
    }

    if tabControllers[worktreePath] == nil {
        tabControllers[worktreePath] = [:]
    }
    tabControllers[worktreePath]?[tabID] = ctrl
    return ctrl
}
```

**Step 2: Run existing tests**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing TreemuxTests 2>&1 | tail -20`
Expected: All existing tests PASS

**Step 3: Commit**

```bash
git add Treemux/Domain/WorkspaceModels.swift
git commit -m "feat: wire onPaneStateChanged to saveActiveTabState in WorkspaceModel"
```

---

### Task 3: Add test for callback behavior

**Files:**
- Modify: `TreemuxTests/WorkspaceModelsTests.swift` (add new test at end, before closing `}`)

**Step 1: Write test verifying the callback fires on pane operations**

```swift
@MainActor
func testOnPaneStateChangedFiringOnPaneOperations() {
    let ctrl = WorkspaceSessionController(workingDirectory: "/tmp/test")
    var callbackCount = 0
    ctrl.onPaneStateChanged = { callbackCount += 1 }

    let paneID = ctrl.layout.paneIDs.first!

    // splitPane should fire callback
    ctrl.splitPane(paneID, axis: .horizontal)
    XCTAssertEqual(callbackCount, 1)

    // toggleZoom should fire callback
    ctrl.toggleZoom()
    XCTAssertEqual(callbackCount, 2)

    // focusNext should fire callback (now 2 panes to cycle through)
    ctrl.focusNext()
    XCTAssertEqual(callbackCount, 3)
}
```

**Step 2: Run all tests**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing TreemuxTests 2>&1 | tail -20`
Expected: All tests PASS including the new test

**Step 3: Commit**

```bash
git add TreemuxTests/WorkspaceModelsTests.swift
git commit -m "test: verify onPaneStateChanged fires on pane operations"
```
