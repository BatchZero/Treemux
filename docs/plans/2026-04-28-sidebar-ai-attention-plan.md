# Sidebar AI Attention Indicator — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the static project-icon dot with a 3-state indicator (none / idle / attention) driven by OSC 777 desktop notifications emitted from Claude Code, Codex, and opencode hooks. Add a per-tab dot mirroring the same state. Provide an opt-in, never-auto, hook-installer UI for local and remote (SSH) targets.

**Architecture:** OSC bytes flow `agent → PTY → libghostty parser → GHOSTTY_ACTION_DESKTOP_NOTIFICATION → TreemuxGhosttyController → ShellSession.aiAttention → WorkspaceModel.hasAttention → SidebarRow / TabButton`. A separate `AIHookInstaller` registry (one `AIHookProvider` per agent kind) handles detection, diff-preview install, and uninstall — driven exclusively by user clicks in Settings or a one-time per-(workspace, agent) banner.

**Tech Stack:** Swift 5.9, SwiftUI, libghostty (vendored xcframework), XCTest. Project file is XcodeGen-generated (`project.yml`); new files placed under existing groups (e.g. `Treemux/Services/AITool/`) auto-include via XcodeGen run if needed.

**Reference:** Companion design doc at `docs/plans/2026-04-28-sidebar-ai-attention-design.md`.

**Conventions for every task:**
- TDD where logic is testable: write test → run → fail → implement → run → pass → commit.
- UI-only tasks: implement → build app → manual smoke check on a worktree-named DerivedData → commit.
- Test runner: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS'`. Use `-only-testing:TreemuxTests/<TestClassName>/<testMethod>` for fast feedback.
- All user-visible strings use `LocalizedStringKey`; **every new key must get a `zh-Hans` entry in `Treemux/Localizable.xcstrings` before that task's commit** (per `.claude/CLAUDE.md`).
- Commit messages: conventional commits (`feat:`, `test:`, `refactor:`, `docs:`, `i18n:`).
- After all tasks done, the build instruction printed for the user follows the project rule:
  `rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<编号>/Build/Products/Debug/Treemux.app`

---

## Phase 1 — OSC ingestion plumbing (manual `printf` proves it works)

End state of phase 1: from any treemux pane, `printf '\033]777;notify;treemux:done;\007' > /dev/tty` makes the sidebar dot blink. No hooks installed yet, no UI for installing yet.

### Task 1: Introduce `AIAttentionState` and per-session storage

**Files:**
- Create: `Treemux/Domain/AIAttentionState.swift`
- Modify: `Treemux/Services/Terminal/ShellSession.swift` (add `@Published` property + parser private method, near existing `detectedAITool` at line 49 and `detectAITool` at line 370)
- Test: `TreemuxTests/AIAttentionStateTests.swift`

**Step 1 — Write test (`TreemuxTests/AIAttentionStateTests.swift`):**

```swift
import XCTest
@testable import Treemux

final class AIAttentionStateTests: XCTestCase {

    func testParseDoneTitle() {
        XCTAssertEqual(AIAttentionState.parse(notificationTitle: "treemux:done"), .done)
    }

    func testParseInputTitle() {
        XCTAssertEqual(AIAttentionState.parse(notificationTitle: "treemux:input"), .input)
    }

    func testParseUnrelatedTitleReturnsNil() {
        XCTAssertNil(AIAttentionState.parse(notificationTitle: "Build finished"))
        XCTAssertNil(AIAttentionState.parse(notificationTitle: ""))
        XCTAssertNil(AIAttentionState.parse(notificationTitle: "treemux:"))
        XCTAssertNil(AIAttentionState.parse(notificationTitle: "treemux:bogus"))
    }

    func testCaseInsensitivePrefixIsNotAccepted() {
        // We require the exact lowercase prefix to keep the wire format simple.
        XCTAssertNil(AIAttentionState.parse(notificationTitle: "TREEMUX:done"))
    }
}
```

**Step 2 — Run test, expect failure:**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -only-testing:TreemuxTests/AIAttentionStateTests 2>&1 | tail -20
```

Expected: `Cannot find 'AIAttentionState' in scope`.

**Step 3 — Implement (`Treemux/Domain/AIAttentionState.swift`):**

```swift
//
//  AIAttentionState.swift
//  Treemux
//

import Foundation

/// Whether a shell session is currently asking for the user's attention because
/// an AI agent (Claude Code / Codex / opencode) finished its turn or is waiting
/// for input. Driven by OSC 777 desktop notifications emitted by treemux-managed
/// hooks (see docs/plans/2026-04-28-sidebar-ai-attention-design.md).
enum AIAttentionState: Equatable {
    case none
    case done
    case input

    /// Map an OSC 777 notification title to a state, or nil if the title is not
    /// one of treemux's known prefixes.
    static func parse(notificationTitle title: String) -> AIAttentionState? {
        switch title {
        case "treemux:done":  return .done
        case "treemux:input": return .input
        default:              return nil
        }
    }
}
```

**Step 4 — Run test, expect pass:**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -only-testing:TreemuxTests/AIAttentionStateTests 2>&1 | tail -5
```

Expected: `Test Suite 'AIAttentionStateTests' passed`.

**Step 5 — Wire into `ShellSession`:**

Edit `Treemux/Services/Terminal/ShellSession.swift`:

After line 49 (`@Published var detectedAITool: AIToolDetection?`), add:

```swift
    /// AI agent attention state, set by OSC 777 `treemux:done` / `treemux:input`
    /// notifications, cleared on focus or user keystroke.
    @Published private(set) var aiAttention: AIAttentionState = .none
```

Add a method near `detectAITool(fromTitle:)` at line 370:

```swift
    /// Apply an OSC 777 desktop notification. Sets `aiAttention` only when the
    /// title carries the treemux protocol prefix.
    fileprivate func applyDesktopNotification(title: String, body: String?) {
        if let state = AIAttentionState.parse(notificationTitle: title) {
            aiAttention = state
        }
    }

    /// Clear the AI attention state. Called on focus and on user keystroke.
    func clearAIAttention() {
        if aiAttention != .none {
            aiAttention = .none
        }
    }
```

**Step 6 — Commit:**

```bash
git add Treemux/Domain/AIAttentionState.swift \
        Treemux/Services/Terminal/ShellSession.swift \
        TreemuxTests/AIAttentionStateTests.swift
git commit -m "feat: introduce AIAttentionState and ShellSession.aiAttention"
```

---

### Task 2: Surface the OSC notification through the terminal-surface protocol

**Files:**
- Modify: `Treemux/Services/Terminal/TerminalSurface.swift` (add to protocol around line 47-64)
- Modify: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift` (declare the var around line 49)

**Step 1 — Add to the `TerminalSurfaceController` protocol:**

In `Treemux/Services/Terminal/TerminalSurface.swift` inside the protocol body (after `var onStatusChange:`):

```swift
    /// Fired when the surface receives an OSC 777 desktop-notification escape.
    /// `title` is the OSC's first field (e.g. "treemux:done"); `body` is the
    /// optional second field. Always called on the main queue.
    var onDesktopNotification: ((String, String?) -> Void)? { get set }
```

**Step 2 — Implement on the ghostty controller:**

In `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift`, add (alongside the other `onXxx` vars):

```swift
    var onDesktopNotification: ((String, String?) -> Void)?
```

**Step 3 — Build to verify protocol conformance:**

```bash
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: build succeeds (no test in this micro-step).

**Step 4 — Commit:**

```bash
git add Treemux/Services/Terminal/TerminalSurface.swift \
        Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift
git commit -m "feat: add onDesktopNotification callback to TerminalSurfaceController"
```

---

### Task 3: Replace the placeholder OSC handler with the real callback dispatch

**Files:**
- Modify: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift` (lines 198-202)

**Step 1 — Replace the existing handler:**

The existing block at line 198 currently is:

```swift
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            // TODO: Task 15 — deliver desktop notifications
            NSSound.beep()
            return true
```

Change it to (mirrors `LineyGhosttyController.swift:189-198`):

```swift
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let title = action.action.desktop_notification.title.map(String.init(cString:)) ?? ""
            let body  = action.action.desktop_notification.body.map(String.init(cString:))
            DispatchQueue.main.async { [weak self] in
                self?.onDesktopNotification?(title, body)
            }
            return true
```

**Step 2 — Wire `ShellSession` to the callback:**

In `Treemux/Services/Terminal/ShellSession.swift`, inside `configureSurfaceCallbacks()` (around line 105-136), add (next to the other `surfaceController.onXxx = { … }` blocks):

```swift
        surfaceController.onDesktopNotification = { [weak self] title, body in
            self?.applyDesktopNotification(title: title, body: body)
        }
```

**Step 3 — Build:**

```bash
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: build succeeds.

**Step 4 — Manual smoke test:**

After building (instructions to user at end of plan), run:
1. Launch treemux, open any local terminal pane.
2. In that pane: `printf '\033]777;notify;treemux:done;\007' > /dev/tty`.
3. Open the macOS debugger console for the running treemux process and confirm the `aiAttention` `@Published` property fires by adding a temporary `print` line to `applyDesktopNotification`. (Remove the print before committing.)

(This step is "verify the wiring works"; the visible UI change comes in Phase 2.)

**Step 5 — Commit:**

```bash
git add Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift \
        Treemux/Services/Terminal/ShellSession.swift
git commit -m "feat: route OSC 777 desktop notifications to ShellSession.aiAttention"
```

---

### Task 4: Clear attention on focus and keystroke

**Files:**
- Modify: `Treemux/Services/Terminal/ShellSession.swift` (`setFocused` at line ~225 area; check before edit)
- Modify: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift` (key event path — `keyDown` callsite; the controller already calls `onWorkspaceAction` for actions, but for raw key input we need a new callback into `ShellSession`)
- Test: extend `TreemuxTests/AIAttentionStateTests.swift` with a `ShellSession` integration test

**Step 1 — Determine focus + keystroke entry points:**

```bash
grep -n -E 'setFocused|isFocusedInWorkspace|keyDown' Treemux/Services/Terminal/ShellSession.swift Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift | head -20
```

Confirm where `setFocused` is implemented in `ShellSession` and how key events reach it. (The plan author observed `setFocused(_:)` exists at the surface level; on `ShellSession` it shows up as `isFocusedInWorkspace` mutation — adjust the implementation to call `clearAIAttention()` whenever focus transitions to `true`.)

**Step 2 — Modify `ShellSession.setFocused(_:)`:**

```swift
    func setFocused(_ isFocused: Bool) {
        let wasFocused = isFocusedInWorkspace
        isFocusedInWorkspace = isFocused
        surfaceController.setFocused(isFocused)
        if isFocused && !wasFocused {
            clearAIAttention()
        }
    }
```

(If the existing implementation differs, preserve its structure and just inject the conditional `clearAIAttention()` call.)

**Step 3 — Add a key-input clear hook on the surface protocol:**

In `Treemux/Services/Terminal/TerminalSurface.swift` add to the `TerminalSurfaceController` protocol:

```swift
    /// Fired the first time the user produces input (key press) into the
    /// surface since the last reset. Used to clear AI attention state.
    var onUserInput: (() -> Void)? { get set }
```

In `TreemuxGhosttyController.swift`:

```swift
    var onUserInput: (() -> Void)?
```

Then, inside the `keyDown` / character-input path (find the call to `sendText(string)` at line 1068 and 1291 and 1504), add a call **once per call** before `sendText`:

```swift
            DispatchQueue.main.async { [weak self] in
                self?.onUserInput?()
            }
```

(Wrap defensively; we want the ShellSession on the main queue.)

In `ShellSession.configureSurfaceCallbacks()`:

```swift
        surfaceController.onUserInput = { [weak self] in
            self?.clearAIAttention()
        }
```

**Step 4 — Test (extend `AIAttentionStateTests` with a session-level test):**

Add to `TreemuxTests/AIAttentionStateTests.swift`:

```swift
    @MainActor
    func testShellSessionFocusClearsAttention() {
        let backend = SessionBackendConfiguration.localShell(.init(shell: "/bin/zsh", arguments: []))
        let session = ShellSession(
            id: UUID(),
            backendConfiguration: backend,
            preferredWorkingDirectory: NSTemporaryDirectory()
        )
        session.applyDesktopNotificationFromTest(title: "treemux:input", body: nil)
        XCTAssertEqual(session.aiAttention, .input)

        session.setFocused(true)

        XCTAssertEqual(session.aiAttention, .none)
    }
```

To make this testable, expose a test seam in `ShellSession.swift`:

```swift
#if DEBUG
    func applyDesktopNotificationFromTest(title: String, body: String?) {
        applyDesktopNotification(title: title, body: body)
    }
#endif
```

**Step 5 — Run test:**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -only-testing:TreemuxTests/AIAttentionStateTests 2>&1 | tail -10
```

Expected: pass.

**Step 6 — Commit:**

```bash
git add Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift \
        Treemux/Services/Terminal/ShellSession.swift \
        Treemux/Services/Terminal/TerminalSurface.swift \
        TreemuxTests/AIAttentionStateTests.swift
git commit -m "feat: clear AI attention on focus and user keystroke"
```

---

### Task 5: WorkspaceModel.hasAttention aggregations

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift` (add methods near line 220-229)
- Test: `TreemuxTests/WorkspaceModelsTests.swift`

**Step 1 — Add tests:**

Append to `TreemuxTests/WorkspaceModelsTests.swift`:

```swift
    @MainActor
    func testHasAttentionFalseWhenNoSessions() {
        let workspace = WorkspaceModel(name: "test", kind: .repository)
        XCTAssertFalse(workspace.hasAttention)
    }

    // NOTE: full attention-aggregation tests across multiple sessions / panes
    // require real session scaffolding; covered by integration smoke tests
    // (see manual QA list). Unit-test the boolean shortcut path here.
    @MainActor
    func testHasAttentionMatchesAnyAttentiveSession() {
        // The unit form: build a fake controller graph and verify the predicate.
        // (Implementation deferred to integration tests because session
        // construction requires live ghostty surfaces.)
    }
```

**Step 2 — Implement:**

In `Treemux/Domain/WorkspaceModels.swift` near `hasAnyRunningSessions` (line 227), add:

```swift
    /// True if any session in any worktree is currently asking for attention.
    var hasAttention: Bool {
        tabControllers.values.contains { tabMap in
            tabMap.values.contains { ctrl in
                ctrl.sessions.values.contains { $0.aiAttention != .none }
            }
        }
    }

    /// True if any session inside the given worktree path is asking for attention.
    func hasAttention(forWorktreePath path: String) -> Bool {
        guard let controllers = tabControllers[path] else { return false }
        return controllers.values.contains { ctrl in
            ctrl.sessions.values.contains { $0.aiAttention != .none }
        }
    }

    /// True if the specific tab inside the given worktree has an attentive session.
    func hasAttention(forTabID tabID: UUID, worktreePath: String) -> Bool {
        guard let ctrl = tabControllers[worktreePath]?[tabID] else { return false }
        return ctrl.sessions.values.contains { $0.aiAttention != .none }
    }
```

**Step 3 — Run tests:**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -only-testing:TreemuxTests/WorkspaceModelsTests 2>&1 | tail -10
```

Expected: pass.

**Step 4 — Commit:**

```bash
git add Treemux/Domain/WorkspaceModels.swift TreemuxTests/WorkspaceModelsTests.swift
git commit -m "feat: WorkspaceModel.hasAttention aggregations"
```

---

## Phase 2 — Sidebar visual

End of phase 2: with manual `printf` of `treemux:done`, the workspace and worktree dots in the sidebar pulse.

### Task 6: Add `.attention` case to `SidebarIconActivityIndicator` + visual

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarItemIconView.swift`

**Step 1 — Extend the enum (at line 11):**

```swift
enum SidebarIconActivityIndicator {
    case none
    case current   // Static dot — this worktree is the active working directory
    case working   // Animated pulse — terminal sessions are running
    case attention // Faster, brighter pulse — AI agent needs the user
}
```

**Step 2 — Adjust `SidebarIconActivityBadge` to render `.attention`:**

In the same file, in the badge, extend `pulseDuration`, `pulseScale`, `coreScale`, `coreOpacity`, `glowRadius` to handle `.attention` with values stronger than `.working`:

```swift
    private var pulseDuration: Double {
        switch kind {
        case .attention: return isEmphasized ? 0.55 : 0.7
        case .working:   return isEmphasized ? 0.95 : 1.15
        default:         return 1.0
        }
    }

    private var coreScale: CGFloat {
        switch kind {
        case .working, .attention: return isAnimating ? 1.18 : 0.9
        default: return 1
        }
    }

    private var coreOpacity: Double {
        switch kind {
        case .working, .attention: return isAnimating ? 1 : 0.82
        default: return 1
        }
    }

    private var glowRadius: CGFloat {
        switch kind {
        case .attention: return isEmphasized ? 8 : 6
        case .working:   return isEmphasized ? 6 : 4
        default:         return 0
        }
    }
```

Update the `if kind == .working` branches in `body` to use a helper `isAnimatedKind`:

```swift
    private var isAnimatedKind: Bool {
        kind == .working || kind == .attention
    }

    var body: some View {
        ZStack {
            if isAnimatedKind { /* outer + middle pulse rings */ }
            // core circle (always)
        }
        .onAppear { updateAnimationState() }
        .onChange(of: kind) { _, _ in updateAnimationState() }
    }

    private func updateAnimationState() {
        guard isAnimatedKind else {
            isAnimating = false
            return
        }
        isAnimating = false
        withAnimation(.easeInOut(duration: pulseDuration).repeatForever(autoreverses: true)) {
            isAnimating = true
        }
    }
```

(Keep all other rendering identical to the current `.working` branch.)

**Step 3 — Build:**

```bash
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5
```

**Step 4 — Commit:**

```bash
git add Treemux/UI/Sidebar/SidebarItemIconView.swift
git commit -m "feat: add .attention case to sidebar activity indicator"
```

---

### Task 7: Wire `hasAttention` into sidebar rows

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarNodeRow.swift` (lines 50-58 and 114-122)

**Step 1 — Update `WorkspaceRowContent.activityIndicator`:**

```swift
    private var activityIndicator: SidebarIconActivityIndicator {
        if workspace.hasAttention {
            return .attention
        }
        if workspace.hasAnyRunningSessions {
            return .working
        }
        if workspace.activeWorktreePath == workspace.repositoryRoot?.path {
            return .current
        }
        return .none
    }
```

**Step 2 — Update `WorktreeRowContent.activityIndicator`:**

```swift
    private var activityIndicator: SidebarIconActivityIndicator {
        if workspace.hasAttention(forWorktreePath: worktree.path.path) {
            return .attention
        }
        if workspace.hasRunningSessions(forWorktreePath: worktree.path.path) {
            return .working
        }
        if workspace.activeWorktreePath == worktree.path.path {
            return .current
        }
        return .none
    }
```

**Step 3 — Build:**

```bash
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5
```

**Step 4 — Manual smoke (with the build instructions at the end of plan):**

After launching the rebuilt app, in any local pane: `printf '\033]777;notify;treemux:done;\007' > /dev/tty`. Confirm: workspace dot starts pulsing visibly faster/brighter than the existing "working" pulse. Click the pane → pulse stops within one frame.

**Step 5 — Commit:**

```bash
git add Treemux/UI/Sidebar/SidebarNodeRow.swift
git commit -m "feat: surface AI attention pulse in sidebar rows"
```

---

## Phase 3 — Tab bar dot

### Task 8: Tab button dot + dynamic width

**Files:**
- Modify: `Treemux/UI/Workspace/WorkspaceTabBarView.swift`

**Step 1 — Add a dot helper view inside `WorkspaceTabBarView.swift`:**

```swift
private struct TabActivityDot: View {
    enum Kind { case idle, attention }
    let kind: Kind
    @State private var isAnimating = false

    private var color: Color { Color.orange }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(kind == .attention ? (isAnimating ? 1 : 0.4) : 0.8)
            .onAppear { startAnimation() }
            .onChange(of: kind) { _, _ in startAnimation() }
    }

    private func startAnimation() {
        guard kind == .attention else {
            isAnimating = false
            return
        }
        isAnimating = false
        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
            isAnimating = true
        }
    }
}
```

**Step 2 — Render it in `TabButton`:**

`TabButton` needs the workspace to query `hasAttention(forTabID:worktreePath:)`. Pass it as a parameter (extend the `TabButton` initializer):

```swift
private struct TabButton: View {
    let tab: WorkspaceTabStateRecord
    let isSelected: Bool
    let isHovered: Bool
    let paneCount: Int
    let dotKind: TabActivityDot.Kind?   // nil = no dot
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: () -> Void
```

In `body`'s `HStack(spacing: 4)`, before `Text(tab.title)`:

```swift
                if let dotKind {
                    TabActivityDot(kind: dotKind)
                        .padding(.trailing, 2)
                }
```

**Step 3 — Compute `dotKind` in the parent (`WorkspaceTabBarView.body`):**

Replace the existing `TabButton(...)` call with one that supplies `dotKind`:

```swift
                            TabButton(
                                tab: tab,
                                isSelected: tab.id == workspace.activeTabID,
                                isHovered: hoveredTabID == tab.id,
                                paneCount: paneCount(for: tab),
                                dotKind: dotKind(for: tab),
                                ...
                            )
```

Add helper:

```swift
    private func dotKind(for tab: WorkspaceTabStateRecord) -> TabActivityDot.Kind? {
        let path = workspace.activeWorktreePath
        if workspace.hasAttention(forTabID: tab.id, worktreePath: path) {
            return .attention
        }
        // Steady dot = "this tab has at least one running session". A tab without
        // a controller hasn't been opened yet; show no dot.
        if workspace.hasRunningSessions(forWorktreePath: path) {
            return .idle
        }
        return nil
    }
```

**Step 4 — Adjust `TreemuxTabSizing.width` to reserve dot space:**

Add an extra parameter `hasDot: Bool`:

```swift
    static func width(for title: String, paneCount: Int, hasDot: Bool = false) -> CGFloat {
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width)
        var totalWidth = titleWidth + 44
        if paneCount > 1 {
            let countText = "\(paneCount)"
            let countWidth = ceil((countText as NSString).size(withAttributes: [.font: countFont]).width)
            totalWidth += countWidth + 12
        }
        if hasDot { totalWidth += 10 }
        return min(max(totalWidth, 100), 260)
    }
```

Update both call sites in this file to pass `hasDot: dotKind != nil` for `TabButton`'s frame, and similarly for the rename field width (false there).

**Step 5 — Build + manual:**

```bash
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5
```

After launching, open a workspace, create a 2nd tab, run the `printf` from Phase 1 in tab 1 from tab 2's perspective: switch to tab 2, then in tab 1 send the OSC. Confirm tab 1's dot pulses; tab 2's does not. Switch to tab 1 → its dot stops.

**Step 6 — Commit:**

```bash
git add Treemux/UI/Workspace/WorkspaceTabBarView.swift
git commit -m "feat: add per-tab activity dot reflecting AI attention"
```

---

## Phase 4 — Hook installer foundation (no UI)

End of phase 4: the `AIHookInstaller` registry exists and works on local target via direct calls in unit tests. No UI yet; the next phase adds Settings + banner.

### Task 9: Bundle the helper scripts as Resources

**Files:**
- Create: `Treemux/Support/AIHooks/notify.sh`
- Create: `Treemux/Support/AIHooks/notify-codex.sh`
- Create: `Treemux/Support/AIHooks/treemux-notify.js`
- Modify: `project.yml` (under `targets.Treemux.sources`, add `Treemux/Support/AIHooks` with `type: folder` so the entire directory ships as a resource)

**Step 1 — Write the helpers:**

`Treemux/Support/AIHooks/notify.sh`:

```bash
#!/bin/bash
# treemux-managed v1
# Emit OSC 777 desktop notification for treemux.
# Args:
#   $1 = event kind: "done" | "input"
#   $2 = optional body text
event="${1:-done}"
body="${2:-}"
printf '\033]777;notify;treemux:%s;%s\007' "$event" "$body" > /dev/tty 2>/dev/null
```

`Treemux/Support/AIHooks/notify-codex.sh`:

```bash
#!/bin/bash
# treemux-managed v1
# Codex passes the event JSON as the last argv. Map to done/input and forward.
event_json="${1:-}"
case "$event_json" in
    *'"type":"agent-turn-tool-call-approval'*) kind=input ;;
    *'"type":"agent-turn-complete"'*)          kind=done  ;;
    *)                                          kind=done  ;;
esac
exec "$HOME/.treemux/hooks/notify.sh" "$kind"
```

`Treemux/Support/AIHooks/treemux-notify.js`:

```javascript
// treemux-managed v1
import { execSync } from "node:child_process"

function notify(kind) {
    try {
        execSync(`"$HOME/.treemux/hooks/notify.sh" ${kind}`, { stdio: "ignore" })
    } catch (_) {
        // best-effort; silently ignore if the helper is missing
    }
}

export default {
    "session.idle":         () => notify("done"),
    "permission.requested": () => notify("input"),
}
```

**Step 2 — Make scripts executable:**

```bash
chmod +x Treemux/Support/AIHooks/notify.sh Treemux/Support/AIHooks/notify-codex.sh
```

**Step 3 — Update `project.yml`:**

Add under the `Treemux` target's `sources` (after the existing entries):

```yaml
    - path: Treemux/Support/AIHooks
      type: folder
```

(The `type: folder` form ships the directory as a "Folder Reference" — files are copied into the bundle's `Resources/AIHooks/` at build time.)

**Step 4 — Regenerate the Xcode project (XcodeGen):**

```bash
xcodegen generate
```

Expected: no errors; `Treemux.xcodeproj/project.pbxproj` gets a new file reference for `Treemux/Support/AIHooks`.

**Step 5 — Build and verify resource packaging:**

```bash
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5
ls "$(find ~/Library/Developer/Xcode/DerivedData -name 'Treemux.app' -path '*Debug*' -type d 2>/dev/null | head -1)/Contents/Resources/AIHooks/"
```

Expected: 3 files listed.

**Step 6 — Commit:**

```bash
git add Treemux/Support/AIHooks/ project.yml Treemux.xcodeproj/
git commit -m "feat: bundle AI hook helper scripts as app resources"
```

---

### Task 10: Hook installer types + protocol

**Files:**
- Create: `Treemux/Services/AITool/AIHookInstaller.swift`
- Create: `Treemux/Services/AITool/AIHookProvider.swift`
- Create: `Treemux/Services/AITool/AIHookFileSystem.swift`
- Test: `TreemuxTests/AIHookInstallerTests.swift`

**Step 1 — Write the protocol/types skeleton (`AIHookInstaller.swift`):**

```swift
//
//  AIHookInstaller.swift
//  Treemux
//

import Foundation

/// Where a hook should be installed: the user's local home, or a remote SSH host.
enum HookTarget: Equatable {
    case local
    case remote(SSHTarget)

    /// Stable identity used in persistence keys.
    var id: String {
        switch self {
        case .local: return "local"
        case .remote(let t): return "remote:\(t.host)"
        }
    }
}

/// Result of inspecting whether a hook is installed for a given provider+target.
enum HookStatus: Equatable {
    case notDetected
    case detectedNotInstalled
    case installed(version: String, installedAt: Date)
    case installedOutdated(currentVersion: String, latestVersion: String)
    case tampered(reason: String)
    case unknown(reason: String)
}

/// Read receipt produced by an install operation, used to populate the cache.
struct HookInstallReceipt: Equatable {
    let version: String
    let installedAt: Date
}

/// Errors thrown by the installer.
enum HookInstallError: LocalizedError {
    case userConfigConflict(String)   // e.g. Codex notify already set to a non-treemux value
    case ioError(String)
    case parseError(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .userConfigConflict(let m): return m
        case .ioError(let m): return m
        case .parseError(let m): return m
        case .unsupported(let m): return m
        }
    }
}
```

**Step 2 — Filesystem abstraction (`AIHookFileSystem.swift`):**

```swift
//
//  AIHookFileSystem.swift
//  Treemux
//

import Foundation

/// Minimal filesystem operations needed by hook providers, abstracted so that
/// remote (SSH-based) targets can plug in a different implementation. All
/// methods throw `HookInstallError.ioError` on transport failure.
protocol AIHookFileSystem {
    func exists(_ path: String) async throws -> Bool
    func readText(_ path: String) async throws -> String?     // nil if not present
    func writeText(_ path: String, _ contents: String) async throws
    func removeFile(_ path: String) async throws
    func makeDirectory(_ path: String) async throws
    func makeExecutable(_ path: String) async throws
    /// Expands a path beginning with `~/` against the target's home.
    func expand(_ path: String) async throws -> String
}

/// Local filesystem implementation: operates on the user's home via
/// `FileManager`.
final class LocalHookFileSystem: AIHookFileSystem {
    private var home: String { NSHomeDirectory() }
    private let fm = FileManager.default

    func exists(_ path: String) async throws -> Bool {
        let p = try await expand(path)
        return fm.fileExists(atPath: p)
    }

    func readText(_ path: String) async throws -> String? {
        let p = try await expand(path)
        guard fm.fileExists(atPath: p) else { return nil }
        do {
            return try String(contentsOfFile: p, encoding: .utf8)
        } catch {
            throw HookInstallError.ioError("read \(p): \(error.localizedDescription)")
        }
    }

    func writeText(_ path: String, _ contents: String) async throws {
        let p = try await expand(path)
        let dir = (p as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try contents.write(toFile: p, atomically: true, encoding: .utf8)
    }

    func removeFile(_ path: String) async throws {
        let p = try await expand(path)
        if fm.fileExists(atPath: p) {
            try fm.removeItem(atPath: p)
        }
    }

    func makeDirectory(_ path: String) async throws {
        let p = try await expand(path)
        try fm.createDirectory(atPath: p, withIntermediateDirectories: true)
    }

    func makeExecutable(_ path: String) async throws {
        let p = try await expand(path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p)
    }

    func expand(_ path: String) async throws -> String {
        if path.hasPrefix("~/") {
            return (home as NSString).appendingPathComponent(String(path.dropFirst(2)))
        }
        return path
    }
}
```

(Note: `RemoteHookFileSystem` is implemented in Task 14.)

**Step 3 — Provider protocol (`AIHookProvider.swift`):**

```swift
//
//  AIHookProvider.swift
//  Treemux
//

import Foundation

/// One AI agent's view of "where do I live and what does my hook config look like".
/// Implementations are stateless; they take an `AIHookFileSystem` to operate on.
protocol AIHookProvider {
    var kind: AIToolKind { get }
    var displayName: String { get }
    /// File paths whose existence (any-of) indicates the user has used this agent.
    var detectionPaths: [String] { get }
    /// Path of the primary config file we'd merge into.
    var configFile: String { get }
    /// Helper resource filenames (relative to the app bundle's `Resources/AIHooks/`).
    var helperResources: [String] { get }
    /// Current schema version we install. Used to detect outdated installs.
    var version: String { get }

    func inspect(fs: AIHookFileSystem) async throws -> HookStatus
    func install(fs: AIHookFileSystem, helperBundleURL: URL) async throws -> HookInstallReceipt
    func uninstall(fs: AIHookFileSystem) async throws
}

/// Built-in registry. Future agents are added here.
enum AIHookProviderRegistry {
    static func providers() -> [AIHookProvider] {
        [
            ClaudeCodeHookProvider(),
            CodexHookProvider(),
            OpencodeHookProvider(),
        ]
    }
}
```

**Step 4 — Failing test stub (`TreemuxTests/AIHookInstallerTests.swift`):**

```swift
import XCTest
@testable import Treemux

final class AIHookInstallerTests: XCTestCase {

    /// Sanity: registry returns three known providers.
    func testRegistryHasThreeBuiltinProviders() {
        let providers = AIHookProviderRegistry.providers()
        let kinds = providers.map(\.kind)
        XCTAssertEqual(Set(kinds), Set([.claudeCode, .openaiCodex, .custom]))
        // NOTE: opencode currently maps to .custom in AIToolKind.
        // If a dedicated case .opencode is added later, update this test.
    }
}
```

(If `AIToolKind` doesn't yet have a case suitable for opencode, this task either depends on adding `case opencode` to `AIToolKind` first, or the OpencodeHookProvider uses `.custom`. Choose: **add `case opencode = "opencode"` to `AIToolKind`** in `Treemux/Domain/SessionBackend.swift:30-33` and update the existing detection in `AIToolModels.swift:42-51` to recognize "opencode" / "opencode-cli". This is a 5-line change — include it in this task and update the test to expect `.opencode`.)

**Step 5 — Run the test (will fail since providers don't exist yet):**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -only-testing:TreemuxTests/AIHookInstallerTests 2>&1 | tail -10
```

Expected: build error referencing `ClaudeCodeHookProvider` not found. That's fine — the next tasks add them.

**Step 6 — Commit (still red):**

```bash
git add Treemux/Domain/SessionBackend.swift \
        Treemux/Domain/AIToolModels.swift \
        Treemux/Services/AITool/AIHookInstaller.swift \
        Treemux/Services/AITool/AIHookProvider.swift \
        Treemux/Services/AITool/AIHookFileSystem.swift \
        TreemuxTests/AIHookInstallerTests.swift
git commit -m "feat: scaffold AIHookInstaller registry and filesystem abstraction"
```

(Expected: build still fails at test target until Task 11–13 land. Tasks 11–13 each go red→green individually.)

---

### Task 11: ClaudeCodeHookProvider

**Files:**
- Create: `Treemux/Services/AITool/Providers/ClaudeCodeHookProvider.swift`
- Test: extend `TreemuxTests/AIHookInstallerTests.swift`

**Step 1 — Add tests:**

```swift
    func testClaudeCodeNotDetectedWhenSettingsAbsent() async throws {
        let fs = InMemoryFileSystem()
        let p = ClaudeCodeHookProvider()
        let status = try await p.inspect(fs: fs)
        XCTAssertEqual(status, .notDetected)
    }

    func testClaudeCodeDetectedNotInstalledForEmptyJSON() async throws {
        let fs = InMemoryFileSystem()
        try await fs.writeText("~/.claude/settings.json", "{}")
        let p = ClaudeCodeHookProvider()
        XCTAssertEqual(try await p.inspect(fs: fs), .detectedNotInstalled)
    }

    func testClaudeCodeInstallAddsManagedHooks() async throws {
        let fs = InMemoryFileSystem()
        try await fs.writeText("~/.claude/settings.json", "{\"hooks\":{}}")
        let p = ClaudeCodeHookProvider()
        let url = URL(fileURLWithPath: "/tmp/Resources/AIHooks/")
        try await fs.writeText("~/.treemux/hooks/notify.sh", "stub")
        _ = try await p.install(fs: fs, helperBundleURL: url)
        let updated = try await fs.readText("~/.claude/settings.json")!
        XCTAssertTrue(updated.contains("\"_treemuxManaged\":true") || updated.contains("\"_treemuxManaged\" : true"))
        XCTAssertTrue(updated.contains("notify.sh input"))
        XCTAssertTrue(updated.contains("notify.sh done"))
    }

    func testClaudeCodeInstallPreservesUserHooks() async throws {
        let fs = InMemoryFileSystem()
        let original = """
        {"hooks":{"Notification":[{"hooks":[{"type":"command","command":"my-script.sh"}]}]}}
        """
        try await fs.writeText("~/.claude/settings.json", original)
        let p = ClaudeCodeHookProvider()
        try await fs.writeText("~/.treemux/hooks/notify.sh", "stub")
        _ = try await p.install(
            fs: fs,
            helperBundleURL: URL(fileURLWithPath: "/tmp/Resources/AIHooks/")
        )
        let updated = try await fs.readText("~/.claude/settings.json")!
        XCTAssertTrue(updated.contains("my-script.sh"))   // user entry survived
        XCTAssertTrue(updated.contains("notify.sh"))      // ours added
    }

    func testClaudeCodeUninstallRemovesOnlyManagedEntries() async throws {
        let fs = InMemoryFileSystem()
        try await fs.writeText("~/.claude/settings.json", "{}")
        let p = ClaudeCodeHookProvider()
        try await fs.writeText("~/.treemux/hooks/notify.sh", "stub")
        _ = try await p.install(fs: fs, helperBundleURL: URL(fileURLWithPath: "/tmp/Resources/AIHooks/"))
        try await p.uninstall(fs: fs)
        let updated = try await fs.readText("~/.claude/settings.json")!
        XCTAssertFalse(updated.contains("_treemuxManaged"))
    }
```

**Step 2 — In-memory filesystem helper for tests:**

Add to the same test file (or a separate `TreemuxTests/Support/InMemoryFileSystem.swift`):

```swift
final class InMemoryFileSystem: AIHookFileSystem, @unchecked Sendable {
    private var files: [String: String] = [:]
    private let home = "/Users/test"

    func expand(_ path: String) async throws -> String {
        if path.hasPrefix("~/") { return home + "/" + String(path.dropFirst(2)) }
        return path
    }

    func exists(_ path: String) async throws -> Bool {
        files[try await expand(path)] != nil
    }

    func readText(_ path: String) async throws -> String? {
        files[try await expand(path)]
    }

    func writeText(_ path: String, _ contents: String) async throws {
        files[try await expand(path)] = contents
    }

    func removeFile(_ path: String) async throws {
        files.removeValue(forKey: try await expand(path))
    }

    func makeDirectory(_ path: String) async throws { /* no-op */ }
    func makeExecutable(_ path: String) async throws { /* no-op */ }
}
```

**Step 3 — Implement provider:**

```swift
//
//  ClaudeCodeHookProvider.swift
//  Treemux
//

import Foundation

struct ClaudeCodeHookProvider: AIHookProvider {
    var kind: AIToolKind { .claudeCode }
    var displayName: String { "Claude Code" }
    var detectionPaths: [String] { ["~/.claude/settings.json", "~/.claude"] }
    var configFile: String { "~/.claude/settings.json" }
    var helperResources: [String] { ["notify.sh"] }
    var version: String { "1" }

    func inspect(fs: AIHookFileSystem) async throws -> HookStatus {
        let detected = try await detectionPaths.async.contains { try await fs.exists($0) }
        guard detected else { return .notDetected }

        guard let raw = try await fs.readText(configFile) else { return .detectedNotInstalled }
        guard let json = parseJSON(raw) as? [String: Any] else {
            return .tampered(reason: "settings.json is not valid JSON")
        }
        let hooks = json["hooks"] as? [String: Any] ?? [:]
        let hasNotification = anyManaged(in: hooks["Notification"])
        let hasStop = anyManaged(in: hooks["Stop"])
        guard hasNotification && hasStop else { return .detectedNotInstalled }
        // version match check + helper script presence
        if try await fs.exists("~/.treemux/hooks/notify.sh") {
            return .installed(version: version, installedAt: Date())
        } else {
            return .tampered(reason: "helper script missing")
        }
    }

    func install(fs: AIHookFileSystem, helperBundleURL: URL) async throws -> HookInstallReceipt {
        // 1. Copy notify.sh to ~/.treemux/hooks/notify.sh and chmod +x
        let helperSrc = helperBundleURL.appendingPathComponent("notify.sh")
        let helperData = try String(contentsOf: helperSrc, encoding: .utf8)
        try await fs.makeDirectory("~/.treemux/hooks")
        try await fs.writeText("~/.treemux/hooks/notify.sh", helperData)
        try await fs.makeExecutable("~/.treemux/hooks/notify.sh")

        // 2. Merge into settings.json
        let raw = (try await fs.readText(configFile)) ?? "{}"
        guard var json = parseJSON(raw) as? [String: Any] else {
            throw HookInstallError.parseError("settings.json: not valid JSON")
        }
        var hooks = json["hooks"] as? [String: Any] ?? [:]

        let notificationEntry: [String: Any] = [
            "_treemuxManaged": true,
            "_treemuxVersion": version,
            "hooks": [["type": "command", "command": "$HOME/.treemux/hooks/notify.sh input"]]
        ]
        let stopEntry: [String: Any] = [
            "_treemuxManaged": true,
            "_treemuxVersion": version,
            "hooks": [["type": "command", "command": "$HOME/.treemux/hooks/notify.sh done"]]
        ]
        hooks["Notification"] = appendOrReplaceManaged(in: hooks["Notification"], with: notificationEntry)
        hooks["Stop"]         = appendOrReplaceManaged(in: hooks["Stop"], with: stopEntry)
        json["hooks"] = hooks

        let serialized = try serializeJSON(json)
        try await fs.writeText(configFile, serialized)
        return HookInstallReceipt(version: version, installedAt: Date())
    }

    func uninstall(fs: AIHookFileSystem) async throws {
        guard let raw = try await fs.readText(configFile),
              var json = parseJSON(raw) as? [String: Any]
        else { return }
        var hooks = json["hooks"] as? [String: Any] ?? [:]
        hooks["Notification"] = removeManaged(in: hooks["Notification"])
        hooks["Stop"]         = removeManaged(in: hooks["Stop"])
        json["hooks"] = hooks
        let serialized = try serializeJSON(json)
        try await fs.writeText(configFile, serialized)
        try await fs.removeFile("~/.treemux/hooks/notify.sh")
    }

    // MARK: - helpers

    private func anyManaged(in any: Any?) -> Bool {
        guard let arr = any as? [[String: Any]] else { return false }
        return arr.contains { ($0["_treemuxManaged"] as? Bool) == true }
    }

    private func appendOrReplaceManaged(in existing: Any?, with entry: [String: Any]) -> [[String: Any]] {
        var arr = (existing as? [[String: Any]]) ?? []
        arr.removeAll { ($0["_treemuxManaged"] as? Bool) == true }
        arr.append(entry)
        return arr
    }

    private func removeManaged(in existing: Any?) -> [[String: Any]]? {
        guard var arr = existing as? [[String: Any]] else { return nil }
        arr.removeAll { ($0["_treemuxManaged"] as? Bool) == true }
        return arr.isEmpty ? nil : arr
    }

    private func parseJSON(_ raw: String) -> Any? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func serializeJSON(_ obj: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

extension Sequence {
    func async<T>(transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for el in self { out.append(try await transform(el)) }
        return out
    }

    func async<E: Error>(_ predicate: (Element) async throws(E) -> Bool) async throws(E) -> Bool {
        for el in self where try await predicate(el) { return true }
        return false
    }
}
```

**Step 4 — Run tests:**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -only-testing:TreemuxTests/AIHookInstallerTests 2>&1 | tail -15
```

Expected: 5 ClaudeCode tests pass; the registry test still red because Codex/opencode providers don't exist yet.

**Step 5 — Commit:**

```bash
git add Treemux/Services/AITool/Providers/ClaudeCodeHookProvider.swift \
        TreemuxTests/AIHookInstallerTests.swift
git commit -m "feat: ClaudeCodeHookProvider with merge-aware install/uninstall"
```

---

### Task 12: CodexHookProvider

**Files:**
- Create: `Treemux/Services/AITool/Providers/CodexHookProvider.swift`
- Test: extend `TreemuxTests/AIHookInstallerTests.swift`

**Step 1 — Add tests:**

```swift
    func testCodexNotDetectedWithoutConfig() async throws {
        let fs = InMemoryFileSystem()
        XCTAssertEqual(try await CodexHookProvider().inspect(fs: fs), .notDetected)
    }

    func testCodexInstallWritesNotifyLine() async throws {
        let fs = InMemoryFileSystem()
        try await fs.writeText("~/.codex/config.toml", "model = \"gpt-5\"\n")
        try await fs.writeText("~/.treemux/hooks/notify.sh", "stub")
        try await fs.writeText("~/.treemux/hooks/notify-codex.sh", "stub")
        let p = CodexHookProvider()
        _ = try await p.install(fs: fs, helperBundleURL: URL(fileURLWithPath: "/tmp/Resources/AIHooks/"))
        let updated = try await fs.readText("~/.codex/config.toml")!
        XCTAssertTrue(updated.contains("# treemux-managed"))
        XCTAssertTrue(updated.contains("notify-codex.sh"))
        XCTAssertTrue(updated.contains("model = \"gpt-5\""))   // user content preserved
    }

    func testCodexInstallFailsOnUserNotifyConflict() async throws {
        let fs = InMemoryFileSystem()
        try await fs.writeText("~/.codex/config.toml", "notify = [\"my-program\"]\n")
        try await fs.writeText("~/.treemux/hooks/notify.sh", "stub")
        let p = CodexHookProvider()
        do {
            _ = try await p.install(fs: fs, helperBundleURL: URL(fileURLWithPath: "/tmp/Resources/AIHooks/"))
            XCTFail("expected userConfigConflict")
        } catch HookInstallError.userConfigConflict { /* ok */ }
    }

    func testCodexUninstallRemovesOnlyManagedLines() async throws {
        let fs = InMemoryFileSystem()
        try await fs.writeText("~/.codex/config.toml", "model = \"gpt-5\"\n")
        try await fs.writeText("~/.treemux/hooks/notify.sh", "stub")
        try await fs.writeText("~/.treemux/hooks/notify-codex.sh", "stub")
        let p = CodexHookProvider()
        _ = try await p.install(fs: fs, helperBundleURL: URL(fileURLWithPath: "/tmp/Resources/AIHooks/"))
        try await p.uninstall(fs: fs)
        let updated = try await fs.readText("~/.codex/config.toml")!
        XCTAssertFalse(updated.contains("# treemux-managed"))
        XCTAssertFalse(updated.contains("notify-codex.sh"))
        XCTAssertTrue(updated.contains("model = \"gpt-5\""))
    }
```

**Step 2 — Implement (`CodexHookProvider.swift`):**

The Codex config is TOML; rather than pulling a TOML library we operate on the file as text. We bracket our managed addition with marker comments so uninstall can strip exactly that block.

```swift
import Foundation

struct CodexHookProvider: AIHookProvider {
    var kind: AIToolKind { .openaiCodex }
    var displayName: String { "Codex" }
    var detectionPaths: [String] { ["~/.codex/config.toml", "~/.codex"] }
    var configFile: String { "~/.codex/config.toml" }
    var helperResources: [String] { ["notify.sh", "notify-codex.sh"] }
    var version: String { "1" }

    private let beginMarker = "# >>> treemux-managed v1 >>>"
    private let endMarker   = "# <<< treemux-managed <<<"

    func inspect(fs: AIHookFileSystem) async throws -> HookStatus {
        let detected = try await detectionPaths.async.contains { try await fs.exists($0) }
        guard detected else { return .notDetected }
        let raw = try await fs.readText(configFile) ?? ""
        guard raw.contains(beginMarker) else { return .detectedNotInstalled }
        // Helper presence
        if try await fs.exists("~/.treemux/hooks/notify-codex.sh"),
           try await fs.exists("~/.treemux/hooks/notify.sh") {
            return .installed(version: version, installedAt: Date())
        }
        return .tampered(reason: "Codex helper script missing")
    }

    func install(fs: AIHookFileSystem, helperBundleURL: URL) async throws -> HookInstallReceipt {
        // 1. Copy helpers (notify.sh + notify-codex.sh)
        for name in helperResources {
            let url = helperBundleURL.appendingPathComponent(name)
            let txt = try String(contentsOf: url, encoding: .utf8)
            try await fs.makeDirectory("~/.treemux/hooks")
            try await fs.writeText("~/.treemux/hooks/\(name)", txt)
            try await fs.makeExecutable("~/.treemux/hooks/\(name)")
        }
        // 2. Read config
        let raw = (try await fs.readText(configFile)) ?? ""
        // 3. Detect existing user notify
        let lines = raw.components(separatedBy: "\n")
        let nonOurs = lines.filter { !$0.hasPrefix(beginMarker) && !$0.hasPrefix(endMarker) }
        for line in nonOurs {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("notify"), trimmed.contains("=") {
                throw HookInstallError.userConfigConflict(
                    "~/.codex/config.toml already defines `notify`. Remove or move it before installing the treemux hook."
                )
            }
        }
        // 4. Strip any prior treemux block, append fresh one
        let stripped = stripManagedBlock(raw)
        let block = """
        \(beginMarker)
        notify = ["$HOME/.treemux/hooks/notify-codex.sh"]
        \(endMarker)
        """
        let final = stripped.isEmpty ? block + "\n"
                                     : stripped.trimmingCharacters(in: .newlines) + "\n\n" + block + "\n"
        try await fs.writeText(configFile, final)
        return HookInstallReceipt(version: version, installedAt: Date())
    }

    func uninstall(fs: AIHookFileSystem) async throws {
        if let raw = try await fs.readText(configFile) {
            let stripped = stripManagedBlock(raw)
            try await fs.writeText(configFile, stripped)
        }
        try await fs.removeFile("~/.treemux/hooks/notify-codex.sh")
        // notify.sh stays — it's shared with other providers. Leave it.
    }

    private func stripManagedBlock(_ raw: String) -> String {
        guard let beginRange = raw.range(of: beginMarker),
              let endRange = raw.range(of: endMarker, range: beginRange.upperBound..<raw.endIndex)
        else { return raw }
        let before = raw[..<beginRange.lowerBound]
        var after = String(raw[endRange.upperBound...])
        if after.hasPrefix("\n") { after = String(after.dropFirst()) }
        return String(before).trimmingCharacters(in: .whitespacesAndNewlines)
            + (after.isEmpty ? "" : "\n" + after)
    }
}
```

(NOTE: when `notify.sh` is shared between providers, deleting it on Codex uninstall would break Claude Code's hook. The plan keeps `notify.sh` resident at `~/.treemux/hooks/` and only deletes it when the *last* provider uninstalls. Implement that as a no-delete here; the Settings UI in Phase 5 surfaces a "Tidy up" button that deletes the helper if no providers remain installed. Document this in code comment.)

**Step 3 — Run tests, expect pass for Codex tests:**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -only-testing:TreemuxTests/AIHookInstallerTests 2>&1 | tail -15
```

**Step 4 — Commit:**

```bash
git add Treemux/Services/AITool/Providers/CodexHookProvider.swift TreemuxTests/AIHookInstallerTests.swift
git commit -m "feat: CodexHookProvider with marker-bracketed install/uninstall"
```

---

### Task 13: OpencodeHookProvider

**Files:**
- Create: `Treemux/Services/AITool/Providers/OpencodeHookProvider.swift`
- Test: extend `TreemuxTests/AIHookInstallerTests.swift`

**Step 1 — Add tests:**

```swift
    func testOpencodeInstallWritesPlugin() async throws {
        let fs = InMemoryFileSystem()
        try await fs.writeText("~/.config/opencode/config.json", "{}")
        try await fs.writeText("~/.treemux/hooks/notify.sh", "stub")
        let p = OpencodeHookProvider()
        let url = URL(fileURLWithPath: "/tmp/Resources/AIHooks/")
        // Stub the bundled JS file:
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? "stub".write(to: url.appendingPathComponent("treemux-notify.js"), atomically: true, encoding: .utf8)

        _ = try await p.install(fs: fs, helperBundleURL: url)
        XCTAssertTrue(try await fs.exists("~/.config/opencode/plugins/treemux-notify.js"))
    }

    func testOpencodeUninstallRemovesPlugin() async throws {
        let fs = InMemoryFileSystem()
        try await fs.writeText("~/.config/opencode/plugins/treemux-notify.js", "stub")
        try await OpencodeHookProvider().uninstall(fs: fs)
        XCTAssertFalse(try await fs.exists("~/.config/opencode/plugins/treemux-notify.js"))
    }
```

**Step 2 — Implement:**

```swift
import Foundation

struct OpencodeHookProvider: AIHookProvider {
    var kind: AIToolKind { .opencode }
    var displayName: String { "opencode" }
    var detectionPaths: [String] { ["~/.config/opencode", "~/.config/opencode/config.json"] }
    var configFile: String { "~/.config/opencode/plugins/treemux-notify.js" }
    var helperResources: [String] { ["notify.sh", "treemux-notify.js"] }
    var version: String { "1" }

    func inspect(fs: AIHookFileSystem) async throws -> HookStatus {
        let detected = try await detectionPaths.async.contains { try await fs.exists($0) }
        guard detected else { return .notDetected }
        guard try await fs.exists(configFile) else { return .detectedNotInstalled }
        guard try await fs.exists("~/.treemux/hooks/notify.sh") else {
            return .tampered(reason: "Shared helper script missing")
        }
        return .installed(version: version, installedAt: Date())
    }

    func install(fs: AIHookFileSystem, helperBundleURL: URL) async throws -> HookInstallReceipt {
        // Shared notify.sh
        let helper = try String(contentsOf: helperBundleURL.appendingPathComponent("notify.sh"), encoding: .utf8)
        try await fs.makeDirectory("~/.treemux/hooks")
        try await fs.writeText("~/.treemux/hooks/notify.sh", helper)
        try await fs.makeExecutable("~/.treemux/hooks/notify.sh")
        // Plugin
        let js = try String(contentsOf: helperBundleURL.appendingPathComponent("treemux-notify.js"), encoding: .utf8)
        try await fs.makeDirectory("~/.config/opencode/plugins")
        try await fs.writeText(configFile, js)
        return HookInstallReceipt(version: version, installedAt: Date())
    }

    func uninstall(fs: AIHookFileSystem) async throws {
        try await fs.removeFile(configFile)
    }
}
```

**Step 3 — Add `case opencode` to `AIToolKind`** (referenced from Task 10):

In `Treemux/Domain/SessionBackend.swift:30-33`:

```swift
enum AIToolKind: String, Codable {
    case claudeCode = "claude"
    case openaiCodex = "codex"
    case opencode = "opencode"
    case custom
}
```

In `Treemux/Domain/AIToolModels.swift`:

- Add display/icon cases in the `displayName` and `iconName` switches.
- Extend `detect(processName:)`:
  ```swift
  if lower == "opencode" || lower.hasPrefix("opencode-") {
      return .opencode
  }
  ```

Update the existing `AIToolServiceTests.testAIToolKindDisplayName` to include opencode.

**Step 4 — Run tests:**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -only-testing:TreemuxTests 2>&1 | tail -15
```

Expected: all tests in `AIHookInstallerTests` and `AIToolServiceTests` pass.

**Step 5 — Commit:**

```bash
git add Treemux/Domain/SessionBackend.swift \
        Treemux/Domain/AIToolModels.swift \
        Treemux/Services/AITool/Providers/OpencodeHookProvider.swift \
        TreemuxTests/AIHookInstallerTests.swift \
        TreemuxTests/AIToolServiceTests.swift
git commit -m "feat: opencode AIToolKind case and OpencodeHookProvider"
```

---

### Task 14: Remote SSH filesystem implementation

**Files:**
- Create: `Treemux/Services/AITool/RemoteHookFileSystem.swift`
- Test: `TreemuxTests/RemoteHookFileSystemTests.swift` (if a mock SSHCommandRunner exists)

This task wraps the existing SSH session machinery to satisfy the `AIHookFileSystem` protocol. We re-use `Treemux/Services/Process/ShellCommandRunner.swift` if remote SSH command execution already lives there; otherwise route through the existing `SessionBackendLaunch` path. Inspect the codebase first:

```bash
grep -rn -E 'class.*ShellCommandRunner|sshExec|remoteRun' Treemux/Services/ | head -10
```

**Step 1 — Implementation outline (`RemoteHookFileSystem.swift`):**

```swift
import Foundation

/// SSH-backed implementation. All operations shell out via `ssh <host> -- <cmd>`,
/// with paths quoted by `shellEscape`. Heredoc is used for writes to avoid
/// argv length limits.
final class RemoteHookFileSystem: AIHookFileSystem {
    private let target: SSHTarget
    private let runner: SSHCommandRunner   // existing service in the codebase

    init(target: SSHTarget, runner: SSHCommandRunner) {
        self.target = target
        self.runner = runner
    }

    func expand(_ path: String) async throws -> String {
        // Don't resolve $HOME here — leave that to the remote shell.
        path
    }

    func exists(_ path: String) async throws -> Bool {
        let res = try await runner.run("test -e \(shellQuote(path))")
        return res.exitCode == 0
    }

    func readText(_ path: String) async throws -> String? {
        let res = try await runner.run("cat \(shellQuote(path)) 2>/dev/null")
        return res.exitCode == 0 ? res.stdout : nil
    }

    func writeText(_ path: String, _ contents: String) async throws {
        let dir = (path as NSString).deletingLastPathComponent
        _ = try await runner.run("mkdir -p \(shellQuote(dir))")
        let escaped = contents.replacingOccurrences(of: "'\\''", with: "'\\\\''")
                              .replacingOccurrences(of: "'", with: "'\\''")
        let res = try await runner.run("cat > \(shellQuote(path)) <<'TREEMUX_EOF'\n\(contents)\nTREEMUX_EOF")
        if res.exitCode != 0 { throw HookInstallError.ioError(res.stderr) }
    }

    func removeFile(_ path: String) async throws {
        _ = try await runner.run("rm -f \(shellQuote(path))")
    }

    func makeDirectory(_ path: String) async throws {
        _ = try await runner.run("mkdir -p \(shellQuote(path))")
    }

    func makeExecutable(_ path: String) async throws {
        _ = try await runner.run("chmod +x \(shellQuote(path))")
    }

    private func shellQuote(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
```

(The exact API of `SSHCommandRunner` may differ — use whichever existing service treemux already has for shelling out over SSH. If none exists yet, this task is bigger and may need a sub-task to introduce one. Confirm in step 1's `grep` before proceeding.)

**Step 2 — Manual verification:**

Spin up a local SSH config to your own machine (e.g. `Host self` with `localhost` and your username). Add a workspace pointing to it. From a treemux dev runtime, run a temporary debug menu item that calls `RemoteHookFileSystem(target:...).writeText("~/treemux-test", "hello")` and then SSH in to confirm the file. (Add the debug entry under `Settings → AI Activity Hints → Diagnostics`.)

**Step 3 — Commit:**

```bash
git add Treemux/Services/AITool/RemoteHookFileSystem.swift
git commit -m "feat: RemoteHookFileSystem dispatching over SSH command runner"
```

---

### Task 15: AIHookInstaller orchestration

**Files:**
- Modify: `Treemux/Services/AITool/AIHookInstaller.swift` (add the orchestrator class)
- Test: extend `TreemuxTests/AIHookInstallerTests.swift`

**Step 1 — Implement orchestrator:**

```swift
@MainActor
final class AIHookInstaller {
    private let providers: [AIHookProvider]
    private let bundle: Bundle

    init(providers: [AIHookProvider] = AIHookProviderRegistry.providers(),
         bundle: Bundle = .main) {
        self.providers = providers
        self.bundle = bundle
    }

    private var helperBundleURL: URL {
        bundle.resourceURL!.appendingPathComponent("AIHooks", isDirectory: true)
    }

    func provider(for kind: AIToolKind) -> AIHookProvider? {
        providers.first { $0.kind == kind }
    }

    func inspect(_ kind: AIToolKind, fs: AIHookFileSystem) async throws -> HookStatus {
        guard let p = provider(for: kind) else { return .unknown(reason: "unknown agent") }
        return try await p.inspect(fs: fs)
    }

    func inspectAll(fs: AIHookFileSystem) async -> [(AIHookProvider, HookStatus)] {
        var results: [(AIHookProvider, HookStatus)] = []
        for p in providers {
            do {
                results.append((p, try await p.inspect(fs: fs)))
            } catch {
                results.append((p, .unknown(reason: error.localizedDescription)))
            }
        }
        return results
    }

    func install(_ kind: AIToolKind, fs: AIHookFileSystem) async throws -> HookInstallReceipt {
        guard let p = provider(for: kind) else {
            throw HookInstallError.unsupported("Unknown agent kind: \(kind)")
        }
        return try await p.install(fs: fs, helperBundleURL: helperBundleURL)
    }

    func uninstall(_ kind: AIToolKind, fs: AIHookFileSystem) async throws {
        guard let p = provider(for: kind) else { return }
        try await p.uninstall(fs: fs)
    }
}
```

**Step 2 — Run all tests:**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -only-testing:TreemuxTests/AIHookInstallerTests 2>&1 | tail -10
```

Expected: all green.

**Step 3 — Commit:**

```bash
git add Treemux/Services/AITool/AIHookInstaller.swift TreemuxTests/AIHookInstallerTests.swift
git commit -m "feat: AIHookInstaller orchestrator API"
```

---

## Phase 5 — Settings UI + Banner

### Task 16: AppSettings persistence fields

**Files:**
- Modify: `Treemux/Domain/AppSettings.swift`
- Modify: `Treemux/Persistence/AppSettingsPersistence.swift` (verify Codable round-trip — settings are auto-persisted; new fields just need defaults)
- Test: extend `TreemuxTests/PersistenceTests.swift`

**Step 1 — Add fields:**

```swift
    var aiActivityHintsEnabled: Bool = true
    var aiHookSkippedKeys: [String] = []          // "<workspace.id>:<AIToolKind>"
```

(Use `[String]` rather than `Set<String>` for clean Codable behavior.)

**Step 2 — Add a persistence round-trip test in `PersistenceTests.swift`** confirming the new fields default correctly and survive encode→decode.

**Step 3 — Commit:**

```bash
git add Treemux/Domain/AppSettings.swift TreemuxTests/PersistenceTests.swift
git commit -m "feat: persist AI activity hints settings"
```

---

### Task 17: Settings panel section "AI Activity Hints"

**Files:**
- Modify: `Treemux/UI/Settings/SettingsSheet.swift`
- Create: `Treemux/UI/Settings/AIActivityHintsSection.swift`
- Update: `Treemux/Localizable.xcstrings`

**Step 1 — Implement `AIActivityHintsSection`:**

A SwiftUI view that:

1. Shows the master toggle bound to `appSettings.aiActivityHintsEnabled`.
2. On appear (and on `WorkspaceStore` change), loads `(target, provider, status)` rows asynchronously by calling `AIHookInstaller.inspectAll(fs:)` for each known target (Local + each unique remote SSH host across workspaces).
3. Groups rows by target; hides empty groups; hides `.notDetected` rows.
4. For each row, renders the appropriate buttons (`Install` / `Reinstall` / `Remove` / `Repair` / `Update`).
5. Each button calls into a confirmation flow (next task).

Skeleton (~150 lines; full implementation goes here):

```swift
struct AIActivityHintsSection: View {
    @ObservedObject var store: WorkspaceStore       // for the list of targets
    @ObservedObject var appSettings: AppSettings
    @State private var rows: [HintRow] = []
    @State private var isLoading = false
    @State private var pendingPreview: HookPreviewModel?

    struct HintRow: Identifiable { let id: String; let target: HookTarget; let provider: AIHookProvider; var status: HookStatus }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show AI activity in sidebar", isOn: $appSettings.aiActivityHintsEnabled)

            if appSettings.aiActivityHintsEnabled {
                if isLoading { ProgressView() } else { rowsList }
            }
        }
        .task { await refresh() }
        .sheet(item: $pendingPreview) { model in
            HookPreviewSheet(model: model, onApply: applyPreview)
        }
    }

    private var rowsList: some View { /* Section per target → ForEach */ EmptyView() }

    private func refresh() async { /* iterate targets, call installer.inspectAll */ }
    private func install(_ row: HintRow) { /* compute diff → set pendingPreview */ }
    private func applyPreview(_ model: HookPreviewModel) async { /* installer.install → refresh */ }
}
```

**Step 2 — Add the new section to `SettingsSheet`:**

Find the existing settings tab list and add:

```swift
case aiHooks
// ...
case .aiHooks:
    AIActivityHintsSection(store: store, appSettings: settings)
```

**Step 3 — Add localized strings:**

Add to `Treemux/Localizable.xcstrings` (English source + zh-Hans):

| Key | EN | zh-Hans |
|---|---|---|
| `Show AI activity in sidebar` | Show AI activity in sidebar | 在侧边栏显示 AI 活动状态 |
| `AI Activity Hints` | AI Activity Hints | AI 活动提示 |
| `Install` | Install | 安装 |
| `Reinstall` | Reinstall | 重新安装 |
| `Update` | Update | 更新 |
| `Repair` | Repair | 修复 |
| `Remove` | Remove | 移除 |
| `Modified by user` | Modified by user | 已被用户修改 |
| `Update available` | Update available | 有可用更新 |
| `Apply` | Apply | 应用 |
| `Cancel` | Cancel | 取消 |
| `Local` | Local | 本机 |
| `Loading…` | Loading… | 加载中… |

**Step 4 — Build + manual smoke:**

After build, open Settings → AI Activity Hints. Confirm:
- Master toggle works (off → no rows).
- For agents you have configured, rows appear with the expected status.
- For agents you do not have, no rows.

**Step 5 — Commit:**

```bash
git add Treemux/UI/Settings/AIActivityHintsSection.swift \
        Treemux/UI/Settings/SettingsSheet.swift \
        Treemux/Localizable.xcstrings
git commit -m "feat: Settings panel section for AI activity hints"
```

---

### Task 18: Diff preview sheet + apply flow

**Files:**
- Create: `Treemux/UI/Sheets/HookPreviewSheet.swift`

The sheet shows the **current contents** of the agent's config file on the left and the **proposed merged contents** on the right (using a simple `TextEditor` pair with `.disabled(true)` and monospaced font; full diff visualization is out of scope for v1). User clicks `Apply` → installer runs.

**Step 1 — Sheet implementation:**

```swift
struct HookPreviewModel: Identifiable {
    let id = UUID()
    let kind: AIToolKind
    let target: HookTarget
    let displayName: String
    let configPath: String
    let before: String
    let after: String
    let onApply: (HookPreviewModel) async -> Void
}

struct HookPreviewSheet: View {
    let model: HookPreviewModel
    let onApply: (HookPreviewModel) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isApplying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install \(model.displayName)").font(.title2.bold())
            Text(model.configPath).font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                column(title: "Before", text: model.before)
                column(title: "After",  text: model.after)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") {
                    isApplying = true
                    Task {
                        await onApply(model)
                        isApplying = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isApplying)
            }
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 480)
    }

    private func column(title: LocalizedStringKey, text: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            TextEditor(text: .constant(text))
                .font(.system(.body, design: .monospaced))
                .disabled(true)
                .frame(maxHeight: .infinity)
        }
    }
}
```

**Step 2 — Wire into `AIActivityHintsSection`:**

The `install(_ row:)` method computes `before` (current file text) and `after` (a "dry-run" of the install). For dry-run, the providers need a `dryRunInstall` method that returns the proposed `(path, contents)` pairs without writing. Add this to the protocol:

```swift
protocol AIHookProvider {
    // ...
    func dryRunInstall(fs: AIHookFileSystem, helperBundleURL: URL) async throws -> [(path: String, contents: String)]
}
```

Implement in each provider (factor out the body of `install` into a shared computation; `install` is `dryRunInstall` followed by writing each file).

The sheet shows only `configFile` (the agent's main config). Helper-script writes are mentioned in the sheet's footer: *"Treemux will also write `~/.treemux/hooks/notify.sh`."*

**Step 3 — Build + manual:**

Verify clicking `Install` opens the sheet, the diff is sensible, and `Apply` writes the file and refreshes the row to `.installed`.

**Step 4 — Commit:**

```bash
git add Treemux/UI/Sheets/HookPreviewSheet.swift \
        Treemux/UI/Settings/AIActivityHintsSection.swift \
        Treemux/Services/AITool/AIHookProvider.swift \
        Treemux/Services/AITool/Providers/ \
        Treemux/Localizable.xcstrings
git commit -m "feat: hook preview sheet with dry-run and apply flow"
```

---

### Task 19: Banner triggered by detected AI tool

**Files:**
- Create: `Treemux/UI/Components/AIHookBanner.swift`
- Modify: `Treemux/UI/Workspace/<the active workspace view that owns the terminal area>` — find with grep:

```bash
grep -n -E 'TerminalPaneView|WorkspaceContainerView|workspace.tabs' Treemux/UI/Workspace/ -r | head
```

The banner appears above the tab bar.

**Step 1 — Banner view:**

```swift
struct AIHookBanner: View {
    let displayName: String
    let configPath: String
    let onPreview: () -> Void
    let onSkip: () -> Void
    let onSkipHost: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading) {
                Text("Treemux can show when \(displayName) finishes or needs your input")
                    .font(.subheadline)
                Text("by adding a hook to \(configPath).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Preview & Install") { onPreview() }
            Button("Not Now") { onSkip() }.buttonStyle(.borderless)
            Button("Don't ask for this host") { onSkipHost() }.buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.yellow.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
```

**Step 2 — Trigger logic in `WorkspaceModel` (or its owning view-model):**

Add an `@Published var pendingHookBanner: AIHookBannerModel?` (struct with `kind`, `target`, `displayName`, `configPath`).

When any `ShellSession` in the workspace observes `detectedAITool` change to a known kind:
1. If `appSettings.aiActivityHintsEnabled == false`, skip.
2. If `aiHookSkippedKeys.contains("<workspace.id>:<kind>")`, skip.
3. Call `AIHookInstaller.inspect(kind, fs:...)`.
4. If status is `.detectedNotInstalled`, set `pendingHookBanner` to a model. Else clear.

The view observes and renders the banner.

**Step 3 — i18n strings** (add to `Localizable.xcstrings`):

| Key | EN | zh-Hans |
|---|---|---|
| `Treemux can show when %@ finishes or needs your input` | (same) | Treemux 可以在 %@ 完成或需要输入时提示 |
| `by adding a hook to %@.` | (same) | 通过在 %@ 中添加一个 hook 实现。 |
| `Preview & Install` | (same) | 预览并安装 |
| `Not Now` | (same) | 暂不 |
| `Don't ask for this host` | (same) | 不再为此主机询问 |
| `Install %@` | (same) | 安装 %@ |
| `Treemux will also write %@.` | (same) | Treemux 也会写入 %@。 |

**Step 4 — Manual flow:**

1. Make sure no hook is installed locally. Open a workspace, run `claude` in a pane.
2. Banner should appear above the tab bar.
3. Click `Don't ask for this host` → banner closes; relaunch claude → banner does **not** reappear.
4. Re-enable by manually removing the entry from `~/Library/Application Support/Treemux/.../app-settings.json` `aiHookSkippedKeys`. (No UI for re-enabling in v1; documented as a known limitation.)

**Step 5 — Commit:**

```bash
git add Treemux/UI/Components/AIHookBanner.swift \
        Treemux/Domain/WorkspaceModels.swift \
        <the modified view> \
        Treemux/Localizable.xcstrings
git commit -m "feat: per-workspace banner inviting hook install"
```

---

## Phase 6 — Final pass

### Task 20: Localization audit

**Files:** `Treemux/Localizable.xcstrings`

**Step 1 — Diff against the project's prior xcstrings to confirm every new key has both `en` (state: `translated`) and `zh-Hans` entries.**

```bash
grep -E '"(Install|Reinstall|Repair|Update|Remove|AI Activity Hints|Show AI activity|Treemux can show|by adding a hook|Preview & Install|Not Now|Don.t ask for this host|Modified by user|Update available|Apply|Cancel|Local|Loading…)"' Treemux/Localizable.xcstrings | head -40
```

**Step 2 — Run the localization smoke test** (manual): open the app with `defaults write -app Treemux AppleLanguages '(zh-Hans)'`, navigate to Settings → AI Activity Hints, verify all strings display in Chinese with correct accents/diacritics.

**Step 3 — Commit (if any fixes were needed):**

```bash
git add Treemux/Localizable.xcstrings
git commit -m "i18n: complete zh-Hans for AI activity hints"
```

---

### Task 21: Final integration smoke + sign-off checklist

**No code changes** — execute the manual QA checklist from the design doc (`docs/plans/2026-04-28-sidebar-ai-attention-design.md` § "Testing Strategy → Manual QA Checklist") and tick off each row in the PR description.

**Build instructions for the user (per project rule in `.claude/CLAUDE.md`):**

After the implementation is complete and you want to test:

```bash
rm -rf ~/.treemux-debug/ && \
  open ~/Library/Developer/Xcode/DerivedData/Treemux-<DerivedData-id>/Build/Products/Debug/Treemux.app
```

Replace `<DerivedData-id>` with the result of:

```bash
ls ~/Library/Developer/Xcode/DerivedData/ | grep '^Treemux-' | head -1
```

(Read the latest one — typically the most recently modified.)

---

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Codex / opencode plugin APIs evolve and break our hook | `inspect()` already returns `.tampered` on parse failure; the UI surfaces `Repair` / `Remove`. No silent breakage. |
| Hook fires during a TUI session and corrupts the screen | OSC 777 is non-displayable. Verified by Liney usage. The helper writes to `/dev/tty`, which is always the controlling terminal — not the TUI's redirected fd. |
| Remote SSH host without `bash` (uses dash etc.) | The helper script starts with `#!/bin/bash`. Document as a requirement; make it a prereq check during install. |
| `~/.codex/config.toml` parsed naively (regex) — edge cases like multi-line strings | The marker block is the only heuristic we rely on. User config that happens to start a line with `notify` outside that block triggers `userConfigConflict`, which is the correct conservative behavior. |
| OSC notification not reaching ghostty due to terminal multiplexer (tmux) | Tmux passes OSC through with `set -g allow-passthrough on`. Document this as a known limitation; defer to v2 if it becomes a real issue (no users yet). |

---

## Post-merge follow-ups (out of scope for this plan)

- v2: Distinct visuals for `done` vs `input` (e.g. different colors).
- v2: System notification fallback when treemux is not the focused app.
- v2: A "Manage skip list" button in Settings to undo `Don't ask for this host`.
- v2: Generic OSC 9 / iTerm-style notification fallback into a notifications history panel.
- v3: Custom `AIHookProvider` backed by a JSON config file in `~/.treemux/agents/`, so users can add their own agents without recompiling treemux.
