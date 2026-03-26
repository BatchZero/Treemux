# Fix: Split & Add Terminal Buttons Not Working — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix the broken SwiftUI observation chain so split-pane and add-terminal toolbar buttons actually update the UI, and unify active-controller resolution across all call sites.

**Architecture:** Add a single `activeSessionController` computed property on `WorkspaceStore` as the canonical way to get the current controller. Extract an `@ObservedObject`-based bridge view in `WorkspaceDetailView` (Liney pattern) so layout mutations propagate to `SplitNodeView`. Update all call sites (toolbar, command palette, menu bar) to use the unified property.

**Tech Stack:** Swift, SwiftUI, macOS (AppKit interop)

---

### Task 1: Add `activeSessionController` to WorkspaceStore

**Files:**
- Modify: `Treemux/App/WorkspaceStore.swift:56-65` (after `selectedWorktree` computed property)

**Step 1: Add the computed property**

Insert after the `selectedWorktree` property (line 65):

```swift
/// The session controller for the currently active workspace or worktree.
/// All UI call sites (toolbar, detail view, command palette, menu bar)
/// should use this single source of truth.
var activeSessionController: WorkspaceSessionController? {
    guard let workspace = selectedWorkspace else { return nil }
    if let worktree = selectedWorktree {
        return workspace.sessionController(forWorktreePath: worktree.path.path)
    }
    return workspace.sessionController
}
```

**Step 2: Build to verify compilation**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/App/WorkspaceStore.swift
git commit -m "feat: add activeSessionController computed property to WorkspaceStore"
```

---

### Task 2: Extract observation bridge in WorkspaceDetailView

**Files:**
- Modify: `Treemux/UI/Workspace/WorkspaceDetailView.swift` (full rewrite — 32 lines → ~30 lines)

**Step 1: Rewrite WorkspaceDetailView with bridge view**

Replace the entire body of `WorkspaceDetailView.swift` with:

```swift
//
//  WorkspaceDetailView.swift
//  Treemux

import SwiftUI

/// Detail view for the selected workspace.
/// Displays the split pane layout with terminal sessions.
/// When a specific worktree is selected, shows that worktree's session controller.
struct WorkspaceDetailView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        if let controller = store.activeSessionController {
            WorkspaceSessionDetailView(controller: controller)
                .id(store.selectedWorkspaceID)
        }
    }
}

/// Observes the session controller directly so that layout mutations
/// (e.g. splitPane) propagate to SplitNodeView. Follows the same pattern
/// as Liney's WorkspaceSessionDetailView.
private struct WorkspaceSessionDetailView: View {
    @ObservedObject var controller: WorkspaceSessionController

    var body: some View {
        SplitNodeView(sessionController: controller, node: controller.layout)
    }
}
```

**Step 2: Build to verify compilation**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/UI/Workspace/WorkspaceDetailView.swift
git commit -m "fix: extract observation bridge view so layout changes propagate to SplitNodeView"
```

---

### Task 3: Update toolbar buttons in MainWindowView

**Files:**
- Modify: `Treemux/UI/MainWindowView.swift:47-77` (toolbar button actions)

**Step 1: Replace all three button actions**

Change the three toolbar button actions from `store.selectedWorkspace?.sessionController` to `store.activeSessionController`:

```swift
// Split Down button (line 48-52)
Button {
    if let sc = store.activeSessionController,
       let focused = sc.focusedPaneID {
        sc.splitPane(focused, axis: .horizontal)
    }
}

// Split Right button (line 58-62)
Button {
    if let sc = store.activeSessionController,
       let focused = sc.focusedPaneID {
        sc.splitPane(focused, axis: .vertical)
    }
}

// New Terminal button (line 68-72)
Button {
    if let sc = store.activeSessionController,
       let focused = sc.focusedPaneID {
        sc.splitPane(focused, axis: .horizontal)
    }
}
```

**Step 2: Build to verify compilation**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/UI/MainWindowView.swift
git commit -m "fix: toolbar buttons use activeSessionController for correct controller resolution"
```

---

### Task 4: Update CommandPaletteView commands

**Files:**
- Modify: `Treemux/UI/Components/CommandPaletteView.swift:120-154` (allCommands actions)

**Step 1: Replace controller access in all three pane commands**

Change `store.selectedWorkspace?.sessionController` to `store.activeSessionController` in the Split Horizontal, Split Vertical, and Close Pane commands:

```swift
// Split Horizontal (line 126-130)
action: {
    if let sc = store.activeSessionController,
       let focused = sc.focusedPaneID {
        sc.splitPane(focused, axis: .horizontal)
    }
}

// Split Vertical (line 137-141)
action: {
    if let sc = store.activeSessionController,
       let focused = sc.focusedPaneID {
        sc.splitPane(focused, axis: .vertical)
    }
}

// Close Pane (line 148-152)
action: {
    if let sc = store.activeSessionController,
       let focused = sc.focusedPaneID {
        sc.closePane(focused)
    }
}
```

**Step 2: Build to verify compilation**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/UI/Components/CommandPaletteView.swift
git commit -m "fix: command palette uses activeSessionController for pane actions"
```

---

### Task 5: Update AppDelegate menu actions

**Files:**
- Modify: `Treemux/AppDelegate.swift:169-171` (sessionController computed property)

**Step 1: Change the private sessionController property**

Replace line 169-171:

```swift
// Before:
private var sessionController: WorkspaceSessionController? {
    store?.selectedWorkspace?.sessionController
}

// After:
private var sessionController: WorkspaceSessionController? {
    store?.activeSessionController
}
```

**Step 2: Build to verify compilation**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/AppDelegate.swift
git commit -m "fix: menu bar actions use activeSessionController"
```

---

### Task 6: Manual verification

**Step 1: Build and launch**

Run full build, then launch the app.

**Step 2: Verify split buttons work**

1. Click "Split Down" toolbar button → terminal pane should split vertically (top/bottom)
2. Click "Split Right" toolbar button → terminal pane should split horizontally (left/right)
3. Click "New Terminal" toolbar button → should add a new pane
4. Try ⌘D and ⌘⇧D keyboard shortcuts → same behavior
5. Open command palette (⌘⇧P), run "Split Horizontal" and "Split Vertical" → same behavior
6. Use menu bar Pane → Split Horizontal / Split Vertical → same behavior

**Step 3: Verify worktree scenario (if applicable)**

If a git repo with worktrees is available:
1. Select a worktree in sidebar
2. Click split buttons → should split the worktree's terminal, not the workspace's

**Step 4: Verify no regressions**

1. Sidebar toggle button still works
2. Settings button still opens settings sheet
3. Close pane (⌘W) still works
4. Pane focus navigation still works
