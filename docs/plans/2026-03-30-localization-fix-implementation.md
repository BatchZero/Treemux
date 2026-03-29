# Localization Fix Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix runtime language switching so it takes effect immediately without app restart, and localize all hardcoded English strings.

**Architecture:** Convert `LanguageManager` from a stateless `enum` to an `ObservableObject` that publishes a `Locale`. Inject it via `.environment(\.locale)` at the root view so all `String(localized:)` calls re-render instantly. Fix ~28 hardcoded English strings across 5 files and add their Chinese translations to `Localizable.xcstrings`.

**Tech Stack:** SwiftUI, `Locale`, `ObservableObject`, `.xcstrings`

---

### Task 1: Refactor LanguageManager to ObservableObject

**Files:**
- Modify: `Treemux/Support/LanguageManager.swift` (full rewrite)

**Step 1: Rewrite LanguageManager**

Replace the entire file contents with:

```swift
//
//  LanguageManager.swift
//  Treemux
//

import Foundation
import SwiftUI

/// Manages application language override and publishes a Locale
/// for SwiftUI environment injection.
@MainActor
final class LanguageManager: ObservableObject {

    /// The active locale derived from the language setting.
    /// Bind this to `.environment(\.locale)` on the root view.
    @Published private(set) var locale: Locale

    init(languageCode: String) {
        self.locale = Self.resolveLocale(languageCode)
        Self.persistOverride(languageCode)
    }

    /// Apply a new language setting at runtime.
    /// Updates the published locale (immediate SwiftUI effect)
    /// and persists the override for next launch.
    func apply(languageCode: String) {
        locale = Self.resolveLocale(languageCode)
        Self.persistOverride(languageCode)
    }

    // MARK: - Private

    private static func resolveLocale(_ code: String) -> Locale {
        guard code != "system" else {
            return Locale.autoupdatingCurrent
        }
        return Locale(identifier: code)
    }

    private static func persistOverride(_ code: String) {
        guard code != "system" else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            return
        }
        UserDefaults.standard.set([code], forKey: "AppleLanguages")
    }
}
```

**Step 2: Build to verify compilation**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: Build will fail because `TreemuxApp.swift` and `WindowContext.swift` still reference the old API. That's expected — we fix them in Tasks 2-3.

**Step 3: Commit**

```bash
git add Treemux/Support/LanguageManager.swift
git commit -m "refactor: convert LanguageManager to ObservableObject with published Locale"
```

---

### Task 2: Integrate LanguageManager into WindowContext and TreemuxApp

**Files:**
- Modify: `Treemux/App/WindowContext.swift`
- Modify: `Treemux/App/TreemuxApp.swift`

**Step 1: Update WindowContext**

In `Treemux/App/WindowContext.swift`, add `languageManager` property and inject it into the root view.

Change the `WindowContext` class to:

```swift
@MainActor
final class WindowContext {
    let store: WorkspaceStore
    let themeManager: ThemeManager
    let languageManager: LanguageManager
    private var window: NSWindow?
    private var themeCancellable: AnyCancellable?
    private var localeCancellable: AnyCancellable?

    init(store: WorkspaceStore) {
        self.store = store
        self.themeManager = ThemeManager(activeThemeID: store.settings.activeThemeID)
        self.languageManager = LanguageManager(languageCode: store.settings.language)
        themeManager.ensureBuiltInThemesExist()
    }
```

In the `show()` method, update the root view injection — replace:

```swift
        let host = NSHostingController(
            rootView: MainWindowView()
                .environmentObject(store)
                .environmentObject(themeManager)
        )
```

with:

```swift
        let host = NSHostingController(
            rootView: MainWindowView()
                .environmentObject(store)
                .environmentObject(themeManager)
                .environmentObject(languageManager)
                .environment(\.locale, languageManager.locale)
        )
```

Still in `show()`, after the existing `themeCancellable` block, add a locale observer so that `.environment(\.locale)` stays in sync when `languageManager.locale` changes:

```swift
        // Observe language changes to update the root view's locale environment.
        localeCancellable = languageManager.$locale
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak host, weak self] newLocale in
                guard let self, let host else { return }
                host.rootView = MainWindowView()
                    .environmentObject(self.store)
                    .environmentObject(self.themeManager)
                    .environmentObject(self.languageManager)
                    .environment(\.locale, newLocale)
            }
```

**Step 2: Update TreemuxApp**

In `Treemux/App/TreemuxApp.swift`, remove the old `LanguageManager.apply()` call. Replace:

```swift
    func launch() {
        let store = WorkspaceStore()
        LanguageManager.apply(languageCode: store.settings.language)
        let window = WindowContext(store: store)
```

with:

```swift
    func launch() {
        let store = WorkspaceStore()
        let window = WindowContext(store: store)
```

The `LanguageManager` is now created inside `WindowContext.init()` and handles both the initial locale setup and `AppleLanguages` persistence.

**Step 3: Build to verify compilation**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Treemux/App/WindowContext.swift Treemux/App/TreemuxApp.swift
git commit -m "feat: inject LanguageManager locale into SwiftUI environment for runtime switching"
```

---

### Task 3: Wire SettingsSheet Save to LanguageManager

**Files:**
- Modify: `Treemux/UI/Settings/SettingsSheet.swift`

**Step 1: Add LanguageManager environment object**

In `SettingsSheet`, add this property alongside the existing `@EnvironmentObject` declarations (after line 13):

```swift
    @EnvironmentObject private var languageManager: LanguageManager
```

**Step 2: Update the Save button action**

Replace the Save button block (lines 110-113):

```swift
                    Button(String(localized: "Save")) {
                        store.updateSettings(draft)
                        dismiss()
                    }
```

with:

```swift
                    Button(String(localized: "Save")) {
                        store.updateSettings(draft)
                        languageManager.apply(languageCode: draft.language)
                        dismiss()
                    }
```

**Step 3: Build to verify compilation**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Treemux/UI/Settings/SettingsSheet.swift
git commit -m "feat: apply language change immediately on settings save"
```

---

### Task 4: Localize hardcoded strings in MainWindowView

**Files:**
- Modify: `Treemux/UI/MainWindowView.swift`

**Step 1: Replace hardcoded strings**

Line 43 — change:
```swift
                .accessibilityLabel("Toggle Sidebar")
```
to:
```swift
                .accessibilityLabel(String(localized: "Toggle Sidebar"))
```

Line 44 — change:
```swift
                .help("Toggle Sidebar")
```
to:
```swift
                .help(String(localized: "Toggle Sidebar"))
```

Line 56 — change:
```swift
                .help("Split Down (⌘D)")
```
to:
```swift
                .help(String(localized: "Split Down (⌘D)"))
```

Line 66 — change:
```swift
                .help("Split Right (⌘⇧D)")
```
to:
```swift
                .help(String(localized: "Split Right (⌘⇧D)"))
```

Line 73 — change:
```swift
                .help("New Terminal (⌘T)")
```
to:
```swift
                .help(String(localized: "New Terminal (⌘T)"))
```

Line 80 — change:
```swift
                .help("Settings (⌘,)")
```
to:
```swift
                .help(String(localized: "Settings (⌘,)"))
```

**Step 2: Build to verify**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/UI/MainWindowView.swift
git commit -m "fix(i18n): localize toolbar tooltips in MainWindowView"
```

---

### Task 5: Localize hardcoded strings in SidebarNodeRow

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarNodeRow.swift`

**Step 1: Replace hardcoded strings**

Line 80 — change:
```swift
                SidebarInfoBadge(text: "current", tone: .subtleSuccess)
```
to:
```swift
                SidebarInfoBadge(text: String(localized: "current"), tone: .subtleSuccess)
```

Line 134 — change:
```swift
                SidebarInfoBadge(text: "current", tone: .subtleSuccess)
```
to:
```swift
                SidebarInfoBadge(text: String(localized: "current"), tone: .subtleSuccess)
```

**Step 2: Build to verify**

**Step 3: Commit**

```bash
git add Treemux/UI/Sidebar/SidebarNodeRow.swift
git commit -m "fix(i18n): localize 'current' badge in sidebar rows"
```

---

### Task 6: Localize hardcoded strings in SidebarIconCustomizationSheet

**Files:**
- Modify: `Treemux/UI/Sheets/SidebarIconCustomizationSheet.swift`

**Step 1: Replace hardcoded strings in SidebarIconEditorCard**

Line 32 — change:
```swift
                Button("Random") { icon = randomizer() }
```
to:
```swift
                Button(String(localized: "Random")) { icon = randomizer() }
```

Line 36 — change:
```swift
            Picker("Symbol", selection: $icon.symbolName) {
```
to:
```swift
            Picker(String(localized: "Symbol"), selection: $icon.symbolName) {
```

Line 43 — change:
```swift
            Picker("Style", selection: $icon.fillStyle) {
```
to:
```swift
            Picker(String(localized: "Style"), selection: $icon.fillStyle) {
```

Line 52 — change:
```swift
                Text("Palette")
```
to:
```swift
                Text(String(localized: "Palette"))
```

**Step 2: Replace hardcoded strings in SidebarIconCustomizationSheet**

Line 102 — change:
```swift
            Text("Customize Sidebar Icon")
```
to:
```swift
            Text(String(localized: "Customize Sidebar Icon"))
```

Lines 110-111 — change:
```swift
            SidebarIconEditorCard(
                title: "Icon",
                subtitle: "Choose a symbol, palette, and fill treatment",
```
to:
```swift
            SidebarIconEditorCard(
                title: String(localized: "Icon"),
                subtitle: String(localized: "Choose a symbol, palette, and fill treatment"),
```

Line 118 — change:
```swift
                Button("Reset") {
```
to:
```swift
                Button(String(localized: "Reset")) {
```

Line 122 — change:
```swift
                Button("Cancel") {
```
to:
```swift
                Button(String(localized: "Cancel")) {
```

Line 125 — change:
```swift
                Button("Save") {
```
to:
```swift
                Button(String(localized: "Save")) {
```

**Step 3: Build to verify**

**Step 4: Commit**

```bash
git add Treemux/UI/Sheets/SidebarIconCustomizationSheet.swift
git commit -m "fix(i18n): localize all strings in SidebarIconCustomizationSheet"
```

---

### Task 7: Localize hardcoded strings in EmptyTabStateView

**Files:**
- Modify: `Treemux/UI/Workspace/EmptyTabStateView.swift`

**Step 1: Replace hardcoded strings**

Line 18 — change:
```swift
            Text("No open terminals")
```
to:
```swift
            Text(String(localized: "No open terminals"))
```

Line 23 — change:
```swift
                Label("New Terminal", systemImage: "plus")
```
to:
```swift
                Label(String(localized: "New Terminal"), systemImage: "plus")
```

Line 28 — change:
```swift
            Text("⌘T to create a new tab")
```
to:
```swift
            Text(String(localized: "⌘T to create a new tab"))
```

**Step 2: Build to verify**

**Step 3: Commit**

```bash
git add Treemux/UI/Workspace/EmptyTabStateView.swift
git commit -m "fix(i18n): localize strings in EmptyTabStateView"
```

---

### Task 8: Localize hardcoded strings in WorkspaceTabBarView

**Files:**
- Modify: `Treemux/UI/Workspace/WorkspaceTabBarView.swift`

**Step 1: Replace hardcoded strings**

Line 75 — change:
```swift
            .help("New Tab (⌘T)")
```
to:
```swift
            .help(String(localized: "New Tab (⌘T)"))
```

Line 156 — change:
```swift
            Button("Rename…") { onRename() }
```
to:
```swift
            Button(String(localized: "Rename…")) { onRename() }
```

Line 158 — change:
```swift
            Button("Close Tab") { onClose() }
```
to:
```swift
            Button(String(localized: "Close Tab")) { onClose() }
```

Line 172 — change:
```swift
        TextField("Tab name", text: $text)
```
to:
```swift
        TextField(String(localized: "Tab name"), text: $text)
```

**Step 2: Build to verify**

**Step 3: Commit**

```bash
git add Treemux/UI/Workspace/WorkspaceTabBarView.swift
git commit -m "fix(i18n): localize strings in WorkspaceTabBarView"
```

---

### Task 9: Localize "Path" placeholder in SettingsSheet

**Files:**
- Modify: `Treemux/UI/Settings/SettingsSheet.swift`

**Step 1: Replace hardcoded string**

Line 237 — change:
```swift
                    TextField("Path", text: $settings.ssh.configPaths[index])
```
to:
```swift
                    TextField(String(localized: "Path"), text: $settings.ssh.configPaths[index])
```

**Step 2: Build to verify**

**Step 3: Commit**

```bash
git add Treemux/UI/Settings/SettingsSheet.swift
git commit -m "fix(i18n): localize Path placeholder in SSH settings"
```

---

### Task 10: Add Chinese translations to Localizable.xcstrings

**Files:**
- Modify: `Treemux/Localizable.xcstrings`

**Step 1: Add all missing Chinese translations**

Add the following entries to the `"strings"` object in `Localizable.xcstrings`. Note: "Cancel", "current", "Rename…", and "Toggle Sidebar" already exist — only add the ones that are missing.

New entries to add:

| Key | zh-Hans |
|-----|---------|
| `"Random"` | `"随机"` |
| `"Symbol"` | `"符号"` |
| `"Style"` | `"样式"` |
| `"Palette"` | `"调色板"` |
| `"Customize Sidebar Icon"` | `"自定义侧边栏图标"` |
| `"Icon"` | `"图标"` |
| `"Choose a symbol, palette, and fill treatment"` | `"选择符号、调色板和填充样式"` |
| `"Reset"` | `"重置"` |
| `"Save"` | `"保存"` |
| `"No open terminals"` | `"没有打开的终端"` |
| `"New Terminal"` | `"新建终端"` |
| `"⌘T to create a new tab"` | `"按 ⌘T 创建新标签页"` |
| `"New Tab (⌘T)"` | `"新标签页 (⌘T)"` |
| `"Close Tab"` | `"关闭标签页"` |
| `"Tab name"` | `"标签名称"` |
| `"Split Down (⌘D)"` | `"向下分屏 (⌘D)"` |
| `"Split Right (⌘⇧D)"` | `"向右分屏 (⌘⇧D)"` |
| `"New Terminal (⌘T)"` | `"新建终端 (⌘T)"` |
| `"Settings (⌘,)"` | `"设置 (⌘,)"` |
| `"Path"` | `"路径"` |
| `"Sidebar Icons"` | `"侧边栏图标"` |
| `"Customize icons for workspaces and worktrees"` | `"自定义工作区和工作树的图标"` |
| `"Default"` | `"默认"` |
| `"Default icon for local terminals"` | `"本地终端的默认图标"` |
| `"Default Terminal Icon"` | `"默认终端图标"` |
| `"Language and startup behavior"` | `"语言和启动行为"` |
| `"Shell, font, and cursor settings"` | `"Shell、字体和光标设置"` |
| `"Color themes and appearance"` | `"颜色主题和外观"` |
| `"SSH config file paths"` | `"SSH 配置文件路径"` |
| `"Customize keyboard shortcuts"` | `"自定义键盘快捷键"` |
| `"Not Set"` | `"未设置"` |
| `"Reset All to Defaults"` | `"全部重置为默认值"` |
| `"Disable"` | `"禁用"` |

Each entry follows this JSON pattern:
```json
    "Key" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "翻译值"
          }
        }
      }
    },
```

**Step 2: Validate JSON syntax**

Run: `python3 -c "import json; json.load(open('Treemux/Localizable.xcstrings')); print('Valid JSON')"`
Expected: `Valid JSON`

**Step 3: Build to verify**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Treemux/Localizable.xcstrings
git commit -m "fix(i18n): add Chinese translations for all newly localized strings"
```

---

### Task 11: Final build and manual test

**Step 1: Clean build**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug clean build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 2: Run tests**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug test 2>&1 | tail -10`
Expected: All tests pass

**Step 3: Inform user to test manually**

Tell user to run the app and verify:
1. Open Settings → General → switch Language to English → Save → UI immediately switches to English
2. Switch Language to 中文 → Save → UI immediately switches to Chinese
3. In Chinese mode, verify no English strings remain in: toolbar tooltips, sidebar "current" badge, tab bar context menu, empty state view, icon customization sheet
4. Switch to "Follow System" → Save → uses OS language
