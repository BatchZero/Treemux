# Selection Highlight Visibility — Design

**Date:** 2026-05-06
**Status:** Draft
**Owner:** 卡皮巴拉 / BatchZero

## Problem

When viewing a text file in Treemux's file viewer, dragging the mouse to select characters does not produce a clearly visible background highlight. The user expects VSCode-style selection feedback (a clearly distinguishable colored background under the selected glyphs).

## Current Behavior (Diagnosis)

The text viewer is `TextEditorView`, which embeds `CodeEditSourceEditor.SourceEditor` (`Treemux/UI/FileBrowser/TextEditorView.swift`).

Selection color is already plumbed through:

1. `TreemuxEditorTheme.from(uiColors:)` builds an `EditorTheme.selection`:
   ```swift
   let selection = NSColor(Color(hex: ui.accentColor))
       .withAlphaComponent(0.3)
       .editorThemeColor
   ```
2. `CodeEditSourceEditor` assigns it to `controller.textView.selectionManager.selectionBackgroundColor`
   (`SourceEditorConfiguration+Appearance.swift:144`).
3. `TextSelectionManager.drawSelectedRange` fills selection rects with that color when the
   text view is first responder (`TextSelectionManager+Draw.swift:79`).

So selection IS being drawn — visibility is the issue. Two contributing factors:

- **Alpha is too low for the color/background pairing.** Dark theme: `accentColor #418ADE` at 30% over `paneBackground #111317` ≈ `#1F3653`. Visible, but markedly weaker than VSCode dark+'s `#264F78` over `#1E1E1E`.
- **The construction path goes through SwiftUI→AppKit bridging.** `NSColor(Color(hex:))` returns an NSColor whose representation can be a "resolved" or display-P3-tagged color depending on macOS version; chaining `.withAlphaComponent(_:)` on such an NSColor is not consistently lossless across versions, and the subsequent `.usingColorSpace(.sRGB)` adds a second conversion. The end-effective alpha can be lower than 0.3.

## Goal

When the user drags to select text in the file viewer, the selection background reads clearly against the active theme's background — comparable to VSCode's default selection contrast — for both built-in themes (Treemux Dark, Treemux Light).

## Non-Goals

- Selection-match highlighting (other occurrences of the selected substring).
- Cursor-line ("active line") highlight tuning.
- New theme schema fields, theme migrations, settings toggles, or user-configurable selection colors.
- Any change to selection behavior outside the file viewer (terminal, sidebar, etc.).
- Changes to how `EditorTheme` consumers other than `selection` are constructed.

## Approach

Single-line change in `TreemuxEditorTheme.from(uiColors:)`: rebuild `EditorTheme.selection` so it (a) bypasses the SwiftUI→AppKit color bridge and (b) uses an alpha that produces VSCode-comparable contrast.

### New construction path

Parse the hex string from `ui.accentColor` directly into 8-bit RGB components, then construct an sRGB `NSColor` with explicit `alpha: 0.45`:

```swift
let selection = NSColor.sRGBSelection(fromHex: ui.accentColor, alpha: 0.45)
```

Where `sRGBSelection(fromHex:alpha:)` is a small private helper in this file:

```swift
private extension NSColor {
    static func sRGBSelection(fromHex hex: String, alpha: CGFloat) -> NSColor {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&rgb)
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8)  & 0xFF) / 255.0
        let b = CGFloat( rgb        & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}
```

This bypasses `Color(hex:)` → `NSColor(_: Color)` → `withAlphaComponent` entirely. The returned NSColor is unambiguously sRGB, so the existing `.editorThemeColor` (`usingColorSpace(.sRGB)`) is a no-op and remains for safety.

### Why alpha = 0.45

Visual targets, blended over each theme's `paneBackground`:

| Theme | accent | bg      | result @ 0.45 | VSCode reference |
|-------|--------|---------|---------------|------------------|
| Dark  | `#418ADE` | `#111317` | `~#28547B`    | `#264F78` (dark+) |
| Light | `#2F7DE1` | `#FFFFFF` | `~#A1C2EE`    | `#ADD6FF` (light) |

Both land within a few units of VSCode's defaults. Alpha is kept below 1.0 so glyph color still reads through the highlight (matching VSCode's behavior — selected text isn't reverse-video).

### What stays the same

- `EditorTheme.selection` keeps deriving from `accentColor`, so theme cohesion is preserved.
- All other `EditorTheme` fields, the call site in `TextEditorView.body`, and theme schema are untouched.
- The `editorThemeColor` extension is kept; only the input to it changes.

## Files Touched

- `Treemux/UI/FileBrowser/TextEditorView.swift` — replace the one-line `selection` build inside `TreemuxEditorTheme.from(uiColors:)`, and add a small `NSColor.sRGBSelection(fromHex:alpha:)` helper alongside the existing private NSColor extension in the same file.

No other files are modified. No new strings, so no `Localizable.xcstrings` changes.

## Testing

### Manual (primary)

1. Build the app, open a text file (e.g. any `.swift` source) in the file viewer.
2. Drag-select a span of characters → expect a clearly visible blue selection background, comparable to VSCode dark+.
3. Switch to Treemux Light theme via Settings → repeat → expect a soft blue selection background, comparable to VSCode light.
4. Click into the editor without selecting (caret only) → confirm the cursor still appears and behaves as before (no regression in the line-highlight path, which is unchanged).
5. Resize / scroll while a selection is active → confirm highlight tracks correctly (sanity check that we haven't disturbed the draw path).

### Automated

No new unit test. The change is a color value; verifying it would require either a snapshot test (not currently set up for this view) or asserting RGB components, which is low signal versus visual confirmation. The existing theme test suite (`ThemeTests.swift`) does not cover `EditorTheme` construction; adding coverage there is out of scope.

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| `accentColor` strings ever contain 8-digit hex (with alpha). | The hex parser only reads the low 24 bits — any embedded alpha component is ignored, and the explicit `alpha:` argument always wins. Behavior is well-defined. |
| A future custom theme defines a non-blue accent that looks bad at 0.45 (e.g., a very dark red). | Acceptable: the existing design already couples selection to accent. Custom themes can ship later with a dedicated selection field if needed; that's outside this spec. |
| 0.45 still feels too weak after building. | Trivially tunable — adjust the alpha constant in the same line. No dependent code. |

## Out of Scope (Deferred)

- VSCode "selection match" (highlight all occurrences of the selected substring) — explicitly declined by the user for this iteration.
- Theme-specific selection color overrides via `UIColors`.
- Tuning `EditorTheme.lineHighlight` (the active-line background, currently `paneHeaderBackground` and barely visible against `paneBackground`).
