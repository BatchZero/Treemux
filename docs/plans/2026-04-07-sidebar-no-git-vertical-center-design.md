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
.frame(minHeight: Self.contentMinHeight)
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
- Any change to font sizes or spacing values

## Addendum (2026-04-07) — Remote non-git root cause

During visual verification, a second bug surfaced that the original scope
did not anticipate: **remote (SSH) non-git workspaces** still rendered
the project name "stuck to the top" even after the `minHeight` fix was
in place. Local non-git workspaces looked correct; remote did not.

### What was actually happening

The sidebar code path is identical for local and remote workspaces
(`WorkspaceRowContent` is the single renderer for both). The difference
came from the data: `workspace.currentBranch` was `""` (empty string)
for remote non-git workspaces, not `nil`.

Swift's `if let branch = workspace.currentBranch` unwraps an empty
string as a valid value, so the sidebar entered the two-line branch and
rendered `Text("")` — an invisible 10pt second line. The VStack became
two-line (24pt) and the project name ended up at the *top-line* position
of a two-line layout, which visually reads as "stuck to the top".

### Where the empty string came from

Two layers conspired:

1. **Shell script `|| true` placement.** The remote inspection script
   in `GitRepositoryService.inspectRepository(remotePath:sshTarget:)`
   ends with `... && git rev-list ... 2>/dev/null || true`. Bash's
   `&&`/`||` are left-associative, so the whole chain is parsed as
   `(... && ... && ...) || true` — meaning *any* mid-chain failure
   (including `git rev-parse --abbrev-ref HEAD` on a non-git directory)
   still exits 0. The function therefore does **not** throw for
   non-git remotes; it returns whatever partial stdout it collected.

2. **Parser consuming the trailing empty line.**
   `parseRemoteInspection` called
   `output.split(separator: "\n", omittingEmptySubsequences: false)`,
   which preserves the empty trailing element after the final newline.
   For a non-git remote, stdout is just `__BRANCH__\n`, which splits
   into `["__BRANCH__", ""]`. The first element switched the parser
   into `.branch` mode; the second (empty) element was then assigned:
   `branch = "".trimmingCharacters(...) = ""`.

The catch block in `WorkspaceStore.refreshWorkspace` was never reached,
because `inspectRepository` returned successfully. `currentBranch` was
written as `""` and persisted to disk as such.

### Fix applied in this branch

Two layers of fix, to match the two-layer cause:

1. **Primary (parser):** `parseRemoteInspection` now only assigns
   `branch` / `head` when the trimmed line is non-empty. Non-git
   remotes correctly end up with `currentBranch = nil`.

2. **Defense (UI):** `WorkspaceRowContent`'s condition now also checks
   `!branch.isEmpty`, so any future stray empty-string branch values
   from elsewhere cannot re-trigger the two-line layout.

### Not fixed in this branch

The shell script's `|| true` placement is the upstream cause and is
intentionally deferred to a separate follow-up. Fixing it properly
(wrap only the `git rev-list` in a `( ... ) || true` subshell) changes
the failure semantics of all the mid-chain commands, which could
affect workspaces we haven't fully exercised. The parser-level skip +
UI defense are sufficient to prevent the user-visible symptom.

### Persisted state self-heals

`WorkspaceStore.loadWorkspaceState` calls `WorkspaceModel.init(from:)`
which calls `restoreTabState`, and `restoreTabState` only copies `tabs`
and `activeTabID` — it never reads `WorktreeSessionStateRecord.branch`
back into `currentBranch`. So the stale `branch: ""` currently persisted
on disk has no effect on a fresh launch (`currentBranch` starts `nil`).
The next refresh writes the correct `nil` back, and the next save
cleans the persisted record automatically. No migration needed.
