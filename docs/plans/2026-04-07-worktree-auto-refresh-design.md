# Worktree Sidebar Auto-Refresh on External Changes

**Date:** 2026-04-07
**Status:** Approved

## Problem

When a user runs `git worktree add` or `git worktree remove` from an external
terminal (or any tool outside Treemux), the project sidebar does not update.
The new worktree never appears, and the deleted worktree never disappears,
until the workspace is manually re-selected or the app restarts.

The user expects near-real-time (<1 second) auto-refresh of the worktree list
regardless of where the change originates.

## Root Cause

`WorkspaceMetadataWatchService` already monitors per-worktree git metadata
(`HEAD`, `index`, `refs/`) using `DispatchSourceFileSystemObject`, and any
detected change triggers `WorkspaceStore.refreshWorkspace`, which re-runs
`git worktree list --porcelain` and merges the result. The mechanism for
refreshing exists and works.

The gap is in **what is being watched**:

1. **The `worktrees/` index directory is not in the watch list.** When
   `git worktree add` runs, it creates a new directory at
   `<main-git-dir>/worktrees/<name>/`. This change happens *inside* the
   main `.git/` directory, which is in the watch list — so in principle the
   parent's vnode write event should fire. In practice this is unreliable
   for sub-directory creation across all conditions, and explicitly watching
   `<main-git-dir>/worktrees/` makes the signal deterministic.

2. **Watchers are not re-established after a refresh.** Even if a new worktree
   is detected, the watcher set built at startup does not include a watcher
   for the new worktree's gitdir, so subsequent changes to the new worktree
   would be missed.

## Approach

Two focused changes:

1. Teach `WorkspaceMetadataWatchService` to resolve the **common (main) git
   directory** from any worktree's gitdir, then watch
   `<common-git-dir>/worktrees/` in addition to the existing per-worktree paths.
2. After every successful `WorkspaceStore.refreshWorkspace`, call
   `metadataWatcher.watch(workspace:)` to rebuild watchers, ensuring newly
   discovered worktrees get their own observers and removed worktrees have
   their stale handles cleaned up.

These changes preserve the existing debounce, refresh pipeline, and
`objectWillChange.send()` propagation. No new threading model, no polling,
no FSEventStream rewrite.

## Architecture

### Common Git Directory Resolution

Git stores linked worktree metadata under `<main-git-dir>/worktrees/<name>/`.
Each linked worktree's gitdir contains a `commondir` file whose contents are
a path (typically relative, e.g. `../..`) pointing back to the main gitdir.
The main worktree's gitdir has no `commondir` file.

New private method on `WorkspaceMetadataWatchService`:

```swift
/// Reads the `commondir` file inside a linked worktree's gitdir to find
/// the main repository's git directory. Returns the input path if there
/// is no `commondir` file (meaning the input is already the main gitdir).
private func resolveCommonGitDirectory(for gitDirectory: String) -> String
```

Logic:
- Read `<gitDirectory>/commondir`
- File missing → return `gitDirectory` (input is already the main gitdir)
- File present, contents absolute → use as-is
- File present, contents relative → resolve against `gitDirectory`, standardize

### Watch Path Expansion

`gitMetadataPaths(in:)` is extended to additionally include:
- `<common-git-dir>` itself (catches `worktrees/` sub-directory creation
  when there are zero linked worktrees yet)
- `<common-git-dir>/worktrees` (catches add/remove of linked worktree
  metadata directories)

Both pass through the existing `fileExists` filter, so the `worktrees/` entry
is silently dropped when it does not exist yet — but the parent
`<common-git-dir>` is always present and always watched.

### Watcher Re-establishment After Refresh

`WorkspaceStore.refreshWorkspace` already mutates `workspace.worktrees` and
calls `objectWillChange.send()`. We insert a single call before the send:

```swift
metadataWatcher.watch(workspace: workspace) { [weak self] workspaceID in
    Task { @MainActor [weak self] in
        guard let self,
              let ws = self.workspaces.first(where: { $0.id == workspaceID }) else { return }
        await self.refreshWorkspace(ws)
    }
}
objectWillChange.send()
```

`watch(workspace:)` is idempotent: it calls `stopWatching(workspaceID:)`
internally before opening new descriptors, so repeated calls do not leak fds.

## Data Flow (External `git worktree add`)

```
[CLI] git worktree add ../foo -b feat/foo
   └─> creates <repo>/.git/worktrees/foo/   (new sub-directory)

[Kernel] vnode write event on <repo>/.git/worktrees/   (and on <repo>/.git/)

[WatchService] DispatchSourceFileSystemObject fires
   └─> scheduleCallback(workspaceID, debounce 0.5s)

[WorkspaceStore] refreshWorkspace(workspace)
   └─> git worktree list --porcelain → snapshot.worktrees now contains "foo"
   └─> merge into workspace.worktrees (preserve stable IDs)
   └─> metadataWatcher.watch(workspace:)   ← rebuild watchers
       └─> watchers now include <repo>/.git/worktrees/foo/
   └─> objectWillChange.send()

[SwiftUI] WorkspaceOutlineSidebar rebuilds node tree
   └─> sidebar shows "foo"
```

The deletion case is symmetric: a `.delete` event on the removed worktree's
gitdir (or `.write` on the parent `worktrees/` directory) triggers refresh,
the merged list omits the deleted worktree, watcher rebuild calls
`stopWatching` on the stale handles, and the sidebar removes the node.

## Error Handling

| Condition | Behavior |
|---|---|
| `commondir` read fails | Return input gitdir; degenerate to local watch (still safe) |
| `commondir` is absolute path | Use as-is |
| `commondir` is relative path | Resolve against worktree gitdir, standardize |
| `<common>/worktrees/` does not exist | `fileExists` filter skips; parent watch still catches first creation |
| `open()` fd exhaustion | Existing `guard descriptor >= 0 else { return }` silently skips |
| Remote (SSH) workspace | `repositoryRoot == nil`; `startWatching` early-returns; unaffected |
| `refreshWorkspace` git command fails | Catch block swallows error; old watchers still valid |

## Edge Cases

1. **Empty worktree list at startup** — main `.git/` directory is always
   watched; first `worktrees/` creation fires the parent's vnode event.
2. **Repeated refresh on the same workspace** — `watch(workspace:)` is
   idempotent; no fd leaks.
3. **Burst of external operations** — debounce coalesces into one refresh;
   refresh fetches the latest snapshot regardless of intermediate states.
4. **Watcher rebuild during event handling** — new sources only respond to
   future events; no self-loop.
5. **Selected worktree deleted externally** — existing
   `previousWorktreeIDs`/`merged.contains` logic in `refreshWorkspace`
   already falls selection back to the parent workspace.
6. **All linked worktrees removed** — `worktrees/` directory deletion is a
   write on `.git/`; refresh runs; node disappears.

## Files Changed

- `Treemux/Services/Git/WorkspaceMetadataWatchService.swift`
  - Add `resolveCommonGitDirectory(for:)` private method
  - Extend `gitMetadataPaths(in:)` to include common gitdir and its
    `worktrees/` sub-directory
- `Treemux/App/WorkspaceStore.swift`
  - In `refreshWorkspace(_:)`, call `metadataWatcher.watch(workspace:)`
    just before `objectWillChange.send()`

## Testing

### Unit Tests

Add to `TreemuxTests/` (likely a new
`WorkspaceMetadataWatchServiceTests.swift` or extension of
`GitRepositoryServiceTests.swift`):

1. `test_resolveCommonGitDirectory_forMainWorktree_returnsItself`
   - `git init` in temp dir
   - Assert `resolveCommonGitDirectory(for: <repo>/.git)` == `<repo>/.git`

2. `test_resolveCommonGitDirectory_forLinkedWorktree_returnsMainGitDir`
   - `git init` then `git worktree add ../linked`
   - Assert `resolveCommonGitDirectory(for: <repo>/.git/worktrees/linked)`
     == `<repo>/.git`

3. `test_gitMetadataPaths_includesCommonWorktreesDirectory`
   - Repo with one linked worktree
   - Assert returned paths contain `<repo>/.git/worktrees`

### Manual Acceptance Checklist

1. Open a repo with 1 linked worktree → sidebar shows 1 worktree node.
2. In an external terminal: `git worktree add ../wt2 -b feat/x`
   → sidebar shows `wt2` within 1 second.
3. In an external terminal: `git worktree remove ../wt2`
   → sidebar removes `wt2` within 1 second.
4. Repeat steps 2 and 3 ten times in a row → no fd/memory leak (verify in
   Activity Monitor or `lsof`); sidebar stays consistent.
5. Open a repo with **zero** worktrees → immediately
   `git worktree add ../first` from CLI → `first` appears in sidebar
   (validates the empty-list edge case).
6. Select a worktree, then delete it from CLI → selection falls back to the
   parent workspace (no crash, no orphan selection).
7. SSH remote workspace remains unaffected: no file watching, refresh still
   only runs when the user re-selects (existing behavior).
