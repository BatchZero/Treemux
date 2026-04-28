# Sidebar AI Attention Indicator — Design

**Date:** 2026-04-28
**Status:** Approved (brainstorming complete)
**Branch:** `feat/sidebar-ai-attention`

## Goal

Replace the existing "yellow dot = active worktree / has running session" indicator
with a state model that reflects whether the project's terminals need attention
because Claude Code, Codex, or opencode finished a turn or is waiting for user input.

The dot:

- Disappears entirely when a workspace has no active terminal (or all remote
  terminals are disconnected).
- Renders as a steady amber dot when at least one terminal session is alive.
- Renders as a pulsing amber dot when an AI agent emitted a "needs attention"
  notification that the user hasn't acknowledged yet.

The same indicator surfaces on tab buttons when the user is inside a multi-tab
workspace. Single-tab workspaces hide the tab bar entirely (existing behavior),
so no tab-level indicator is needed there.

Local and remote (SSH) workspaces are both supported, as are all three target
agents (Claude Code, Codex, opencode), and the architecture is extensible to
future agents.

## Non-Goals (v1)

- A notification history panel (no Liney-style "Dynamic Island").
- System-level user notifications via `UNUserNotification`.
- Distinct visual treatment for "turn complete" vs. "needs input" — both blink
  the same dot.
- Automatic editing of any user configuration file. Every write requires
  explicit user confirmation in the UI.
- Detecting agents by binary presence on `PATH` — only by config-file presence.
- Watching agent transcript files (`~/.claude/projects/*.jsonl`) as a fallback
  when hooks aren't installed.

## Architecture Overview

The design has four cooperating layers:

1. **OSC ingestion.** Each AI agent emits an OSC desktop-notification escape
   sequence (`ESC]777;notify;treemux:done;<body>BEL` or `treemux:input`). libghostty
   already parses these into `GHOSTTY_ACTION_DESKTOP_NOTIFICATION`; we add a
   handler in `TreemuxGhosttyController` and forward to `ShellSession`.
2. **Per-session state.** `ShellSession` exposes `aiAttention: AIAttentionState`
   (`.none / .done / .input`). Focus / keypress events clear it.
3. **Workspace aggregation.** `WorkspaceModel` exposes `hasAttention` (and
   `hasAttention(forWorktreePath:)`, `hasAttention(forTab:)`) computed from
   contained sessions. The sidebar and tab bar read from these.
4. **Hook installer.** `AIHookInstaller` is a registry of `AIHookProvider`
   entries. Each provider knows how to detect its agent's presence, inspect its
   config file, install/uninstall a hook entry, and report status. All write
   operations are gated behind explicit user confirmation in the Settings UI or
   a one-time banner.

## State Model

`SidebarIconActivityIndicator` (existing enum at
`Treemux/UI/Sidebar/SidebarItemIconView.swift:11`) gains a new case `.attention`
and a refined semantics map:

| State | Trigger | Visual |
|---|---|---|
| `.none` | No active `ShellSession` in workspace, or all SSH sessions disconnected | No badge |
| `.idle` | At least one session has `lifecycle ∈ {.starting, .running}` | Steady amber dot |
| `.attention` | Any session has `aiAttention ∈ {.done, .input}` (and not yet cleared) | Pulsing amber dot, faster pulse than the old `.working`, slightly brighter |
| `.current` | (Worktree row only) Active worktree marker | Reuses existing `SidebarInfoBadge(text: "current")` text badge — moves out of the dot system |

The old `.working` (animated for "has running sessions") is replaced by the new
`.idle` (steady) so that animation is reserved exclusively for "needs your
attention".

`.attention` is cleared on any of:

- The user focuses a pane belonging to that session (`ShellSession.setFocused(true)`).
- The user types in that pane (existing PTY input path).
- A new OSC notification arrives (state replaced, animation re-triggered).

When multiple sessions in a workspace exist, the workspace-level indicator is
`.attention` if **any** session is in attention; otherwise `.idle` if **any**
session is alive; otherwise `.none`.

## OSC Convention

We piggyback on the existing OSC 777 desktop-notification format:

```
ESC]777;notify;<title>;<body>BEL
```

Treemux interprets `<title>` only:

- `treemux:done` → `aiAttention = .done`
- `treemux:input` → `aiAttention = .input`
- Any other title → not our concern; the OSC is still forwarded to a generic
  notification path (deferred to v2; v1 simply ignores).

`<body>` is currently unused but the field is preserved end-to-end so we can
surface tooltip text in future versions without changing the wire format.

## OSC Ingestion Implementation

### `TreemuxGhosttyController`

Add a case in the action handler (mirroring Liney
`Liney/Services/Terminal/Ghostty/LineyGhosttyController.swift:189-198`):

```swift
case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
    let title = action.action.desktop_notification.title.map(String.init(cString:)) ?? ""
    let body  = action.action.desktop_notification.body.map(String.init(cString:))
    DispatchQueue.main.async { [weak self] in
        self?.onDesktopNotification?(title, body)
    }
    return true
```

### `TerminalSurface` protocol

Add `var onDesktopNotification: ((String, String?) -> Void)? { get set }` to
`TerminalSurfaceController` so future engines (if any) can route the same
event.

### `ShellSession`

```swift
enum AIAttentionState: Equatable {
    case none
    case done
    case input
}

@Published private(set) var aiAttention: AIAttentionState = .none

private func applyDesktopNotification(title: String, body: String?) {
    switch title {
    case "treemux:done":  aiAttention = .done
    case "treemux:input": aiAttention = .input
    default: return // not ours; ignore in v1
    }
}
```

Clearing hooks:

- `setFocused(true)` → if focused became true, set `aiAttention = .none`.
- The keystroke path inside the surface controller — extend `sendText` /
  key-down callback to call `clearAIAttention()` once per keystroke. (No new
  callback needed; `ShellSession` already wires user input through the surface.)

## Workspace Aggregation

In `WorkspaceModel`:

```swift
var hasAttention: Bool {
    tabControllers.values.contains { tabMap in
        tabMap.values.contains { ctrl in
            ctrl.sessions.values.contains { $0.aiAttention != .none }
        }
    }
}

func hasAttention(forWorktreePath path: String) -> Bool { ... }
func hasAttention(forTabID tabID: UUID, worktreePath: String) -> Bool { ... }
```

`SidebarNodeRow.WorkspaceRowContent.activityIndicator`:

```swift
private var activityIndicator: SidebarIconActivityIndicator {
    if workspace.hasAttention { return .attention }
    if workspace.hasAnyRunningSessions { return .idle }
    return .none
}
```

Worktree row analogous, scoped to that worktree's path.

## Tab Bar

`WorkspaceTabBarView.TabButton` adds a 6×6 leading-side dot when its tab has
running sessions. The dot uses the same three-state palette:

- Tab has `hasAttention(forTabID:worktreePath:) == true` → pulse
- Tab has any `WorkspaceSessionController.sessions` non-empty → steady
- Otherwise → no dot

The dot sits before `Text(tab.title)` inside `HStack(spacing: 4)`. Tab width
calculation in `TreemuxTabSizing.width` adds 10pt (6 dot + 4 spacing) when
applicable.

The tab bar already hides itself when `tabs.count == 1`, so no special-casing
is required for single-tab workspaces.

## Hook Installer Architecture

### Provider Registry

```swift
struct AIHookProvider {
    let kind: AIToolKind
    let displayName: String
    let detectionPaths: [String]   // any-of existence test, e.g. "~/.claude/settings.json"
    let configFile: String          // primary file we'd merge into
    let helperResources: [String]   // helper scripts shipped in app bundle Resources/
    let install:    (HookTarget) async throws -> InstallReceipt
    let uninstall:  (HookTarget) async throws -> Void
    let inspect:    (HookTarget) async throws -> HookStatus
}

enum HookTarget {
    case local
    case remote(SSHTarget)
}

enum HookStatus: Equatable {
    case notDetected
    case detectedNotInstalled
    case installed(version: String, installedAt: Date)
    case installedOutdated(currentVersion: String, latestVersion: String)
    case tampered(reason: String)
    case unknown(reason: String)        // remote unreachable
}

let kBuiltInProviders: [AIHookProvider] = [.claudeCode, .codex, .opencode]
```

Adding a future agent (`cursor`, `gemini`, `aider`, …) is a matter of appending
a new `AIHookProvider` to the registry; no UI changes are required.

### Provider Specs

#### Claude Code

- `detectionPaths`: `["~/.claude", "~/.claude/settings.json"]` (any of)
- `configFile`: `~/.claude/settings.json` (creates if missing on user-confirmed install)
- `helperResources`: `notify.sh`
- Install merges:
  ```json
  {
    "hooks": {
      "Notification": [{
        "_treemuxManaged": true,
        "_treemuxVersion": "1",
        "hooks": [{ "type": "command", "command": "$HOME/.treemux/hooks/notify.sh input" }]
      }],
      "Stop": [{
        "_treemuxManaged": true,
        "_treemuxVersion": "1",
        "hooks": [{ "type": "command", "command": "$HOME/.treemux/hooks/notify.sh done" }]
      }]
    }
  }
  ```
  Existing user entries in `Notification` / `Stop` arrays are preserved (we
  append, not replace). Uninstall removes only the entries with
  `"_treemuxManaged": true`.

#### Codex

- `detectionPaths`: `["~/.codex", "~/.codex/config.toml"]`
- `configFile`: `~/.codex/config.toml`
- `helperResources`: `notify.sh`, `notify-codex.sh`
- Install adds (preceded by a `# treemux-managed` marker line):
  ```toml
  # treemux-managed v1
  notify = ["$HOME/.treemux/hooks/notify-codex.sh"]
  ```
  If `notify` already exists with a non-treemux value, install fails with a
  clear error directing the user to remove their existing line; we never silently
  overwrite. Uninstall removes both the marker and the `notify` line.
  `notify-codex.sh` parses the JSON event passed by Codex, mapping
  `agent-turn-complete → done`, `agent-turn-tool-call-approval-requested → input`.

#### opencode

- `detectionPaths`: `["~/.config/opencode", "~/.config/opencode/config.json"]`
- `configFile`: `~/.config/opencode/plugins/treemux-notify.js` (we own this
  file outright; no merge needed)
- `helperResources`: `notify.sh`, `treemux-notify.js`
- Install: write `treemux-notify.js` directly into the plugins directory.
  Uninstall: delete that file.

### Helper Script

`~/.treemux/hooks/notify.sh` (single source of truth, all providers reference it):

```bash
#!/bin/bash
# treemux v1
event="${1:-done}"
body="${2:-}"
printf '\033]777;notify;treemux:%s;%s\007' "$event" "$body" > /dev/tty 2>/dev/null
```

Writing to `/dev/tty` ensures the OSC bytes reach the controlling terminal even
when stdout/stdin are captured by the agent.

### Remote Installation

For `case .remote(let sshTarget)` we reuse the existing SSH session that
treemux already maintains for that workspace. Operations:

- `mkdir -p ~/.treemux/hooks ~/.claude ~/.codex ~/.config/opencode/plugins`
- `cat > path` with heredoc-quoted content for each file
- `chmod +x ~/.treemux/hooks/*.sh`

No remote daemon, no port forwarding, no extra binaries.

### Status Detection

`inspect(target)` for each provider:

1. Existence check on `detectionPaths` — if none exist, return `.notDetected`.
2. Read `configFile`, parse, look for `_treemuxManaged` markers (or, for opencode,
   plugin file presence).
3. Compare against the version embedded in the helper bundle resource:
   - Marker absent → `.detectedNotInstalled`
   - Marker present, version match, helper script exists → `.installed`
   - Marker present, version older → `.installedOutdated`
   - Marker present but command path or helper script missing → `.tampered`
4. Network/SSH error on remote → `.unknown(reason:)`.

## Trigger UX

### Passive Banner (one-time per (workspace, agent))

Conditions, all required:

1. `ShellSession.detectedAITool` becomes non-nil with kind matching a provider.
2. That provider's status on the workspace's target is `.detectedNotInstalled`.
3. The (workspace.id, provider.kind) pair is **not** in `aiHookSkippedKeys`.

Action: render a non-modal banner above the active terminal area:

```
┌──────────────────────────────────────────────────────────────────────┐
│  💡  Treemux can show when Claude Code finishes or needs your input  │
│      by adding a hook to ~/.claude/settings.json.                    │
│      [Preview & Install]   [Not Now]   [Don't ask for this host]    │
└──────────────────────────────────────────────────────────────────────┘
```

`Preview & Install` opens a sheet showing the proposed before/after of the
config file (read-only diff view); user must click `Apply` inside the sheet
to actually write.

`Not Now` dismisses for the current treemux session only.

`Don't ask for this host` adds the (workspace.id, provider.kind) tuple to a
persisted skip list.

### Settings Panel (active management)

`Settings → AI Activity Hints`:

- Master toggle: `Show AI activity in sidebar` (default: on). When off, the
  whole feature is gated — no OSC processing, no banners.
- A list grouped by target (Local + each remote host the user has workspaces
  for). Each group shows only providers whose `inspect` returned anything other
  than `.notDetected` for that target. If a group would be empty, the group is
  hidden.
- Each row: provider display name, status badge, action buttons:
  - `.detectedNotInstalled` → `[Install]`
  - `.installed` → `[Reinstall]` `[Remove]`
  - `.installedOutdated` → `[Update]` `[Remove]`
  - `.tampered` → `[Repair]` `[Remove]`
- Every button opens the same diff-preview sheet before writing.

## Persistence

`AppSettings` additions:

```swift
@Published var aiActivityHintsEnabled: Bool = true
@Published var aiHookSkippedKeys: Set<String> = []
//  key format: "<workspace.id.uuidString>:<AIToolKind.rawValue>"
@Published var aiHookInstallStatusCache: [String: AIHookStatusRecord] = [:]
//  key format: "<target.id>:<AIToolKind.rawValue>"
//  populated lazily by inspect() calls; treated as a hint, not authoritative
```

`AIHookStatusRecord`: `Codable` struct with `version`, `installedAt`, `helperHash`.

Status cache exists only to avoid re-running `inspect` on every UI redraw; the
real source of truth is always the file system.

## Edge Cases

| Scenario | Behavior |
|---|---|
| User never invokes claude/codex/opencode in a workspace | Settings list shows no providers for that target. No banner ever appears. |
| User deletes `~/.claude/settings.json` after install | Next claude launch in any workspace re-detects `.detectedNotInstalled`; banner reappears unless skipped. |
| User edits our hook entry | `inspect` returns `.tampered`; UI shows `[Repair]`. We never auto-rewrite. |
| Agent updates introduce a new config schema | `inspect` returns `.tampered` (parse failure); user chooses Repair or ignores. |
| Future agent type added | New `AIHookProvider` instance in registry; UI adapts automatically. |
| Remote SSH temporarily disconnected during inspect | Status `.unknown(reason:)`; cached previous result is shown with a stale-marker; refresh on reconnect. |
| Multiple panes in a tab, only one runs an AI agent | That session's `aiAttention` drives the dot; tab and workspace aggregate as `.attention`. |
| OSC arrives without `treemux:` prefix | Ignored in v1 (no notification panel; no system notification). |
| Config exists but agent is configured per-project, not per-user (e.g. `.claude/settings.json` in repo root) | Outside scope of detection; v1 only inspects `~/`. Documented as a known limitation. |

## Internationalization

New `LocalizedStringKey` strings (English source + `zh-Hans` translations
required per project rule):

- `Show AI activity in sidebar` / `在侧边栏显示 AI 活动状态`
- `AI Activity Hints` / `AI 活动提示`
- `Treemux can show when %@ finishes or needs your input` / `Treemux 可以在 %@ 完成或需要输入时提示`
- `Preview & Install` / `预览并安装`
- `Not Now` / `暂不`
- `Don't ask for this host` / `不再为此主机询问`
- `Install` / `安装`
- `Reinstall` / `重新安装`
- `Repair` / `修复`
- `Update` / `更新`
- `Remove` / `移除`
- `Modified by user` / `已被用户修改`
- `Update available` / `有可用更新`
- `Apply` / `应用`
- `Cancel` / `取消`
- Banner / sheet body strings as needed.

All entries land in `Treemux/Localizable.xcstrings` before merging.

## Testing Strategy

### Unit Tests

- `AIAttentionState` parsing: `treemux:done` / `treemux:input` / unrelated title /
  empty title.
- `WorkspaceModel.hasAttention` aggregation across multiple sessions / worktrees /
  tabs.
- Claude `settings.json` merge: empty file, file with unrelated hooks, file
  with our hooks already present (idempotent reinstall), file with our hooks
  plus user hooks (preserved on uninstall).
- Codex TOML merge: no `notify` key, our `notify` key, user's `notify` key
  (must error rather than overwrite).
- opencode plugin file: write/delete round-trip.
- `HookStatus` decision tree: each branch covered.

### Integration Tests

- Spawn a local shell, externally `printf` an OSC `treemux:done` to its TTY,
  verify sidebar reaches `.attention` within one runloop tick.
- Same for SSH session: from inside the remote shell, `printf` to the remote
  TTY, verify it propagates back.
- Install hook for Claude locally, run `claude` to a clean exit (Stop event),
  verify dot blinks.
- Focus the pane → dot clears.

### Manual QA Checklist (in PR description)

- [ ] Single-tab workspace: project dot blinks, no tab bar shown.
- [ ] Multi-tab workspace: project dot + tab dot both blink.
- [ ] Switching to the blinking tab clears its dot.
- [ ] Local Claude Code hook install via Settings UI shows correct diff.
- [ ] Local Claude Code Stop / Notification hooks both trigger blink.
- [ ] Codex install: turn-complete and approval requests both trigger blink.
- [ ] opencode install: session.idle and permission.requested both trigger blink.
- [ ] Banner appears once per (workspace, agent), not on every restart after
      "Don't ask".
- [ ] Provider hidden in Settings UI when its detection paths don't exist.
- [ ] Remote SSH workspace: install + trigger end-to-end.
- [ ] Tampered hook (manually edit settings.json) → status shows `.tampered`,
      Repair button restores correctly.
- [ ] Uninstall removes only our entries; user-added hooks survive.
