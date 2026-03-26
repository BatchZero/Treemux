# Settings Save/Cancel Mode Design

**Date:** 2026-03-26
**Status:** Approved

## Summary

Change Treemux settings from immediate-apply (`@Binding` to `store.settings`) to a deferred-apply pattern with explicit Save/Cancel buttons, matching Liney's approach.

## Requirements

| Requirement | Decision |
|-------------|----------|
| Apply mode | Deferred — changes only persist on Save |
| Theme preview | Real-time preview while editing; Cancel reverts to original theme |
| Save button state | Disabled when no changes detected (`draft == originalSettings`) |
| Cancel / Esc behavior | Discard changes silently, no confirmation dialog |
| Reset All to Defaults (shortcuts) | Operates on draft copy; requires Save to persist |

## Architecture

### Data Flow

```
Current (immediate):
  SubView @Binding → store.settings (didSet → persist)

New (deferred):
  Sheet opens → @State draft = store.settings (copy)
  SubView @Binding → draft (edits only affect copy)
  Cancel → revert theme if needed → dismiss() (draft discarded)
  Save → store.updateSettings(draft) → persist → dismiss()
```

### State Variables in SettingsSheet

```swift
@State private var draft = AppSettings()            // Editable copy
@State private var originalSettings = AppSettings()  // Snapshot for comparison
```

Initialized in `.task {}`:
```swift
draft = store.settings
originalSettings = store.settings
```

### Change Detection

```swift
private var hasChanges: Bool {
    draft != originalSettings
}
```

Requires `AppSettings` (and all nested types) to conform to `Equatable`.

### Theme Preview

The existing `onChange(of: settings.activeThemeID)` in ThemeSettingsView continues to call `themeManager.setActiveTheme()` — now it watches `draft.activeThemeID`.

On Cancel, if theme was changed:
```swift
if draft.activeThemeID != originalSettings.activeThemeID {
    theme.setActiveTheme(originalSettings.activeThemeID)
}
```

## UI Layout

Footer inside the detail pane (right side only), following Liney's pattern:

```
┌──────────┬──────────────────────────────────────┐
│ Sidebar  │  Section Header                      │
│          │  ──────────────────────────────────── │
│          │  [Scrollable Settings Content]        │
│          │                                       │
│          │  ──────────────────────────────────── │
│          │                    [Cancel]   [Save]  │
└──────────┴──────────────────────────────────────┘
```

- Cancel: default button style
- Save: `.buttonStyle(.borderedProminent)`, `.disabled(!hasChanges)`
- Footer padding: 20pt
- Divider above footer for visual separation

## Files to Change

| File | Change |
|------|--------|
| `AppSettings.swift` | Add `Equatable` conformance to `AppSettings` and all nested types (`TerminalSettings`, `StartupSettings`, `SSHSettings`, `AIToolSettings`, `ShortcutOverride`) |
| `SettingsSheet.swift` | Add `@State draft`/`originalSettings`; add footer with Save/Cancel; change sub-view bindings from `$store.settings` to `$draft`; change `ShortcutsSettingsView` to accept `@Binding` instead of using `@EnvironmentObject` directly |
| `WorkspaceStore.swift` | Add `updateSettings(_:)` method |

### Files NOT Changed

- `AppSettingsPersistence.swift` — persistence logic unchanged
- `ThemeManager.swift` — preview mechanism unchanged
- `MainWindowView.swift` — sheet presentation unchanged
- Sub-view internals — their `@Binding var settings` interface is unchanged; only the binding source changes
