# Sidebar Workspace Row — No-Git Vertical Centering Design

**Date:** 2026-04-07
**Status:** Approved

## Problem

In the sidebar, a workspace row normally shows two lines: project name on top
(e.g. "Treemux") and the current git branch underneath (e.g. "main"). When the
folder is not a git repository — or when the workspace has more than one
worktree — the second line is omitted, leaving the project name visually
"sticking" near the top of the row instead of being vertically centered. This
makes single-line workspace rows look misaligned next to two-line rows.

## Goal

Single-line workspace rows (no git, or multi-worktree) should have the same
overall height as two-line rows, and the project name should be vertically
centered inside that uniform height.

## Decision

Pin the inner `VStack` of `WorkspaceRowContent` to a fixed minimum height equal
to the natural two-line content height (24pt), so that the single-line case is
centered within the same height as the two-line case. The HStack default
`.center` alignment then keeps the icon visually centered against the same
height as well.

## Design

### Scope

- `Treemux/UI/Sidebar/SidebarNodeRow.swift` — `WorkspaceRowContent` only
- `WorktreeRowContent` and `SectionHeaderRow` are not touched

### Affected States

The trigger condition for "single-line workspace row" is broader than just "no
git". Both cases below should be centered:

| State                                  | `currentBranch` | `worktrees.count` | Second line shown? |
|----------------------------------------|-----------------|-------------------|--------------------|
| Has git, single worktree               | non-nil         | ≤ 1               | yes                |
| **No git** (the user's case)           | nil             | ≤ 1               | no — needs centering |
| **Multi-worktree** (with or without git)| any            | > 1               | no — needs centering |

### Layout Change

Inside `WorkspaceRowContent.body`, add a `.frame(minHeight:alignment:)` to the
inner `VStack`:

```swift
private static let contentMinHeight: CGFloat = 24
// 12pt name + 2pt spacing + 10pt branch = 24pt — matches the natural
// two-line height so single-line rows align with two-line rows.

VStack(alignment: .leading, spacing: 2) {
    Text(workspace.name) ...
    if workspace.worktrees.count <= 1, let branch = workspace.currentBranch {
        Text(branch) ...
    }
}
.frame(minHeight: Self.contentMinHeight, alignment: .leading)
```

The constant lives as a `private static let` on `WorkspaceRowContent` so the
magic number is documented in one place and easy to update if the font sizes
change.

### Why This Approach

Considered three options:

1. **VStack `minHeight` + center (chosen)** — 1 line of code, no fake content
   in the view tree, no a11y impact, leverages SwiftUI's default HStack center
   alignment.
2. **Always-rendered placeholder branch text with `.opacity(0)`** — adds an
   invisible Text to the view tree which VoiceOver may still announce; less
   honest about intent.
3. **Two distinct `if/else` layouts** — duplicates the row HStack and still
   requires a `minHeight` to keep heights consistent, so it ends up being
   strictly more code than option 1.

### Behaviour Matrix

| State                          | VStack natural height | After `minHeight: 24` | Result                  |
|--------------------------------|----------------------|----------------------|-------------------------|
| Has git, single worktree       | 24pt                 | 24pt                 | Unchanged               |
| No git                         | 12pt                 | 24pt, centered       | Project name centered ✓ |
| Multi-worktree                 | 12pt                 | 24pt, centered       | Project name centered ✓ |

The 22pt icon stays centered against the 24pt VStack via the HStack default
`.center` alignment, so the row maintains a consistent overall height across
all three states.

## Verification

Manual visual verification (no unit tests — pure SwiftUI layout):

1. Add at least three workspaces to the sidebar covering all three states:
   - A git repo with a single worktree
   - A plain folder without git
   - A git repo with multiple worktrees
2. Confirm that all workspace rows have the same overall height
3. Confirm that single-line rows show the project name vertically centered
   (no longer "sticking" to the top edge)
4. Toggle between light and dark themes; confirm the hover background still
   fills the entire row uniformly

## Out of Scope

- `WorktreeRowContent` layout
- `SectionHeaderRow` layout
- Any change to how `currentBranch` is computed or refreshed
- Any change to font sizes or spacing values
