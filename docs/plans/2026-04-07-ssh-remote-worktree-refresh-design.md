# SSH Remote Workspace Auto-Refresh

**Date:** 2026-04-07
**Status:** Approved

## Problem

The local-worktree auto-refresh feature (commits `b08fba1`/`6e9657e`/`a08062c`)
only covers workspaces that have a `repositoryRoot` (i.e. local file system
paths). SSH remote workspaces — where the repo lives on a remote server and
Treemux talks to it via `ssh` + `git` — are never auto-refreshed: they only
update on app launch, when the user adds them, or when the user manually
re-selects them.

External `git worktree add`/`remove` commands run on the remote server have
no way to notify the local Treemux instance, so the sidebar drifts out of
sync until the user takes a manual action.

## Constraints

- File system event monitoring (`DispatchSourceFileSystemObject`, FSEvents)
  cannot reach across SSH. The remote file system is not visible to macOS.
- Long-lived `ssh ... inotifywait` connections are complex (connection
  management, server-side dependency on inotify, reconnect logic) and out
  of scope.
- Each SSH-backed `refreshWorkspace` call costs one ssh invocation +
  network round-trip + remote `git` execution. Frequent polling is not free.

## Approach

A **hybrid pull strategy**: poll on a generous interval, plus an immediate
refresh whenever the Treemux window regains focus.

1. **Periodic poll** — a `Timer` fires every 30 seconds. When it fires, the
   store iterates over all `sshTarget != nil` workspaces and serially awaits
   `refreshWorkspace(_:)` for each one.
2. **Window-focus refresh** — observe `NSWindow.didBecomeKeyNotification`.
   When the Treemux window becomes key, immediately invoke the same
   serial-refresh routine.

The two triggers share the same code path. A reentry guard
(`isRefreshingRemotes` boolean) prevents overlapping invocations: if a
previous refresh is still in flight when a new trigger arrives, the new
trigger is dropped (the next tick will pick up any drift).

## Why hybrid (not poll-only or focus-only)

| Mode | Latency on changes while user is interacting | Latency after returning to Treemux | SSH cost |
|---|---|---|---|
| Poll only | ≤ 30s | ≤ 30s | 1× per workspace per 30s |
| Focus only | Never (until refocus) | Immediate | Only on focus |
| **Hybrid** | **≤ 30s** | **Immediate** | 1× per workspace per 30s + 1 on focus |

The hybrid mode makes sure the user sees fresh state the moment they look
at the window, while still catching changes that happen during long
foreground sessions.

## Architecture

### Where the logic lives

`WorkspaceStore.swift`. The store already owns `metadataWatcher` (for local
file system events), `gitService`, and the canonical `refreshWorkspace`
method which already supports both local and SSH paths. Adding the remote
scheduler as another private member of the store keeps all refresh
orchestration in one place.

### New members on `WorkspaceStore`

```swift
private static let remoteRefreshInterval: TimeInterval = 30
private var remoteRefreshTimer: Timer?
private var remoteWindowObserver: NSObjectProtocol?
private var isRefreshingRemotes = false
```

### Wiring

In `WorkspaceStore.init()` (after the existing initialization):

```swift
startRemoteWorkspaceRefreshScheduler()
```

The scheduler method:

```swift
private func startRemoteWorkspaceRefreshScheduler() {
    // Periodic poll
    remoteRefreshTimer = Timer.scheduledTimer(
        withTimeInterval: Self.remoteRefreshInterval,
        repeats: true
    ) { [weak self] _ in
        Task { @MainActor [weak self] in
            await self?.refreshAllRemoteWorkspaces()
        }
    }

    // Refresh on window focus
    remoteWindowObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification,
        object: nil,
        queue: .main
    ) { [weak self] _ in
        Task { @MainActor [weak self] in
            await self?.refreshAllRemoteWorkspaces()
        }
    }
}
```

The serial refresh routine:

```swift
/// Refreshes every SSH-backed workspace serially. No-op for local workspaces.
/// Reentry-guarded so overlapping triggers (timer + window focus, or back-to-back)
/// don't stack SSH connections.
private func refreshAllRemoteWorkspaces() async {
    guard !isRefreshingRemotes else { return }
    let remotes = workspaces.filter { $0.sshTarget != nil && !$0.isArchived }
    guard !remotes.isEmpty else { return }
    isRefreshingRemotes = true
    defer { isRefreshingRemotes = false }
    for workspace in remotes {
        await refreshWorkspace(workspace)
    }
}
```

### Lifecycle

`WorkspaceStore` is constructed once at app launch and lives for the entire
app lifetime. There is no need for a `deinit` to invalidate the timer or
remove the observer — the OS reclaims them on process exit. (If
`WorkspaceStore` is ever made non-singleton in the future, a `deinit` should
be added; flag this in a comment so the next maintainer knows.)

## Data Flow

```
[Trigger A] Timer fires every 30s
[Trigger B] NSWindow.didBecomeKeyNotification posted
        ↓ (both triggers)
Task { @MainActor in refreshAllRemoteWorkspaces() }
        ↓
guard !isRefreshingRemotes else { return }    // reentry guard
filter workspaces where sshTarget != nil      // skip local
guard !remotes.isEmpty else { return }        // skip if no remotes
isRefreshingRemotes = true
        ↓
for workspace in remotes:
    await refreshWorkspace(workspace)
        ↓
        gitService.inspectRepository(remotePath:, sshTarget:)
        ↓
        merged worktree list, branch, status updated on workspace
        ↓
        objectWillChange.send()  → sidebar rebuilds
        ↓
isRefreshingRemotes = false
```

## Error Handling

| Condition | Behavior |
|---|---|
| ssh times out / connection refused | `refreshWorkspace` already catches and silently swallows errors. The workspace keeps its previous state. Next tick will retry. |
| ssh prompts for password (BatchMode disabled) | Same as above — the inspect call fails, error is swallowed. The CLI script in `inspectRepository(remotePath:sshTarget:)` already passes `-o BatchMode=yes` so this is safe. |
| User adds a new remote workspace mid-tick | The new workspace is in `workspaces` after the next tick; it will be picked up on the next 30s poll, or immediately on next window focus. |
| User removes a remote workspace mid-tick | If the removed workspace was already iterated, no harm. If still pending, the loop variable still references it but `refreshWorkspace` will run against its old state — this is harmless because the workspace's UI is gone. |
| Reentry from focus + timer firing in quick succession | `isRefreshingRemotes` guard drops the second trigger. The next 30s tick or focus event will recover any missed state. |

## Edge Cases

1. **No remote workspaces** → `refreshAllRemoteWorkspaces` early-returns
   after the empty filter check. Timer keeps spinning but the per-tick cost
   is one filter pass over a small array. Negligible.
2. **Many remote workspaces** → serial iteration ensures we never have more
   than one ssh connection open at a time. Total tick duration scales with
   N × per-ssh latency. If a user has 10 remotes at ~2s each, a tick takes
   ~20s, which is fine because the next tick is 30s away.
3. **Mid-tick window focus** → reentry guard drops the focus trigger.
   Acceptable: the in-flight tick will complete and the user only waits the
   remaining tick time, which is bounded by the SSH per-call latency.
4. **App enters background then foreground rapidly** → focus notification
   fires once per `becomeKey`; reentry guard handles bursts.

## Out of Scope

- User-configurable poll interval. The constant
  `remoteRefreshInterval = 30` is hard-coded. If user feedback warrants it
  later, surface as an `AppSettings` field.
- SSH connection multiplexing or persistent ssh sessions.
- Server-side `inotifywait`-based push notifications.
- Differential refresh (only re-fetch when something changed) — the cost
  of the full inspection is acceptable for now.
- Background task scheduling when app is hidden.

## Files Changed

- `Treemux/App/WorkspaceStore.swift`
  - Add `remoteRefreshInterval` static constant
  - Add `remoteRefreshTimer`, `remoteWindowObserver`, `isRefreshingRemotes`
    private members
  - Add `startRemoteWorkspaceRefreshScheduler()` private method
  - Add `refreshAllRemoteWorkspaces()` private method
  - Call `startRemoteWorkspaceRefreshScheduler()` from `init()`

## Testing

### Unit Tests

The new logic is tightly coupled to `Timer.scheduledTimer` and
`NSWindow.didBecomeKeyNotification`, both of which are awkward to unit-test
without a window/runloop fixture. The dispatch is also wired directly inside
`init()` for simplicity. We will not add unit tests for the scheduler
itself; instead the existing `refreshWorkspace` integration tests
(`refreshWorkspace` with an SSH target) and manual acceptance below will
cover the feature.

### Manual Acceptance

1. Add an SSH remote workspace pointing to a server with at least one
   linked worktree → sidebar shows the worktree.
2. From an external ssh terminal: `git worktree add ../wt-test -b feat/test`
   on that server → within ~30 seconds the sidebar shows `wt-test`. ✅
3. From an external ssh terminal: `git worktree remove ../wt-test`
   → within ~30 seconds the sidebar removes `wt-test`. ✅
4. Switch focus to another app, then `git worktree add ../wt-2 -b feat/2`
   on the server, then click back into Treemux → `wt-2` appears
   immediately (within 1-3 seconds, bounded by ssh latency). ✅
5. Local workspaces continue to refresh in real time as before
   (regression check). ✅
6. With no remote workspaces, the timer should still fire silently with
   no observable cost (verify in Activity Monitor or Console.app). ✅
