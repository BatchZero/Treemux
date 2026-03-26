# Settings Save/Cancel Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Change settings from immediate-apply to deferred-apply with Save/Cancel buttons.

**Architecture:** Add `Equatable` to `AppSettings` and nested types for change detection. Replace direct `store.settings` bindings with `@State` draft copy in `SettingsSheet`. Add footer with Save/Cancel. Theme previews live, Cancel reverts.

**Tech Stack:** SwiftUI, macOS

---

### Task 1: Add Equatable conformance to AppSettings and nested types

**Files:**
- Modify: `Treemux/Domain/AppSettings.swift:11-43`

**Step 1: Add Equatable to all types**

Change each struct declaration to include `Equatable`:

```swift
struct AppSettings: Codable, Equatable {
```

```swift
struct TerminalSettings: Codable, Equatable {
```

```swift
struct StartupSettings: Codable, Equatable {
```

```swift
struct SSHSettings: Codable, Equatable {
```

```swift
struct AIToolSettings: Codable, Equatable {
```

No manual `==` needed — all stored properties are already `Equatable` (`Int`, `String`, `Bool`, `[String]`, `[String: ShortcutOverride]`). `ShortcutOverride` and `StoredShortcut` already conform to `Hashable` which implies `Equatable`.

**Step 2: Build to verify**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/Domain/AppSettings.swift
git commit -m "feat: add Equatable conformance to AppSettings types"
```

---

### Task 2: Add updateSettings method to WorkspaceStore

**Files:**
- Modify: `Treemux/App/WorkspaceStore.swift:18-21`

**Step 1: Add the method**

Insert after line 20 (the `didSet` closing brace of `settings`), before line 22 (`private let settingsPersistence`):

```swift
/// Applies a new settings snapshot (used by SettingsSheet Save).
func updateSettings(_ newSettings: AppSettings) {
    settings = newSettings
}
```

This triggers the existing `didSet { try? settingsPersistence.save(settings) }` automatically.

**Step 2: Build to verify**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/App/WorkspaceStore.swift
git commit -m "feat: add updateSettings method to WorkspaceStore"
```

---

### Task 3: Rewrite SettingsSheet with draft/Save/Cancel pattern

**Files:**
- Modify: `Treemux/UI/Settings/SettingsSheet.swift` (full rewrite of the view body and sub-view bindings)

**Step 1: Add state properties**

Add after line 13 (`@Environment(\.dismiss) private var dismiss`):

```swift
@State private var draft = AppSettings()
@State private var originalSettings = AppSettings()
```

**Step 2: Add hasChanges computed property**

Add after the new state properties:

```swift
private var hasChanges: Bool {
    draft != originalSettings
}
```

**Step 3: Rewrite body**

Replace the entire `body` (lines 56-92) with:

```swift
var body: some View {
    HStack(spacing: 0) {
        // Sidebar
        List(SettingsSection.allCases, selection: $selection) { section in
            Label(section.title, systemImage: section.icon)
                .tag(section)
        }
        .listStyle(.sidebar)
        .frame(width: 180)

        Divider()

        // Detail
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text(selection.title)
                    .font(.system(size: 20, weight: .semibold))
                Text(selection.subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)

            Divider()

            // Content
            ScrollView {
                settingsContent(for: selection)
                    .padding(4)
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) {
                    if draft.activeThemeID != originalSettings.activeThemeID {
                        theme.setActiveTheme(originalSettings.activeThemeID)
                    }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "Save")) {
                    store.updateSettings(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
    }
    .frame(width: 640, height: 460)
    .task {
        draft = store.settings
        originalSettings = store.settings
    }
}
```

**Step 4: Change settingsContent bindings from `$store.settings` to `$draft`**

Replace the `settingsContent(for:)` method (lines 96-112) with:

```swift
@ViewBuilder
private func settingsContent(for section: SettingsSection) -> some View {
    switch section {
    case .general:
        GeneralSettingsView(settings: $draft)
    case .terminal:
        TerminalSettingsView(settings: $draft)
    case .theme:
        ThemeSettingsView(settings: $draft, themeManager: theme)
    case .aiTools:
        AIToolsSettingsView(settings: $draft)
    case .ssh:
        SSHSettingsView(settings: $draft)
    case .shortcuts:
        ShortcutsSettingsView(settings: $draft)
    }
}
```

**Step 5: Change ShortcutsSettingsView to accept @Binding**

Replace the current `ShortcutsSettingsView` (lines 232-256) — change from `@EnvironmentObject` to `@Binding`:

```swift
private struct ShortcutsSettingsView: View {
    @Binding var settings: AppSettings

    var body: some View {
        Form {
            ForEach(ShortcutCategory.allCases.filter { cat in
                ShortcutAction.allCases.contains { $0.category == cat }
            }) { category in
                Section(category.title) {
                    let actions = ShortcutAction.allCases.filter { $0.category == category }
                    ForEach(actions) { action in
                        ShortcutRow(action: action, settings: $settings)
                    }
                }
            }

            Section {
                Button(String(localized: "Reset All to Defaults")) {
                    TreemuxKeyboardShortcuts.resetAll(in: &settings)
                }
            }
        }
        .formStyle(.grouped)
    }
}
```

**Step 6: Build to verify**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 7: Commit**

```bash
git add Treemux/UI/Settings/SettingsSheet.swift
git commit -m "feat: implement Save/Cancel deferred-apply pattern in SettingsSheet"
```

---

### Task 4: Manual verification

**Step 1: Launch the app**

```bash
rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-*/Build/Products/Debug/Treemux.app
```

**Step 2: Verify these scenarios**

1. Open Settings → change font size → click Cancel → reopen Settings → font size should be original
2. Open Settings → change font size → click Save → reopen Settings → font size should be new value
3. Open Settings → no changes → Save button should be disabled (grayed out)
4. Open Settings → switch theme → theme previews live → click Cancel → theme reverts to original
5. Open Settings → switch theme → click Save → theme persists
6. Open Settings → go to Shortcuts → Reset All to Defaults → click Cancel → shortcuts unchanged
7. Open Settings → go to Shortcuts → Reset All to Defaults → click Save → shortcuts reset
8. Open Settings → make a change → press Esc → changes discarded (same as Cancel)
