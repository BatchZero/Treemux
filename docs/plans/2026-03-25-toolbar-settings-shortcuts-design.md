# Treemux UI Design: Toolbar, Settings, Command Palette & Shortcuts

**Date:** 2026-03-25
**Status:** Approved

## Overview

Enhance Treemux's UI by adding toolbar buttons, wiring up existing but disconnected components (SettingsSheet, CommandPaletteView), implementing dark/light appearance switching, and building a full keyboard shortcut customization system — all referencing Liney's implementation patterns.

## Current State

| Component | Code exists? | Integrated? |
|-----------|-------------|------------|
| SettingsSheet (6 tabs) | Yes | No — no `.sheet()` mount, `openSettings()` is a stub |
| CommandPaletteView | Yes | No — no `.overlay()` mount, `toggleCommandPalette()` is a stub |
| Split tree + drag dividers | Yes | Yes — working |
| Toolbar buttons (split/new/settings) | No | — |
| Shortcut customization (recorder) | No | — |
| Dark/light appearance toggle | No | — |

## Design

### Module 1: State Management & Toolbar Buttons

**State:** Add `@Published var showSettings = false` and `@Published var showCommandPalette = false` to `WorkspaceStore`.

**AppDelegate wiring:** `openSettings()` → `store?.showSettings = true`; `toggleCommandPalette()` → `store?.showCommandPalette.toggle()`.

**MainWindowView mounts:**
- `.sheet(isPresented: $store.showSettings) { SettingsSheet() }`
- `.overlay { if store.showCommandPalette { CommandPaletteView(isPresented: $store.showCommandPalette) } }`

**Toolbar layout:**
```
[sidebar toggle]          [split↓] [split→] [new terminal+] [⚙️]
  .navigation                        .primaryAction
```

Button actions:
- **Split ↓** → `splitPane(focused, axis: .horizontal)` (top/bottom)
- **Split →** → `splitPane(focused, axis: .vertical)` (left/right)
- **New terminal +** → create a new default terminal pane in the current workspace
- **⚙️** → `store.showSettings = true`

### Module 2: Command Palette Binding (⌘⇧P)

Wire up the existing `CommandPaletteView`:
1. Mount as `.overlay` in `MainWindowView` bound to `$store.showCommandPalette`
2. AppDelegate `toggleCommandPalette()` → `store?.showCommandPalette.toggle()`
3. The existing ⌘⇧P menu shortcut then triggers the palette correctly

### Module 3: Dark/Light Appearance Toggle

**AppSettings:** Add `var appearance: String = "system"` (values: `"system"` / `"dark"` / `"light"`).

**WindowContext:** Apply appearance based on setting:
- `"system"` → `window.appearance = nil` (follow system)
- `"dark"` → `window.appearance = NSAppearance(named: .darkAqua)`
- `"light"` → `window.appearance = NSAppearance(named: .aqua)`

**SettingsSheet General tab:** Add a Picker: Follow System / Dark / Light.

**Live update:** On change, update `NSApp.keyWindow?.appearance` immediately.

Note: This controls the system appearance (SwiftUI controls, system colors). It is independent of ThemeManager's terminal color scheme.

### Module 4: Full Keyboard Shortcut Customization

**Data model (referencing Liney's StoredShortcut):**

```swift
struct StoredShortcut: Codable, Hashable {
    var key: String       // "d", "p", "b", etc.
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool
}

enum ShortcutAction: String, CaseIterable, Codable {
    case splitHorizontal, splitVertical, closePane
    case focusNextPane, focusPreviousPane, zoomPane
    case toggleSidebar, commandPalette
    case openProject, openSettings
    case newClaudeCode
}

enum ShortcutOverride: Codable {
    case custom(StoredShortcut)
    case disabled
}
```

**Storage:** Add `var shortcutOverrides: [String: ShortcutOverride]` to `AppSettings`. Key = `ShortcutAction.rawValue`. Missing key = use default.

**Shortcut recorder UI (referencing Liney's ShortcutRecorderNSButton):**
- NSViewRepresentable wrapping an NSButton
- Click to enter "recording mode", press key combo to record
- Automatic conflict detection (warn if new shortcut clashes with another action)
- "Reset to Default" and "Disable" buttons per shortcut

**Menu bar sync:** `AppDelegate.buildMainMenu()` reads effective shortcuts from AppSettings instead of hardcoded `keyEquivalent`. Rebuild menu when settings change.

## Key Files to Modify

| File | Changes |
|------|---------|
| `WorkspaceStore.swift` | Add `showSettings`, `showCommandPalette` published properties |
| `MainWindowView.swift` | Add toolbar buttons, `.sheet()`, `.overlay()` |
| `AppDelegate.swift` | Wire menu actions to store; read shortcuts from settings |
| `AppSettings.swift` | Add `appearance`, `shortcutOverrides` fields |
| `SettingsSheet.swift` | Add appearance picker to General; rewrite Shortcuts tab with recorder |
| `WindowContext.swift` | Apply appearance setting |

## New Files to Create

| File | Purpose |
|------|---------|
| `Domain/StoredShortcut.swift` | Shortcut data model + ShortcutAction enum + defaults |
| `UI/Settings/ShortcutRecorderButton.swift` | NSViewRepresentable shortcut recorder |
