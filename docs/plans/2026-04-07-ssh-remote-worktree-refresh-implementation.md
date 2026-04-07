# SSH Remote Workspace Auto-Refresh Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a hybrid pull strategy (30 second periodic poll + immediate refresh on `NSWindow.didBecomeKeyNotification`) to keep SSH-backed workspaces' worktree lists in sync with the remote server, since local fsevents cannot reach across SSH.

**Architecture:** A new private scheduler inside `WorkspaceStore` owns a `Timer` and an `NSWindow.didBecomeKeyNotification` observer. Both triggers call a single serial-refresh routine (`refreshAllRemoteWorkspaces`) protected by an `isRefreshingRemotes` reentry guard. The routine filters `workspaces` for `sshTarget != nil` and serially `await`s the existing `refreshWorkspace(_:)` (which already supports SSH).

**Tech Stack:** Swift, AppKit (`NSWindow.didBecomeKeyNotification`), Foundation `Timer`.

**Worktree:** `.worktrees/feat+worktree-auto-refresh/` (branch: `feat/worktree-auto-refresh`)

**Design doc:** `docs/plans/2026-04-07-ssh-remote-worktree-refresh-design.md`

---

## Pre-Flight

```bash
pwd
# Expected: /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+worktree-auto-refresh
git branch --show-current
# Expected: feat/worktree-auto-refresh
```

If not in the worktree, `cd` into it before continuing.

---

## Task 1: Add the scheduler members and methods

**File:** `Treemux/App/WorkspaceStore.swift`

This is a single-file change that introduces five new pieces:
1. A static `remoteRefreshInterval` constant
2. Three new private stored properties (`remoteRefreshTimer`, `remoteWindowObserver`, `isRefreshingRemotes`)
3. A `startRemoteWorkspaceRefreshScheduler()` private method
4. A `refreshAllRemoteWorkspaces()` private async method
5. A call to `startRemoteWorkspaceRefreshScheduler()` from `init()`

We are not adding tests for this scheduler — see "Testing strategy" below for the rationale.

### Step 1: Locate and read `WorkspaceStore.swift`

Open `Treemux/App/WorkspaceStore.swift` and find:
- The existing private members block (around lines 40-44, where `settingsPersistence`, `workspaceStatePersistence`, `gitService`, `metadataWatcher`, `tmuxService` are declared)
- The `init()` method (around line 120)
- The end of the class (the very last `}` before the `// MARK: - Sidebar Icon Customization` block, around line 561)

### Step 2: Add the new private members

In the existing private-members block (immediately after `private let tmuxService = TmuxService()`), add:

```swift
    /// How often to poll SSH-backed workspaces for git state changes.
    /// File system events cannot reach across SSH, so we fall back to a
    /// generous periodic poll plus an immediate refresh on window focus.
    private static let remoteRefreshInterval: TimeInterval = 30

    /// Timer that periodically polls SSH-backed workspaces. Created in `init`
    /// and lives for the entire app lifetime — `WorkspaceStore` is a long-lived
    /// singleton, so no `deinit` cleanup is required. If `WorkspaceStore` ever
    /// becomes non-singleton, add a deinit that invalidates this timer and
    /// removes `remoteWindowObserver`.
    private var remoteRefreshTimer: Timer?

    /// Notification observer that immediately refreshes SSH-backed workspaces
    /// when any Treemux window becomes key. See `remoteRefreshTimer` for
    /// lifetime notes.
    private var remoteWindowObserver: NSObjectProtocol?

    /// Reentry guard for `refreshAllRemoteWorkspaces`. Drops overlapping
    /// triggers (e.g. timer firing while a window-focus refresh is in flight).
    private var isRefreshingRemotes = false
```

### Step 3: Wire the scheduler from `init()`

Find `init()` (around line 120). The current body is:

```swift
init() {
    self.settings = settingsPersistence.load()
    loadWorkspaceState()
    ensureDefaultTerminal()
}
```

Add a call to the new scheduler at the end:

```swift
init() {
    self.settings = settingsPersistence.load()
    loadWorkspaceState()
    ensureDefaultTerminal()
    startRemoteWorkspaceRefreshScheduler()
}
```

### Step 4: Add the scheduler method

Find a logical place to add the new method. The cleanest spot is at the end of the `// MARK: - Refreshing` section (right after the closing brace of `refreshWorkspace`, before `// MARK: - Persistence`). Add:

```swift
    /// Sets up the periodic timer and window-focus observer that drive
    /// `refreshAllRemoteWorkspaces`. Called once from `init()`.
    private func startRemoteWorkspaceRefreshScheduler() {
        remoteRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: Self.remoteRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAllRemoteWorkspaces()
            }
        }

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

    /// Refreshes every SSH-backed workspace serially. No-op for local workspaces.
    /// Reentry-guarded so overlapping triggers (timer + window focus, or
    /// back-to-back) don't stack SSH connections.
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

### Step 5: Build to verify it compiles

```bash
xcodebuild build \
  -project Treemux.xcodeproj \
  -scheme Treemux \
  -destination 'platform=macOS'
```

Expected: `** BUILD SUCCEEDED **`.

If the build fails:
- "Cannot find 'NSWindow' in scope" → `WorkspaceStore.swift` already imports `SwiftUI`, which transitively imports AppKit on macOS targets, so this should not happen. If it does, add `import AppKit` at the top of the file.
- Any other error: read the message and fix the actual issue. Don't guess.

### Step 6: Run the existing test suite

```bash
xcodebuild test \
  -project Treemux.xcodeproj \
  -scheme Treemux \
  -destination 'platform=macOS' \
  -only-testing:TreemuxTests
```

Expected: all 115 tests pass (no regression).

Note: there is one risk — if any existing test instantiates `WorkspaceStore` directly, the new `init()` will start a real `Timer` and observer, which may leak between tests. If you see test failures with messages about timer firing or unexpected observer callbacks, the fix is to make the scheduler init opt-out via a flag in `init`, but **only** if a test actually needs it. **Try the tests first** before making any preemptive changes.

### Step 7: Commit

```bash
git add Treemux/App/WorkspaceStore.swift
git commit -m "$(cat <<'EOF'
feat(store): add periodic + focus-driven refresh for SSH workspaces

File system events cannot reach across SSH, so SSH-backed workspaces
were never auto-refreshed after launch. Add a hybrid pull strategy:

- A 30-second `Timer` that polls every SSH-backed workspace
- An `NSWindow.didBecomeKeyNotification` observer that triggers an
  immediate refresh whenever any Treemux window becomes key

Both triggers call the same serial routine (refreshAllRemoteWorkspaces)
which filters for sshTarget != nil and reuses the existing
refreshWorkspace pipeline. A reentry guard drops overlapping triggers
so we never stack SSH connections.

Closes the gap left by the local fsevents-based auto-refresh
(commits b08fba1, 6e9657e, a08062c).
EOF
)"
```

---

## Task 2: Manual Acceptance

**Files:** none

This is verification only. Do not commit anything for this task.

### Step 1: Build Debug

```bash
xcodebuild build \
  -project Treemux.xcodeproj \
  -scheme Treemux \
  -configuration Debug \
  -destination 'platform=macOS'
```

Expected: `** BUILD SUCCEEDED **`.

### Step 2: Find the DerivedData folder

```bash
ls -dt ~/Library/Developer/Xcode/DerivedData/Treemux-*/Build/Products/Debug/Treemux.app | head -1
```

Use this exact path in the run command for 卡皮巴拉.

### Step 3: Tell 卡皮巴拉 the run command

```
rm -rf ~/.treemux-debug/ && open <the-path-from-step-2>
```

### Step 4: 卡皮巴拉 runs the acceptance checklist

The checklist is documented in the design doc's "Manual Acceptance" section:

1. Add an SSH remote workspace pointing to a server with at least one linked worktree → sidebar shows the worktree.
2. From an external ssh terminal: `git worktree add ../wt-test -b feat/test` on that server → within ~30 seconds the sidebar shows `wt-test`.
3. From an external ssh terminal: `git worktree remove ../wt-test` → within ~30 seconds the sidebar removes `wt-test`.
4. Switch focus to another app, then `git worktree add ../wt-2 -b feat/2` on the server, then click back into Treemux → `wt-2` appears immediately (within 1-3 seconds, bounded by ssh latency).
5. Local workspaces continue to refresh in real time (regression check).
6. With no remote workspaces, the timer should still fire silently with no observable cost.

If any step fails, gather logs (`Console.app` filtered by Treemux process) and stop.

---

## Notes for the Implementer

- **Read the design doc first**: `docs/plans/2026-04-07-ssh-remote-worktree-refresh-design.md` (in this same worktree).
- **All comments in English**, communication in Chinese (call the user 卡皮巴拉).
- **No new tests**: see "Testing strategy" below.
- **No scope creep**: do not add user-configurable polling intervals, do not extract a `RemoteRefreshScheduler` class, do not add a Settings UI for this. The whole feature is one Timer + one observer + one method, all in `WorkspaceStore`.
- **No deinit cleanup**: `WorkspaceStore` is a long-lived singleton. Document this with the comments above the new properties.
- **Pattern note**: the existing `WorkspaceStore` uses many `Task { @MainActor in ... }` invocations from closures that capture `[weak self]`. Match that style.

## Testing strategy

The new scheduler is tightly coupled to `Timer.scheduledTimer` and `NSWindow.didBecomeKeyNotification`, both of which require a runloop and (for the observer) a real `NSWindow`. Wrapping these in mockable abstractions just to write a unit test would add significant complexity for a 20-line feature. The risk-to-test-cost ratio is poor.

What we lose: no automated coverage of the timer firing, the observer being installed, or the reentry guard.

What we have instead:
- The serial-refresh routine reuses `refreshWorkspace`, which is already exercised by `GitRepositoryServiceTests` indirectly (via `inspectRepository(at:)`).
- The reentry guard logic is trivial (one boolean check) and code-reviewable by inspection.
- The manual acceptance checklist directly validates the user-facing behavior in 6 steps.

If a future bug surfaces that needs regression coverage, we can extract the scheduler into a smaller testable type at that time.
