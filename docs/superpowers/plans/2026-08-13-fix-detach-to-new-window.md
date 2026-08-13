# Detach-to-New-Window Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make sidebar tear-off work through context menus and drag release, keep detached nodes out of the main sidebar, render correct workspace/worktree child layouts, and restore detached windows after relaunch.

**Architecture:** Keep `WindowManager` as the lifecycle owner, but route detached-set mutations through assignment-based `WorkspaceStore` APIs so Observation invalidates the sidebar bridge. Use the actual `NSTableViewDelegate` drag-end callback and allow both local and outside-application move sessions. Give worktrees deterministic path-derived IDs and delay launch restoration until initial local repository discovery completes. A detached workspace gets a scoped navigation sidebar containing that workspace and its worktrees; a detached worktree remains a focused single-detail window.

**Tech Stack:** Swift 6, SwiftUI Observation, AppKit `NSOutlineView`/`NSWindow`, XCTest, Xcode/macOS.

## Global Constraints

- Work only in `.worktrees/feat+detach-to-new-window`; keep the main checkout on `main`.
- Use `NSWindow(contentViewController: NSHostingController(...))` for all windows.
- User-visible strings remain localized through existing SwiftUI localization behavior.
- Add regression coverage before each production change and observe the expected failure.

---

### Task 1: Route real outline drag completion to detach

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarCoordinator.swift`
- Modify: `Treemux/UI/Sidebar/SidebarContainerView.swift`
- Test: `TreemuxTests/DetachPasteboardItemTests.swift`

**Interfaces:**
- Consumes: `DetachPasteboardItem.detachType`, `onDetachNode`.
- Produces: `outlineView(_:draggingSession:endedAt:operation:)` and move masks for local/external sessions.

- [ ] Add a test asserting `SidebarCoordinator` responds to `tableView:draggingSession:endedAtPoint:operation:` and `SidebarContainerView` advertises `.move` for local and non-local drags.
- [ ] Run the focused test and confirm it fails because the delegate selector is absent and the non-local mask is empty.
- [ ] Replace the unused generic `NSDraggingSource` endpoint with the `NSTableViewDelegate` endpoint, retaining the existing screen-geometry, pasteboard decode, and `operation == []` guards; set the non-local source mask to `.move`.
- [ ] Re-run the focused test and the existing pasteboard/reorder tests.

### Task 2: Make detach/reattach observable and persistable

**Files:**
- Modify: `Treemux/App/WorkspaceStore.swift`
- Modify: `Treemux/App/WindowManager.swift`
- Test: `TreemuxTests/WorkspaceStoreDetachTests.swift`
- Test: `TreemuxTests/WindowManagerTests.swift`

**Interfaces:**
- Produces: `WorkspaceStore.detachNode(_:) -> Bool` and `reattachNode(_:) -> Bool`, both assigning a new `Set` value and scheduling persistence.
- Consumes: `WindowManager.detach`, child close, stale-ref cleanup, workspace removal.

- [ ] Add tests that observe `detachedNodes` while calling detach/reattach APIs, and assert idempotence plus persisted state.
- [ ] Run them and confirm the APIs/invalidations are missing.
- [ ] Implement assignment-based APIs and replace direct set mutation in window lifecycle paths.
- [ ] Re-run store, filter, context-menu, and window lifecycle suites.

### Task 3: Render a scoped workspace child layout

**Files:**
- Modify: `Treemux/UI/Detached/SingleWorkspaceWindowView.swift`
- Test: `TreemuxTests/WindowManagerTests.swift`

**Interfaces:**
- Consumes: shared `WorkspaceModel`, `WorkspaceStore`, and `ThemeManager` environments.
- Produces: a `NavigationSplitView` whose sidebar contains the detached workspace and its worktrees and whose detail switches locally without mutating the main window selection.

- [ ] Add focused tests for the local selection-to-detail resolver (workspace selection resolves to the workspace; a known worktree selection resolves to that worktree; unknown selection falls back safely).
- [ ] Run them and confirm the scoped layout resolver is missing.
- [ ] Implement the scoped sidebar with `SidebarNodeRow`, local selection, appropriate detail view, sidebar toggle toolbar, and existing theme tokens.
- [ ] Re-run focused tests and render the application to verify the sidebar and terminal content are visible.

### Task 4: Restore worktree windows after relaunch

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift`
- Modify: `Treemux/Services/Git/GitRepositoryService.swift`
- Modify: `Treemux/App/WorkspaceStore.swift`
- Modify: `Treemux/App/TreemuxApp.swift`
- Test: `TreemuxTests/GitRepositoryServiceTests.swift`
- Test: `TreemuxTests/DetachLifecycleIntegrationTests.swift`

**Interfaces:**
- Produces: `WorktreeModel.stableID(for:)`, `WorkspaceStore.waitForInitialWorkspaceRefresh()`.
- Consumes: git worktree parsing and `TreemuxApp.launch()` restoration ordering.

- [ ] Add a real temporary-git-repository test proving two inspections return identical worktree IDs, and an integration test proving a persisted worktree ref survives fresh-store discovery before restoration.
- [ ] Run them and confirm random IDs / early restore break the tests.
- [ ] Derive worktree IDs deterministically from normalized paths, retain IDs during in-process merges, retain the initial refresh task, and await it before calling `restoreChildWindows()`.
- [ ] Re-run lifecycle, workspace-store, and git-service suites.

### Task 5: Full verification and interactive acceptance

**Files:**
- Modify only if a verification failure identifies a remaining root cause.

- [ ] Run the full `TreemuxTests` suite with package-plugin validation skipped.
- [ ] Build the Debug app and record the exact DerivedData product path.
- [ ] Interactively verify context-menu workspace/worktree detach, drag to detail, drag outside the window, main-sidebar hiding, scoped workspace layout, focused worktree layout, red-× restoration, and quit/relaunch restoration.
- [ ] Inspect `git diff`, ensure no unrelated user changes were overwritten, and report any acceptance item that macOS automation cannot reliably drive.
