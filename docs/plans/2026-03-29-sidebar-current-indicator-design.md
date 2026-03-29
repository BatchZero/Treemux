# Sidebar Icon Activity Indicator & "Current" Logic Design

**Date:** 2026-03-29
**Approach:** Incremental refactor on existing SwiftUI List + SidebarNodeRow architecture

## Overview

Upgrade the sidebar to match Liney's icon activity indicator system and "current" display logic. Three main changes:

1. Replace the simple `isActive` green dot with a three-state activity indicator (none/current/working)
2. Change "current" semantics from sidebar selection to `activeWorktreePath`
3. Align font sizes, spacing, and icon shapes with Liney

## Part 1: Icon System Upgrade

### SidebarIconActivityIndicator Enum

```swift
enum SidebarIconActivityIndicator {
    case none
    case current   // Static dot — this worktree is the active working directory
    case working   // Animated pulse — terminal sessions are running
}
```

### SidebarItemIconView Parameter Changes

Remove `isActive: Bool`. Add:

| Parameter | Type | Description |
|-----------|------|-------------|
| `usesCircularShape` | `Bool` | `true` for worktree icons (circular), `false` for workspace (rounded rect) |
| `activityIndicator` | `SidebarIconActivityIndicator` | Replaces `isActive` |
| `activityPalette` | `SidebarIconPalette` | Activity badge color, default `.amber` |
| `isEmphasized` | `Bool` | Stronger pulse when row is selected |

### SidebarIconActivityBadge

Positioned at icon bottom-right with `offset(x: 2, y: 2)`:

- `.current`: Static filled circle, size `max(6, size * 0.28)`, amber color, white ring border
- `.working`: Pulsing animated circle, size `max(7, size * 0.34)`, two-layer animation (inner core scale + outer ring expand/fade), glow shadow

### Icon Sizes

- Workspace: 22pt rounded rectangle (unchanged)
- Worktree: 16pt circular, placed in a 24pt-wide column, leading-aligned

## Part 2: "Current" Semantic Change

### Before → After

- **Before:** `isSelected` (sidebar selection state) → show "current"
- **After:** Based on `activeWorktreePath` (actual active working directory) → show "current"

Selection and "current" are independent: a worktree can be "current" but not selected, or selected but not "current".

### Determination Logic

**Worktree row:**
```
if workspace has running sessions for worktree.path → .working
else if workspace.activeWorktreePath == worktree.path → .current
else → .none
```

**Workspace row (single worktree or collapsed):**
```
if workspace has any running sessions → .working
else if workspace.activeWorktreePath == workspace.repositoryRoot → .current
else → .none
```

### WorkspaceModel Addition

```swift
func hasRunningSessions(forWorktreePath path: String) -> Bool
```

Checks `tabControllers[path]` for non-empty controller set.

### Text Badge Rules

- `.current` → show icon dot AND "current" text badge
- `.working` → show icon pulse only, no "current" text badge (animation is already prominent)
- `.none` → nothing

## Part 3: SidebarInfoBadge Component

### Tones

| Tone | Foreground | Background | Usage |
|------|-----------|------------|-------|
| `neutral` | `textSecondary` | `subtleFill` | Generic info |
| `accent` | `accentColor` | `subtleFill` | Emphasis |
| `success` | green | `subtleFill` | Success state |
| `subtleSuccess` | green 82% opacity | green 8% opacity | "current" badge |
| `warning` | orange | `subtleFill` | Warning |

Style: 9pt semibold monospaced font, horizontal padding 6pt, vertical padding 2pt, Capsule shape.

## Part 4: Row Layout

### Workspace Row

```
HStack(spacing: 8) {
  [Icon 22x22 rounded rect]  [VStack: name 12pt semibold + branch 10pt monospaced muted]  [Spacer]  [SidebarInfoBadge?]
}
padding: vertical 4, leading 2, trailing 4
```

### Worktree Row

```
HStack(spacing: 8) {
  [Icon 16x16 circular].frame(width: 24, alignment: .leading)  [name 10pt medium]  [Spacer]  [SidebarInfoBadge?]
}
padding: vertical 1, leading 5, trailing 4
minHeight: 24
```

## Affected Files

| File | Change |
|------|--------|
| `SidebarItemIconView.swift` | Rewrite: add `usesCircularShape`, `activityIndicator`, `activityPalette`, `isEmphasized`; add `SidebarIconActivityIndicator`, `SidebarIconActivityBadge` |
| `SidebarNodeRow.swift` | Update `WorkspaceRowContent` and `WorktreeRowContent` layout, font sizes, current logic |
| `WorkspaceSidebarView.swift` | Update `ProjectLabel`, `WorktreeRow`, `WorkspaceRowGroup` current logic and layout |
| `WorkspaceModels.swift` | Add `hasRunningSessions(forWorktreePath:)` method |
| New: `SidebarInfoBadge.swift` | Reusable badge component |
