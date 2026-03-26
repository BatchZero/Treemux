# Worktree State Isolation & Layout Restoration — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix the bug where different git worktrees share the same tabs/panes/working directory, and restore pane layouts from saved state.

**Architecture:** Fix `restoreTabState()` to populate `worktreeTabStates` for all worktrees, extract symmetric save/load methods, and extend `WorkspaceSessionController` to accept saved layout + pane snapshots for full layout restoration.

**Tech Stack:** Swift, SwiftUI, XCTest

---

### Task 1: Test — worktree tab state isolation on restore

**Files:**
- Modify: `TreemuxTests/WorkspaceModelsTests.swift`

**Step 1: Write the failing test**

Add a test that creates a `WorkspaceRecord` with two worktree states, constructs a `WorkspaceModel` from it, then verifies both worktrees' tabs are accessible.

```swift
@MainActor
func testRestoreTabStatePopulatesAllWorktrees() {
    let mainTab = WorkspaceTabStateRecord.makeDefault(workingDirectory: "/tmp/project", title: "Main Tab")
    let featureTab = WorkspaceTabStateRecord.makeDefault(workingDirectory: "/tmp/project-feature", title: "Feature Tab")

    let record = WorkspaceRecord(
        id: UUID(),
        kind: .repository,
        name: "test",
        repositoryPath: "/tmp/project",
        isPinned: false,
        isArchived: false,
        sshTarget: nil,
        worktreeStates: [
            WorktreeSessionStateRecord(
                worktreePath: "/tmp/project",
                branch: "main",
                tabs: [mainTab],
                selectedTabID: mainTab.id
            ),
            WorktreeSessionStateRecord(
                worktreePath: "/tmp/project-feature",
                branch: "feature",
                tabs: [featureTab],
                selectedTabID: featureTab.id
            )
        ],
        worktreeOrder: nil
    )

    let ws = WorkspaceModel(from: record)

    // Active worktree (main) should have its tabs loaded
    XCTAssertEqual(ws.tabs.count, 1)
    XCTAssertEqual(ws.tabs[0].title, "Main Tab")

    // Switch to feature worktree — should restore saved tabs, not create default
    ws.switchToWorktree("/tmp/project-feature")
    XCTAssertEqual(ws.tabs.count, 1)
    XCTAssertEqual(ws.tabs[0].title, "Feature Tab")
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing TreemuxTests/WorkspaceModelsTests/testRestoreTabStatePopulatesAllWorktrees 2>&1 | tail -20`

Expected: FAIL — `ws.tabs[0].title` will be "Tab 1" (default) instead of "Feature Tab"

**Step 3: Commit the failing test**

```bash
git add TreemuxTests/WorkspaceModelsTests.swift
git commit -m "test: add failing test for worktree tab state isolation on restore"
```

---

### Task 2: Fix — populate worktreeTabStates for all worktrees on restore

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift:358-364`

**Step 1: Fix `restoreTabState(from:)`**

Replace the current implementation (lines 358-364) with:

```swift
/// Restores tab state from persisted worktree states.
private func restoreTabState(from worktreeStates: [WorktreeSessionStateRecord]) {
    for state in worktreeStates {
        if state.worktreePath == activeWorktreePath {
            // Load active worktree state into visible tabs
            if !state.tabs.isEmpty {
                tabs = state.tabs
                activeTabID = state.selectedTabID ?? state.tabs.first?.id
            }
        } else {
            // Store inactive worktree state for later retrieval
            if !state.tabs.isEmpty {
                worktreeTabStates[state.worktreePath] = (
                    tabs: state.tabs,
                    activeTabID: state.selectedTabID
                )
            }
        }
    }
}
```

**Step 2: Run the test from Task 1 to verify it passes**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing TreemuxTests/WorkspaceModelsTests/testRestoreTabStatePopulatesAllWorktrees 2>&1 | tail -20`

Expected: PASS

**Step 3: Run all existing tests to check for regressions**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing TreemuxTests/WorkspaceModelsTests 2>&1 | tail -20`

Expected: All PASS

**Step 4: Commit**

```bash
git add Treemux/Domain/WorkspaceModels.swift
git commit -m "fix: populate worktreeTabStates for all worktrees on restore"
```

---

### Task 3: Test — worktree round-trip persistence

**Files:**
- Modify: `TreemuxTests/WorkspaceModelsTests.swift`

**Step 1: Write the test**

Add a test that verifies worktree state survives a save→restore→save→restore cycle.

```swift
@MainActor
func testWorktreeStateRoundTripPersistence() {
    // Create workspace with two worktrees
    let mainTab = WorkspaceTabStateRecord.makeDefault(workingDirectory: "/tmp/project", title: "Main Tab")
    let featureTab1 = WorkspaceTabStateRecord.makeDefault(workingDirectory: "/tmp/project-feature", title: "Feature A")
    let featureTab2 = WorkspaceTabStateRecord.makeDefault(workingDirectory: "/tmp/project-feature", title: "Feature B")

    let record = WorkspaceRecord(
        id: UUID(),
        kind: .repository,
        name: "test",
        repositoryPath: "/tmp/project",
        isPinned: false,
        isArchived: false,
        sshTarget: nil,
        worktreeStates: [
            WorktreeSessionStateRecord(
                worktreePath: "/tmp/project",
                branch: "main",
                tabs: [mainTab],
                selectedTabID: mainTab.id
            ),
            WorktreeSessionStateRecord(
                worktreePath: "/tmp/project-feature",
                branch: "feature",
                tabs: [featureTab1, featureTab2],
                selectedTabID: featureTab2.id
            )
        ],
        worktreeOrder: nil
    )

    // First load
    let ws = WorkspaceModel(from: record)

    // Serialize back
    let saved = ws.toRecord()

    // Verify both worktrees are in the serialized output
    XCTAssertEqual(saved.worktreeStates.count, 2)

    let mainState = saved.worktreeStates.first(where: { $0.worktreePath == "/tmp/project" })
    let featureState = saved.worktreeStates.first(where: { $0.worktreePath == "/tmp/project-feature" })

    XCTAssertNotNil(mainState)
    XCTAssertEqual(mainState?.tabs.count, 1)
    XCTAssertEqual(mainState?.tabs[0].title, "Main Tab")

    XCTAssertNotNil(featureState)
    XCTAssertEqual(featureState?.tabs.count, 2)
    XCTAssertEqual(featureState?.tabs[0].title, "Feature A")
    XCTAssertEqual(featureState?.tabs[1].title, "Feature B")
    XCTAssertEqual(featureState?.selectedTabID, featureTab2.id)
}
```

**Step 2: Run the test**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing TreemuxTests/WorkspaceModelsTests/testWorktreeStateRoundTripPersistence 2>&1 | tail -20`

Expected: PASS (the fix from Task 2 should make this work)

**Step 3: Commit**

```bash
git add TreemuxTests/WorkspaceModelsTests.swift
git commit -m "test: add worktree state round-trip persistence test"
```

---

### Task 4: Refactor — extract saveActiveWorktreeState / loadActiveWorktreeState

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift`

**Step 1: Extract symmetric save/load methods**

Add these two methods and refactor `switchToWorktree()` to use them. Place them in the "Worktree Switching" MARK section.

```swift
// MARK: - Worktree Switching

/// Saves the current worktree's tab state into the worktreeTabStates dictionary.
private func saveActiveWorktreeState() {
    saveActiveTabState()
    worktreeTabStates[activeWorktreePath] = (tabs: tabs, activeTabID: activeTabID)
}

/// Loads the target worktree's tab state from worktreeTabStates, or creates a default.
private func loadActiveWorktreeState() {
    if let saved = worktreeTabStates[activeWorktreePath] {
        tabs = saved.tabs
        activeTabID = saved.activeTabID
    } else {
        let defaultTab = WorkspaceTabStateRecord.makeDefault(workingDirectory: activeWorktreePath)
        tabs = [defaultTab]
        activeTabID = defaultTab.id
    }
}

/// Switches to a different worktree, saving current tab state and restoring the target's.
func switchToWorktree(_ path: String) {
    guard path != activeWorktreePath else { return }
    saveActiveWorktreeState()
    activeWorktreePath = path
    loadActiveWorktreeState()
}
```

**Step 2: Run all WorkspaceModelsTests**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing TreemuxTests/WorkspaceModelsTests 2>&1 | tail -20`

Expected: All PASS

**Step 3: Commit**

```bash
git add Treemux/Domain/WorkspaceModels.swift
git commit -m "refactor: extract saveActiveWorktreeState/loadActiveWorktreeState"
```

---

### Task 5: Test — WorkspaceSessionController layout restoration

**Files:**
- Modify: `TreemuxTests/WorkspaceModelsTests.swift`

**Step 1: Write the failing test**

Add a test that verifies `WorkspaceSessionController` can be initialized with a saved layout and pane snapshots.

```swift
@MainActor
func testSessionControllerRestoresLayout() {
    let paneA = UUID()
    let paneB = UUID()
    let savedLayout: SessionLayoutNode = .split(PaneSplitNode(
        axis: .horizontal,
        first: .pane(PaneLeaf(paneID: paneA)),
        second: .pane(PaneLeaf(paneID: paneB))
    ))
    let snapshots = [
        PaneSnapshot(id: paneA, backend: .localShell(LocalShellConfig.defaultShell()), workingDirectory: "/tmp/a"),
        PaneSnapshot(id: paneB, backend: .localShell(LocalShellConfig.defaultShell()), workingDirectory: "/tmp/b")
    ]

    let ctrl = WorkspaceSessionController(
        workingDirectory: "/tmp",
        savedLayout: savedLayout,
        paneSnapshots: snapshots,
        focusedPaneID: paneB,
        zoomedPaneID: nil
    )

    // Layout should be the saved split, not a single pane
    XCTAssertEqual(ctrl.layout.paneIDs.count, 2)
    XCTAssertTrue(ctrl.layout.paneIDs.contains(paneA))
    XCTAssertTrue(ctrl.layout.paneIDs.contains(paneB))
    XCTAssertEqual(ctrl.focusedPaneID, paneB)
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing TreemuxTests/WorkspaceModelsTests/testSessionControllerRestoresLayout 2>&1 | tail -20`

Expected: FAIL — compilation error, the new init doesn't exist yet

**Step 3: Commit**

```bash
git add TreemuxTests/WorkspaceModelsTests.swift
git commit -m "test: add failing test for session controller layout restoration"
```

---

### Task 6: Implement — WorkspaceSessionController layout restoration init

**Files:**
- Modify: `Treemux/Services/Terminal/WorkspaceSessionController.swift`

**Step 1: Add the new convenience initializer**

Add after the existing `init(workingDirectory:)` (line 31):

```swift
/// Creates a controller restoring a previously saved layout and pane snapshots.
/// If savedLayout is nil or paneSnapshots is empty, falls back to single-pane default.
convenience init(
    workingDirectory: String,
    savedLayout: SessionLayoutNode?,
    paneSnapshots: [PaneSnapshot],
    focusedPaneID: UUID?,
    zoomedPaneID: UUID?
) {
    self.init(workingDirectory: workingDirectory)

    guard let savedLayout = savedLayout, !paneSnapshots.isEmpty else { return }

    // Restore the saved layout tree
    self.layout = savedLayout

    // Create sessions from saved snapshots
    let snapshotMap = Dictionary(paneSnapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for paneID in savedLayout.paneIDs {
        let snapshot = snapshotMap[paneID]
        let session = ShellSession(
            id: paneID,
            backendConfiguration: snapshot?.backend ?? .localShell(LocalShellConfig.defaultShell()),
            preferredWorkingDirectory: snapshot?.workingDirectory ?? workingDirectory
        )
        session.onFocus = { [weak self] in
            self?.focusedPaneID = paneID
        }
        session.onWorkspaceAction = { [weak self] action in
            self?.handleWorkspaceAction(action, from: paneID)
        }
        session.startIfNeeded()
        sessions[paneID] = session
    }

    // Restore focus and zoom state
    self.focusedPaneID = focusedPaneID ?? savedLayout.paneIDs.first
    self.zoomedPaneID = zoomedPaneID
}
```

Note: `handleWorkspaceAction` is currently `private`. It needs to be accessible from the convenience init. Since both methods are in the same class, this should work. But if `sessions` is `private(set)`, we need to make sure the setter is accessible within the class. Check the property declaration — it's `@Published private(set) var sessions` — the private setter is internal to the file, so within the same class it's fine.

**Step 2: Run the test from Task 5**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing TreemuxTests/WorkspaceModelsTests/testSessionControllerRestoresLayout 2>&1 | tail -20`

Expected: PASS

**Step 3: Run all tests**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing TreemuxTests 2>&1 | tail -30`

Expected: All PASS

**Step 4: Commit**

```bash
git add Treemux/Services/Terminal/WorkspaceSessionController.swift
git commit -m "feat: add layout restoration initializer to WorkspaceSessionController"
```

---

### Task 7: Wire — controller(forTabID:) passes saved state

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift:388-398`

**Step 1: Update `controller(forTabID:worktreePath:)` to pass saved state**

Replace the existing implementation (lines 388-398):

```swift
/// Returns or creates a session controller for the given tab and worktree.
private func controller(forTabID tabID: UUID, worktreePath: String) -> WorkspaceSessionController {
    if let existing = tabControllers[worktreePath]?[tabID] {
        return existing
    }

    // Look up the saved tab state to restore layout and panes
    let tabState = tabs.first(where: { $0.id == tabID })

    let ctrl = WorkspaceSessionController(
        workingDirectory: worktreePath,
        savedLayout: tabState?.layout,
        paneSnapshots: tabState?.panes ?? [],
        focusedPaneID: tabState?.focusedPaneID,
        zoomedPaneID: tabState?.zoomedPaneID
    )

    if tabControllers[worktreePath] == nil {
        tabControllers[worktreePath] = [:]
    }
    tabControllers[worktreePath]?[tabID] = ctrl
    return ctrl
}
```

**Step 2: Run all tests**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing TreemuxTests 2>&1 | tail -30`

Expected: All PASS

**Step 3: Commit**

```bash
git add Treemux/Domain/WorkspaceModels.swift
git commit -m "feat: wire saved layout and pane state into controller creation"
```

---

### Task 8: Test — end-to-end worktree isolation with layout

**Files:**
- Modify: `TreemuxTests/WorkspaceModelsTests.swift`

**Step 1: Write end-to-end test**

```swift
@MainActor
func testWorktreeSwitchPreservesAndRestoresState() {
    let ws = WorkspaceModel(
        name: "test",
        kind: .repository,
        repositoryRoot: URL(fileURLWithPath: "/tmp/project")
    )

    // Start on main worktree, create a second tab
    XCTAssertEqual(ws.tabs.count, 1)
    ws.createTab()
    XCTAssertEqual(ws.tabs.count, 2)
    let mainTabIDs = ws.tabs.map(\.id)

    // Switch to feature worktree
    ws.switchToWorktree("/tmp/project-feature")
    XCTAssertEqual(ws.tabs.count, 1) // New worktree starts with default tab
    let featureTabID = ws.tabs[0].id
    XCTAssertFalse(mainTabIDs.contains(featureTabID))

    // Switch back to main — should have 2 tabs again
    ws.switchToWorktree("/tmp/project")
    XCTAssertEqual(ws.tabs.count, 2)
    XCTAssertEqual(Set(ws.tabs.map(\.id)), Set(mainTabIDs))

    // Switch back to feature — should have 1 tab with correct ID
    ws.switchToWorktree("/tmp/project-feature")
    XCTAssertEqual(ws.tabs.count, 1)
    XCTAssertEqual(ws.tabs[0].id, featureTabID)
}
```

**Step 2: Run the test**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing TreemuxTests/WorkspaceModelsTests/testWorktreeSwitchPreservesAndRestoresState 2>&1 | tail -20`

Expected: PASS

**Step 3: Commit**

```bash
git add TreemuxTests/WorkspaceModelsTests.swift
git commit -m "test: add end-to-end worktree switch state isolation test"
```

---

### Task 9: Run full test suite and verify build

**Step 1: Run full test suite**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux 2>&1 | tail -40`

Expected: All tests PASS, build succeeds

**Step 2: Verify app launches**

Run: `xcodebuild build -project Treemux.xcodeproj -scheme Treemux -configuration Debug 2>&1 | tail -10`

Expected: BUILD SUCCEEDED
