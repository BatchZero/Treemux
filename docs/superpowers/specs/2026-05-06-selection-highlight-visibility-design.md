# Selection Highlight Visibility — Design

**Date:** 2026-05-06
**Status:** Implemented
**Owner:** 卡皮巴拉 / BatchZero

## Problem

When viewing a text file in Treemux's file viewer, the selection background is
**invisible** under every selection method — mouse drag-select, ⌘A select-all,
shift-arrow extension. The selection range itself is correct (⌘C copies the
right text), but no visual feedback appears.

Goal: make selection produce a clearly visible, VSCode-style background
highlight, **without** sacrificing the existing horizontal scrolling for
unwrapped long lines.

## Investigation Trail (kept for the file's archaeological value)

The root cause is non-obvious and shared between an upstream library bug and
a Treemux-side workaround that was added for a different reason. The first
hypothesis (alpha being eaten by the SwiftUI→AppKit `NSColor` bridge) turned
out to be wrong; recording the real chain so future debugging doesn't repeat
the dead end:

### Bug 1 — upstream `maxLineWidth` never propagates

In `CodeEditTextView`'s `TextLayoutManager+Layout.swift:190`, the per-line
layout helper does:

```swift
private func layoutLine(
    ...,
    maxFoundLineWidth: inout CGFloat
) -> (...) {
    ...
    var maxFoundLineWidth = maxFoundLineWidth   // ← shadows the inout
    ...
    if maxFoundLineWidth < lineSize.width {
        maxFoundLineWidth = lineSize.width      // ← writes to the local copy
    }
}
```

The `var maxFoundLineWidth = maxFoundLineWidth` line creates a local copy
that shadows the `inout` parameter. Every subsequent write goes to the
local; nothing is propagated back to the caller. As a result,
`TextLayoutManager.maxLineWidth` permanently stays at its initial value of
`0`, no matter how wide the actual document is.

Introduced in commit `e7f1580a` (2025-07-23) and still present in
CodeEditTextView main HEAD as of 2026-05.

### Bug 2 — Treemux's existing scroll workaround

`ScrollBehaviorCoordinator` (this file) was added to make horizontal
scrolling work for long unwrapped lines despite Bug 1. It does so by
inflating `layoutManager.edgeInsets.right` until `estimatedWidth() =
maxLineWidth + edgeInsets.horizontal` reports a value large enough that
`updateFrameIfNeeded` keeps the textView frame wider than the viewport
(giving NSScrollView something to scroll).

That inflation has a side effect that the original comment incorrectly
dismissed as "no visible effect": `wrapLinesWidth = viewport.width −
edgeInsets.horizontal` goes **negative** once `right` exceeds the viewport.

### Where the two bugs meet — `getFillRects`

`TextSelectionManager.getFillRects` clamps every selection rect to a
bounding rect of width `max(maxLineWidth, wrapLinesWidth)`:

```swift
let textWidth = if maxLineLayoutWidth == .greatestFiniteMagnitude {
    maxLineWidth         // 0, per Bug 1
} else {
    maxLineLayoutWidth   // wrapLines==true path, not used here
}
let maxWidth = max(textWidth, wrapLinesWidth)   // max(0, negative) = 0
let validTextDrawingRect = CGRect(x: ..., width: maxWidth, ...)
```

With `wrapLines: false` (Treemux's setting), the `if` branch hits
`maxLineWidth = 0`. With Bug 2 active, `wrapLinesWidth` is negative.
`max(0, negative) = 0`, so `validTextDrawingRect.width = 0`. Every
selection rect intersected with this zero-width rect collapses to zero
width. `context.fill(...)` paints zero pixels. Selection is invisible.

The selection range data is correct throughout — only the visual draw is
broken.

### Containment check before solving

`textViewportSize()` (which feeds `wrapLinesWidth`) is called from
exactly one place in CodeEditTextView: the `wrapLinesWidth` getter
itself. `wrapLinesWidth` is consumed in two places:

1. `maxLineLayoutWidth` — only when `wrapLines == true` (we never set it).
2. `getFillRects` — exactly the path we want to fix.

So overriding `textViewportSize()` only affects selection-rect width.
Nothing else in the package depends on it.

## Approach

Single-file change in `Treemux/UI/FileBrowser/TextEditorView.swift`. Two
independent improvements that ship together:

### 1. Wrapper delegate to keep `wrapLinesWidth` non-negative

Add a `SelectionRectFixDelegate` private class that conforms to
`TextLayoutManagerDelegate`. It's installed in front of the textView
on `TextLayoutManager.delegate` (a `public weak var` — accessible from
outside the package). Five of the six protocol members forward
unchanged to the textView. The sixth — `textViewportSize()` — returns:

```swift
var size = textView.textViewportSize()
size.width += layoutManager.edgeInsets.horizontal
return size
```

Reading `edgeInsets.horizontal` at call-time means we always reflect the
current inflation level. With this lie, `wrapLinesWidth = (real_viewport
+ horizontal) − horizontal = real_viewport` — always positive,
regardless of how far `ScrollBehaviorCoordinator` has inflated `right`.
Selection rects clamp to the actual viewport width and become visible.

The wrapper is installed in `controllerDidAppear`, restored to the
original delegate in `destroy()`, and held strongly by the coordinator
(since `TextLayoutManager.delegate` is `weak`).

### 2. VSCode-strength selection color

Independent of the wrapper fix: replace the `EditorTheme.selection`
construction so the alpha is reliably 0.45 (matching VSCode dark+'s
contrast against the editor background) and the NSColor is built
directly in sRGB rather than going through the SwiftUI `Color(hex:)` →
`NSColor(_:)` → `withAlphaComponent` bridge:

```swift
let selection = NSColor.sRGBSelection(fromHex: ui.accentColor, alpha: 0.45)
```

A small `NSColor.sRGBSelection(fromHex:alpha:)` helper sits next to the
existing `editorThemeColor` extension — parses the hex string into 8-bit
sRGB components and constructs the color directly with the requested
alpha.

The alpha and color-space hardening were originally believed to be
load-bearing fixes for the visibility issue (per the v1 of this spec).
They aren't — even alpha 1.0 magenta would have rendered invisibly
because of the zero-width clamp. They are kept anyway as a quality
improvement: the resulting blue is closer to VSCode's dark+/light
defaults, reading clearly against both built-in themes.

## Numbers (for visual reference)

Blended over each theme's `paneBackground`:

| Theme | accent | bg      | result @ 0.45 | VSCode reference |
|-------|--------|---------|---------------|------------------|
| Dark  | `#418ADE` | `#111317` | `~#28547B`    | `#264F78` (dark+) |
| Light | `#2F7DE1` | `#FFFFFF` | `~#A1C2EE`    | `#ADD6FF` (light) |

## Files Touched

- `Treemux/UI/FileBrowser/TextEditorView.swift` — single file
  - Add `SelectionRectFixDelegate` private class implementing
    `TextLayoutManagerDelegate`
  - In `ScrollBehaviorCoordinator`: hold the wrapper strongly,
    install in `controllerDidAppear`, restore in `destroy()`
  - In `TreemuxEditorTheme.from(uiColors:)`: build `selection` via
    `NSColor.sRGBSelection(fromHex:alpha:)`
  - Add `NSColor.sRGBSelection(fromHex:alpha:)` helper next to the
    existing `editorThemeColor` extension
  - Update the `ScrollBehaviorCoordinator` doc-comment to correct the
    "no visible effect" claim (it broke selection draw — that's the
    whole reason this change exists)

No other files modified. No theme schema changes. No new strings
(no `Localizable.xcstrings` update).

## Out of Scope (Deferred)

- VSCode "selection match" (highlight all occurrences of the selected
  substring) — explicitly declined for this iteration.
- Theme-specific selection color overrides via `UIColors`.
- Tuning `EditorTheme.lineHighlight` (the active-line background).
- **Patching upstream `maxLineWidth` / `inout` shadowing.** The right
  long-term fix is a one-line PR to CodeEditTextView removing the
  `var maxFoundLineWidth = maxFoundLineWidth` shadow. Once upstream
  merges that, our `ScrollBehaviorCoordinator` and the wrapper delegate
  can both be deleted entirely. Filing the PR is a separate task; the
  wrapper here is forward-compatible (when upstream is fixed,
  `edgeInsets.horizontal` shrinks to its natural value, the
  compensation in `textViewportSize()` becomes nearly zero, and the
  numbers fall out the same).

## Testing

Manual visual verification only — confirmed in both built-in themes:

- **Selection visibility**: drag-select, ⌘A, shift-arrow all show a
  clearly visible blue background under the selected glyphs.
- **Horizontal scroll preserved**: a file with lines wider than the
  viewport scrolls horizontally (trackpad pan or scrollbar drag), and
  selections within the off-viewport region still highlight correctly.

No automated test added: the change is a behavioral fix that depends
on visual rendering of CGContext fills behind subviews. Unit-testing
that would require either a snapshot harness (not configured for this
view) or asserting RGB components (low signal). Manual verification
is the agreed test.

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Upstream adds another consumer of `textViewportSize()` that depends on the *real* viewport size; our wrapper would feed it an inflated value. | Containment is verified in this spec — currently only `wrapLinesWidth` consumes `textViewportSize()`. The wrapper's compensation should be revisited on every CodeEditTextView upgrade. |
| Upstream fixes `maxLineWidth`; the wrapper would still be installed but harmless. | When `edgeInsets.horizontal` is small, `compensation = horizontal` is small too, so `wrapLinesWidth` resolves to ~`viewport_width` either way. The wrapper is forward-compatible; deleting it later is purely cleanup. |
| `TextLayoutManager.delegate` weak-pointer churn: if the wrapper is deallocated mid-edit, the layout manager loses its delegate. | The coordinator holds the wrapper as a stored `let` property, so it lives as long as the coordinator. The coordinator is held by `@StateObject` in `CodeEditorRepresentable`, so it survives view updates. |
| `accentColor` ever contains an 8-digit hex (with embedded alpha). | The hex parser only reads the low 24 bits — any embedded alpha is ignored, and the explicit `alpha:` argument always wins. |
