# SSH Backend Awareness for New Pane/Session Creation

**Date:** 2026-03-27
**Status:** Approved

## Problem

`WorkspaceSessionController` is unaware of workspace's SSH context when creating new sessions. Three entry points hardcode `.localShell`:

| Entry Point | Location | Issue |
|---|---|---|
| `makeDefault()` | WorkspaceModels.swift | New tab pane always `.localShell` |
| `ensureSession(for:)` | WorkspaceSessionController.swift | New session always `.localShell` |
| `splitPane()` | WorkspaceSessionController.swift | Split pane gets `.localShell` via `ensureSession` |

In remote workspaces, only restored panes (from persisted snapshots) correctly use SSH. New tabs, splits, and unvisited worktrees all produce local shells.

## Design

### Approach: Thread `sshTarget` through `WorkspaceSessionController`

Core rule: **has `sshTarget` → SSH backend, no `sshTarget` → local shell.**

### 1. Centralized Backend Decision

Add a static helper on `SessionBackendConfiguration`:

```swift
static func defaultBackend(for sshTarget: SSHTarget?) -> SessionBackendConfiguration {
    if let target = sshTarget {
        return .ssh(SSHSessionConfig(target: target, remoteCommand: nil))
    }
    return .localShell(LocalShellConfig.defaultShell())
}
```

All new-pane code paths call this instead of hardcoding `.localShell()`.

### 2. `makeDefault()` Accepts `sshTarget`

```swift
static func makeDefault(
    workingDirectory: String,
    sshTarget: SSHTarget? = nil,
    title: String = "Tab 1"
) -> WorkspaceTabStateRecord
```

Callers pass `self.sshTarget` from `WorkspaceModel`:
- `WorkspaceModel.init()`
- `WorkspaceModel.createTab()`
- `WorkspaceModel.loadActiveWorktreeState()`

Default `nil` preserves backward compatibility for local workspaces and tests.

### 3. `WorkspaceSessionController` Holds `sshTarget`

```swift
final class WorkspaceSessionController: ObservableObject {
    let sshTarget: SSHTarget?

    init(workingDirectory: String, sshTarget: SSHTarget? = nil) { ... }
}
```

Used in:
- `ensureSession(for:)` — replaces hardcoded `.localShell()`
- convenience init fallback — when snapshot is missing, uses `.defaultBackend(for: sshTarget)`

`splitPane()` itself unchanged — new pane sessions are created by `ensureSession(for:)` on render.

### 4. Caller Threading

`WorkspaceModel.controller(forTabID:worktreePath:)` passes `self.sshTarget` when constructing controller. No changes needed in `WorkspaceStore` or UI layer.

## Testing

1. `makeDefault()` with `sshTarget` → verify `PaneSnapshot.backend` is `.ssh(...)`
2. `WorkspaceSessionController.ensureSession()` with `sshTarget` → verify session backend is `.ssh(...)`
3. Existing tests unchanged — `sshTarget` defaults to `nil`

## Files Changed

- `Treemux/Domain/SessionBackend.swift` — add `defaultBackend(for:)`
- `Treemux/Domain/WorkspaceModels.swift` — `makeDefault()` signature, `init()`, `createTab()`, `loadActiveWorktreeState()`, `controller(forTabID:)`
- `Treemux/Services/Terminal/WorkspaceSessionController.swift` — add `sshTarget` property, update `init`, `convenience init`, `ensureSession(for:)`
- Test files — add SSH-aware test cases
