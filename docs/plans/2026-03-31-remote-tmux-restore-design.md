# Remote Tmux Session Restore Design

**Date**: 2026-03-31
**Status**: Approved

## Problem

Remote SSH panes do not restore tmux sessions on app restart, while local panes do.

### Root Causes

**Bug 1 — Detection failure**: Tmux session detection relies on Ghostty shell integration's preexec title reporting (`GHOSTTY_SHELL_FEATURES`), which is only available in the local shell. Remote shells over SSH lack this env var, so `detectTmux(fromTitle:)` never fires for remote panes. The local process tree fallback (`resolveExactTmuxSession`) also fails because the tmux client runs on the remote host, not locally.

**Bug 2 — Missing `-t` flag**: `SessionBackendLaunch.swift` does not add `-t` (force PTY allocation) to SSH args in the `.tmuxAttach` remote branch. Without a PTY, `tmux attach-session` fails on the remote.

### Evidence

- `workspace-state.json` shows no `detectedTmuxSession` field for any remote pane snapshot.
- The `.tmuxAttach` remote case (lines 110-132) lacks `-t`, while the regular `.ssh` case (line 69) correctly adds it.

## Solution: B+D Hybrid

Two-layer detection (title-triggered + save-time) plus a one-line bug fix.

```
Title change (D)  →  SSH probe  →  set detectedTmuxSession  →  snapshot picks it up
Save time (B)     →  SSH probe  →  set detectedTmuxSession  →  snapshot picks it up
Restore           →  ssh -t host "tmux attach -t <name>"     (Bug 2 fix)
```

### 1. Bug 2 Fix: Add `-t` to Remote Tmux Attach

In `SessionBackendLaunch.swift`, `.tmuxAttach` remote branch, insert `-t` into SSH args before the destination.

### 2. SSH Probe Infrastructure

Add to `ShellSession`:

- `probeRemoteTmuxSession()` — async method that SSHs into the remote and runs `tmux list-sessions -F '#{session_name}' 2>/dev/null`. Uses `BatchMode=yes` and `ConnectTimeout=5` to avoid interactive prompts and long waits. Parses output, takes first session name, sets `detectedTmuxSession`.
- `queryRemoteTmuxSessions(target:)` — static helper that builds SSH args from `SSHTarget` and executes the probe process.

### 3. D: Title-Change-Triggered Probe (Primary)

In `configureSurfaceCallbacks()`, after `detectTmux(fromTitle:)`, call `probeRemoteTmuxIfNeeded()`.

Guard conditions:
- Backend is `.ssh`
- `detectedTmuxSession` is nil
- Debounce: at least 5 seconds since last probe

Rationale: When tmux starts on the remote, the inner shell's prompt often sets the terminal title via escape sequences. These flow through SSH to Ghostty, triggering `onTitleChange`. This event signals that the terminal state changed, making it a natural trigger for the probe.

### 4. B: Save-Time Probe (Safety Net)

In `TreemuxApp.shutdown()`, before `saveWorkspaceState()`:

- Collect all SSH panes with `detectedTmuxSession == nil`
- Run SSH probes concurrently via `WorkspaceSessionController.probeAllRemoteTmuxSessions()`
- Total timeout: 3 seconds
- Then proceed with normal save

Covers edge cases where D misses (e.g., remote tmux has `set-titles off` and the inner shell doesn't set terminal title).

### 5. Restore Path

No changes needed. Existing mechanism in `WorkspaceSessionController.convenience init` already converts `.ssh` backend to `.tmuxAttach` when `detectedTmuxSession` is present. The Bug 2 fix ensures the resulting SSH command includes `-t`.

## Files Changed

| File | Change |
|------|--------|
| `SessionBackendLaunch.swift` | Add `-t` to `.tmuxAttach` remote SSH args |
| `ShellSession.swift` | Add `probeRemoteTmuxSession()`, `probeRemoteTmuxIfNeeded()`, `queryRemoteTmuxSessions(target:)`; modify `onTitleChange` callback |
| `WorkspaceSessionController.swift` | Add `probeAllRemoteTmuxSessions()` for save-time batch probing |
| `TreemuxApp.swift` | Call save-time probe in `shutdown()` |
