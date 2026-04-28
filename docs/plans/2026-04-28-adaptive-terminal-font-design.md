# Adaptive Terminal Font Across Displays — Design

Date: 2026-04-28
Branch: `feat/adaptive-terminal-font`

## Problem

Dragging a Treemux window between monitors with different effective PPI changes the perceived font size.
A high-PPI Retina display and a 4K external in "More Space" mode both report `backingScaleFactor = 2`,
but the same `font-size = 14pt` renders at very different physical sizes.
Users today can only nudge the global `fontSize` integer in Settings, which then breaks the other display.

The reference projects do not solve this:

- **Liney** (`Services/Terminal/Ghostty/LineyGhosttyController.swift`) only listens to
  `didChangeBackingPropertiesNotification` to push the new scale into ghostty surface metrics. Font size is
  a single global `terminalFontSize: Double?`.
- **cmux** (`Sources/GhosttyTerminalView.swift`, ~9k lines) has the same model: one `GhosttyConfig.fontSize`,
  `scaleFactors(for:)` is just `backingScaleFactor` repeated three times. No per-display adaptation.

Treemux already has the right hooks — `viewDidChangeBackingProperties` / `setFrameSize` /
`viewDidMoveToWindow` all call `syncSurfaceMetrics()` — so the infrastructure for "react to a screen
change" exists. What's missing is the font-size adaptation itself.

## Design Choices

| Decision | Choice | Why |
|----------|--------|-----|
| Anchor for "what does 14 mean" | Hardcoded reference PPI | User picked C — settings should not expose an absolute pt number |
| Adjustment surface | "Larger / Smaller / Reset" buttons + hotkeys | User picked B + D |
| Scope of adjustment | Global, persisted | User picked A |
| Step size | 1pt linear, range -8 ... +12 | Simple, predictable; covers ~6pt to ~26pt at base |
| Reference PPI value | 109 | Apple "1.0× Retina" standard (iMac 5K 27" / Studio Display) |
| Base font size | 14pt | Current default |

## Core Formula

```
finalFontSize = clamp(round((BASE + offset) × currentPPI / REF_PPI), 6, 72)
```

- `BASE = 14` (source-code constant, not persisted)
- `REF_PPI = 109` (source-code constant)
- `currentPPI` derived from `CGDisplayScreenSize(displayID)` and `screen.frame.width`
- `offset` is the only persisted user input — an `Int` clamped to `-8 ... +12`

The user's offset is applied **in the base coordinate system before the PPI scale**, so adjusting the offset
on any display moves the rendered size proportionally on every display. Cross-display physical size stays
matched.

## Data Model

`AppSettings.terminal` change:

```swift
struct TerminalSettings {
    // Removed: var fontSize: Int = 14
    var fontSizeOffset: Int = 0  // clamp -8 ... +12
}
```

Migration in `AppSettingsPersistence.load()`:

- If decoder finds the legacy `fontSize` key, compute `offset = clamp(legacyFontSize - 14, -8, +12)` and
  drop the legacy field on next save.
- If neither field is present, default `offset = 0`.

`BASE` and `REF_PPI` live as `static let` on a new `AdaptiveFontSizeCalculator` type, alongside the formula.

## Trigger Points / Cross-Display Sync

`TreemuxGhosttyController` (and the per-surface `TerminalSurface`) already sync surface metrics on three
hooks. Add a sibling `applyAdaptiveFontSize()` that runs on:

1. `viewDidMoveToWindow`
2. `viewDidChangeBackingProperties`
3. `NSWindow.didChangeScreenNotification` (new observer — covers same-backing cross-screen drags)
4. Combine subscription on `AppSettings.terminal.fontSizeOffset` — pushes to all live surfaces when the
   user invokes a hotkey or button.

The function:

```swift
func applyAdaptiveFontSize() {
    guard let surface else { return }
    let screen = window?.screen ?? NSScreen.main
    let pt = AdaptiveFontSizeCalculator.fontSize(
        for: screen,
        offset: settings.terminal.fontSizeOffset
    )
    ghostty_surface_set_font_size(surface, Float(pt))
}
```

Surface creation continues to set `configuration.font_size` initially using the same calculator, so newly
spawned surfaces start with the correct value.

## PPI Calculation

```swift
enum AdaptiveFontSizeCalculator {
    static let base: Int = 14
    static let referencePPI: CGFloat = 109
    static let offsetRange: ClosedRange<Int> = -8 ... 12

    static func fontSize(for screen: NSScreen?, offset: Int) -> Int {
        let clampedOffset = max(offsetRange.lowerBound, min(offsetRange.upperBound, offset))
        let ppi = effectivePPI(for: screen) ?? referencePPI
        let raw = CGFloat(base + clampedOffset) * ppi / referencePPI
        let rounded = Int(raw.rounded())
        return max(6, min(72, rounded))
    }

    static func effectivePPI(for screen: NSScreen?) -> CGFloat? {
        guard let screen, let displayID = screen.displayID, displayID != 0 else { return nil }
        let physMm = CGDisplayScreenSize(displayID)
        guard physMm.width > 0 else { return nil }
        let physInches = physMm.width / 25.4
        let effectivePoints = screen.frame.width
        let ppi = effectivePoints / physInches
        return (ppi.isFinite && ppi > 30 && ppi < 600) ? ppi : nil
    }
}
```

Fallback `nil → referencePPI` covers AirPlay / Sidecar / virtual displays / headless screens / EDID
without physical size. Behavior in those cases is "use the base font as-is", which is safe.

## Settings UI

Replace the existing `Stepper(value: clampedFontSize, in: 6...72)` block at
`Treemux/UI/Settings/SettingsSheet.swift:181`:

```
Section "Terminal font size"
  HStack {
    Button("Smaller") { decrement() }   // disabled at lower bound
    Text(offsetLabel)                   // "+0", "+3", "-2"
    Button("Larger")  { increment() }   // disabled at upper bound
    Spacer()
    Button("Reset")   { offset = 0 }
  }
  Text("Currently \(currentFontSize) pt — auto-scaled for this display")
    .footerStyle()
  Text("Use ⌘= / ⌘- / ⌘0 to adjust quickly. The font size adjusts automatically per display so physical size stays consistent.")
    .footerStyle()
```

All three labels and footers go through `LocalizedStringKey` and into `Localizable.xcstrings` with
`zh-Hans` translations, per the project's i18n rules.

## Hotkeys

Add three cases to `ShortcutAction`:

- `terminalFontSizeIncrease` (default ⌘=)
- `terminalFontSizeDecrease` (default ⌘-)
- `terminalFontSizeReset`    (default ⌘0)

Plumb defaults via `TreemuxKeyboardShortcuts`. Each action resolves to:

```swift
settings.terminal.fontSizeOffset = clamp(settings.terminal.fontSizeOffset ± 1)
// or = 0 for reset
```

The Combine subscription on `fontSizeOffset` then propagates to every live surface.

## Surface Update Mechanism

Treemux's existing flow uses `configuration.font_size = Float(...)` at surface creation
(`TreemuxGhosttyController.swift:1111`). For runtime updates after offset change or screen change:

- Prefer the C API `ghostty_surface_set_font_size(surface, Float)` if exposed in the bundled
  GhosttyKit headers.
- Otherwise fall back to the action-string mechanism cmux uses
  (`set_font_size:%.3f` via `ghostty_surface_dispatch_action`).

The exact symbol will be determined during implementation; both paths exist in the upstream Ghostty C API.

## Edge Cases

- **No screen yet** (window not in a window): skip the update; the next `viewDidMoveToWindow` will fire it.
- **Multi-display windows** (window straddles two screens): use `window.screen` (NSWindow's primary). It
  follows mouse focus per AppKit. No special handling.
- **Multiple surfaces (split panes, multiple tabs)**: each `TerminalSurface` registers its own observer,
  so each updates independently. No cross-surface coordination needed.
- **Rapid screen changes** (e.g., monitor sleep/wake): `applyAdaptiveFontSize` is idempotent and cheap
  (one `ghostty_surface_set_font_size` call). No debounce needed.
- **EDID lies / round physical size**: the `> 30 && < 600` PPI sanity guard rejects nonsense and falls
  back to reference PPI.

## Test Plan

Unit tests (`Tests/AdaptiveFontSizeCalculatorTests.swift`):

- Formula at `(ppi=109, offset=0) → 14`, `(ppi=109, offset=+3) → 17`, `(ppi=121, offset=0) → 16`,
  `(ppi=82, offset=0) → 11`, `(ppi=163, offset=0) → 21`.
- Clamp behavior: `offset=+99` clamps to `+12`, `offset=-99` clamps to `-8`.
- Final clamp: extreme PPI does not exceed `[6, 72]`.

Persistence migration tests:

- Legacy `fontSize=18` decodes to `offset=4`, no `fontSize` re-encoded.
- Legacy `fontSize=8`  decodes to `offset=-6`.
- Legacy `fontSize=99` decodes to `offset=12` (clamped).
- Missing both keys decodes to `offset=0`.

Manual verification (UI not unit-testable):

- MBP internal display ↔ external 4K in "Default", "More Space", "Larger Text" — physical glyph height
  visually consistent across all three.
- ⌘= ⌘- ⌘0 from any focused terminal, confirm all open terminals update simultaneously.
- Drag a window mid-typing across the screen boundary; cursor and text reflow, no garbage glyphs.
- New tab / new split inherits the live offset.
- Settings sheet: button disabled states at offset bounds; "Currently N pt" reflects the active display.

## Out of Scope

- Per-window or per-tab font offsets (rejected during brainstorming — chose Global).
- UI font scaling for sidebar / tab bar (the user's pain point is terminal text only; SwiftUI Dynamic
  Type already handles chrome).
- A user-facing "reference PPI" knob (rejected — kept as internal constant per choice C).
- Detecting "Use Font Smoothing" or other rendering preferences.
