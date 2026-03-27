# Sidebar NSOutlineView Migration Design

**Date:** 2026-03-27
**Status:** Approved

## Problem

1. **UI lag:** Selecting Repository or Worktree in the sidebar causes noticeable stutter. The current SwiftUI `List(selection:)` with `.listStyle(.sidebar)` triggers excessive diffing on selection changes, and the `OutlineViewConfigurator` hack (async traversal of the view tree) adds overhead.
2. **Selection highlight spans full sidebar width:** SwiftUI's `.listRowBackground()` fills the entire row without inset, producing a flat full-width selection instead of the smooth rounded selection style used in Liney.

## Solution: Migrate to AppKit NSOutlineView

Replace the SwiftUI `List` with an AppKit `NSOutlineView` wrapped in `NSViewRepresentable`, following Liney's proven pattern.

## Architecture

```
WorkspaceSidebarView (SwiftUI, retained as shell)
├── VStack(spacing: 0)
│   ├── WorkspaceOutlineSidebar (NEW, NSViewRepresentable)
│   │   ├── makeCoordinator() → SidebarCoordinator
│   │   ├── makeNSView() → SidebarContainerView
│   │   └── updateNSView() → coordinator.apply(workspaces:, selectedID:)
│   │
│   │   SidebarContainerView (NEW, NSView)
│   │   ├── NSScrollView
│   │   │   └── SidebarOutlineView (NEW, NSOutlineView subclass)
│   │   └── Footer (Open Project button via NSHostingView)
│   │
│   │   SidebarCoordinator (NEW, NSOutlineViewDataSource + Delegate)
│   │   ├── rootNodes: [SidebarNodeItem]
│   │   ├── apply() — fingerprint diff + reloadData
│   │   ├── outlineViewSelectionDidChange() → store.selectedWorkspaceID
│   │   └── drag-reorder, context menus, expand/collapse
│   │
│   │   SidebarRowView (NEW, NSTableRowView subclass)
│   │   └── drawSelection() — inset rounded rectangle
│   │
│   │   SidebarCellView (NEW, NSTableCellView)
│   │   └── NSHostingView<SidebarNodeRow>
│   │
│   ├── Divider()
│   └── "Open Project..." button (retained)
│
├── .alert (rename / delete — retained)
└── .sheet (open project / icon customization — retained)
```

## Selection & Hover Styling

### Custom NSTableRowView (`SidebarRowView`)

- `drawBackground(in:)` — empty (disable default background)
- `drawSelection(in:)` — `bounds.insetBy(dx: 5, dy: 1)` with `NSBezierPath(roundedRect:, xRadius: 10, yRadius: 10)`, themed fill + stroke (lineWidth 1.25)
- `isEmphasized` — always `true` (prevent gray unfocused selection)

### Theme Colors

| Token | Description |
|-------|-------------|
| `sidebarSelectionFill` | Selection background fill (coordinated with accent color) |
| `sidebarSelectionStroke` | Selection border stroke (~0.9 alpha accent blue) |

### Hover

- Handled in SwiftUI row content via `.onHover` + local `@State`
- Visual: `RoundedRectangle(cornerRadius: 8)` with subtle semi-transparent background
- Layered: selection drawn by AppKit at row level, hover drawn by SwiftUI at cell content level

### NSOutlineView Configuration

- `selectionHighlightStyle = .regular` (custom rowView takes over)
- `intercellSpacing = NSSize(width: 0, height: 4)` (4pt row gap)
- `focusRingType = .none`
- `backgroundColor = .clear`

## Data Source & Fingerprint Diffing

### Node Model (`SidebarNodeItem`)

```
SidebarNodeItem (NSObject)
├── kind: .workspace(WorkspaceModel) | .worktree(WorkspaceModel, WorktreeModel)
├── children: [SidebarNodeItem]
└── id: String (UUID-based, stable identity for NSOutlineView)
```

### apply() Flow

```
updateNSView triggers
    → coordinator.apply(workspaces:, selectedID:)
    → compute fingerprint (ids + names + branches + worktree state + icons)
    → fingerprint changed?
        YES → rebuildNodes + reloadData + restoreExpansion + syncSelection
        NO  → syncSelection only
```

### Bidirectional Selection Sync

| Direction | Trigger | Handler |
|-----------|---------|---------|
| Store → OutlineView | updateNSView with changed selectedID | `synchronizeSelection()` → `outlineView.selectRowIndexes` |
| OutlineView → Store | User clicks row | `outlineViewSelectionDidChange` → `store.selectedWorkspaceID = ...` |

`isApplyingSelection` flag prevents circular updates.

## Row Content

Existing SwiftUI views reused with minor adjustments:

| View | Change |
|------|--------|
| `ProjectLabel` | Remove `@EnvironmentObject`, accept params directly |
| `SidebarItemIconView` | No change |
| `WorktreeRow` | Remove `@EnvironmentObject`, `.listRowBackground`, hover binding; simplify to pure display |

Row heights by delegate:
- workspace: 36pt
- worktree: 28pt

## Interactions

| Feature | Implementation |
|---------|---------------|
| Selection | NSOutlineView native + delegate callback |
| Expand/collapse | NSOutlineView native disclosure |
| Drag-to-reorder | NSOutlineViewDataSource pasteboard methods |
| Context menu | NSMenu built per row in coordinator |
| Hover highlight | SwiftUI `.onHover` in cell content |
| Rename/Delete | Store published properties → SwiftUI alerts (retained) |
| Icon customization | `store.sidebarIconCustomizationRequest` → SwiftUI sheet (retained) |

## File Changes

| File | Action |
|------|--------|
| `UI/Sidebar/WorkspaceSidebarView.swift` | Major rewrite (keep shell, replace List) |
| `UI/Sidebar/SidebarOutlineView.swift` | New — NSOutlineView subclass |
| `UI/Sidebar/SidebarContainerView.swift` | New — NSView container |
| `UI/Sidebar/SidebarCoordinator.swift` | New — DataSource + Delegate |
| `UI/Sidebar/SidebarRowView.swift` | New — Custom selection drawing |
| `UI/Sidebar/SidebarCellView.swift` | New — NSTableCellView + NSHostingView |
| `UI/Sidebar/SidebarNodeItem.swift` | New — Tree node model |
| `UI/Sidebar/SidebarNodeRow.swift` | New — SwiftUI row content dispatch |
| `UI/Sidebar/SidebarItemIconView.swift` | No change |
| `Support/ThemeManager.swift` | Add selection colors |
| `UI/MainWindowView.swift` | No change |

## Code Removed

- `OutlineViewConfigurator` (system highlight hack)
- `sidebarRowBackground()` helper
- `WorkspaceRowGroup` view (replaced by coordinator node building + cell view)
- `List(selection:)` and `.listStyle(.sidebar)` code
