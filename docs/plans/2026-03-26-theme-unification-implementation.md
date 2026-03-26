# Theme Unification Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix the toolbar/titlebar showing white in dark mode by making each theme drive the window appearance automatically.

**Architecture:** Each `ThemeDefinition` gains an `appearance` field ("dark"/"light") and a `windowBackground` UI color. `WindowContext` reads appearance from the theme instead of a standalone setting. The separate `AppSettings.appearance` property is removed from the UI (kept in Codable for backward compat).

**Tech Stack:** Swift, SwiftUI, AppKit (NSWindow, NSAppearance, NSColor)

---

### Task 1: Add `appearance` and `windowBackground` to ThemeDefinition

**Files:**
- Modify: `Treemux/Domain/ThemeDefinition.swift:11-18` (ThemeDefinition struct)
- Modify: `Treemux/Domain/ThemeDefinition.swift:30-46` (UIColors struct)
- Modify: `Treemux/Domain/ThemeDefinition.swift:59-93` (treemuxDark static)
- Modify: `Treemux/Domain/ThemeDefinition.swift:96-130` (treemuxLight static)

**Step 1: Add `appearance` field to `ThemeDefinition`**

In `ThemeDefinition.swift`, add `appearance` with a default for backward compat:

```swift
struct ThemeDefinition: Codable, Identifiable {
    let id: String
    let name: String
    let author: String?
    /// "dark" or "light" — determines NSAppearance for the window.
    let appearance: String
    let terminal: TerminalColors
    let ui: UIColors
    let font: FontConfig?

    // Backward-compatible decoding: default to "dark" if missing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        appearance = try container.decodeIfPresent(String.self, forKey: .appearance) ?? "dark"
        terminal = try container.decode(TerminalColors.self, forKey: .terminal)
        ui = try container.decode(UIColors.self, forKey: .ui)
        font = try container.decodeIfPresent(FontConfig.self, forKey: .font)
    }

    // Keep memberwise init for built-in themes.
    init(id: String, name: String, author: String?, appearance: String,
         terminal: TerminalColors, ui: UIColors, font: FontConfig?) {
        self.id = id
        self.name = name
        self.author = author
        self.appearance = appearance
        self.terminal = terminal
        self.ui = ui
        self.font = font
    }
}
```

**Step 2: Add `windowBackground` to `UIColors`**

```swift
struct UIColors: Codable {
    let sidebarBackground: String
    let sidebarForeground: String
    let sidebarSelection: String
    let tabBarBackground: String
    let paneBackground: String
    let paneHeaderBackground: String
    let dividerColor: String
    let accentColor: String
    let statusBarBackground: String
    let textPrimary: String
    let textSecondary: String
    let textMuted: String
    let success: String
    let warning: String
    let danger: String
    /// Window background color (NSWindow.backgroundColor).
    let windowBackground: String

    // Backward-compatible decoding: default to paneBackground if missing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sidebarBackground = try container.decode(String.self, forKey: .sidebarBackground)
        sidebarForeground = try container.decode(String.self, forKey: .sidebarForeground)
        sidebarSelection = try container.decode(String.self, forKey: .sidebarSelection)
        tabBarBackground = try container.decode(String.self, forKey: .tabBarBackground)
        paneBackground = try container.decode(String.self, forKey: .paneBackground)
        paneHeaderBackground = try container.decode(String.self, forKey: .paneHeaderBackground)
        dividerColor = try container.decode(String.self, forKey: .dividerColor)
        accentColor = try container.decode(String.self, forKey: .accentColor)
        statusBarBackground = try container.decode(String.self, forKey: .statusBarBackground)
        textPrimary = try container.decode(String.self, forKey: .textPrimary)
        textSecondary = try container.decode(String.self, forKey: .textSecondary)
        textMuted = try container.decode(String.self, forKey: .textMuted)
        success = try container.decode(String.self, forKey: .success)
        warning = try container.decode(String.self, forKey: .warning)
        danger = try container.decode(String.self, forKey: .danger)
        windowBackground = try container.decodeIfPresent(String.self, forKey: .windowBackground) ?? (try container.decode(String.self, forKey: .paneBackground))
    }
}
```

**Step 3: Update built-in dark theme with new fields and optimized colors**

```swift
static let treemuxDark = ThemeDefinition(
    id: "treemux-dark",
    name: "Treemux Dark",
    author: "BatchZero",
    appearance: "dark",                          // NEW
    terminal: TerminalColors(
        foreground: "#C5C8C6",
        background: "#111317",
        cursor: "#C5C8C6",
        selection: "#373B41",
        ansi: [
            "#1D1F21", "#CC6666", "#B5BD68", "#F0C674",
            "#81A2BE", "#B294BB", "#8ABEB7", "#C5C8C6",
            "#969896", "#CC6666", "#B5BD68", "#F0C674",
            "#81A2BE", "#B294BB", "#8ABEB7", "#FFFFFF"
        ]
    ),
    ui: UIColors(
        sidebarBackground: "#0F1114",
        sidebarForeground: "#E5E5E7",
        sidebarSelection: "#1A2A42",
        tabBarBackground: "#0F1114",
        paneBackground: "#111317",
        paneHeaderBackground: "#151820",
        dividerColor: "#FFFFFF1A",
        accentColor: "#418ADE",
        statusBarBackground: "#0F1114",
        textPrimary: "#F0F0F2",
        textSecondary: "#A0A8B8",
        textMuted: "#6B7280",
        success: "#4FD67B",
        warning: "#F0A830",
        danger: "#EB6B57",
        windowBackground: "#111317"              // NEW
    ),
    font: nil
)
```

**Step 4: Update built-in light theme with new fields and optimized colors**

```swift
static let treemuxLight = ThemeDefinition(
    id: "treemux-light",
    name: "Treemux Light",
    author: "BatchZero",
    appearance: "light",                         // NEW
    terminal: TerminalColors(
        foreground: "#1D1F21",
        background: "#FFFFFF",
        cursor: "#1D1F21",
        selection: "#D6D6D6",
        ansi: [
            "#1D1F21", "#CC6666", "#718C00", "#EAB700",
            "#4271AE", "#8959A8", "#3E999F", "#FFFFFF",
            "#969896", "#CC6666", "#718C00", "#EAB700",
            "#4271AE", "#8959A8", "#3E999F", "#FFFFFF"
        ]
    ),
    ui: UIColors(
        sidebarBackground: "#F5F5F7",
        sidebarForeground: "#1D1F21",
        sidebarSelection: "#D0E0F0",
        tabBarBackground: "#EDEDEF",
        paneBackground: "#FFFFFF",
        paneHeaderBackground: "#F5F5F7",
        dividerColor: "#00000014",
        accentColor: "#2F7DE1",
        statusBarBackground: "#EDEDEF",
        textPrimary: "#1D1F21",
        textSecondary: "#6B7280",
        textMuted: "#9CA3AF",
        success: "#34A853",
        warning: "#D99116",
        danger: "#D93025",
        windowBackground: "#FFFFFF"              // NEW
    ),
    font: nil
)
```

**Step 5: Build to verify compilation**

Run: `xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (or errors from downstream files not yet updated — that's OK)

**Step 6: Commit**

```bash
git add Treemux/Domain/ThemeDefinition.swift
git commit -m "feat: add appearance and windowBackground to ThemeDefinition

Each theme now declares whether it is dark or light and provides a window
background color. Includes backward-compatible Codable decoding for
existing user theme JSON files."
```

---

### Task 2: Add window appearance helpers to ThemeManager

**Files:**
- Modify: `Treemux/UI/Theme/ThemeManager.swift:53-69` (computed properties section)

**Step 1: Add NSAppearance and NSColor properties**

Add these computed properties after the existing color properties (after line 69):

```swift
// MARK: - Window Appearance

/// The NSAppearance corresponding to the active theme.
var windowAppearance: NSAppearance? {
    switch activeTheme.appearance {
    case "dark":
        return NSAppearance(named: .darkAqua)
    case "light":
        return NSAppearance(named: .aqua)
    default:
        return NSAppearance(named: .darkAqua)
    }
}

/// The NSColor for NSWindow.backgroundColor derived from the active theme.
var nsWindowBackgroundColor: NSColor {
    let hex = activeTheme.ui.windowBackground
    let color = Color(hex: hex)
    return NSColor(color)
}
```

Also add `import AppKit` at the top of the file (currently only imports Foundation and SwiftUI).

**Step 2: Build to verify**

Run: `xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/UI/Theme/ThemeManager.swift
git commit -m "feat: add windowAppearance and nsWindowBackgroundColor to ThemeManager"
```

---

### Task 3: Update WindowContext to use theme-driven appearance

**Files:**
- Modify: `Treemux/App/WindowContext.swift` (entire file)

**Step 1: Rewrite `applyAppearance` and `show` to use theme**

Replace the entire `WindowContext.swift` content:

```swift
//
//  WindowContext.swift
//  Treemux

import AppKit
import Combine
import SwiftUI

/// Manages the main NSWindow and hosts the SwiftUI content view.
@MainActor
final class WindowContext {
    let store: WorkspaceStore
    let themeManager: ThemeManager
    private var window: NSWindow?
    private var themeCancellable: AnyCancellable?

    init(store: WorkspaceStore) {
        self.store = store
        self.themeManager = ThemeManager(activeThemeID: store.settings.activeThemeID)
        themeManager.ensureBuiltInThemesExist()
    }

    /// Creates and shows the main application window.
    func show() {
        let host = NSHostingController(
            rootView: MainWindowView()
                .environmentObject(store)
                .environmentObject(themeManager)
        )

        let window = NSWindow(contentViewController: host)
        window.title = "Treemux"
        window.setContentSize(NSSize(width: 1200, height: 800))

        // Disable macOS window tabbing so the title bar stays focused on the
        // workspace controls we actually use.
        window.tabbingMode = .disallowed

        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unifiedCompact
        window.center()
        applyThemeAppearance(to: window)
        window.makeKeyAndOrderFront(nil)

        self.window = window

        // Observe theme changes to keep the window appearance in sync.
        themeCancellable = themeManager.$activeTheme
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateAppearance()
            }
    }

    /// Applies the active theme's appearance to the given window.
    private func applyThemeAppearance(to window: NSWindow) {
        window.appearance = themeManager.windowAppearance
        window.backgroundColor = themeManager.nsWindowBackgroundColor
    }

    /// Re-applies appearance to the current window (call when theme changes).
    func updateAppearance() {
        guard let window else { return }
        applyThemeAppearance(to: window)
    }
}
```

**Step 2: Build to verify**

Run: `xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/App/WindowContext.swift
git commit -m "fix: sync toolbar appearance with active theme

WindowContext now reads NSAppearance and backgroundColor from the theme
instead of the standalone appearance setting, fixing the white toolbar
in dark mode bug."
```

---

### Task 4: Remove Appearance picker from Settings UI

**Files:**
- Modify: `Treemux/UI/Settings/SettingsSheet.swift:89-102` (GeneralSettingsView)

**Step 1: Remove the Appearance picker and its onChange handler**

In `GeneralSettingsView`, delete lines 90-102 (the Appearance Picker block and its `.onChange`):

```swift
// DELETE THIS BLOCK:
Picker(String(localized: "Appearance"), selection: $settings.appearance) {
    Text(String(localized: "Follow System")).tag("system")
    Text(String(localized: "Dark")).tag("dark")
    Text(String(localized: "Light")).tag("light")
}
.onChange(of: settings.appearance) { _, newValue in
    let appearance: NSAppearance? = switch newValue {
    case "dark": NSAppearance(named: .darkAqua)
    case "light": NSAppearance(named: .aqua)
    default: nil
    }
    NSApp.keyWindow?.appearance = appearance
}
```

The `GeneralSettingsView` body should now just contain:

```swift
var body: some View {
    Form {
        Picker(String(localized: "Language"), selection: $settings.language) {
            Text(String(localized: "Follow System")).tag("system")
            Text("English").tag("en")
            Text("中文").tag("zh-Hans")
        }

        Picker(String(localized: "On Startup"), selection: $settings.startup.restoreLastSession) {
            Text(String(localized: "Restore Last Session")).tag(true)
            Text(String(localized: "Blank Window")).tag(false)
        }
    }
    .formStyle(.grouped)
}
```

**Step 2: Build to verify**

Run: `xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/UI/Settings/SettingsSheet.swift
git commit -m "refactor: remove standalone Appearance picker from settings

Appearance is now driven by the active theme, so the separate picker is
no longer needed."
```

---

### Task 5: Fix sidebar readability — replace .secondary with theme colors

**Files:**
- Modify: `Treemux/UI/Sidebar/WorkspaceSidebarView.swift:61,92,278,363`

**Step 1: Replace `.foregroundStyle(.secondary)` with theme colors in sidebar**

There are 4 instances in `WorkspaceSidebarView.swift`:

1. **Line 61** — Section header "Local Projects":
   ```swift
   // Before:
   .foregroundStyle(.secondary)
   // After:
   .foregroundStyle(theme.textSecondary)
   ```

2. **Line 92** — Remote section header:
   ```swift
   // Before:
   .foregroundStyle(.secondary)
   // After:
   .foregroundStyle(theme.textSecondary)
   ```

3. **Line 278** — Branch text in single-worktree row:
   ```swift
   // Before:
   .foregroundStyle(.secondary)
   // After:
   .foregroundStyle(theme.textSecondary)
   ```

4. **Line 363** — Worktree branch icon:
   ```swift
   // Before:
   .foregroundStyle(.secondary)
   // After:
   .foregroundStyle(theme.textMuted)
   ```

**Step 2: Build to verify**

Run: `xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/UI/Sidebar/WorkspaceSidebarView.swift
git commit -m "fix: use theme colors instead of .secondary in sidebar

Improves readability of section headers, branch names, and worktree
icons in dark mode by using explicit theme tokens."
```

---

### Task 6: Delete stale built-in theme JSON files and rebuild

**Files:**
- None (file system operation)

**Step 1: Delete existing built-in theme JSONs so they get regenerated with new fields**

```bash
rm -f ~/.treemux/themes/treemux-dark.json ~/.treemux/themes/treemux-light.json
```

The app calls `ensureBuiltInThemesExist()` on launch, which will write fresh JSON files
containing the new `appearance` and `windowBackground` fields.

**Step 2: Full build and manual test**

Run: `xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Manual verification checklist**

1. Launch Treemux with dark theme — toolbar should be dark, content should be dark
2. Switch to light theme in Settings > Theme — toolbar should turn light, content light
3. Switch back to dark — everything dark again
4. Sidebar text (section headers, branch names) should be clearly readable in both themes
5. Check `~/.treemux/themes/treemux-dark.json` contains `"appearance": "dark"` and `"windowBackground": "#111317"`

**Step 4: Commit (if any file changes needed)**

No code commit needed for this task — it's a verification step.

---

### Task 7: Final commit — update design doc status

**Files:**
- Modify: `docs/plans/2026-03-26-theme-unification-design.md:4`

**Step 1: Update status**

```markdown
**Status:** Implemented
```

**Step 2: Commit**

```bash
git add docs/plans/2026-03-26-theme-unification-design.md
git commit -m "docs: mark theme unification design as implemented"
```
