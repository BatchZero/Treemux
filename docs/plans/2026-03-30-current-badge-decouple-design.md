# Decouple "当前" Badge from Activity Indicator

**Date:** 2026-03-30
**Status:** Approved

## Problem

The green "当前" (current) badge in the sidebar never shows because it's coupled to `activityIndicator == .current`, which is overridden by `.working` when terminal sessions are running. Liney shows the badge independently of session state.

## Design

**Approach:** Decouple the badge display from `activityIndicator`, aligning with Liney's behavior.

**File:** `Treemux/UI/Sidebar/SidebarNodeRow.swift`

### Changes

1. **WorktreeRowContent** — Change badge condition from `activityIndicator == .current` to `workspace.activeWorktreePath == worktree.path.path`. Badge shows regardless of running sessions.

2. **WorkspaceRowContent** — Remove the badge entirely. Liney only shows "当前" on worktree child rows, not on workspace rows.

### Unchanged

- `activityIndicator` logic (icon dot/pulse animation)
- `SidebarInfoBadge` component
- Localization ("current" → "当前")
