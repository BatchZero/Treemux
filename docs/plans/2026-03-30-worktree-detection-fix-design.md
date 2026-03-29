# Fix: Git Worktree Detection Not Propagating to Sidebar

**Date:** 2026-03-30
**Status:** Approved

## Problem

When a git repository with multiple worktrees is added to Treemux, the sidebar only shows it as a single workspace node without expanding to show worktree children. The worktrees are correctly fetched via `git worktree list --porcelain` and parsed, but the sidebar never updates.

## Root Cause

Classic SwiftUI nested `ObservableObject` propagation issue:

1. `refreshWorkspace()` updates `workspace.worktrees` — a `@Published` property on `WorkspaceModel`
2. `WorkspaceOutlineSidebar` observes `WorkspaceStore`, not individual `WorkspaceModel` instances
3. No `@Published` property on `WorkspaceStore` changes when worktrees are populated
4. `updateNSView` is never called, so `SidebarCoordinator.apply` never rebuilds the node tree

## Fix

Add `objectWillChange.send()` at the end of `WorkspaceStore.refreshWorkspace(_:)` after worktree data is updated. This triggers `updateNSView`, which calls `SidebarCoordinator.apply`, which detects the fingerprint change and rebuilds the outline view nodes.

## File Changed

- `Treemux/App/WorkspaceStore.swift` — `refreshWorkspace(_:)` method
