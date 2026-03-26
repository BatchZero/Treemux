# Worktree Sidebar Startup Fix — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix the bug where worktree lists and branch names don't appear in the sidebar until user interaction after app launch.

**Architecture:** Add an async refresh call in `WorkspaceStore.loadWorkspaceState()` to populate worktrees and branch info from git immediately after loading persisted state. Restart file system watchers after refresh so they cover all worktree paths.

**Tech Stack:** Swift, SwiftUI, async/await, Xcode

---

### Task 1: Add Startup Refresh to loadWorkspaceState()

**Files:**
- Modify: `Treemux/App/WorkspaceStore.swift:323-328`

**Step 1: Modify `loadWorkspaceState()` to trigger async refresh**

Replace the current method (lines 323–328):

```swift
private func loadWorkspaceState() {
    let state = workspaceStatePersistence.load()
    selectedWorkspaceID = state.selectedWorkspaceID
    workspaces = state.workspaces.map { WorkspaceModel(from: $0) }
    startWatchingAll()
}
```

With:

```swift
private func loadWorkspaceState() {
    let state = workspaceStatePersistence.load()
    selectedWorkspaceID = state.selectedWorkspaceID
    workspaces = state.workspaces.map { WorkspaceModel(from: $0) }
    startWatchingAll()

    // Populate worktrees and branch info from git on launch
    Task {
        for workspace in workspaces {
            await refreshWorkspace(workspace)
        }
        // Restart watchers with full worktree paths now available
        startWatchingAll()
    }
}
```

Notes:
- `WorkspaceStore` is `@MainActor`, so the `Task` inherits main-actor context — no explicit `@MainActor` annotation needed on the Task closure.
- The first `startWatchingAll()` remains to catch `.git` changes during refresh.
- The second `startWatchingAll()` re-registers watchers with correct worktree paths (since `watchPaths(for:)` reads `workspace.worktrees`).
- `refreshWorkspace()` has a `guard let root = workspace.repositoryRoot else { return }` so non-repository workspaces (local terminals) are safely skipped.

**Step 2: Build the project to verify compilation**

Run:
```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add Treemux/App/WorkspaceStore.swift
git commit -m "fix: populate worktrees and branch info on app launch"
```

---

### Task 2: Manual Verification

**Step 1: Clean debug state and launch**

```bash
rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-fbvzemhsknohjwfflqakdhefxzwi/Build/Products/Debug/Treemux.app
```

**Step 2: Verify sidebar behavior**

1. Add a project that has git worktrees (or use an existing one)
2. Quit and relaunch the app
3. Confirm: sidebar immediately shows worktree disclosure groups and branch names
4. Confirm: worktrees are clickable and switch correctly
5. Confirm: no regressions — projects without worktrees still display normally
