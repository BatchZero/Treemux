# Pane Close Button Design

**Date:** 2026-04-03
**Status:** Approved

## Goal

Add a close button to the right side of each pane's info header bar, allowing users to close individual panes directly from the UI.

## Current State

Each pane has a compact header (`TerminalPaneView.paneHeader`) with this layout:

```
[Status Dot] [AI Badge] [Tmux Badge] [Title] ---- [Working Directory]
```

Pane closing is currently only available via:
- Keyboard shortcut `Cmd+W` (closePane action)
- Command palette

## Design

### Approach: Callback-based (Recommended)

`TerminalPaneView` receives an `onClose: () -> Void` callback. The caller (`SplitNodeView` / `WorkspaceSessionDetailView`) decides the close behavior:

- **Multiple panes**: calls `WorkspaceSessionController.closePane(paneID)` — collapses the split tree
- **Single pane (last one)**: calls `Workspace.closeTab(tabID)` — closes the tab entirely
- **No tabs remaining**: existing empty workspace UI with "new tab" button is shown

### Button Visual Style

- SF Symbol `xmark`, 9pt font
- Default color: `.secondary`
- Hover state: circular background highlight using `theme.dividerColor`
- Position: rightmost element in the header HStack, after working directory text

### Updated Header Layout

```
[●] [AI] [tmux] Title ---- ~/Projects  [✕]
```

### Data Flow

```
TerminalPaneView (button tap)
  → onClose() callback
    → SplitNodeView / WorkspaceSessionDetailView
      → check paneIDs.count
        → count > 1: controller.closePane(paneID)
        → count == 1: workspace.closeTab(tabID)
```

### Files to Modify

1. **`TerminalPaneView.swift`** — Add close button to header, accept `onClose` callback
2. **`SplitNodeView.swift`** — Pass `onClose` callback when creating `TerminalPaneView`
3. **`WorkspaceSessionController.swift`** — Modify `closePane()` to handle last-pane scenario OR keep as-is and let the view layer handle the tab-close decision
4. **`WorkspaceSessionDetailView.swift`** — May need to pass close context down

### Edge Cases

- Last pane in tab → close tab (not blocked)
- Last tab in workspace → empty workspace state (already handled)
- Zoomed pane → close should work normally, exit zoom if the zoomed pane is closed
