# Worktree State Isolation & Layout Restoration

**Date:** 2026-03-26
**Status:** Approved

## Problem

Different git worktrees within the same workspace share the same tabs, pane layouts, and terminal working directories. Switching to another worktree creates a fresh default tab instead of restoring the saved state.

### Root Cause

`WorkspaceModels.swift:restoreTabState(from:)` only loads the active worktree's tab state during deserialization. The `worktreeTabStates` dictionary is never populated for inactive worktrees, so `switchToWorktree()` always falls through to the `else` branch and creates a new default tab.

Additionally, `WorkspaceSessionController` is hardcoded to initialize with a single pane — it cannot restore a saved layout tree.

## Design

### Part 1: Fix Worktree State Isolation

**File:** `WorkspaceModels.swift`

1. **`restoreTabState(from:)`** — iterate ALL worktree states; load active one into `self.tabs`, load all others into `worktreeTabStates[path]`.

2. **Extract symmetric `saveActiveWorktreeState()` / `loadActiveWorktreeState()`** — modeled after Liney's `WorkspaceRuntime.swift:736-772`. Used by `init`, `switchToWorktree()`, and `toRecord()`.

3. **Working directory** — ensure new tabs/panes created after switching use the target worktree path.

### Part 2: Pane Layout Restoration

**Files:** `WorkspaceSessionController.swift`, `WorkspaceModels.swift`

1. **Extend `WorkspaceSessionController` init** — add a new initializer that accepts `savedLayout`, `paneSnapshots`, `focusedPaneID`, and `zoomedPaneID`. If `savedLayout` is provided, use it as the layout tree and create `ShellSession` instances from the snapshots. Fall back to single-pane behavior for new tabs.

2. **Modify `controller(forTabID:worktreePath:)`** — look up the corresponding `WorkspaceTabStateRecord` and pass its saved state to the new initializer.

3. **Restore focus and zoom** — set `focusedPaneID` and `zoomedPaneID` from the saved tab record.

### Part 3: Data Flow

**Startup:**
```
workspace-state.json
  → WorkspaceModel.init(from:)
    → active worktree tabs → self.tabs
    → inactive worktree tabs → self.worktreeTabStates
    → first tab access → controller with savedLayout + paneSnapshots
```

**Runtime worktree switch:**
```
switchToWorktree(newPath)
  → saveActiveWorktreeState()
  → loadActiveWorktreeState()
  → controller initialized with saved state on first tab access
```

**Persistence (unchanged):**
```
toRecord()
  → active worktree from self.tabs
  → inactive worktrees from worktreeTabStates
  → write workspace-state.json
```

### Out of Scope

- Terminal scroll history / shell output restoration
- Cross-workspace state restoration (already independent)
