# Theme Unification Design

**Date:** 2026-03-26
**Status:** Implemented

## Problem

When the user selects `treemux-dark` theme but has Appearance set to "System" (and macOS
is in light mode), the toolbar/titlebar renders white while the rest of the app uses dark
theme colors. This creates a jarring visual split. Additionally, sidebar text (Project and
Worktree labels) uses system `.secondary` color instead of theme colors, making them hard
to read in dark mode.

### Root Cause

Two independent systems control appearance:

| System | Controls | Setting |
|--------|----------|---------|
| `AppSettings.appearance` | NSWindow's `NSAppearance` (toolbar, titlebar, system controls) | "system" / "dark" / "light" |
| `AppSettings.activeThemeID` | ThemeManager SwiftUI colors (sidebar, content, status bar) | "treemux-dark" / "treemux-light" |

These two settings are decoupled. When they disagree, the toolbar and content have
different color schemes.

Additionally, `window.backgroundColor` is hardcoded to a dark color `(0.07, 0.08, 0.09)`
regardless of the active theme.

## Solution: Theme-Driven Appearance (Approach A)

Each `ThemeDefinition` declares its own `appearance` ("dark" or "light"). Selecting a
theme automatically sets the correct `NSAppearance` and window background color. The
standalone `appearance` setting is removed.

### Architecture Changes

1. **ThemeDefinition.swift**
   - Add `appearance: String` field ("dark" or "light")
   - Add `windowBackground: String` to `UIColors`

2. **ThemeManager.swift**
   - Add computed property `windowAppearance: NSAppearance?`
   - Add computed property `nsWindowBackground: NSColor`

3. **WindowContext.swift**
   - `applyAppearance()` reads from `themeManager.windowAppearance`
   - `window.backgroundColor` reads from `themeManager.nsWindowBackground`
   - Observe theme changes to re-apply appearance

4. **AppSettings.swift**
   - Remove `appearance` property

5. **SettingsSheet.swift**
   - Remove Appearance picker from settings UI

6. **WorkspaceSidebarView.swift**
   - Replace `.foregroundStyle(.secondary)` with theme colors for readability

### Color Palette (Optimized)

**Dark Theme** (WCAG AAA, Developer Tool palette):

| Token | Value | Notes |
|-------|-------|-------|
| appearance | "dark" | NEW |
| windowBackground | #111317 | NEW - matches paneBackground |
| sidebarBackground | #0F1114 | Darker than content for layering |
| sidebarForeground | #E5E5E7 | High contrast >=7:1 |
| sidebarSelection | #1A2A42 | Blue-tinted, more visible |
| tabBarBackground | #0F1114 | |
| paneBackground | #111317 | |
| paneHeaderBackground | #151820 | Subtle distinction from content |
| dividerColor | #FFFFFF1A | Slightly more visible |
| accentColor | #418ADE | |
| statusBarBackground | #0F1114 | |
| textPrimary | #F0F0F2 | AAA contrast |
| textSecondary | #A0A8B8 | Fixed color instead of alpha |
| textMuted | #6B7280 | Fixed color instead of alpha |
| success | #4FD67B | |
| warning | #F0A830 | |
| danger | #EB6B57 | |

**Light Theme** (macOS-native feel):

| Token | Value | Notes |
|-------|-------|-------|
| appearance | "light" | NEW |
| windowBackground | #FFFFFF | NEW |
| sidebarBackground | #F5F5F7 | macOS-native sidebar gray |
| sidebarForeground | #1D1F21 | |
| sidebarSelection | #D0E0F0 | |
| tabBarBackground | #EDEDEF | |
| paneBackground | #FFFFFF | |
| paneHeaderBackground | #F5F5F7 | |
| dividerColor | #00000014 | |
| accentColor | #2F7DE1 | |
| statusBarBackground | #EDEDEF | |
| textPrimary | #1D1F21 | |
| textSecondary | #6B7280 | Fixed color instead of alpha |
| textMuted | #9CA3AF | Fixed color instead of alpha |
| success | #34A853 | |
| warning | #D99116 | |
| danger | #D93025 | |

### Sidebar Readability Fixes

Replace system `.secondary` with theme colors:
- Section headers: `.foregroundStyle(.secondary)` -> `theme.textSecondary`
- Worktree branch icon: `.foregroundStyle(.secondary)` -> `theme.textMuted`
- Branch text: `.foregroundStyle(.secondary)` -> `theme.textSecondary`

### Migration

Existing `~/.treemux/themes/*.json` files will gain the new `appearance` and
`windowBackground` fields via default values in the Codable decoder. The
`AppSettings.appearance` field can remain in persisted data but will be ignored.
