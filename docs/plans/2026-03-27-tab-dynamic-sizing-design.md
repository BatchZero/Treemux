# Tab Dynamic Sizing Design

## Problem

Treemux tabs currently use natural HStack layout with no explicit width calculation.
This leads to inconsistent tab widths — short titles produce tiny tabs, long titles
produce oversized tabs, and the overall tab bar looks uneven.

## Solution

Port Liney's `WorkspaceTabSizing` approach: use `NSFont` to measure actual rendered
title width, add fixed chrome (padding, badge, close button space), and clamp to a
min/max range.

## Design

### New Component: `TreemuxTabSizing`

A private enum in `WorkspaceTabBarView.swift` that calculates tab width.

**Formula:**
```
titleFont  = NSFont.systemFont(ofSize: 12, weight: .semibold)
countFont  = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)

titleWidth = ceil(NSFont-measured title width)
badgeWidth = paneCount > 1 ? ceil(NSFont-measured count width) + 20 : 0
chrome     = 52  (12 leading + 12 trailing + 16 close button + 12 spacing)
finalWidth = clamp(titleWidth + badgeWidth + chrome, 100, 260)
```

### Changes

**File:** `Treemux/UI/Workspace/WorkspaceTabBarView.swift`

1. Add `TreemuxTabSizing` enum with a `width(for:paneCount:)` static method
2. Apply `.frame(width:)` to each `TabButton` using the calculated width
3. Ensure TabButton content uses `.frame(maxWidth: .infinity, alignment: .leading)`
   so title text fills available space and truncates with `.truncationMode(.tail)`

### Adaptations from Liney

- Font size 12 (treemux) vs 11 (Liney) — use treemux's existing font params
- Close button always reserves space (treemux shows on hover, avoid width jump)
- Min/max range: 100-260 (adjusted for treemux's slightly larger font)

### Non-changes

- No visual style changes (background, border, shadow, animations)
- No data model changes
- No drag-and-drop changes
- No business logic changes
