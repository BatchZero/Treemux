# Feature 12 + 13 — Tab-Bar Interaction: Browser-Style Equal Width + Wheel Horizontal Scroll

Date: 2026-07-14
Batch: B–H (tab-bar interaction subsystem), requirements (12) + (13)
Status: Design approved

## Goal

Make both tab bars behave like a modern browser's tab strip:

- **(12) Equal width:** all tabs share the available width equally
  (browser-style adaptive), shrinking together as more tabs open, with long
  titles truncated with an ellipsis.
- **(13) Wheel horizontal scroll:** a plain mouse scroll wheel (vertical)
  scrolls the tab strip horizontally, while trackpad two-finger horizontal
  swipe keeps working natively.

Scope covers **both** tab bars:
- `WorkspaceTabBarView` (workspace terminal/file tabs, with Files/Shell group
  eyebrows and a divider).
- `FileSubTabBarView` (file-browser sub-tabs inside a file tab).

## Current State

- **`WorkspaceTabBarView`**: each tab has an explicit
  `.frame(width: TreemuxTabSizing.width(...))` producing a per-title variable
  width clamped to `100…260`. Title already truncates
  (`lineLimit(1)` + `.truncationMode(.tail)` + `maxWidth: .infinity`). Inner
  content sits in a `ScrollView(.horizontal)`; the "+" new-tab button is
  outside the scroll view. Group eyebrows ("Files"/"Shell") and a 1pt divider
  share the strip with the tabs.
- **`FileSubTabBarView`**: `SubTabButton` has **no** explicit width (intrinsic,
  grows to fit the filename) and its title `Text` has **no** line limit or
  truncation. Also a `ScrollView(.horizontal)`. No eyebrows, no "+".
- Deployment target is **macOS 15.0**, so `ScrollPosition` +
  `.scrollPosition(_:)` + `.onScrollGeometryChange(for:)` are available and
  already used in `FileTreePanelView`.
- `TreemuxGhosttyController.scrollWheel(with:)` is an existing precedent for
  reading `event.scrollingDeltaX/Y` and `event.hasPreciseScrollingDeltas`.

## Requirements

### (12) Browser-style equal width

1. Every tab in a bar renders at the same width.
2. Width adapts to available space: `uniform = clamp((viewport − reservedChrome) / tabCount, minWidth, maxWidth)`.
   - When few tabs, width caps at `maxWidth` (Chrome-style; a lone tab is not
     absurdly wide, trailing space is left empty).
   - When many tabs, width floors at `minWidth`; once tabs no longer fit, the
     strip overflows and horizontal scrolling (13) takes over.
3. Long titles/filenames truncate with a trailing ellipsis.
4. `minWidth = 64`, `maxWidth = 240` (tunable constants).

### (13) Wheel horizontal scroll

1. A mouse scroll wheel (vertical, non-precise) over a tab bar scrolls that
   bar horizontally.
2. Trackpad gestures (`hasPreciseScrollingDeltas == true`) are NOT
   intercepted — native horizontal scrolling of the `ScrollView` continues to
   work.
3. Scrolling into a tab bar that has no overflow is a no-op (clamped).

## Design

### Shared primitives

**`TabBarLayout` (pure, testable)** — new file
`Treemux/UI/Workspace/TabBarLayout.swift`:

```swift
enum TabBarLayout {
    /// Browser-style equal-width tab sizing. Returns the width every tab in a
    /// bar should take so that `tabCount` tabs divide the space left after the
    /// bar's fixed chrome, clamped to a readable range.
    static func uniformWidth(
        viewport: CGFloat,
        tabCount: Int,
        reservedChrome: CGFloat,
        minWidth: CGFloat,
        maxWidth: CGFloat
    ) -> CGFloat {
        guard tabCount > 0 else { return maxWidth }
        let usable = viewport - reservedChrome
        let raw = usable / CGFloat(tabCount)
        return min(max(raw, minWidth), maxWidth)
    }
}
```

Semantics locked for tests: `tabCount == 0` → `maxWidth` (no division);
`viewport - reservedChrome` negative or tiny → clamps up to `minWidth`;
result never below `minWidth` nor above `maxWidth`.

**`ScrollWheelHorizontalRedirect` (AppKit bridge)** — new file
`Treemux/UI/Components/ScrollWheelHorizontalRedirect.swift`. An
`NSViewRepresentable` that installs a **local** `NSEvent` scroll-wheel monitor
(`NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)`) on appear and
removes it on disappear. In the handler:

- Determine whether the event's pointer location falls inside the tab bar's
  frame (the bar reports its frame via a `GeometryReader` in a known
  coordinate space; the representable receives that frame).
- If `event.hasPreciseScrollingDeltas` (trackpad) → return the event
  unchanged (native handling).
- Else if the pointer is inside the bar and the wheel delta is vertical →
  invoke a callback with the vertical delta and consume the event
  (return `nil`).
- Otherwise → return the event unchanged.

The callback receiver (the tab bar view) computes
`target = clamp(liveX − deltaY × step, 0, maxScroll)` and calls
`scrollPosition.scrollTo(x: target)`.

Direction: vertical wheel **down** scrolls the strip toward its **trailing**
(right) edge. The exact `deltaY` sign is calibrated during implementation
against macOS conventions (documented in the manual smoke checklist).

### Per-bar wiring (same shape for both bars)

1. Wrap the `ScrollView(.horizontal)` in a `GeometryReader` (or use a
   background `GeometryReader` + `PreferenceKey`) to obtain `viewportWidth`.
2. Track scroll offset with macOS 15 APIs: attach `@State var scrollPosition =
   ScrollPosition()`, `.scrollPosition($scrollPosition)`, and
   `.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action:
   { _, x in liveX = x }`. Measure `contentWidth` via a `PreferenceKey` on the
   inner `HStack` so `maxScroll = max(0, contentWidth − viewportWidth)`.
3. Compute `uniformWidth = TabBarLayout.uniformWidth(viewport: viewportWidth,
   tabCount: <bar's tab count>, reservedChrome: <bar's chrome>, minWidth: 64,
   maxWidth: 240)` and apply `.frame(width: uniformWidth)` to every tab
   button.
4. Overlay `ScrollWheelHorizontalRedirect` (transparent) bound to the bar's
   frame + the `scrollPosition`/`liveX`/`maxScroll` state.

**`WorkspaceTabBarView` specifics:**
- `reservedChrome` = measured width of the group eyebrows ("Files"/"Shell")
  plus the divider plus the inner `HStack` horizontal padding. Eyebrow /
  divider widths are read at runtime through a `PreferenceKey` (their content
  is localized, so runtime measurement is used rather than hardcoded metrics).
- Replace the `TreemuxTabSizing.width(...)` at the tab button (line ~198) and
  at the rename field (line ~79) with the computed `uniformWidth`.
- Delete the now-unused `TreemuxTabSizing` enum at the end of the file.

**`FileSubTabBarView` specifics:**
- `reservedChrome` = the inner `HStack` horizontal padding only (constant;
  no eyebrows/divider).
- Add the truncation trio to `SubTabButton`'s title `Text`:
  `.lineLimit(1)`, `.truncationMode(.tail)`,
  `.frame(maxWidth: .infinity, alignment: .leading)`.
- Apply `.frame(width: uniformWidth)` to each `SubTabButton`.

### Theme / i18n

- No new colors — reuse existing theme tokens; the transparent redirect view
  draws nothing.
- No new user-visible strings — no `Localizable.xcstrings` change.

## Testing

**Unit tests** — new `TreemuxTabLayoutTests` covering `TabBarLayout.uniformWidth`:

- Few tabs: `(viewport − chrome) / tabCount > maxWidth` → returns `maxWidth`.
- Medium: result strictly within `min…max` equals `(viewport − chrome) / tabCount`.
- Many tabs: `(viewport − chrome) / tabCount < minWidth` → returns `minWidth`.
- `tabCount == 0` → returns `maxWidth` (no division by zero).
- `viewport < reservedChrome` (negative usable) → clamps up to `minWidth`.

**Remove** `TreemuxTabSizingTests.swift` in full (the type it tests is deleted).

**Manual smoke (GUI)** — behavior tied to real wheel/layout:

- Both bars render equal-width tabs; opening many tabs shrinks them together
  to the floor, after which the bar scrolls horizontally.
- Long titles / long filenames show a trailing ellipsis.
- A mouse scroll wheel (vertical) over each bar scrolls it horizontally in the
  natural direction; a trackpad two-finger horizontal swipe still scrolls it
  natively (not intercepted).
- Existing interactions do not regress: drag-to-reorder, rename, close button,
  right-click context menus, the "+" new-tab button.

## Acceptance Criteria

- Both tab bars use browser-style adaptive equal width with ellipsis
  truncation.
- Mouse-wheel vertical scroll moves each bar horizontally; trackpad scrolling
  is unaffected.
- `TabBarLayout` unit tests pass; full suite green after `TreemuxTabSizing`
  removal.
- GUI smoke passes for both bars.

## Out of Scope

- Changing tab ordering, grouping (Files/Shell), or drag-reorder behavior.
- Vertical/stacked tab layouts.
- Tab overflow menus (a chevron/dropdown of hidden tabs) — overflow is handled
  purely by horizontal scrolling.
- Any change to the file-tree scroll behavior in `FileTreePanelView`.
