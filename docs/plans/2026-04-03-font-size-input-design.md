# Font Size TextField + Stepper Design

**Date:** 2026-04-03
**Status:** Approved

## Problem

The font size setting in Settings only supports Stepper (+/- buttons). Users want to type a specific font size directly via keyboard input.

## Decision

Replace the display-only `Text` in the Stepper label with an editable `TextField`, keeping the Stepper +/- buttons intact.

## Design

### Scope

- `SettingsSheet.swift` — `TerminalSettingsView` only
- Font size range changed from `8...32` to `6...72`

### Data Flow

1. `AppSettings.terminal.fontSize` stays `Int`
2. A local `@State var fontSizeText: String` serves as the TextField edit buffer
3. Stepper `value` binds to `settings.terminal.fontSize` with range `6...72`
4. Stepper label: `Text` replaced by `TextField` bound to `fontSizeText`

### Commit Logic (on Enter / focus lost)

- Parse `fontSizeText` to `Int`, clamp to `6...72`, write back to `settings.terminal.fontSize`
- Sync `fontSizeText` to the clamped value
- If parse fails, revert `fontSizeText` to current `settings.terminal.fontSize`

### Stepper → TextField Sync

- `.onChange(of: settings.terminal.fontSize)` updates `fontSizeText` when +/- buttons are used

### TextField Style

- Fixed width ~40pt, right-aligned, `monospacedDigit`
- `.foregroundStyle(.secondary)` to match original `Text` appearance
