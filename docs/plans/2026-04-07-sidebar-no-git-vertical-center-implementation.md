# Sidebar Workspace Row Vertical Centering — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make single-line workspace rows in the sidebar (no git, or multi-worktree) vertically center the project name so they visually match two-line rows.

**Architecture:** Pin the inner `VStack` of `WorkspaceRowContent` to a fixed `minHeight` of 24pt (the natural two-line content height: 12pt name + 2pt spacing + 10pt branch). The HStack default `.center` alignment then keeps both icon and text vertically centered against the same uniform height across all states.

**Tech Stack:** SwiftUI, Xcode 15+, macOS app (`Treemux.xcodeproj` / scheme `Treemux`).

**Design Doc:** `docs/plans/2026-04-07-sidebar-no-git-vertical-center-design.md`

---

## Notes for the implementer

- Per `.claude/CLAUDE.md`, all code changes happen in a worktree under `.worktrees/<branch-name>/`.
- Per `.claude/CLAUDE.md`, when communicating with the user, address them as "卡皮巴拉" and write user-facing messages in Chinese; **code comments stay in English**.
- This is a SwiftUI layout-only change. There are **no unit tests** for this — verification is **manual visual inspection** of the running debug build.
- The Xcode default `DerivedData` directory for this project is `Treemux-fbvzemhsknohjwfflqakdhefxzwi`. Confirm with `ls -dt ~/Library/Developer/Xcode/DerivedData/Treemux-*/Build/Products/Debug/Treemux.app | head -1` if in doubt.
- Frequent commits — but in this plan there is essentially one commit (the change is 1 line + 1 constant).

---

## Task 1: Create the worktree and branch

**Files:** none yet — this is the workspace bootstrap.

**Step 1: Verify the main repo is clean and on `main`**

Run:
```bash
cd /Users/yanu/Documents/code/Terminal/treemux
git status
git branch --show-current
```

Expected:
- `工作区干净` / `nothing to commit, working tree clean`
- Current branch: `main`

**Step 2: Create the worktree on a new branch**

Run:
```bash
cd /Users/yanu/Documents/code/Terminal/treemux
git worktree add .worktrees/fix+sidebar-no-git-vertical-center -b fix/sidebar-no-git-vertical-center
```

Expected: a new directory `.worktrees/fix+sidebar-no-git-vertical-center/` containing a checkout of the new branch.

**Step 3: Verify the worktree is set up correctly**

Run:
```bash
git worktree list
ls /Users/yanu/Documents/code/Terminal/treemux/.worktrees/fix+sidebar-no-git-vertical-center/Treemux/UI/Sidebar/SidebarNodeRow.swift
```

Expected:
- `git worktree list` shows the new worktree on branch `fix/sidebar-no-git-vertical-center`
- `SidebarNodeRow.swift` exists at the expected path inside the worktree

**Step 4: Commit checkpoint** — none (no changes yet).

---

## Task 2: Apply the layout change

**Files:**
- Modify: `.worktrees/fix+sidebar-no-git-vertical-center/Treemux/UI/Sidebar/SidebarNodeRow.swift` (around lines 42–93, the `WorkspaceRowContent` struct)

**Step 1: Read the current `WorkspaceRowContent` to confirm line ranges**

Read the file to verify nothing has shifted since the design was written. The struct should look like:

```swift
struct WorkspaceRowContent: View {
    let workspace: WorkspaceModel
    let store: WorkspaceStore
    let theme: ThemeManager
    let isSelected: Bool

    @State private var isHovered = false

    private var activityIndicator: SidebarIconActivityIndicator { ... }

    var body: some View {
        HStack(spacing: 8) {
            SidebarItemIconView(...)
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.sidebarForeground)
                    .lineLimit(1)
                if workspace.worktrees.count <= 1, let branch = workspace.currentBranch {
                    Text(branch)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        ...
    }
}
```

If the structure has drifted, stop and reassess before editing.

**Step 2: Add the `contentMinHeight` constant**

Add a `private static let` constant immediately after the property declarations and before `var body`. Place it logically near the other state-derived helpers:

```swift
    // Natural height of the two-line case (12pt name + 2pt spacing + 10pt branch).
    // Pinning the VStack to this minHeight keeps single-line rows (no git, or
    // multi-worktree) the same overall height as two-line rows so the project
    // name is vertically centered.
    private static let contentMinHeight: CGFloat = 24
```

**Step 3: Add `.frame(minHeight:alignment:)` to the inner VStack**

Locate the inner `VStack(alignment: .leading, spacing: 2) { ... }` block inside `body`. Immediately after its closing `}` (and before `Spacer()`), add a single modifier line:

```swift
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.sidebarForeground)
                    .lineLimit(1)
                if workspace.worktrees.count <= 1, let branch = workspace.currentBranch {
                    Text(branch)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(minHeight: Self.contentMinHeight, alignment: .leading)
            Spacer()
```

**Do NOT** touch:
- `WorktreeRowContent`
- `SectionHeaderRow`
- The HStack alignment, padding, or background
- `currentBranch` computation in `WorkspaceModels.swift` or `GitRepositoryService.swift`

**Step 4: Re-read the file to confirm the diff is exactly as intended**

Read the file again and confirm:
- Exactly one new `private static let contentMinHeight: CGFloat = 24` line + its English comment block
- Exactly one new `.frame(minHeight: Self.contentMinHeight, alignment: .leading)` line
- No other lines changed
- No accidental whitespace/indentation drift in surrounding lines

**Step 5: Commit checkpoint** — defer the commit until after the build (Task 3) succeeds, so we don't commit a file that doesn't compile.

---

## Task 3: Build and verify it compiles

**Files:** none modified — this is the build step.

**Step 1: Build the Debug configuration via xcodebuild**

Run from the worktree:
```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/fix+sidebar-no-git-vertical-center
xcodebuild \
  -project Treemux.xcodeproj \
  -scheme Treemux \
  -configuration Debug \
  build 2>&1 | tail -40
```

Expected: `** BUILD SUCCEEDED **` as the final line. No errors.

**Step 2: If the build fails**

- Read the actual error output (do not assume it's the new code)
- If it IS in `SidebarNodeRow.swift`, re-check the diff against Task 2 Step 3
- If it's elsewhere, the build environment may need attention — stop and report to the user instead of guessing

**Step 3: Locate the freshly built `.app` bundle**

Run:
```bash
ls -dt ~/Library/Developer/Xcode/DerivedData/Treemux-*/Build/Products/Debug/Treemux.app | head -1
```

Expected: a path like `/Users/yanu/Library/Developer/Xcode/DerivedData/Treemux-fbvzemhsknohjwfflqakdhefxzwi/Build/Products/Debug/Treemux.app` with a fresh modification time.

**Step 4: Tell the user (卡皮巴拉) how to run the new build**

Per `.claude/CLAUDE.md`, after a successful build, give the user a copyable command:

```bash
rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-fbvzemhsknohjwfflqakdhefxzwi/Build/Products/Debug/Treemux.app
```

(Confirm the `Treemux-...` directory ID from Step 3 — if it differs, substitute the actual one.)

**Step 5: Commit checkpoint** — defer until after manual visual verification.

---

## Task 4: Manual visual verification

**Files:** none — this runs the app and inspects the sidebar by eye.

This step requires human eyes (the user, 卡皮巴拉). Hand control back to the user with a clear checklist.

**Step 1: Ask the user to run the app and confirm the three states**

Tell the user to add (or already have) at least three workspaces in the sidebar:

1. **State A — git, single worktree**: project name on top, branch below (e.g. `Treemux` / `main`)
2. **State B — no git**: a plain folder without a `.git` directory; only the project name
3. **State C — git, multiple worktrees**: a workspace with two or more worktrees; main row shows only the project name (worktrees are listed as children)

**Step 2: Visual checklist for the user**

Ask the user to confirm:

- [ ] All three workspace rows have the **same overall height**
- [ ] In State B, the project name is **vertically centered** in the row (no longer "sticking" near the top)
- [ ] In State C, the project name is also **vertically centered** in the row
- [ ] In State A (unchanged), the project name + branch still look correct (project name on top, branch below)
- [ ] Hover background still **fills the entire row** uniformly in all three states
- [ ] Switch between light and dark theme — all of the above still hold

**Step 3: If anything looks wrong**

- If a row is centered but the icon now looks off, the HStack alignment may need to be checked — but the design assumes default `.center` is correct, so first re-check that the `.frame` modifier is on the **VStack**, not on the HStack
- If the row got taller than before in the two-line case, the `contentMinHeight` value may be too high — measure and adjust (24pt is the target)
- Stop and report any other unexpected change to the user before committing

**Step 4: Commit checkpoint** — defer to Task 5.

---

## Task 5: Commit and finish the branch

**Files:** the modified `SidebarNodeRow.swift`.

**Step 1: Stage the change**

From the worktree:
```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/fix+sidebar-no-git-vertical-center
git status
git diff Treemux/UI/Sidebar/SidebarNodeRow.swift
```

Expected:
- `git status` shows only `Treemux/UI/Sidebar/SidebarNodeRow.swift` modified
- `git diff` shows exactly the constant + the `.frame` modifier additions, nothing else

**Step 2: Commit**

```bash
git add Treemux/UI/Sidebar/SidebarNodeRow.swift
git commit -m "$(cat <<'EOF'
fix(sidebar): vertically center project name when no git or multi-worktree

Pin the inner VStack of WorkspaceRowContent to a fixed minHeight of 24pt
(the natural two-line content height) so single-line workspace rows have
the same overall height as two-line rows and the project name is
vertically centered. Affects workspaces without git and workspaces with
multiple worktrees.
EOF
)"
```

**Step 3: Verify commit**

```bash
git log --oneline -3
git status
```

Expected:
- New commit at the top of the log on branch `fix/sidebar-no-git-vertical-center`
- Working tree clean

**Step 4: Hand off to the finishing-a-development-branch skill**

Per superpowers conventions, after the implementation is complete, invoke `superpowers:finishing-a-development-branch` to decide between merge / PR / cleanup.

**Do NOT** push, merge, or create a PR without the user's explicit go-ahead — per the project's deploy and release rules in `.claude/CLAUDE.md`, only `main` and `stable` are sensitive, but the user should still authorize the merge direction.

---

## Done criteria

- [ ] `.worktrees/fix+sidebar-no-git-vertical-center/` exists on branch `fix/sidebar-no-git-vertical-center`
- [ ] `SidebarNodeRow.swift` has exactly one new constant + one new `.frame` modifier on the inner `VStack` of `WorkspaceRowContent`, with English code comments
- [ ] `xcodebuild ... -configuration Debug build` succeeds
- [ ] User (卡皮巴拉) has visually confirmed all five items in the Task 4 checklist
- [ ] One new commit on `fix/sidebar-no-git-vertical-center` with the message above
- [ ] `superpowers:finishing-a-development-branch` invoked to decide merge strategy
