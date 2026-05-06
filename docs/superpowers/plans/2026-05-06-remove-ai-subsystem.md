# Remove AI Subsystem & Repurpose Sidebar Activity Dot — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Strip the entire AI attention/hook subsystem from Treemux and reduce the sidebar activity dot to a single static "has running session" indicator.

**Architecture:** Phase 1 sets up the worktree and baseline. Phase 2 deletes 20 AI-only files and removes their entries from `Treemux.xcodeproj/project.pbxproj` (build will be broken at this point). Phase 3 surgically edits the 13 consumer files that referenced the deleted symbols, restoring the build. Phase 4 cleans localization, verifies tests, and runs the app for visual regression confirmation.

**Tech Stack:** Swift 5 / SwiftUI / AppKit, Xcode 15+, `xcodebuild` for headless build & test, Combine, Codable. Project uses `.xcstrings` for localization. Existing test framework is XCTest.

**Spec:** `docs/superpowers/specs/2026-05-06-remove-ai-subsystem-design.md`

---

## Phase 1: Setup

### Task 1: Create worktree

**Files:** None (worktree management).

- [ ] **Step 1: Confirm worktree exists or create it**

The executing flow should have set up an isolated worktree via `superpowers:using-git-worktrees`. Confirm:

```bash
ls -d /Users/yanu/Documents/code/Terminal/treemux/.worktrees/refactor+remove-ai-subsystem 2>/dev/null \
  || git -C /Users/yanu/Documents/code/Terminal/treemux worktree add \
       /Users/yanu/Documents/code/Terminal/treemux/.worktrees/refactor+remove-ai-subsystem \
       -b refactor+remove-ai-subsystem
```

Expected: directory exists. All subsequent paths in this plan are **relative to the worktree root** (`.worktrees/refactor+remove-ai-subsystem/`). `cd` into it before continuing.

- [ ] **Step 2: Verify branch**

```bash
git status -sb
```

Expected: `## refactor+remove-ai-subsystem`

---

### Task 2: Baseline build

**Files:** None (verification).

- [ ] **Step 1: Compile current state**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. If it fails, stop and surface the error — the worktree is broken before we start.

- [ ] **Step 2: Run baseline tests**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' test 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`. Baseline is now established.

---

## Phase 2: Delete AI files

> Build will be **broken** during this phase and remain broken until Phase 3 completes. Do not attempt mid-phase builds — they will fail with "no such module" or "use of undeclared type". The first verification build is in Task 23.

### Task 3: Delete 15 production AI source files

**Files:**
- Delete: `Treemux/Domain/AIAttentionState.swift`
- Delete: `Treemux/Domain/AIHookBannerController.swift`
- Delete: `Treemux/Domain/AIToolModels.swift`
- Delete: `Treemux/Domain/AttentionStore.swift`
- Delete: `Treemux/Services/AITool/AIHookFileSystem.swift`
- Delete: `Treemux/Services/AITool/AIHookInstaller.swift`
- Delete: `Treemux/Services/AITool/AIHookProvider.swift`
- Delete: `Treemux/Services/AITool/AIToolService.swift`
- Delete: `Treemux/Services/AITool/HookBackupService.swift`
- Delete: `Treemux/Services/AITool/RemoteHookFileSystem.swift`
- Delete: `Treemux/Services/AITool/Providers/ClaudeCodeHookProvider.swift`
- Delete: `Treemux/Services/AITool/Providers/CodexHookProvider.swift`
- Delete: `Treemux/Services/AITool/Providers/OpencodeHookProvider.swift`
- Delete: `Treemux/UI/Components/AIHookBanner.swift`
- Delete: `Treemux/UI/Settings/AIActivityHintsSettingsView.swift`
- Delete: `Treemux/UI/Sheets/HookPreviewSheet.swift`

(That's 16 files — `Services/AITool/` directory has 9 files including 3 Providers.)

- [ ] **Step 1: Delete files**

```bash
rm -v \
  Treemux/Domain/AIAttentionState.swift \
  Treemux/Domain/AIHookBannerController.swift \
  Treemux/Domain/AIToolModels.swift \
  Treemux/Domain/AttentionStore.swift \
  Treemux/Services/AITool/AIHookFileSystem.swift \
  Treemux/Services/AITool/AIHookInstaller.swift \
  Treemux/Services/AITool/AIHookProvider.swift \
  Treemux/Services/AITool/AIToolService.swift \
  Treemux/Services/AITool/HookBackupService.swift \
  Treemux/Services/AITool/RemoteHookFileSystem.swift \
  Treemux/Services/AITool/Providers/ClaudeCodeHookProvider.swift \
  Treemux/Services/AITool/Providers/CodexHookProvider.swift \
  Treemux/Services/AITool/Providers/OpencodeHookProvider.swift \
  Treemux/UI/Components/AIHookBanner.swift \
  Treemux/UI/Settings/AIActivityHintsSettingsView.swift \
  Treemux/UI/Sheets/HookPreviewSheet.swift
```

- [ ] **Step 2: Remove now-empty directories**

```bash
rmdir Treemux/Services/AITool/Providers Treemux/Services/AITool
```

Expected: both directories removed without "directory not empty" error.

- [ ] **Step 3: Stage deletions but DO NOT commit yet**

```bash
git add -A Treemux/Domain Treemux/Services Treemux/UI
git status --short | head -20
```

Expected: 16 lines starting with `D ` (deleted).

---

### Task 4: Delete 5 AI test files

**Files:**
- Delete: `TreemuxTests/AttentionStoreTests.swift`
- Delete: `TreemuxTests/AIHookInstallerTests.swift`
- Delete: `TreemuxTests/AIAttentionStateTests.swift`
- Delete: `TreemuxTests/AIToolServiceTests.swift`
- Delete: `TreemuxTests/Support/InMemoryHookFileSystem.swift`

- [ ] **Step 1: Delete test files**

```bash
rm -v \
  TreemuxTests/AttentionStoreTests.swift \
  TreemuxTests/AIHookInstallerTests.swift \
  TreemuxTests/AIAttentionStateTests.swift \
  TreemuxTests/AIToolServiceTests.swift \
  TreemuxTests/Support/InMemoryHookFileSystem.swift
```

- [ ] **Step 2: Stage and commit Phase 2 deletions**

```bash
git add -A TreemuxTests
git commit -m "refactor: delete 21 AI subsystem source/test files

Removes attention monitoring (AttentionStore, AIAttentionState),
hook installer/providers (entire Services/AITool/ tree), banner UI,
settings UI, and all related tests. Build will fail until Phase 3
restores consumer files."
```

---

### Task 5: Remove deleted files from `project.pbxproj`

**Files:**
- Modify: `Treemux.xcodeproj/project.pbxproj`

The pbxproj file contains 4 entries per source file: PBXBuildFile, PBXFileReference, group child membership, and PBXSourcesBuildPhase membership. We delete every line that mentions any of the 21 filenames.

- [ ] **Step 1: Snapshot original pbxproj for safety**

```bash
cp Treemux.xcodeproj/project.pbxproj /tmp/project.pbxproj.backup
wc -l Treemux.xcodeproj/project.pbxproj
```

Note the line count — used to sanity-check the diff later.

- [ ] **Step 2: Run filter script**

```bash
python3 - <<'PY'
import re

DELETED = [
    "AIAttentionState.swift",
    "AIHookBannerController.swift",
    "AIToolModels.swift",
    "AttentionStore.swift",
    "AIHookFileSystem.swift",
    "AIHookInstaller.swift",
    "AIHookProvider.swift",
    "AIToolService.swift",
    "HookBackupService.swift",
    "RemoteHookFileSystem.swift",
    "ClaudeCodeHookProvider.swift",
    "CodexHookProvider.swift",
    "OpencodeHookProvider.swift",
    "AIHookBanner.swift",
    "AIActivityHintsSettingsView.swift",
    "HookPreviewSheet.swift",
    "AttentionStoreTests.swift",
    "AIHookInstallerTests.swift",
    "AIAttentionStateTests.swift",
    "AIToolServiceTests.swift",
    "InMemoryHookFileSystem.swift",
]

path = "Treemux.xcodeproj/project.pbxproj"
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

kept = []
removed = 0
for line in lines:
    if any(name in line for name in DELETED):
        removed += 1
        continue
    kept.append(line)

with open(path, "w", encoding="utf-8") as f:
    f.writelines(kept)

print(f"Removed {removed} lines from project.pbxproj")
PY
```

Expected: prints something like `Removed 84 lines from project.pbxproj` (21 files × ~4 entries each).

- [ ] **Step 3: Sanity-check pbxproj is still parseable**

```bash
xcodebuild -project Treemux.xcodeproj -list 2>&1 | head -10
```

Expected: lists the targets (`Treemux`, `TreemuxTests`, ...) without parse errors. If you see "project.pbxproj is corrupted", restore the backup (`cp /tmp/project.pbxproj.backup Treemux.xcodeproj/project.pbxproj`) and investigate.

- [ ] **Step 4: Confirm no orphaned references remain**

```bash
grep -cE "AIAttentionState|AIHookBannerController|AIToolModels|AttentionStore\\.swift|AIHookFileSystem|AIHookInstaller|AIHookProvider|AIToolService|HookBackupService|RemoteHookFileSystem|ClaudeCodeHookProvider|CodexHookProvider|OpencodeHookProvider|AIHookBanner|AIActivityHintsSettingsView|HookPreviewSheet|AttentionStoreTests|AIHookInstallerTests|AIAttentionStateTests|AIToolServiceTests|InMemoryHookFileSystem" Treemux.xcodeproj/project.pbxproj
```

Expected: `0`.

- [ ] **Step 5: Commit**

```bash
git add Treemux.xcodeproj/project.pbxproj
git commit -m "refactor: drop deleted AI files from Xcode project"
```

---

## Phase 3: Surgical edits to consumers

> Build still broken; will pass at end of Task 18.

### Task 6: Simplify `SidebarItemIconView`

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarItemIconView.swift` (replace whole file)

- [ ] **Step 1: Replace file contents**

```swift
//
//  SidebarItemIconView.swift
//  Treemux
//

import SwiftUI

// MARK: - Activity Indicator State

/// Two-state activity indicator for sidebar icons.
enum SidebarIconActivityIndicator {
    case none
    case working   // Static dot — terminal sessions are running
}

// MARK: - Icon View

/// Renders a sidebar icon as a rounded-rectangle (or circular) tile with an SF Symbol
/// and an optional activity dot at the bottom-right corner.
struct SidebarItemIconView: View {
    let icon: SidebarItemIcon
    let size: CGFloat
    var usesCircularShape: Bool = false
    var activityIndicator: SidebarIconActivityIndicator = .none
    var activityPalette: SidebarIconPalette = .amber
    var isEmphasized: Bool = false

    private var palette: SidebarIconPaletteDescriptor {
        icon.palette.descriptor
    }

    private var backgroundShape: some InsettableShape {
        RoundedRectangle(
            cornerRadius: usesCircularShape ? size / 2 : max(7, size * 0.34),
            style: .continuous
        )
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: icon.symbolName)
                .font(.system(size: max(9, size * 0.48), weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(palette.foreground)
                .frame(width: size, height: size)
                .background(background)
                .overlay(
                    backgroundShape
                        .strokeBorder(palette.border, lineWidth: 1)
                )

            if activityIndicator == .working {
                SidebarIconActivityBadge(size: size, palette: activityPalette)
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: size + 2, height: size + 2)
    }

    @ViewBuilder
    private var background: some View {
        switch icon.fillStyle {
        case .solid:
            backgroundShape.fill(palette.solidBackground)
        case .gradient:
            backgroundShape.fill(
                LinearGradient(
                    colors: [palette.gradientStart, palette.gradientEnd],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }
}

// MARK: - Activity Badge

/// Static dot shown at the bottom-right of a sidebar icon when the node has
/// at least one running terminal session.
struct SidebarIconActivityBadge: View {
    let size: CGFloat
    let palette: SidebarIconPalette

    private var activityColor: Color {
        palette.descriptor.gradientEnd
    }

    private var badgeSize: CGFloat {
        max(6, size * 0.28)
    }

    var body: some View {
        Circle()
            .fill(activityColor)
            .frame(width: badgeSize, height: badgeSize)
            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Treemux/UI/Sidebar/SidebarItemIconView.swift
git commit -m "refactor(sidebar): collapse activity indicator to two states

Removes .current (dead code) and .attention (AI-only) cases plus all
pulse/glow animation state. The dot now only renders when the node
has running terminal sessions and is fully static."
```

---

### Task 7: Simplify `SidebarCoordinator`

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarCoordinator.swift:28-34, 56-64, 251-269`

- [ ] **Step 1: Remove the `attentionCancellable` property + doc comment**

Replace lines 28-34 (the property + its doc comment):

```swift
    /// Subscribes to `AttentionStore.shared.objectWillChange` and force-rebuilds
    /// visible cell content. Sidebar rows are hosted in `NSHostingView<AnyView>`,
    /// where `@ObservedObject` subscriptions are unreliable, so the indicator
    /// is precomputed in `makeCellContent` and passed by value into
    /// `SidebarNodeRow`. This sink is what drives recompute on store changes.
    private var attentionCancellable: AnyCancellable?
```

→ (delete entirely)

After removing, check if `import Combine` is still used elsewhere in the file:

```bash
grep -n "Combine\|AnyCancellable\|Publishers\|\\.sink" Treemux/UI/Sidebar/SidebarCoordinator.swift
```

If no other Combine usage remains, also delete `import Combine` at the top.

- [ ] **Step 2: Remove the AttentionStore subscription block**

In `attach(_:)`, delete the block that starts with `// Subscribe to AttentionStore changes` (around line 56-63):

```swift
        // Subscribe to AttentionStore changes and force-refresh visible rows.
        // Throttled so a burst of updates doesn't tax the main thread.
        attentionCancellable = AttentionStore.shared.objectWillChange
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self, weak outlineView] in
                guard let self, let outlineView else { return }
                self.refreshVisibleRows(on: outlineView)
            }
```

→ (delete entirely)

- [ ] **Step 3: Simplify `activityIndicator(for:)`**

Replace the existing function (around line 251-269) with:

```swift
    /// Computes the activity indicator for a sidebar node from the workspace's
    /// running-session counts. Returns `.working` when the node (or any of its
    /// worktrees) has at least one active TerminalTabController.
    private func activityIndicator(for node: SidebarNodeItem) -> SidebarIconActivityIndicator {
        switch node.kind {
        case .section:
            return .none
        case .workspace(let ws):
            return ws.hasAnyRunningSessions ? .working : .none
        case .worktree(let ws, let wt):
            return ws.hasRunningSessions(forWorktreePath: wt.path.path) ? .working : .none
        }
    }
```

- [ ] **Step 4: Commit**

```bash
git add Treemux/UI/Sidebar/SidebarCoordinator.swift
git commit -m "refactor(sidebar): drop AttentionStore subscription"
```

---

### Task 8: Clean up `SidebarNodeRow` doc comments

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarNodeRow.swift:11-16, 57-58, 126-127`

- [ ] **Step 1: Update top-of-file doc**

Replace lines 11-16 (the `activityIndicator is precomputed by the coordinator (from AttentionStore...)` comment):

```swift
/// `activityIndicator` is precomputed by the coordinator (from `AttentionStore`
/// + workspace running-session state) and passed in by value. We avoid
/// observing `AttentionStore` directly here because this row is hosted inside
/// `NSHostingView<AnyView>`, where SwiftUI's diffing of the wrapped view can
/// suppress `@ObservedObject` re-evaluation. Plain-value props always force a
/// fresh view struct, so the body re-runs whenever the indicator changes.
```

→

```swift
/// `activityIndicator` is precomputed by the coordinator from the workspace's
/// running-session state and passed in by value. The row is hosted inside
/// `NSHostingView<AnyView>`, where SwiftUI's diffing of the wrapped view can
/// suppress `@ObservedObject` re-evaluation. Plain-value props always force a
/// fresh view struct, so the body re-runs whenever the indicator changes.
```

- [ ] **Step 2: Update both row-level docs (lines 57-58 and 126-127) in one pass**

The same comment block appears twice — once on `WorkspaceRowContent.activityIndicator` and once on `WorktreeRowContent.activityIndicator`. Use `Edit` with `replace_all: true` so both are updated together.

`old_string`:

```swift
    /// Precomputed by the coordinator. See `SidebarNodeRow` for why we don't
    /// observe `AttentionStore` directly inside this row.
    let activityIndicator: SidebarIconActivityIndicator
```

`new_string`:

```swift
    /// Precomputed by the coordinator. See `SidebarNodeRow` for why we don't
    /// observe workspace state directly inside this row.
    let activityIndicator: SidebarIconActivityIndicator
```

- [ ] **Step 3: Verify both occurrences updated**

```bash
grep -c "observe workspace state directly" Treemux/UI/Sidebar/SidebarNodeRow.swift
grep -c "observe \`AttentionStore\` directly" Treemux/UI/Sidebar/SidebarNodeRow.swift
```

Expected: `2` and `0`.

- [ ] **Step 4: Commit**

```bash
git add Treemux/UI/Sidebar/SidebarNodeRow.swift
git commit -m "docs(sidebar): drop AttentionStore references from row docs"
```

---

### Task 9: Remove `WorkspaceModel.hasAttention*` overloads

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift:325-378`

- [ ] **Step 1: Delete the three `hasAttention` declarations**

Find and delete:

1. Lines ~356-364 (the computed `var hasAttention: Bool { ... }` and its doc comment "True if any session in any worktree of this workspace is currently asking for attention...").
2. Lines ~366-372 (`func hasAttention(forWorktreePath path: String) -> Bool { ... }` plus doc comment).
3. Lines ~374-378 (`func hasAttention(forTabID tabID: UUID, worktreePath: String) -> Bool { ... }` plus doc comment).

Use Edit calls anchored on the exact `hasAttention` signatures to ensure the right block is removed.

- [ ] **Step 2: Update the upstream comment that mentions `AIHookBannerController`**

Around line 325-330 there's a doc block on `sessionController` mentioning "AIHookBannerController.evaluate must tolerate ...". Replace the sentence referencing `AIHookBannerController` with a generic phrasing:

Find:

```swift
    /// session controller; callers (e.g. AIHookBannerController.evaluate) must tolerate
```

Replace with:

```swift
    /// session controller; callers must tolerate
```

- [ ] **Step 3: Commit**

```bash
git add Treemux/Domain/WorkspaceModels.swift
git commit -m "refactor(workspace): remove hasAttention helpers"
```

---

### Task 10: Strip AI bits from `WorkspaceTabBarView`

**Files:**
- Modify: `Treemux/UI/Workspace/WorkspaceTabBarView.swift:11-14, 102-111, 134-138, 202-231`

- [ ] **Step 1: Remove `attentionStore` observed object**

Replace lines 11-14:

```swift
    /// Observed so attention state changes trigger a re-render. The
    /// `dotKind(for:)` computation calls `workspace.hasAttention(...)`, which
    /// routes through `AttentionStore`.
    @ObservedObject var attentionStore: AttentionStore = .shared
```

→ (delete entirely — including the comment block and the property)

- [ ] **Step 2: Simplify `dotKind(for:)`**

Replace the existing function (lines 102-111):

```swift
    private func dotKind(for tab: WorkspaceTabStateRecord) -> TabActivityDot.Kind? {
        let path = workspace.activeWorktreePath
        if workspace.hasAttention(forTabID: tab.id, worktreePath: path) {
            return .attention
        }
        if workspace.hasRunningSessions(forWorktreePath: path) {
            return .idle
        }
        return nil
    }
```

→

```swift
    private func dotKind(for tab: WorkspaceTabStateRecord) -> TabActivityDot.Kind? {
        let path = workspace.activeWorktreePath
        return workspace.hasRunningSessions(forWorktreePath: path) ? .idle : nil
    }
```

- [ ] **Step 3: Simplify `TabActivityDot` (lines 202-231)**

Replace the entire `TabActivityDot` struct with:

```swift
// MARK: - Activity Dot

/// Small leading-edge dot on a `TabButton` indicating an active session.
private struct TabActivityDot: View {
    enum Kind: Equatable { case idle }

    let kind: Kind

    var body: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 6, height: 6)
            .opacity(0.8)
    }
}
```

- [ ] **Step 4: Update the comment in TabButton body (line 134)**

Find:

```swift
                // AI activity dot (idle/attention) appears between kind icon and title.
```

Replace with:

```swift
                // Activity dot appears between kind icon and title when a session is running.
```

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/Workspace/WorkspaceTabBarView.swift
git commit -m "refactor(tabbar): drop AI attention from tab activity dot"
```

---

### Task 11: Strip AI bits from `ShellSession`

**Files:**
- Modify: `Treemux/Services/Terminal/ShellSession.swift:46-57, 119-124, 139-145, 386-420`

- [ ] **Step 1: Remove `detectedAITool` and `aiAttention`**

Find and delete (lines 46-57):

```swift
    /// Detected AI tool running in this pane.
    @Published var detectedAITool: AIToolDetection?

    /// AI agent attention state, set by OSC 777 `treemux:done` / `treemux:input`
    /// notifications, cleared on focus or user keystroke. Reads live from
    /// `AttentionStore`, the single observable source of truth that views
    /// subscribe to directly.
    var aiAttention: AIAttentionState {
        AttentionStore.shared.state(for: id)
    }
```

→ (delete entire block; keep `detectedTmuxSession` above it)

- [ ] **Step 2: Remove `detectAITool(fromTitle:)` call from `onTitleChange`**

In `configureSurfaceCallbacks()` (around line 119-124), find:

```swift
        surfaceController.onTitleChange = { [weak self] title in
            guard let self, !title.isEmpty else { return }
            self.title = title
            self.detectTmux(fromTitle: title)
            self.detectAITool(fromTitle: title)
        }
```

Replace with:

```swift
        surfaceController.onTitleChange = { [weak self] title in
            guard let self, !title.isEmpty else { return }
            self.title = title
            self.detectTmux(fromTitle: title)
        }
```

- [ ] **Step 3: Remove `clearAIAttention` from `onUserInput`**

Around line 142-144, find:

```swift
        surfaceController.onUserInput = { [weak self] in
            self?.clearAIAttention()
        }
```

→ (delete entire block — the callback is no longer needed)

- [ ] **Step 4: Strip the OSC 777 attention branch + AI helpers**

Delete lines 386-420 (everything from the `applyDesktopNotification` doc comment through the end of `detectAITool(fromTitle:)`):

```swift
    /// Apply an OSC 777 desktop notification. Sets `aiAttention` only when the
    /// title carries the treemux protocol prefix.
    fileprivate func applyDesktopNotification(title: String, body: String?) {
        if let state = AIAttentionState.parse(notificationTitle: title) {
            AttentionStore.shared.setAttention(paneID: id, state: state)
        }
    }

    /// Clear the AI attention state. Called on focus and on user keystroke.
    func clearAIAttention() {
        AttentionStore.shared.clear(paneID: id)
    }

#if DEBUG
    /// Test seam allowing unit tests to drive `aiAttention` without instantiating
    /// a real ghostty surface.
    func applyDesktopNotificationFromTest(title: String, body: String?) {
        applyDesktopNotification(title: title, body: body)
    }
#endif

    /// Detect if an AI tool is running based on the terminal title.
    private func detectAITool(fromTitle title: String) {
        // Extract the likely process name from the title
        let processName = title.components(separatedBy: " ").first ?? title
        if let kind = AIToolKind.detect(processName: processName) {
            detectedAITool = AIToolDetection(kind: kind, isRunning: true, processName: processName)
        } else if detectedAITool != nil {
            // Only clear if the previously detected tool is no longer in the title
            let lower = title.lowercased()
            if !lower.contains("claude") && !lower.contains("codex") {
                detectedAITool = nil
            }
        }
    }
```

→ (delete entire block)

- [ ] **Step 5: Check whether `onDesktopNotification` callback is still needed**

```bash
grep -n "onDesktopNotification\|applyDesktopNotification" Treemux/Services/Terminal/ShellSession.swift
```

If the only remaining reference is in `configureSurfaceCallbacks()` (the `surfaceController.onDesktopNotification = ...` setup), the callback now does nothing useful — remove that setup too:

In `configureSurfaceCallbacks()` find and delete:

```swift
        surfaceController.onDesktopNotification = { [weak self] title, body in
            self?.applyDesktopNotification(title: title, body: body)
        }
```

- [ ] **Step 6: Commit**

```bash
git add Treemux/Services/Terminal/ShellSession.swift
git commit -m "refactor(session): strip AI tool detection and attention hooks"
```

---

### Task 12: Strip AI tool badge from `TerminalPaneView`

**Files:**
- Modify: `Treemux/UI/Workspace/TerminalPaneView.swift:41-53`

- [ ] **Step 1: Remove the AI tool badge block**

Find (lines 41-53):

```swift
            // AI tool badge
            if let aiTool = session.detectedAITool {
                HStack(spacing: 3) {
                    Image(systemName: aiTool.kind.iconName)
                        .font(.system(size: 9))
                    Text(aiTool.kind.displayName)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(theme.successColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(theme.successColor.opacity(0.12), in: Capsule())
            }
```

→ (delete entire block — keep tmux badge below it)

- [ ] **Step 2: Commit**

```bash
git add Treemux/UI/Workspace/TerminalPaneView.swift
git commit -m "refactor(pane): drop AI tool badge from terminal pane header"
```

---

### Task 13: Strip AI banner from `WorkspaceDetailView`

**Files:**
- Modify: `Treemux/UI/Workspace/WorkspaceDetailView.swift` (substantial trim)

- [ ] **Step 1: Replace the `WorkspaceTabContainerView` body**

Replace lines 21-128 (the entire `private struct WorkspaceTabContainerView` definition) with:

```swift
/// Container that manages tab bar visibility and routes to the active tab's content.
private struct WorkspaceTabContainerView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar: shown when 2+ tabs
            if workspace.tabs.count > 1 {
                WorkspaceTabBarView(workspace: workspace)
            }

            // Content area: dispatch by tab kind
            if let tabID = workspace.activeTabID,
               let tab = workspace.tabs.first(where: { $0.id == tabID }) {
                Group {
                    switch tab.kind {
                    case .terminal:
                        if let controller = workspace.sessionController {
                            WorkspaceSessionDetailView(
                                controller: controller,
                                onCloseTab: { workspace.closeTab(tabID) }
                            )
                        }
                    case .fileBrowser:
                        if let controller = workspace.fileBrowserController(forTabID: tabID) {
                            FileBrowserTabContentView(controller: controller)
                        }
                    }
                }
                .id(tabID)
            } else {
                EmptyTabStateView {
                    workspace.createTab()
                }
            }
        }
        .sheet(item: $workspace.pendingBatchClose) { req in
            BatchUnsavedChangesSheet(
                dirtyRelativePaths: req.relativePaths,
                onSaveAll: { workspace.resolveBatchClose(saveAll: true, discard: false) },
                onDiscardAll: { workspace.resolveBatchClose(saveAll: false, discard: true) },
                onCancel: { workspace.pendingBatchClose = nil }
            )
        }
    }
}
```

This drops `bannerController`, `pendingPreview`, the AIHookBanner block, the `.task`/`.onReceive` evaluate calls, the `openPreview` method, the `skipHost` method, and the `.sheet(item: $pendingPreview)` — all of which referenced deleted types.

- [ ] **Step 2: Commit**

```bash
git add Treemux/UI/Workspace/WorkspaceDetailView.swift
git commit -m "refactor(workspace): remove AIHookBanner integration"
```

---

### Task 14: Remove the `aiHooks` settings section

**Files:**
- Modify: `Treemux/UI/Settings/SettingsSheet.swift:24, 36, 49, 62, 153-154`

- [ ] **Step 1: Drop `aiHooks` from the `SettingsSection` enum**

Replace line 24:

```swift
        case general, terminal, theme, sidebarIcons, ssh, shortcuts, aiHooks, updates
```

→

```swift
        case general, terminal, theme, sidebarIcons, ssh, shortcuts, updates
```

- [ ] **Step 2: Remove the `.aiHooks` arms from `title`, `subtitle`, `icon` switches**

Find and delete each of these three lines (they appear in three switch statements):

```swift
            case .aiHooks: return "AI Activity Hints"
```

```swift
            case .aiHooks: return "Hook installation status for Claude Code, Codex, opencode"
```

```swift
            case .aiHooks: return "bell.badge"
```

- [ ] **Step 3: Remove the `case .aiHooks` from the detail switch (around line 153-154)**

Find and delete:

```swift
        case .aiHooks:
            AIActivityHintsSettingsView(settings: $draft, store: store)
```

- [ ] **Step 4: Commit**

```bash
git add Treemux/UI/Settings/SettingsSheet.swift
git commit -m "refactor(settings): remove AI Activity Hints section"
```

---

### Task 15: Remove AI fields from `AppSettings`

**Files:**
- Modify: `Treemux/Domain/AppSettings.swift:27-32, 39-42, 60-61`

- [ ] **Step 1: Delete the two AI properties**

Find and delete (lines 27-32):

```swift
    /// Whether the sidebar/tab AI attention indicator is enabled. Default: on.
    var aiActivityHintsEnabled: Bool = true

    /// Persisted set of (workspace, agent) pairs the user has dismissed via
    /// "Don't ask for this host". Stored as `["<workspaceID>:<AIToolKind.rawValue>"]`.
    var aiHookSkippedKeys: [String] = []
```

→ (delete entire block, keep the surrounding `showDefaultTerminal` and `enableCodeCompletion` properties)

- [ ] **Step 2: Update `CodingKeys`**

Replace lines 39-42:

```swift
    enum CodingKeys: String, CodingKey {
        case version, language, activeThemeID, appearance, terminal, startup, ssh,
             shortcutOverrides, defaultLocalTerminalIcon, updates, showDefaultTerminal,
             aiActivityHintsEnabled, aiHookSkippedKeys, enableCodeCompletion
    }
```

→

```swift
    enum CodingKeys: String, CodingKey {
        case version, language, activeThemeID, appearance, terminal, startup, ssh,
             shortcutOverrides, defaultLocalTerminalIcon, updates, showDefaultTerminal,
             enableCodeCompletion
    }
```

- [ ] **Step 3: Update the custom `init(from decoder:)`**

Find and delete the two `decodeIfPresent` lines (around line 60-61):

```swift
        aiActivityHintsEnabled = try container.decodeIfPresent(Bool.self, forKey: .aiActivityHintsEnabled) ?? true
        aiHookSkippedKeys = try container.decodeIfPresent([String].self, forKey: .aiHookSkippedKeys) ?? []
```

→ (delete both lines; keep the `enableCodeCompletion` line below)

- [ ] **Step 4: Commit**

```bash
git add Treemux/Domain/AppSettings.swift
git commit -m "refactor(settings): drop aiActivityHintsEnabled and aiHookSkippedKeys"
```

---

### Task 16: Remove `AIToolKind` and `toolKind` field from `SessionBackend`

**Files:**
- Modify: `Treemux/Domain/SessionBackend.swift:28-35, 39-45`

- [ ] **Step 1: Delete the `AIToolKind` enum**

Find and delete (lines 28-35):

```swift
// MARK: - AI tool kind

enum AIToolKind: String, Codable {
    case claudeCode = "claude"
    case openaiCodex = "codex"
    case opencode = "opencode"
    case custom
}
```

→ (delete entire block including the MARK comment)

- [ ] **Step 2: Drop `toolKind` from `AgentSessionConfig`**

Replace lines 39-45:

```swift
struct AgentSessionConfig: Codable, Hashable {
    let name: String
    let launchCommand: String
    let arguments: [String]
    let environment: [String: String]
    let toolKind: AIToolKind?
}
```

→

```swift
struct AgentSessionConfig: Codable, Hashable {
    let name: String
    let launchCommand: String
    let arguments: [String]
    let environment: [String: String]
}
```

- [ ] **Step 3: Commit**

```bash
git add Treemux/Domain/SessionBackend.swift
git commit -m "refactor(backend): remove AIToolKind and AgentSessionConfig.toolKind"
```

---

### Task 17: Update `SessionBackendTests` to drop `toolKind`

**Files:**
- Modify: `TreemuxTests/SessionBackendTests.swift:62-78`

- [ ] **Step 1: Replace the `testAgentConfigCodableRoundTrip` function body**

Replace lines 62-78:

```swift
    func testAgentConfigCodableRoundTrip() throws {
        let config = SessionBackendConfiguration.agent(AgentSessionConfig(
            name: "Claude Code",
            launchCommand: "claude",
            arguments: [],
            environment: [:],
            toolKind: .claudeCode
        ))
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SessionBackendConfiguration.self, from: data)
        if case .agent(let agent) = decoded {
            XCTAssertEqual(agent.name, "Claude Code")
            XCTAssertEqual(agent.toolKind, .claudeCode)
        } else {
            XCTFail("Expected agent")
        }
    }
```

→

```swift
    func testAgentConfigCodableRoundTrip() throws {
        let config = SessionBackendConfiguration.agent(AgentSessionConfig(
            name: "Claude Code",
            launchCommand: "claude",
            arguments: [],
            environment: [:]
        ))
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SessionBackendConfiguration.self, from: data)
        if case .agent(let agent) = decoded {
            XCTAssertEqual(agent.name, "Claude Code")
            XCTAssertEqual(agent.launchCommand, "claude")
        } else {
            XCTFail("Expected agent")
        }
    }
```

- [ ] **Step 2: Commit**

```bash
git add TreemuxTests/SessionBackendTests.swift
git commit -m "test(backend): update agent codable test for toolKind removal"
```

---

### Task 18: Clean comment refs in `WorkspaceModelTabKindTests`

**Files:**
- Modify: `TreemuxTests/WorkspaceModelTabKindTests.swift:39, 55`

- [ ] **Step 1: Update the regression comment on line 39**

Find:

```swift
    /// Regression: AIHookBannerController.evaluate touches `workspace.sessionController`
```

Replace with:

```swift
    /// Regression: external observers may touch `workspace.sessionController`
```

- [ ] **Step 2: Update the inline comment on line 55**

Find:

```swift
        // Simulate the AIHookBannerController path: external code touches
```

Replace with:

```swift
        // Simulate an external-observer code path that touches
```

- [ ] **Step 3: Commit**

```bash
git add TreemuxTests/WorkspaceModelTabKindTests.swift
git commit -m "test(workspace): drop AIHookBannerController references from comments"
```

---

## Phase 4: Verification

### Task 19: Build the project

**Files:** None (verification).

- [ ] **Step 1: Compile**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`.

If the build fails:
- Read each error carefully — they will pinpoint any remaining stragglers (e.g. an `import` of a deleted module, a comment referencing a deleted symbol via `///`-style cross-link, a settings key still serialized somewhere we missed).
- Apply targeted fixes; do **not** restore deleted files. Each fix is its own commit (`fix: <one-line>`).
- Re-run this step until clean.

- [ ] **Step 2: Verify no AI symbol leaked back in**

```bash
grep -rnE "AttentionStore|AIHook|AITool|aiAttention|AIAttentionState|aiActivityHints|aiHookSkippedKeys" \
  --include="*.swift" Treemux TreemuxTests
```

Expected: empty output.

```bash
grep -nE "AI |AI\\.|claude|codex|opencode" Treemux/Localizable.xcstrings | head -20
```

Some hits expected (will be cleaned in Task 20).

---

### Task 20: Strip AI keys from `Localizable.xcstrings`

**Files:**
- Modify: `Treemux/Localizable.xcstrings`

The `.xcstrings` format is JSON. Each top-level string key contains a `localizations` block. We open the file in Xcode (or edit the JSON) and remove every entry whose key references AI features.

- [ ] **Step 1: Identify candidate keys**

```bash
python3 - <<'PY'
import json, re

with open("Treemux/Localizable.xcstrings", "r", encoding="utf-8") as f:
    data = json.load(f)

PATTERN = re.compile(r"AI |AI$|AI Tools|AI Activity|AI agent|hook|Hook|claude|Claude|codex|Codex|opencode|Opencode|attention|agent preset|Auto-detect|Activity Hints|Inspecting", re.IGNORECASE)

candidates = []
for key in data.get("strings", {}).keys():
    if PATTERN.search(key):
        candidates.append(key)

for k in candidates:
    print(k)
print(f"\n{len(candidates)} candidate keys")
PY
```

- [ ] **Step 2: Review candidate list**

Examine the printed keys. Some keys (e.g. `"Save failed"`, `"Update available"`, `"Repair"`) may share words but are NOT AI-related — keep them. Build the **final** delete list manually, then drop entries:

- [ ] **Step 3: Apply deletions**

Edit the file (using Edit tool or jq). Example for one key removal:

```python
import json
with open("Treemux/Localizable.xcstrings", "r", encoding="utf-8") as f:
    data = json.load(f)

# Replace this list with the actual keys to delete from Step 2.
TO_DELETE = [
    "AI Tools",
    "Auto-detect AI Tools",
    "Place agent preset JSON files in ~/.treemux/agents/",
    "AI Activity Hints",
    "Hook installation status for Claude Code, Codex, opencode",
    "Show AI activity in sidebar",
    "Inspecting hook status…",
    "No AI agents detected. Run claude, codex, or opencode at least once on this machine to see install options.",
    "by adding a hook to %@.",
    "No provider registered for this agent",
    "New Codex Session",
    # ...add the rest from Step 2
]

removed = 0
for key in TO_DELETE:
    if key in data["strings"]:
        del data["strings"][key]
        removed += 1

with open("Treemux/Localizable.xcstrings", "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")

print(f"Removed {removed} keys")
```

- [ ] **Step 4: Verify file still parses and no AI-only keys remain**

```bash
python3 -c "import json; json.load(open('Treemux/Localizable.xcstrings'))" && echo "VALID JSON"
grep -cE "AI Activity|AI Tools|AI agent" Treemux/Localizable.xcstrings
```

Expected: `VALID JSON`, `0`.

- [ ] **Step 5: Rebuild to confirm no missing string keys**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build 2>&1 | tail -10
```

Expected: still `** BUILD SUCCEEDED **`. If a build warning about a missing localization key appears, restore that key — it means the source still uses it.

- [ ] **Step 6: Commit**

```bash
git add Treemux/Localizable.xcstrings
git commit -m "chore(i18n): drop AI-related localization keys"
```

---

### Task 21: Run the full test suite

**Files:** None.

- [ ] **Step 1: Run tests**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' test 2>&1 | tail -40
```

Expected: `** TEST SUCCEEDED **`.

If any failure, read the error and fix in a follow-up commit. Do not skip failing tests.

---

### Task 22: Manual run verification

**Files:** None (visual QA).

- [ ] **Step 1: Find the DerivedData app path**

```bash
ls -d ~/Library/Developer/Xcode/DerivedData/Treemux-*/Build/Products/Debug/Treemux.app 2>/dev/null
```

Note the exact path. There may be a single `Treemux-<id>` directory. If multiple, pick the most recently modified (`ls -dt ... | head -1`).

- [ ] **Step 2: Launch with clean debug state**

```bash
rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<id>/Build/Products/Debug/Treemux.app
```

Substitute the actual `<id>` from Step 1.

- [ ] **Step 3: Walk the verification checklist**

Confirm each by visual inspection:

- [ ] Open a workspace, start a terminal session → sidebar workspace icon shows a static amber dot at bottom-right.
- [ ] Close all sessions in that workspace → dot disappears.
- [ ] If the workspace has multiple worktrees, the worktree row shows the same static dot when its own sessions are running.
- [ ] **The dot does not pulse, breathe, or glow** — it is purely static. (This is the visual marker that AI attention is fully gone.)
- [ ] No AI banner appears at the top of the workspace detail view.
- [ ] Open Preferences → no "AI Activity Hints" row in the section list.
- [ ] In a terminal pane header, no "Claude Code" / "Codex" / "opencode" badge appears even when running those tools.
- [ ] In the tab bar (with 2+ tabs), the per-tab dot only appears for tabs whose worktree has running sessions.
- [ ] Quit and relaunch — app opens cleanly, no crash, no warning dialog about settings.

If any check fails, capture the symptom and either fix and recommit, or surface for review.

---

### Task 23: Final cleanup

**Files:** None (housekeeping).

- [ ] **Step 1: Verify clean working tree**

```bash
git status -sb
```

Expected: `## refactor+remove-ai-subsystem`, no dirty paths.

- [ ] **Step 2: Inspect commit log**

```bash
git log --oneline main..HEAD
```

Expected: roughly 17 commits — file deletions, pbxproj cleanup, per-file refactors, i18n cleanup. Each commit message describes one concern.

- [ ] **Step 3: Run finishing-a-development-branch skill**

Hand off to `superpowers:finishing-a-development-branch` to decide between merge to main, PR, or further iteration. Do not auto-merge — surface the option list to the user.

---

## Self-Review Notes

- All 33 files from the spec (20 deleted + 13 modified) are covered: Tasks 3-4 delete; Task 5 cleans pbxproj; Tasks 6-18 surgically edit 13 files (including the test comment cleanup).
- No "TBD" / "TODO" / "implement later" placeholders.
- Code blocks in Tasks 6, 7, 10, 13 are full file or full function replacements — no fragments.
- Compiler-driven approach explicitly acknowledged in Phase 2 preamble: build is broken between Tasks 3 and 19; Task 19 is the recovery checkpoint.
- Risk mitigations from spec carried through: backup of pbxproj in Task 5 Step 1; restore-from-backup escape hatch documented inline.
- Task 20 (i18n) intentionally has a Step 2 "review" beat — the candidate list is heuristic, not authoritative, so a human/agent eye is required before deletion.
