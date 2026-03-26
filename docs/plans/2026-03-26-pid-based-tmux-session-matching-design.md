# PID-Based Tmux Session Matching Design

**Date**: 2026-03-26
**Status**: Approved

## Problem

When multiple panes rapidly launch bare `tmux` (without `-s`), the current fallback
uses a "most recently created session" heuristic (`tmux list-sessions | sort -rn | head -1`)
after a fixed 1.5-second delay. This causes:

1. **Session mismatch** — multiple panes may resolve to the same session
2. **Unnecessary delay** — the 1.5s wait is a hard-coded workaround
3. **No PID tracking** — `managedPID` returns `nil` (Ghostty C API limitation), preventing
   precise pane-to-process correlation

## Approach

**App PID process tree + `TREEMUX_PANE_ID` environment variable** (Approach A, Sub-approach 1).

Instead of relying on Ghostty to expose child PIDs, use macOS `sysctl` APIs to walk the
process tree rooted at the Treemux app PID. Each pane injects a unique environment variable
(`TREEMUX_PANE_ID`) into its shell, enabling precise mapping from process → pane.

## Design

### 1. ProcessTree Utility

New file: `Treemux/Services/System/ProcessTree.swift`

Provides static methods wrapping macOS `sysctl`:

- **`allProcesses() -> [ProcessEntry]`** — `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_ALL)`,
  returns `(pid, parentPID, command)` tuples for all processes.
- **`descendants(of pid: pid_t) -> Set<pid_t>`** — builds parent→children map from
  `allProcesses()`, BFS traversal from root PID.
- **`processEnvironment(pid: pid_t) -> [String: String]?`** — `sysctl(CTL_KERN, KERN_PROCARGS2, pid)`,
  parses the `argc + execpath + NULLs + argv + NULLs + env` memory layout.
- **`findDescendant(of rootPID: pid_t, envKey: String, envValue: String) -> pid_t?`** —
  iterates descendants, reads each process's environment, returns first match.

All methods are `nonisolated static`. Only reads same-user processes (no special entitlements needed).

### 2. TREEMUX_PANE_ID Injection

In `ShellSession.init()` and `ShellSession.start()`, inject `TREEMUX_PANE_ID=<pane-uuid>`
into the base environment before calling `makeLaunchConfiguration()`:

```
baseEnv = Self.defaultEnvironment()
baseEnv["TREEMUX_PANE_ID"] = id.uuidString
launchConfiguration = backendConfiguration.makeLaunchConfiguration(
    preferredWorkingDirectory: ...,
    baseEnvironment: baseEnv
)
```

The variable propagates through the existing chain:
`defaultEnvironment()` → `makeLaunchConfiguration()` → `ShellIntegration.prepare()` →
Ghostty `env_vars` → forked shell → tmux client (inherited).

No changes needed to `SessionBackendLaunch.swift`, `TreemuxGhosttyShellIntegration.swift`,
or `TreemuxGhosttyController.swift`.

### 3. Shell PID Discovery (Replacing managedPID)

Replace `syncManagedProcessStateAfterLaunch()` with `resolveShellPID()`:

```
resolveShellPID()
  └─ Task (background)
       ├─ appPID = ProcessInfo.processInfo.processIdentifier
       ├─ Retry loop (max ~2s, every 200ms):
       │    └─ ProcessTree.findDescendant(of: appPID,
       │         envKey: "TREEMUX_PANE_ID", envValue: self.id.uuidString)
       ├─ Found → self.pid = shellPID
       └─ Timeout → keep nil, log warning
```

`TreemuxGhosttyController.managedPID` stays `nil` — the two are decoupled.

### 4. Exact Tmux Session Matching

Replace `resolveRecentTmuxSession()` with `resolveExactTmuxSession()`:

```
resolveExactTmuxSession()
  └─ Task (background)
       ├─ 1. Wait for self.pid (from resolveShellPID), max 3s
       ├─ 2. Poll for tmux client in process tree (max 3s, every 300ms):
       │      descendants = ProcessTree.descendants(of: shellPID)
       │      check for tmux client process among descendants
       ├─ 3. Cross-reference with tmux list-clients:
       │      tmux list-clients -F '#{client_pid} #{session_name}'
       │      find row where client_pid ∈ descendants → extract session_name
       └─ 4. MainActor: self.detectedTmuxSession = sessionName
```

| Aspect        | Old                                | New                                 |
|---------------|------------------------------------|-------------------------------------|
| Matching      | Most recent session (heuristic)    | PID-exact (process tree)            |
| Precision     | May mismatch under concurrency     | One-to-one, pane-isolated           |
| Latency       | Fixed 1.5s                         | Adaptive polling, typically < 1s    |
| Concurrency   | Multiple panes race to same result | Each pane finds its own client      |

Edge cases:
- **tmux server not yet started**: retry loop covers the startup time.
- **Nested tmux**: `descendants(of: shellPID)` scopes to current pane's subtree only.
- **Resolution timeout**: placeholder `"tmux"` remains; `snapshot()` filters it out (no persist). Graceful degradation.

### 5. Cleanup

**Remove:**
- `resolveRecentTmuxSession()` (ShellSession.swift) — 1.5s delay + placeholder logic
- `findMostRecentTmuxSession()` (ShellSession.swift) — "newest session" heuristic query

**Keep unchanged:**
- `detectTmux(fromTitle:)` — both detection patterns intact; only the bare-tmux branch
  calls `resolveExactTmuxSession()` instead of `resolveRecentTmuxSession()`
- `parseTmuxSessionName(from:)` — `-s` / `-t` parsing (no PID needed)
- `snapshot()` placeholder filter — safety net for timeout cases
- `WorkspaceModels.swift`, `WorkspaceSessionController.swift`, `SessionBackendLaunch.swift`,
  `TreemuxGhosttyController.swift` — no changes

**New file:** `Treemux/Services/System/ProcessTree.swift` (only new file)

## Data Flow Summary

### Save (unchanged)
```
User runs "tmux new -s hello"
→ preexec sets title "tmux new -s hello"
→ detectTmux parses "hello" → detectedTmuxSession = "hello"
→ snapshot() persists PaneSnapshot.detectedTmuxSession = "hello"
```

### Save (bare tmux, NEW)
```
User runs "tmux"
→ preexec sets title "tmux"
→ detectTmux: no -s flag → placeholder "tmux"
→ resolveExactTmuxSession():
    shell PID (via TREEMUX_PANE_ID) → tmux client descendant
    → tmux list-clients → session_name = "0"
→ detectedTmuxSession = "0"
→ snapshot() persists PaneSnapshot.detectedTmuxSession = "0"
```

### Restore (unchanged)
```
Load PaneSnapshot, detectedTmuxSession = "hello"
→ backend = .tmuxAttach(sessionName: "hello")
→ zsh --login -c "exec tmux attach-session -t hello"
```
