# Treemux Design Document

Date: 2026-03-25

## Overview

Treemux is a native macOS terminal workspace application for developers who work across repositories, worktrees, branches, and split panes. Built from scratch in Swift/SwiftUI with libghostty as the embedded terminal engine, it is inspired by [Liney](https://github.com/everettjf/liney) but adds key features: internationalization (Chinese/English), remote server support via SSH, tmux session restoration, customizable theme system, and deep AI tool integration.

## Goals

- Native macOS experience (Swift 6 + SwiftUI + AppKit, Apple Silicon)
- Manage multiple local and remote projects in a unified sidebar
- Preserve and restore terminal pane layouts per worktree
- First-class support for SSH remote development with auto-detection of SSH config
- Automatic tmux session reconnection on app restart
- Global theme system with custom theme support
- Deep integration with AI coding tools (Claude Code, Codex, etc.)
- Native Chinese/English internationalization

## Architecture

### Layer Overview

```
Treemux/
├─ App/                     # App lifecycle, window management
├─ Domain/                  # Core models (Workspace, Pane, Session, Theme)
├─ Persistence/             # JSON file persistence (~/.treemux/)
├─ Services/
│  ├─ Git/                  # Git/Worktree operations
│  ├─ Terminal/
│  │  └─ Ghostty/           # libghostty embedding
│  ├─ SSH/                  # SSH Config parsing, remote connection management
│  ├─ Tmux/                 # tmux session detection, restoration
│  ├─ AITool/               # AI tool detection and integration
│  └─ Process/              # Subprocess management
├─ Localization/            # i18n (Chinese/English)
├─ UI/
│  ├─ Sidebar/              # Left project tree
│  ├─ Workspace/            # Terminal panes, split views
│  ├─ Sheets/               # Dialogs (new project, SSH connection, etc.)
│  ├─ Theme/                # Theme management UI
│  ├─ Settings/             # Settings interface
│  └─ Components/           # Reusable components
└─ Vendor/
   └─ GhosttyKit.xcframework
```

### Data Flow

```
AppDelegate
  → TreemuxApp (app orchestration)
    → WindowContext
      → WorkspaceStore (@MainActor ObservableObject, source of truth)
        → MainWindowView
          → SplitNodeView (recursive binary tree render)
            → TerminalPaneView
              → ShellSession
                → GhosttyController (libghostty)
```

## Core Data Models

### Workspace

```swift
enum WorkspaceKind {
    case repository
    case localTerminal
    case remote(SSHTarget)
}

class WorkspaceModel: ObservableObject {
    let id: UUID
    var kind: WorkspaceKind
    var name: String
    var repositoryRoot: URL?
    var currentBranch: String?
    var worktrees: [WorktreeModel]
    var tabs: [WorkspaceTab]
    var selectedTabID: UUID?
    var sessionController: WorkspaceSessionController
}

struct WorkspaceRecord: Codable {
    let id: UUID
    let kind: WorkspaceKindRecord
    let name: String
    let repositoryPath: String?
    let worktreeStates: [WorktreeSessionStateRecord]
}
```

### Pane Layout (recursive binary tree)

```swift
indirect enum SessionLayoutNode: Codable {
    case pane(PaneLeaf)
    case split(PaneSplitNode)
}

struct PaneSplitNode: Codable {
    var axis: SplitAxis        // .horizontal | .vertical
    var fraction: Double       // 0.12...0.88
    var first: SessionLayoutNode
    var second: SessionLayoutNode
}
```

### Session Backend Configuration

```swift
enum SessionBackendConfiguration: Codable {
    case localShell(LocalShellConfig)
    case ssh(SSHSessionConfig)
    case agent(AgentSessionConfig)
    case tmuxAttach(TmuxAttachConfig)
}

struct TmuxAttachConfig: Codable {
    let sessionName: String
    let windowIndex: Int?
    let isRemote: Bool
    let sshTarget: SSHTarget?
}
```

### SSH Target

```swift
struct SSHTarget: Codable, Hashable {
    let host: String
    let port: Int
    let user: String?
    let identityFile: String?
    let displayName: String
    let remotePath: String?
}
```

### Theme

```swift
struct ThemeDefinition: Codable {
    let id: String
    let name: String
    let author: String?
    let terminal: TerminalColors
    let ui: UIColors
    let font: FontConfig?
}

struct TerminalColors: Codable {
    let foreground: String
    let background: String
    let cursor: String
    let selection: String
    let ansi: [String]          // 16 colors
}

struct UIColors: Codable {
    let sidebarBackground: String
    let sidebarForeground: String
    let sidebarSelection: String
    let tabBarBackground: String
    let paneBackground: String
    let paneHeaderBackground: String
    let dividerColor: String
    let accentColor: String
    let statusBarBackground: String
    let textPrimary: String
    let textSecondary: String
    let textMuted: String
    let success: String
    let warning: String
    let danger: String
}
```

### AI Tool Models

```swift
struct AIToolDetection {
    let kind: AIToolKind
    let isRunning: Bool
    let processName: String
}

enum AIToolKind: String, Codable {
    case claudeCode = "claude"
    case openaiCodex = "codex"
    case custom
}

struct AgentSessionConfig: Codable {
    let name: String
    let launchCommand: String
    let arguments: [String]
    let environment: [String: String]
    let toolKind: AIToolKind?
}
```

## Services

### Git Service

```swift
actor GitRepositoryService {
    func inspectRepository(at path: URL) async throws -> RepositorySnapshot
    func listWorktrees(at path: URL) async throws -> [WorktreeModel]
    func createWorktree(at path: URL, branch: String, newPath: URL) async throws
    func removeWorktree(at path: URL) async throws
    func currentBranch(at path: URL) async throws -> String
    func repositoryStatus(at path: URL) async throws -> RepositoryStatusSnapshot
}
```

### SSH Config Service

```swift
actor SSHConfigService {
    func loadSSHConfig() async throws -> [SSHTarget]
    func startWatching() async
    func testConnection(_ target: SSHTarget) async -> ConnectionStatus
    func listRemoteDirectory(_ target: SSHTarget, path: String) async throws -> [RemoteFileEntry]
    func detectRemoteRepository(_ target: SSHTarget, path: String) async throws -> Bool
}

enum ConnectionStatus {
    case connected
    case authRequired
    case unreachable(Error)
}
```

### Tmux Service

```swift
actor TmuxService {
    func listLocalSessions() async throws -> [TmuxSessionInfo]
    func listRemoteSessions(_ target: SSHTarget) async throws -> [TmuxSessionInfo]
    func isSessionAlive(name: String, remote: SSHTarget?) async -> Bool
    func attachCommand(for session: TmuxSessionInfo) -> String
    func remoteAttachCommand(for session: TmuxSessionInfo, via target: SSHTarget) -> String
}

struct TmuxSessionInfo: Codable {
    let name: String
    let windowCount: Int
    let isAttached: Bool
    let createdAt: Date?
}
```

### AI Tool Service

```swift
@MainActor
class AIToolService: ObservableObject {
    func detectAITool(in session: ShellSession) -> AIToolDetection?
    @Published var presets: [AgentSessionConfig]
    func loadPresets() throws
    func launchConfig(for preset: AgentSessionConfig, workingDirectory: URL) -> TerminalLaunchConfiguration
}
```

Detection: via Ghostty shell integration process name matching against known AI tool processes. When detected, the pane header displays the corresponding icon and label.

### Terminal/Ghostty Service

```
GhosttyRuntime (singleton)        // libghostty init, global config
  → GhosttyController            // one per pane, manages surface lifecycle
    → GhosttyShellIntegration    // shell hook injection (cwd tracking, etc.)
    → GhosttyInputSupport        // keyboard input handling
    → GhosttyClipboardSupport    // clipboard operations

Extension: GhosttyRuntime.applyTheme(_ theme: ThemeDefinition)
```

### File System Watch Service

```swift
actor WorkspaceMetadataWatchService {
    func watch(repositoryAt path: URL, onChange: @escaping () -> Void)
    func watchSSHConfig(onChange: @escaping () -> Void)
}
```

## UI Design

### Overall Layout

```
┌──────────────────────────────────────────────────────────┐
│                                          [⚙ Menu ▾]     │
├──────────┬───────────────────────────────────────────────┤
│          │  Tab Bar: [General ▾] [codex ▾] [+]          │
│ Sidebar  ├──────────────────────┬──────────────────────┤
│          │                      │                      │
│ Local    │  Pane 1              │  Pane 2              │
│ project1 │  🤖 Claude Code      │  (shell)             │
│  main    │                      │                      │
│  feat-1  │                      │                      │
│ project2 │                      │                      │
│          ├──────────────────────┴──────────────────────┤
│ 🟢 srv1  │                                             │
│  proj-a  │  Pane 3                                     │
│ 🟡 srv2  │  📎 tmux: dev-session                       │
│  proj-b  │                                             │
│          │─────────────────────────────────────────────│
│          │ ⌥ main | ↑2 ↓1    ⌥ main | ↑2 ↓1          │
│[Open...] │ (per-pane git status bar at bottom)         │
└──────────┴─────────────────────────────────────────────┘
```

### Sidebar Structure

```
Sidebar
├─ Section: Local Projects
│  ├─ 📂 project1
│  │  ├─ main (current)
│  │  └─ feat-1
│  └─ 📂 project2
│
├─ Section: 🟢 server1 (user1@)
│  ├─ proj-a
│  └─ proj-b
├─ Section: 🟡 server2 (user1@)
│  ├─ proj-a
│  └─ proj-b
├─ Section: 🔴 server2 (user2@)
│  ├─ proj-a
│  └─ proj-b
│
└─ [Open Project...]
```

Each server+user combination is an independent Section at the same level as "Local Projects". Visual distinction via:
- Connection status dot (🟢 online / 🟡 connecting / 🔴 offline)
- Host alias + `user@` display
- Remote project rows have subtle remote icon differentiation

### Top-right Menu Button (⚙ ▾)

```
┌──────────────────┐
│ Settings...  ⌘,  │
│ ──────────────── │
│ Command Palette ⌘⇧P │
│ About Treemux    │
│ Check for Updates│
└──────────────────┘
```

Theme switching and language settings are inside the Settings sheet.

### Terminal Pane

```
┌────────────────────────────────┐
│ 🤖 Claude Code  ~/project1    │  ← Pane header
│                                │
│  Terminal content...           │
│                                │
├────────────────────────────────┤
│ ⌥ main | ↑2 ↓1 | +3 ~2 -0   │  ← Per-pane git status bar
└────────────────────────────────┘
```

### Pane Context Menu

- Split horizontally
- Split vertically
- Close pane
- Zoom / Unzoom
- Duplicate pane
- ────────
- New Claude Code session
- New Codex session
- Attach tmux session...
- SSH connection...

### Open Project Dialog

```
┌─ Open Project ─────────────────────┐
│                                    │
│  ○ Local Project                   │
│    [Choose Folder...]              │
│                                    │
│  ○ Remote Server                   │
│    Server: [ server1        ▾ ]    │
│            (auto-read from SSH config) │
│    Path:   [ /home/user/proj  📁 ] │
│            (remote directory browsing) │
│                                    │
│           [Cancel]  [Open]         │
└────────────────────────────────────┘
```

### Settings Sheet

```
Settings
├─ Tab: General
│  ├─ Language: [Follow System ▾] / 中文 / English
│  ├─ Startup: Restore last session / Blank
│  └─ Quit confirmation when active sessions
├─ Tab: Terminal
│  ├─ Default Shell
│  ├─ Font size
│  └─ Cursor style
├─ Tab: Theme
│  └─ Theme picker (Treemux Dark / Treemux Light / custom)
├─ Tab: AI Tools
│  ├─ Preset management (add/edit/delete)
│  └─ Auto-detection toggle
├─ Tab: SSH
│  ├─ SSH Config paths
│  └─ Detected server list
└─ Tab: Shortcuts
   └─ Shortcut customization
```

### Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| New Tab | ⌘T |
| Close Pane | ⌘W |
| Split Horizontal | ⌘D |
| Split Vertical | ⌘⇧D |
| Switch Panes | ⌘[ / ⌘] |
| Zoom Pane | ⌘⇧Enter |
| Command Palette | ⌘⇧P |
| Toggle Sidebar | ⌘B |
| Quick Switch Project | ⌘K |
| Theme Switch | ⌘⇧T |
| New Claude Code | ⌘⇧C |

## Persistence

### File Structure

```
~/.treemux/
├─ settings.json
├─ workspace-state.json
├─ themes/
│  ├─ treemux-dark.json
│  ├─ treemux-light.json
│  └─ *.json                  # user custom themes
└─ agents/
   └─ *.json                  # AI tool preset configs
```

All JSON files use `version` field for forward migration. Written with pretty-printed + sorted keys formatting.

### Persistence Timing

| Event | Action |
|-------|--------|
| Pane split/close/resize | Save workspace-state.json |
| Switch workspace/worktree | Save workspace-state.json |
| Modify settings | Save settings.json |
| Switch theme | Update activeThemeID in settings.json |
| App quit | Save all state |
| App launch | Load settings.json → workspace-state.json → theme files |

## Session Restoration

### App Launch Flow

```
App Launch
  → Load settings.json
  → Load and apply theme
  → Load workspace-state.json
  → Restore window layout (position, size)
  → Iterate selected workspace's current worktree tabs
    → For each tab, restore layout tree
      → For each pane by backend type:
         ├─ localShell → Start new shell, cd to saved workingDirectory
         ├─ ssh → Re-establish SSH connection; show error on failure with manual retry
         ├─ agent → Do NOT auto-restart; show "Session ended, press Enter to restart"
         └─ tmuxAttach → Detect tmux session (local or remote)
             ├─ Alive → Auto tmux attach -t <name>
             └─ Dead → Degrade to localShell/ssh, restore cwd
```

### Tmux Detection

When user runs `tmux attach` or `tmux new-session` in any pane:
1. Shell integration hook reports current process name
2. Process name matches "tmux"
3. Parse $TMUX environment variable for session info
4. Pane header shows 📎 tmux: <session-name>
5. On persist, mark pane backend as tmuxAttach

### Lazy Loading for Inactive Workspaces

- Selected workspace → Immediately restore all tabs and panes
- Other workspaces → Only restore sidebar metadata (name, branch)
- On user switch → Restore panes on demand

### Quit Behavior

- Check for active-process panes → Confirm dialog if any
- Save all workspace state to workspace-state.json
- Close all terminal surfaces
- tmux sessions continue running in background (reconnectable on next launch)

## Internationalization

Using Apple's native String Catalog (`.xcstrings`, Xcode 15+).

### Supported Languages

| Language | Code |
|----------|------|
| English | en (development language) |
| Simplified Chinese | zh-Hans |

### Language Switch Logic

- Default: follow system language
- Override: configurable in Settings → General → Language
- Stored in settings.json as `"language": "system" | "en" | "zh-Hans"`

### Translation Scope

Translated: sidebar labels, buttons, context menus, pane headers, status bar text, settings, dialogs, app menu.

NOT translated: terminal content, theme names, AI tool names, file paths, branch names.

## Built-in Themes

### Treemux Dark (default)

- Deep blue-gray background
- Soft blue accent colors
- Optimized for long coding sessions

### Treemux Light

- Clean light background
- Appropriate contrast for daytime use

Custom themes: users place JSON files in `~/.treemux/themes/` following the `ThemeDefinition` schema.

## Technical Stack

| Component | Technology |
|-----------|-----------|
| Language | Swift 6 |
| UI | SwiftUI + AppKit (NSOutlineView for sidebar) |
| Terminal | libghostty (GhosttyKit.xcframework) |
| Build | Xcode 16+ / xcodebuild |
| Min OS | macOS 15+ |
| Arch | Apple Silicon (arm64) |
| License | MIT |

No third-party dependencies beyond GhosttyKit. SSH config parsing, JSON persistence, i18n all use Swift standard library and Apple frameworks.

## Development Phases

| Phase | Goal | Content |
|-------|------|---------|
| P0 | Minimum viable | Ghostty embedding + pane splitting + local project management + git worktree |
| P1 | Differentiation | Theme system + i18n + SSH remote projects |
| P2 | Deep integration | tmux restoration + AI tool detection and deep integration |
| P3 | Polish | Command palette + shortcut customization + auto-updates |
