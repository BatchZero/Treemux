# Treemux Tab System Design

**Date:** 2026-03-26
**Status:** Approved

## Goal

Add a tab system to Treemux so that "New Terminal" creates a new tab (not a split pane). Each tab has its own independent split layout. Reference Liney's UX but design independently from Treemux's own architecture.

## Requirements

- Each workspace/worktree maintains an independent list of tabs
- Each tab owns its own `WorkspaceSessionController` (independent split layout)
- Tab bar visible when 2+ tabs; hidden when 1 tab; empty state page when 0 tabs
- Tab titles auto-update from focused pane (process name > cwd basename > fallback)
- Manual rename locks the title (`isManuallyNamed`)
- Drag-and-drop reordering
- Context menu: rename, move left/right, close
- Keyboard shortcuts: ⌘T, ⌘W, ⌘⇧], ⌘⇧[, ⌘1~9
- Full persistence: tabs survive app restart
- Backward-compatible: old data without tabs auto-migrates to single default tab

## Architecture: Approach A — Tab Management in WorkspaceModel

### Data Model Changes

#### WorkspaceTabStateRecord (extend existing)

```swift
struct WorkspaceTabStateRecord: Codable {
    let id: UUID
    var title: String
    var isManuallyNamed: Bool     // NEW: locks manual rename
    let layout: SessionLayoutNode?
    let panes: [PaneSnapshot]
    let focusedPaneID: UUID?
    let zoomedPaneID: UUID?
}
```

#### WorkspaceModel (runtime extensions)

```
WorkspaceModel
├── @Published tabs: [WorkspaceTabStateRecord]
├── @Published activeTabID: UUID?
├── worktreeControllers: [String: [UUID: WorkspaceSessionController]]
│   // worktreePath → tabID → controller (two-level dictionary)
├── activeSessionController: computed property → current tab's controller
│
├── createTab()
├── selectTab(_ tabID: UUID)
├── closeTab(_ tabID: UUID)
├── renameTab(_ tabID: UUID, title: String)
├── moveTab(from: IndexSet, to: Int)
├── selectNextTab()
├── selectPreviousTab()
└── saveActiveTabState()  // snapshot current controller into tab record
```

### Title Auto-Generation

Priority chain (checked in order):
1. `isManuallyNamed == true` → return existing title
2. Focused pane's `session.title` (process name from terminal)
3. Focused pane's `workingDirectory` basename
4. Existing title / fallback `"Tab"`

### Persistence Flow

**Save:**
- `WorkspaceModel.toRecord()` iterates `tabs`, snapshots each tab's controller layout/panes/focus
- Writes into `WorktreeSessionStateRecord.tabs`

**Restore:**
- `WorkspaceModel.init(from:)` reads `worktreeStates[].tabs`
- Restores `tabs` array and `activeTabID`
- Controllers created lazily on first `selectTab`

**Migration:**
- `worktreeStates` empty or `tabs` empty → create one default tab (single pane, workspace cwd)

## UI Design

### Tab Bar Style: Flat + Dark Mode (Editor-style)

```
┌──────────────────────────────────────────────────────────────────┐
│ ┌─────────────┐ ┌──────────────────┐ ┌──────────┐              │
│ │  zsh     ×  │ │  claude  [3]     │ │  vim     │    [+]       │
│ │  ═════════  │ │                  │ │          │              │
│ └─────────────┘ └──────────────────┘ └──────────┘              │
└──────────────────────────────────────────────────────────────────┘
```

- Selected tab: accent-color underline (2px), slightly elevated background
- Pane count badge: shown when tab has >1 pane
- Close button: shown on hover only
- [+] button at trailing edge
- Transitions: 150-200ms ease-out

### Tab Bar Visibility

| State | Behavior |
|-------|----------|
| 0 tabs | Empty state page (icon + "New Terminal" button + ⌘T hint) |
| 1 tab | Tab bar hidden, terminal content fills area |
| 2+ tabs | Tab bar visible |

### Interactions

| Action | Behavior |
|--------|----------|
| Click tab | Switch to tab |
| Click × | Close tab |
| Double-click title | Inline rename (TextField) |
| Drag tab | Reorder with insertion marker |
| Click [+] | Create new tab at end |
| Right-click tab | Context menu: Rename / Move Left / Move Right / Close |

### Empty State Page

Centered layout with:
- SF Symbol icon (terminal)
- "No open terminals" heading
- "+ New Terminal" button (primary action)
- "⌘T to create a new tab" hint (secondary text)

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘T | New tab |
| ⌘W | Close current tab |
| ⌘⇧] or ⌃Tab | Next tab |
| ⌘⇧[ or ⌃⇧Tab | Previous tab |
| ⌘1 ~ ⌘9 | Jump to tab N |

## State Management

### Tab Lifecycle

**Create:**
1. `saveActiveTabState()` — snapshot current tab
2. Create new `WorkspaceTabStateRecord` (title: "Tab N", single pane)
3. Append to `tabs`, set as `activeTabID`
4. Controller created lazily when `SplitNodeView` renders

**Switch:**
1. `saveActiveTabState()` — snapshot outgoing tab
2. Set `activeTabID` to target
3. Get/create controller from `worktreeControllers`
4. `@Published` change triggers UI refresh

**Close:**
1. `saveActiveTabState()`
2. Remove tab from `tabs`
3. Terminate and remove controller from `worktreeControllers`
4. Select adjacent tab (or enter empty state if last tab)

### Worktree Switching

Each worktree maintains independent tabs:
1. `saveActiveTabState()` for current worktree
2. Store current `tabs`/`activeTabID` into `worktreeTabStates[oldPath]`
3. Restore from `worktreeTabStates[newPath]` (or create default)
4. Load new worktree's active tab controller

## Integration Points

| Existing Code | Change |
|---------------|--------|
| `WorkspaceModel.sessionController` | Stored property → computed property (returns active tab's controller) |
| `WorkspaceModel.toRecord()` | Serialize tabs into `worktreeStates` |
| `WorkspaceModel.init(from:)` | Restore tabs from `worktreeStates`; migrate old data |
| `WorkspaceStore.activeSessionController` | No change (still via workspace) |
| `MainWindowView` toolbar | "New Terminal" → `createTab()` |
| `AppDelegate` menu bar | Add tab menu items + shortcuts |
| `CommandPaletteView` | Add tab commands |
| `ShortcutAction` | Add tab action enum cases |
| `SplitNodeView` / `TerminalPaneView` | **No change** |

## New Files

| File | Purpose |
|------|---------|
| `UI/Workspace/WorkspaceTabBarView.swift` | Tab bar + tab buttons |
| `UI/Workspace/EmptyTabStateView.swift` | Empty state page |
