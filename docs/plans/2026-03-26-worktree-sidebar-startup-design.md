# Worktree Sidebar Startup Fix Design

**Date:** 2026-03-26
**Status:** Approved

## Problem

When the app launches, worktree lists and branch names are not displayed in the sidebar. They only appear after user interaction (e.g., pressing Enter in a pane) triggers a git metadata change.

### Root Cause

`WorkspaceStore.loadWorkspaceState()` creates `WorkspaceModel` objects from persisted `WorkspaceRecord`, but never calls `refreshWorkspace()` to populate:
- `workspace.worktrees: [WorktreeModel]` (remains `[]`)
- `workspace.currentBranch: String?` (remains `nil`)

The `WorkspaceMetadataWatchService` only fires on `.git` directory changes, not on app startup.

## Solution: Async Refresh on Launch (Approach A)

After loading persisted state, trigger `refreshWorkspace()` for each workspace to fetch worktree and branch info from git.

### Changes

**File:** `Treemux/App/WorkspaceStore.swift` — `loadWorkspaceState()` method only.

```swift
private func loadWorkspaceState() {
    let state = workspaceStatePersistence.load()
    selectedWorkspaceID = state.selectedWorkspaceID
    workspaces = state.workspaces.map { WorkspaceModel(from: $0) }
    startWatchingAll()

    // Populate worktrees and branch info from git on launch
    Task { @MainActor in
        for workspace in workspaces {
            await refreshWorkspace(workspace)
        }
        // Restart watchers with full worktree paths now available
        startWatchingAll()
    }
}
```

### Key Design Decisions

1. **Keep initial `startWatchingAll()` before async refresh** — ensures `.git` changes during refresh are not missed.
2. **Call `startWatchingAll()` again after refresh** — `watchPaths(for:)` depends on `workspace.worktrees` to determine watch paths; the first call only watches the main repo `.git` since worktrees are empty.
3. **Serial refresh loop** — simpler than concurrent, and git commands are fast (~50ms each).
4. **No persisted worktree cache** — always fetch fresh from git to avoid stale data.

### Impact

- ~7 lines changed in a single method
- No new types or APIs
- No UI changes needed — sidebar already observes `workspace.worktrees` via `@Published`
