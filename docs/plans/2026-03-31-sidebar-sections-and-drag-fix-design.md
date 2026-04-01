# Sidebar Sections & Drag-Drop Fix Design

## Date: 2026-03-31

## Problem

1. Repository list drag-and-drop reordering is broken — source index is taken from the combined `rootNodes` array, but `moveLocalWorkspace` operates on the filtered `localWorkspaces` subset, causing index mismatch.
2. Local and remote repositories are visually indistinguishable in the sidebar — no section grouping by server.
3. Drag reordering should be restricted within the same section (local-to-local, remote-to-remote within the same server).

## Solution: Section Nodes + Custom SwiftUI Header Rendering (Approach B)

### Data Model Changes

#### SidebarNodeItem — new `.section` kind

```swift
enum SidebarSection: Hashable {
    case local
    case remote(groupKey: String, displayTitle: String)
    // groupKey: "displayName|user" for matching
    // displayTitle: "my-server (root@192.168.1.100)" for display
}

// SidebarNodeItem.Kind adds:
case section(SidebarSection)
```

#### WorkspaceStore — new remote reordering method

- Add `moveRemoteWorkspace(groupKey:from:to:)` for reordering within a remote group.
- Remote group ordering persisted implicitly via `workspaces` array order (same as local).

#### PersistedWorkspaceState — collapsed sections

```swift
struct PersistedWorkspaceState: Codable {
    let version: Int
    let selectedWorkspaceID: UUID?
    let workspaces: [WorkspaceRecord]
    var collapsedSections: [String]?  // "local" or "displayName|user"
}
```

### Node Tree Building

In `SidebarCoordinator.buildNodes()`:

- **Remote repos exist**: Create `.section(.local)` wrapping local workspaces + one `.section(.remote(...))` per remote group wrapping its workspaces.
- **No remote repos**: Skip section layer, return workspace nodes directly at root (preserves current behavior).

Each workspace node's worktree children logic is unchanged.

### Collapse/Expand

- After building nodes, apply `collapsedSections` via `outlineView.collapseItem()`.
- Listen to `outlineViewItemDidCollapse` / `outlineViewItemDidExpand` to sync persisted state.

### Drag-and-Drop Logic

#### Drag source (`pasteboardWriterForItem`)
- Only `.workspace` nodes are draggable. `.section` nodes are not.

#### Drop validation (`validateDrop`)
1. Read dragged workspace ID from pasteboard.
2. Determine source section (via `sshTarget`: nil = local, otherwise match by `displayName|user`).
3. Determine target section from `proposedItem`:
   - With sections: `proposedItem` must be a `.section` node matching source → return `.move`.
   - Without sections (local only): `proposedItem == nil` → return `.move`.
4. Mismatch → return `[]` (shows forbidden cursor).

#### Drop execution (`acceptDrop`)
1. Identify target section.
2. Get workspace children within that section.
3. Compute local index within section (not global index — this fixes the bug).
4. Call `store.moveLocalWorkspace(from:to:)` or `store.moveRemoteWorkspace(groupKey:from:to:)`.

### UI Rendering

#### Section Header Row (SwiftUI)
- Rendered via NSHostingView (same pattern as existing rows).
- Style: small font, gray/semi-transparent text, similar to Finder sidebar group headers.
- Disclosure triangle: native NSOutlineView disclosure cell.
- Local title: i18n `"Local"` / `"本地"`.
- Remote title: `"displayName (user@host)"` format.

#### NSOutlineViewDelegate behavior for sections
- `shouldSelectItem` → `false` for section nodes.
- `heightOfRowByItem` → smaller height (~24pt vs workspace ~32pt).
- `viewFor` → returns `SectionHeaderRow` SwiftUI view hosted in NSHostingView.

#### Existing rows
- `WorkspaceRowContent` and `WorktreeRowContent` unchanged.
- May gain one level of indentation when sections are present.

### i18n

New string: `"Local"` → zh-Hans: `"本地"`.
Remote titles are dynamic from SSH config, no i18n needed.

### Key Design Decisions

- Smart section display: sections only appear when both local and remote repos exist.
- Drag restricted within same section; cross-section drag shows forbidden cursor.
- Each section's order independently persisted.
- Collapsed state persisted across app launches.
- Approach B chosen over native `isGroupItem` for full control over header appearance, consistent with existing SwiftUI-in-AppKit rendering pattern.
