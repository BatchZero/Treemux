# Localization Fix Design

## Problem

1. **Language switch not applied at runtime**: `LanguageManager.apply()` is only called at app launch. Changing the language in Settings and clicking Save does not take effect until the app is restarted.
2. **Hardcoded English strings**: ~17+ UI strings are not localized, appearing in English even when the app language is set to Chinese.

## Solution: SwiftUI `.environment(\.locale)` Real-Time Switching

### Architecture

Convert `LanguageManager` from a stateless `enum` to an `ObservableObject` class. It publishes a `Locale` value that drives SwiftUI's localization system via `.environment(\.locale)`.

### Components

#### 1. LanguageManager Refactor

- Change from `enum` to `@MainActor final class: ObservableObject`
- Add `@Published var locale: Locale` derived from the language code
- `apply(languageCode:)` updates both `locale` (immediate SwiftUI effect) and `AppleLanguages` UserDefaults (persists for next launch)
- Helper to resolve "system" → actual system locale, "en" → `Locale(identifier: "en")`, "zh-Hans" → `Locale(identifier: "zh-Hans")`

#### 2. WindowContext Integration

- Create `LanguageManager` in `WindowContext.init()` (alongside `ThemeManager`)
- Inject into root view: `.environmentObject(languageManager)` and `.environment(\.locale, languageManager.locale)`
- Expose `languageManager` so `TreemuxApp` can call `apply()` at launch

#### 3. SettingsSheet Save Flow

- On Save, call `languageManager.apply(draft.language)` in addition to `store.updateSettings(draft)`
- Access `languageManager` via `@EnvironmentObject`

#### 4. Hardcoded String Fixes

Replace all hardcoded English strings with `String(localized:)`:

| File | Strings |
|------|---------|
| SidebarIconCustomizationSheet | Random, Palette, Customize Sidebar Icon, subtitle, Reset, Cancel, Save |
| EmptyTabStateView | No open terminals, New Terminal, shortcut hint |
| WorkspaceTabBarView | Rename..., Close Tab, Tab name placeholder |
| MainWindowView | Toggle Sidebar, help tooltips (Split Down, Split Right, New Terminal, Settings) |
| SidebarNodeRow | "current" label |
| SettingsSheet | "Path" placeholder |

#### 5. Localizable.xcstrings Updates

Add Chinese translations for all newly localized strings to the `.xcstrings` catalog.

### Data Flow

```
User changes language in Settings → Save
  → store.updateSettings(draft)          // persists to JSON
  → languageManager.apply(draft.language) // updates @Published locale + AppleLanguages
    → SwiftUI re-renders all views using the new Locale environment
```

### Non-Goals

- No custom localization wrapper functions
- No third-party localization libraries
- Language picker labels ("English", "中文") remain hardcoded as display names (intentional — they should always show in their own language)
