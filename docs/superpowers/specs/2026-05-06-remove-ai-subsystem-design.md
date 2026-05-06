# Remove AI Subsystem & Repurpose Sidebar Activity Dot

**Date:** 2026-05-06
**Author:** 卡皮巴拉 (via brainstorming with Claude)
**Status:** Approved for implementation

## Goal

Two coupled changes:

1. **Repurpose the sidebar yellow dot** to mean only *"this workspace/worktree has running terminal sessions"*. Drop the AI-attention overload of the same indicator.
2. **Fully remove the AI subsystem** (attention monitoring, hook installer, hook providers, banner UI, settings UI, related tests) from the codebase as dead weight after change #1.

Sole user is the project maintainer; backwards compatibility for persisted user data is **not** a constraint — first launch after the change may lose AI-related settings, this is acceptable.

## Current Behavior (baseline)

- Sidebar icon's bottom-right indicator (`SidebarIconActivityIndicator` enum, four states: `.none / .current / .working / .attention`) is computed in `SidebarCoordinator.activityIndicator(for:)`:
  - `.attention` (animated pulse) when any session in the workspace/worktree has `aiAttention != .none`, sourced from `AttentionStore.shared`.
  - `.working` (static dot) when there are active `TerminalTabController` instances.
  - `.current` is defined but never returned (dead enum case).
- AI attention itself is set by `ShellSession`'s OSC 777 handler, populated by hook scripts that AI tools (Claude Code / Codex / Opencode) write into `~/.claude/`, `~/.codex/`, etc., installed via `AIHookInstaller` and surfaced through `AIHookBanner` + `AIActivityHintsSettingsView`.
- A second indicator on per-tab `WorkspaceTabBarView.dotKind(for:)` also branches on `workspace.hasAttention(...)`.

## Target Behavior

- Sidebar dot: static (no pulse), `.amber` palette, shown iff the node has any running terminal session.
- Per-tab dot in `WorkspaceTabBarView`: same simplification (drop the attention branch, keep "has running session" semantic).
- Zero AI subsystem code remaining: no AttentionStore, no Hook installer/providers, no banner, no settings UI, no related tests.

## Branch / Worktree

- Branch: `refactor+remove-ai-subsystem`
- Path: `.worktrees/refactor+remove-ai-subsystem/`

## Scope: Files Affected

### Delete entirely (20 files)

**Production source (15):**

| Path | File |
|---|---|
| `Treemux/Domain/` | `AIAttentionState.swift` |
| `Treemux/Domain/` | `AIHookBannerController.swift` |
| `Treemux/Domain/` | `AIToolModels.swift` |
| `Treemux/Domain/` | `AttentionStore.swift` |
| `Treemux/Services/AITool/` | `AIHookFileSystem.swift` |
| `Treemux/Services/AITool/` | `AIHookInstaller.swift` |
| `Treemux/Services/AITool/` | `AIHookProvider.swift` |
| `Treemux/Services/AITool/` | `AIToolService.swift` |
| `Treemux/Services/AITool/` | `HookBackupService.swift` |
| `Treemux/Services/AITool/` | `RemoteHookFileSystem.swift` |
| `Treemux/Services/AITool/Providers/` | `ClaudeCodeHookProvider.swift` |
| `Treemux/Services/AITool/Providers/` | `CodexHookProvider.swift` |
| `Treemux/Services/AITool/Providers/` | `OpencodeHookProvider.swift` |
| `Treemux/UI/Components/` | `AIHookBanner.swift` |
| `Treemux/UI/Settings/` | `AIActivityHintsSettingsView.swift` |
| `Treemux/UI/Sheets/` | `HookPreviewSheet.swift` |

(The whole `Treemux/Services/AITool/` directory should be removed once empty.)

**Tests (5):**

- `TreemuxTests/AttentionStoreTests.swift`
- `TreemuxTests/AIHookInstallerTests.swift`
- `TreemuxTests/AIAttentionStateTests.swift`
- `TreemuxTests/AIToolServiceTests.swift`
- `TreemuxTests/Support/InMemoryHookFileSystem.swift`

### Surgically edit (13 files)

| File | Change |
|---|---|
| `Treemux/Domain/SessionBackend.swift` | Remove `AIToolKind` enum (line 30) and `toolKind` field (line 44). |
| `Treemux/Domain/AppSettings.swift` | Remove AI-related persisted fields (the `["<workspaceID>:<AIToolKind.rawValue>"]` "don't ask" list, etc.). Direct removal — accept first-launch settings loss. |
| `Treemux/Domain/WorkspaceModels.swift` | Remove `hasAttention` (computed), `hasAttention(forWorktreePath:)`, `hasAttention(forTabID:worktreePath:)` overloads + the comment referencing `AIHookBannerController`. |
| `Treemux/Services/Terminal/ShellSession.swift` | Remove `detectedAITool` published property, `aiAttention` computed getter, OSC 777 handler's attention branch (the `AttentionStore.shared.setAttention/clear` calls), `detectAITool(fromTitle:)` method, and the call from init at line 123. |
| `Treemux/UI/Workspace/WorkspaceDetailView.swift` | Remove `bannerController` `@StateObject`, `AIHookBanner` view, `openPreview(_:)` and its installer/fs setup. |
| `Treemux/UI/Workspace/WorkspaceTabBarView.swift` | Remove `attentionStore` `@ObservedObject`, the `if workspace.hasAttention(...)` branch in `dotKind(for:)` at line 104. |
| `Treemux/UI/Workspace/TerminalPaneView.swift` | Remove the `if let aiTool = session.detectedAITool` UI block at line 42. |
| `Treemux/UI/Settings/SettingsSheet.swift` | Remove the `AIActivityHintsSettingsView` row at line 154. |
| `Treemux/UI/Sidebar/SidebarCoordinator.swift` | Remove `attentionCancellable` and the AttentionStore subscription. Simplify `activityIndicator(for:)` (see below). |
| `Treemux/UI/Sidebar/SidebarNodeRow.swift` | Update doc comments that reference `AttentionStore`. No behavior change. |
| `Treemux/UI/Sidebar/SidebarItemIconView.swift` | Trim `SidebarIconActivityIndicator` enum to `.none` and `.working` only. Strip all pulse/glow/animation state from `SidebarIconActivityBadge` (drops `@State isAnimating`, `isAnimatedKind`, `pulseScale`, `pulseDuration`, `coreScale`, `coreOpacity`, `glowRadius`, the two animated `Circle()` overlays, and `updateAnimationState()`). Final view ≈ 30 lines. |
| `Treemux/Localizable.xcstrings` | Remove all AI-related string keys (en source + zh-Hans translations). |
| `TreemuxTests/WorkspaceModelTabKindTests.swift` | Remove the two comment references to `AIHookBannerController` (lines 39 and 55). Test logic unchanged. |

## Core Code Change

### `SidebarCoordinator.activityIndicator(for:)`

```swift
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

### `SidebarIconActivityIndicator` enum

```swift
enum SidebarIconActivityIndicator {
    case none
    case working   // Static dot — terminal sessions are running
}
```

### `SidebarIconActivityBadge`

Reduces to a single static `Circle().fill(activityColor)` with the white window-background stroke. No `@State`, no `onAppear`, no `withAnimation`.

## Implementation Order (compiler-driven)

1. Create worktree at `.worktrees/refactor+remove-ai-subsystem/`.
2. Delete the four data-layer source files (`AttentionStore`, `AIAttentionState`, `AIToolModels`, `AIHookBannerController`) and remove their entries from `Treemux.xcodeproj/project.pbxproj`.
3. Run `xcodebuild` — collect compiler errors. They will pinpoint every remaining call site.
4. Walk the errors: apply the surgical edits in the 13 files in error-driven order.
5. Replace `SidebarIconActivityIndicator` and `SidebarIconActivityBadge` with the simplified versions; update `SidebarCoordinator.activityIndicator(for:)`.
6. Delete the now-orphaned `Services/AITool/` directory, `AIHookBanner.swift`, `AIActivityHintsSettingsView.swift`, `HookPreviewSheet.swift`, and the 5 test files. Sync `project.pbxproj` again.
7. Re-run `xcodebuild` — should be clean.
8. Strip AI keys from `Localizable.xcstrings` (en + zh-Hans).
9. Run `xcodebuild test` — should be green.
10. Manual run verification (see checklist below).

## Runtime Verification Checklist

After build, run via `rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<id>/Build/Products/Debug/Treemux.app`:

- [ ] Sidebar workspace node: opening a terminal session shows a **static** amber dot.
- [ ] Closing all sessions removes the dot.
- [ ] Worktree child node behaves the same.
- [ ] **No pulse / breathing animation anywhere on the dot** (visual regression marker for successful AI removal).
- [ ] No AIHookBanner visible at the top of the workspace detail.
- [ ] Settings sheet does not show an "AI Activity Hints" row.
- [ ] Per-tab dot in `WorkspaceTabBarView` reflects only "has running session".
- [ ] Running `claude` / `codex` in a terminal session triggers no hook-install prompt.
- [ ] Quit and relaunch — no crash, non-AI settings preserved.

## Risks

- **`project.pbxproj` corruption.** Hand-editing the Xcode project file is the single highest-risk step. Mitigation: all work happens in the worktree; if the project becomes unopenable, discard the worktree and restart. Do not touch `main` until the worktree builds and runs cleanly.
- **One-time settings loss.** Acknowledged and accepted by the user. Persisted AI fields will fail to decode on first launch and be dropped.

## Out of Scope

- Migration code for old persisted settings.
- Visual redesign of the dot (color, size, position) — palette stays `.amber`, geometry unchanged.
- Any new feature that reuses the dot for non-session signals (e.g. file dirty, git status). Possible future work, not part of this change.
