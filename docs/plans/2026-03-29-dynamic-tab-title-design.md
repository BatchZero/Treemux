# Dynamic Tab Title Update Design

## Problem

Tab titles in Treemux only update when switching tabs (`createTab`, `selectTab`, `closeTab`). Pane operations (split, close, focus, zoom, resize) happen inside `WorkspaceSessionController` without notifying `WorkspaceModel`, so the tab title stays stale (e.g., "Tab 2") until the user switches away and back.

Liney solves this by calling `saveActiveWorktreeState()` after every pane operation, which triggers `suggestedTitle()` to recompute the tab title from the focused session's shell title or working directory.

## Goal

Make Treemux tab titles update dynamically on pane operations, matching Liney's behavior.

## Design

### Approach: Callback from WorkspaceSessionController to WorkspaceModel

Add an `onPaneStateChanged` closure on `WorkspaceSessionController`. After each pane action dispatched through `handleWorkspaceAction`, invoke the callback. `WorkspaceModel` sets this callback to call `saveActiveTabState()`.

### Changes

#### 1. WorkspaceSessionController (WorkspaceSessionController.swift)

- Add property: `var onPaneStateChanged: (() -> Void)?`
- Call `onPaneStateChanged?()` at the end of `handleWorkspaceAction(_:from:)`

#### 2. WorkspaceModel (WorkspaceModels.swift)

- In `controller(forTabID:worktreePath:)` (or wherever controllers are created/restored), set `controller.onPaneStateChanged = { [weak self] in self?.saveActiveTabState() }`

### What stays the same

- `suggestedTitle()` priority: manual name > shell title > working directory > fallback "Tab"
- `saveActiveTabState()` logic
- `isManuallyNamed` flag behavior
- Initial tab naming ("Tab N")
- Tab bar UI rendering

### Title update priority (unchanged)

1. If `isManuallyNamed == true` → keep user's name
2. Focused pane's `session.title` (shell integration title)
3. Focused pane's `effectiveWorkingDirectory` last path component
4. Existing title or "Tab" fallback
