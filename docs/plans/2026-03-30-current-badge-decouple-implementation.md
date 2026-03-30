# Decouple "当前" Badge Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the green "当前" badge always show on the active worktree row, independent of terminal session state, matching Liney's behavior.

**Architecture:** Decouple badge display from `SidebarIconActivityIndicator` in `SidebarNodeRow.swift`. Remove badge from workspace rows, keep it only on worktree rows with a direct `activeWorktreePath` comparison.

**Tech Stack:** SwiftUI, macOS

---

### Task 1: Create feature branch

**Step 1: Create and checkout branch**

Run: `git checkout -b fix/current-badge-decouple`

**Step 2: Verify**

Run: `git branch --show-current`
Expected: `fix/current-badge-decouple`

---

### Task 2: Decouple badge in WorktreeRowContent

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarNodeRow.swift:133-134`

**Step 1: Change badge condition**

Replace:
```swift
if activityIndicator == .current {
    SidebarInfoBadge(text: "current", tone: .subtleSuccess)
}
```

With:
```swift
if workspace.activeWorktreePath == worktree.path.path {
    SidebarInfoBadge(text: "current", tone: .subtleSuccess)
}
```

**Step 2: Build to verify**

Run: `xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

---

### Task 3: Remove badge from WorkspaceRowContent

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarNodeRow.swift:79-81`

**Step 1: Remove the badge block**

Delete these lines from WorkspaceRowContent body:
```swift
if activityIndicator == .current {
    SidebarInfoBadge(text: "current", tone: .subtleSuccess)
}
```

**Step 2: Build to verify**

Run: `xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

---

### Task 4: Commit

**Step 1: Commit changes**

```bash
git add Treemux/UI/Sidebar/SidebarNodeRow.swift
git commit -m "fix: decouple current badge from activity indicator to match Liney behavior"
```
