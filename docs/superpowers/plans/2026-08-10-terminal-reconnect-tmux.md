# Terminal Reconnect and tmux Restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reset one terminal pane in place and reattach its detected local or remote tmux session without changing the split layout.

**Architecture:** A pure resolver maps the original backend plus runtime tmux name to a one-shot reconnect backend. `ShellSession` owns the reconnect state machine and drives its existing managed surface in terminate/update/start order; `TerminalPaneView` provides confirmation and recovery controls.

**Tech Stack:** Swift 5, Observation, SwiftUI/AppKit, XCTest, XcodeGen, `xcodebuild`.

## Global Constraints

- Work only in `codex/feat/terminal-reconnect-tmux`; primary checkout stays on `main`.
- Keep pane/tab/layout/zoom identities stable and never mutate the persisted original backend.
- Ignore generic runtime tmux value `tmux`.
- Missing tmux never creates a replacement session.
- User-visible strings include `zh-Hans`; colors use theme tokens; comments use English.

---

### Task 1: Pure reconnect backend resolver

**Files:** Create `Treemux/Services/Terminal/ReconnectBackendResolver.swift`; modify `TreemuxTests/SessionBackendTests.swift`.

- [ ] Add failing tests for local, SSH, local tmux, remote tmux, existing attach backend, generic `tmux`, and shell fallback.
- [ ] Run the focused resolver tests and confirm missing API failures.
- [ ] Implement `resolve(originalBackend:detectedTmuxSession:)` and `shellFallback(for:)` with exact `SessionBackendConfiguration` results.
- [ ] Rerun focused tests and commit.

### Task 2: ShellSession reconnect lifecycle

**Files:** Modify `Treemux/Services/Terminal/ShellSession.swift`; create `TreemuxTests/ShellSessionReconnectTests.swift`.

**Interfaces:** Produce `reconnect()`, `retryReconnect()`, `startShellAfterReconnectFailure()`, `isReconnecting`, and `reconnectError`.

- [ ] Use a fake managed surface to write failing tests for terminate/update/start call order, stale-state clearing, focus preservation, duplicate suppression, attach failure, retry, and shell fallback.
- [ ] Implement the minimal state machine while keeping `backendConfiguration` immutable.
- [ ] Run the focused session tests and commit.

### Task 3: Pane header controls and localization

**Files:** Modify `Treemux/UI/Workspace/TerminalPaneView.swift` and `Treemux/Localizable.xcstrings`; create `TreemuxTests/TerminalReconnectPresentationTests.swift` if an additional pure presentation seam is needed.

- [ ] Add reset button next to close, localized help/accessibility, confirmation, progress animation, and failure recovery buttons.
- [ ] Verify every new key has `zh-Hans` and every visible color uses a theme token.
- [ ] Run terminal-focused suites and commit.

### Task 4: Branch verification

- [ ] Run SessionBackend, ShellSession reconnect/dedup, pane layout, and tmux suites.
- [ ] Run all `TreemuxTests` and a Debug build.
- [ ] Inspect `git diff --check`, localization JSON, and exact DerivedData app path.
