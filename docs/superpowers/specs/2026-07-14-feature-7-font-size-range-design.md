# Feature 7 — Expand Terminal Font-Size Range + Slider

Date: 2026-07-14
Batch: B–H (settings subsystem), requirement (7)
Status: Design approved

## Goal

Expand the terminal font-size adjustment range and make reaching the wider
range ergonomic by adding a coarse-drag slider alongside the existing
fine-tune buttons.

Scope is **terminal font only**. The file-browser tree font (driven by
`TreeDensity` presets) and any app-chrome / preview fonts are explicitly out
of scope.

## Requirements

1. Terminal font offset range widens from `-8 … +12` to **`-8 … +36`**.
   - Only the upper bound changes. Lower bound stays `-8`.
   - The `6pt` floor and `72pt` ceiling in the point-size formula are
     unchanged. At reference PPI (109), offset `+36` → `14 + 36 = 50pt`,
     comfortably below the 72pt ceiling, so the extra headroom is real.
2. Settings UI gains a `Slider` for coarse adjustment; the existing
   `−` / value / `+` / Reset row is preserved for fine tuning.
3. `⌘=` keeps incrementing up to the new upper bound automatically (it clamps
   through the same source of truth).
4. No new user-visible strings → no `Localizable.xcstrings` changes required.

## Design

### Single source of truth

`AdaptiveFontSizeCalculator.offsetRange` is the only place the bound is
declared:

```swift
// Treemux/Domain/AdaptiveFontSizeCalculator.swift
static let offsetRange: ClosedRange<Int> = -8 ... 36   // was -8 ... 12
```

Everything downstream derives from it and needs no edit:

- `AdaptiveFontSizeCalculator.clampOffset(_:)` — clamps to the range.
- `TerminalSettings.clamp(_:)` — delegates to `clampOffset`, so decode /
  init / mutation all honour the new upper bound.
- `AppDelegate.adjustTerminalFontSizeOffset(by:)` (⌘= / ⌘-) — clamps via
  `TerminalSettings.clamp`, so the shortcut reaches `+36`.
- `SettingsSheet` `canIncrease` — `< offsetRange.upperBound`, so the `+`
  button stays enabled up to `+36`.

### Settings UI (`TerminalSettingsView` in `SettingsSheet.swift`)

Inside the existing "Terminal Font Size" `Section`, add a `Slider` **above**
the current button row:

- Bound to `settings.terminal.fontSizeOffset` through an `Int ↔ Double`
  bridge: a computed `Binding<Double>` whose getter returns
  `Double(offset)` and whose setter writes
  `TerminalSettings.clamp(Int(value.rounded()))`.
- `in: Double(offsetRange.lowerBound) ... Double(offsetRange.upperBound)`,
  `step: 1`.
- The existing `−` / value-label / `+` / Reset `HStack` stays directly below,
  unchanged.
- The footer ("Currently N pt on this display." + auto-adjust hint) stays as
  is — it already reflects the current offset.
- Slider uses system default tint (no hardcoded color; theme rules satisfied).

### Persistence

No schema change. `fontSizeOffset` is already the persisted key and already
runs through `TerminalSettings.clamp` on decode, so a stored `+36` round-trips
correctly and out-of-range legacy values clamp to `+36`.

## Testing

Unit tests (`AdaptiveFontSizeCalculatorTests`):

- Update `testOffsetRange_isMinus8To12` → assert `offsetRange == -8 ... 36`
  (rename the method to match).
- `clampOffset(100)` expectation `12` → `36`; add boundary cases
  `clampOffset(36) == 36` and `clampOffset(37) == 36`.
- Add: `fontSize(forPPI: 109, offset: 36) == 50` — proves the new upper bound
  actually produces a larger point size and is not swallowed by the 72pt
  ceiling.
- Keep existing lower-bound / ceiling / floor tests unchanged.

Persistence tests (`PersistenceTests`):

- `testTerminalSettings_decodesLegacyFontSize_99_clampsToUpperBound`:
  expectation `12` → `36`.

## Acceptance Criteria

- Slider drags smoothly from `-8` to `+36`; `±` buttons still fine-tune ±1.
- `⌘=` increments all the way to `+36`; `⌘-` down to `-8`; `⌘0` resets.
- Value persists across app restart.
- Full test suite green.
- GUI smoke: dragging the slider to `+36` visibly enlarges terminal text
  (larger than the old `+12` maximum).

## Out of Scope

- File-browser tree font sizing (stays on `TreeDensity`).
- App-chrome / markdown-preview font sizing.
- Lowering the `6pt` floor (lower bound stays `-8`, where the floor already
  bites at reference PPI).
