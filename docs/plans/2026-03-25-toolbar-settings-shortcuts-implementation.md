# Toolbar, Settings, Command Palette & Shortcuts Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Wire up existing but disconnected SettingsSheet and CommandPaletteView, add toolbar buttons, implement dark/light appearance switching, and build a full keyboard shortcut customization system.

**Architecture:** Centralized state in `WorkspaceStore` drives UI visibility (settings/command palette). A new `StoredShortcut` model + `ShortcutAction` enum powers customizable keyboard shortcuts with recorder UI, conflict detection, and menu bar sync. Appearance control uses `NSAppearance` on the window.

**Tech Stack:** Swift, SwiftUI, AppKit (NSEvent, NSButton, NSMenu, NSAppearance), Codable JSON persistence.

---

### Task 1: Add UI State Properties to WorkspaceStore

**Files:**
- Modify: `Treemux/App/WorkspaceStore.swift:12-13` (after existing `@Published` properties)

**Step 1: Add showSettings and showCommandPalette properties**

Add two new `@Published` properties to `WorkspaceStore`, right after line 13 (`@Published var selectedWorkspaceID: UUID?`):

```swift
@Published var showSettings = false
@Published var showCommandPalette = false
```

These are transient UI state — they are NOT persisted (no `didSet` save needed).

**Step 2: Build to verify**

Run: `xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add Treemux/App/WorkspaceStore.swift
git commit -m "feat: add showSettings and showCommandPalette state to WorkspaceStore"
```

---

### Task 2: Wire AppDelegate Menu Actions to Store State

**Files:**
- Modify: `Treemux/AppDelegate.swift:135-157` (openSettings and toggleCommandPalette methods)

**Step 1: Implement openSettings()**

Replace the empty `openSettings()` at line 135-137 with:

```swift
@objc private func openSettings() {
    store?.showSettings = true
}
```

**Step 2: Implement toggleCommandPalette()**

Replace the empty `toggleCommandPalette()` at line 155-157 with:

```swift
@objc private func toggleCommandPalette() {
    store?.showCommandPalette.toggle()
}
```

**Step 3: Build to verify**

Run: `xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 4: Commit**

```bash
git add Treemux/AppDelegate.swift
git commit -m "feat: wire AppDelegate menu actions to WorkspaceStore state"
```

---

### Task 3: Add Toolbar Buttons and Sheet/Overlay Mounts to MainWindowView

**Files:**
- Modify: `Treemux/UI/MainWindowView.swift` (entire toolbar section + add .sheet and .overlay)

**Step 1: Add toolbar buttons in .primaryAction placement**

Inside the existing `.toolbar { ... }` block (after the sidebar toggle ToolbarItem), add a new `ToolbarItemGroup`:

```swift
ToolbarItemGroup(placement: .primaryAction) {
    Button {
        if let sc = store.selectedWorkspace?.sessionController,
           let focused = sc.focusedPaneID {
            sc.splitPane(focused, axis: .horizontal)
        }
    } label: {
        Image(systemName: "rectangle.split.1x2")
    }
    .help("Split Down (⌘D)")

    Button {
        if let sc = store.selectedWorkspace?.sessionController,
           let focused = sc.focusedPaneID {
            sc.splitPane(focused, axis: .vertical)
        }
    } label: {
        Image(systemName: "rectangle.split.2x1")
    }
    .help("Split Right (⌘⇧D)")

    Button {
        if let sc = store.selectedWorkspace?.sessionController,
           let focused = sc.focusedPaneID {
            sc.splitPane(focused, axis: .horizontal)
        }
    } label: {
        Image(systemName: "plus.rectangle")
    }
    .help("New Terminal")

    Button {
        store.showSettings = true
    } label: {
        Image(systemName: "gearshape")
    }
    .help("Settings (⌘,)")
}
```

Note: The "New Terminal" button initially reuses `splitPane` with `.horizontal` axis. This gives users a quick way to add a terminal pane. The exact behavior may be refined later.

**Step 2: Add .sheet for SettingsSheet**

After `.toolbar { ... }`, add:

```swift
.sheet(isPresented: $store.showSettings) {
    SettingsSheet()
}
```

**Step 3: Add .overlay for CommandPaletteView**

After the `.sheet(...)`, add:

```swift
.overlay {
    if store.showCommandPalette {
        CommandPaletteView(isPresented: $store.showCommandPalette)
    }
}
```

**Step 4: Build to verify**

Run: `xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 5: Commit**

```bash
git add Treemux/UI/MainWindowView.swift
git commit -m "feat: add toolbar buttons and wire SettingsSheet/CommandPaletteView"
```

---

### Task 4: Add Appearance Setting to AppSettings

**Files:**
- Modify: `Treemux/Domain/AppSettings.swift:11-18` (add appearance field)

**Step 1: Add appearance property**

Add to `AppSettings` struct, after `var activeThemeID`:

```swift
var appearance: String = "system"  // "system", "dark", "light"
```

**Step 2: Build to verify**

Run: `xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add Treemux/Domain/AppSettings.swift
git commit -m "feat: add appearance setting to AppSettings"
```

---

### Task 5: Apply Appearance in WindowContext

**Files:**
- Modify: `Treemux/App/WindowContext.swift:22-46` (show() method)

**Step 1: Replace hardcoded .darkAqua with appearance-based logic**

Replace the hardcoded line `window.appearance = NSAppearance(named: .darkAqua)` (line 40) with:

```swift
applyAppearance(to: window)
```

**Step 2: Add applyAppearance method and observation**

Add after `show()`:

```swift
/// Applies the appearance setting to the window.
private func applyAppearance(to window: NSWindow) {
    switch store.settings.appearance {
    case "dark":
        window.appearance = NSAppearance(named: .darkAqua)
    case "light":
        window.appearance = NSAppearance(named: .aqua)
    default:
        window.appearance = nil  // Follow system
    }
}
```

**Step 3: Make window accessible for live updates**

The `window` property is already stored as `private var window: NSWindow?`. Add a public method so settings changes can trigger updates:

```swift
/// Re-applies appearance to the current window (call when settings change).
func updateAppearance() {
    guard let window else { return }
    applyAppearance(to: window)
}
```

**Step 4: Build to verify**

Run: `xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 5: Commit**

```bash
git add Treemux/App/WindowContext.swift
git commit -m "feat: apply appearance setting to window instead of hardcoded darkAqua"
```

---

### Task 6: Add Appearance Picker to SettingsSheet General Tab

**Files:**
- Modify: `Treemux/UI/Settings/SettingsSheet.swift:78-96` (GeneralSettingsView)

**Step 1: Add appearance picker**

In `GeneralSettingsView`, add a new Picker inside the Form, after the Language picker:

```swift
Picker(String(localized: "Appearance"), selection: $settings.appearance) {
    Text(String(localized: "Follow System")).tag("system")
    Text(String(localized: "Dark")).tag("dark")
    Text(String(localized: "Light")).tag("light")
}
```

**Step 2: Add live appearance update on change**

Add `.onChange` to the Form (or to the Picker) to apply the appearance change immediately. Since `GeneralSettingsView` doesn't have access to `WindowContext`, the simplest approach is to apply via `NSApp.keyWindow`:

```swift
.onChange(of: settings.appearance) { _, newValue in
    let appearance: NSAppearance? = switch newValue {
    case "dark": NSAppearance(named: .darkAqua)
    case "light": NSAppearance(named: .aqua)
    default: nil
    }
    NSApp.keyWindow?.appearance = appearance
}
```

**Step 3: Build to verify**

Run: `xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 4: Commit**

```bash
git add Treemux/UI/Settings/SettingsSheet.swift
git commit -m "feat: add appearance picker to General settings with live preview"
```

---

### Task 7: Create StoredShortcut Data Model

**Files:**
- Create: `Treemux/Domain/StoredShortcut.swift`

**Step 1: Create the StoredShortcut struct**

Reference: Liney's `StoredShortcut` at `/Users/yanu/Documents/code/Terminal/liney/Liney/Domain/AppSettings.swift:380-586`

Create `Treemux/Domain/StoredShortcut.swift` with:

```swift
//
//  StoredShortcut.swift
//  Treemux
//

import AppKit
import Carbon.HIToolbox

// MARK: - Stored Shortcut

/// A serializable keyboard shortcut combining a key and modifier flags.
struct StoredShortcut: Codable, Hashable {
    var key: String
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool

    // MARK: - Display

    var displayString: String {
        modifierDisplayString + keyDisplayString
    }

    var modifierDisplayString: String {
        var parts: [String] = []
        if control { parts.append("⌃") }
        if option { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if command { parts.append("⌘") }
        return parts.joined()
    }

    var keyDisplayString: String {
        switch key {
        case "\t": return "TAB"
        case "\r": return "↩"
        case " ": return "SPACE"
        default: return key.uppercased()
        }
    }

    // MARK: - AppKit conversion

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        return flags
    }

    /// Key equivalent string for NSMenuItem.
    var menuItemKeyEquivalent: String? {
        switch key {
        case "←":
            guard let scalar = UnicodeScalar(NSLeftArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "→":
            guard let scalar = UnicodeScalar(NSRightArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "↑":
            guard let scalar = UnicodeScalar(NSUpArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "↓":
            guard let scalar = UnicodeScalar(NSDownArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "\t": return "\t"
        case "\r": return "\r"
        case " ": return " "
        default:
            let lowered = key.lowercased()
            guard lowered.count == 1 else { return nil }
            return lowered
        }
    }

    // MARK: - Recording from NSEvent

    static func from(event: NSEvent) -> StoredShortcut? {
        guard let key = storedKey(from: event) else { return nil }

        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])

        let shortcut = StoredShortcut(
            key: key,
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control)
        )

        // Require at least one modifier
        guard shortcut.command || shortcut.shift || shortcut.option || shortcut.control else {
            return nil
        }
        return shortcut
    }

    private static func storedKey(from event: NSEvent) -> String? {
        switch event.keyCode {
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 48: return "\t"
        case 36, 76: return "\r"
        case 49: return " "
        case 33: return "["
        case 30: return "]"
        case 27: return "-"
        case 24: return "="
        case 43: return ","
        case 47: return "."
        case 44: return "/"
        case 41: return ";"
        case 39: return "'"
        case 50: return "`"
        case 42: return "\\"
        default: break
        }

        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              let char = chars.first else {
            return nil
        }

        if char.isLetter || char.isNumber {
            return String(char)
        }
        return nil
    }
}

// MARK: - Shortcut Override

/// Represents a user override: nil shortcut means disabled.
struct ShortcutOverride: Codable, Hashable {
    var shortcut: StoredShortcut?
}
```

**Step 2: Add the file to the Xcode project**

Ensure the file is added to the Treemux target in the Xcode project. If using folder references, placing it in `Treemux/Domain/` should auto-include it.

**Step 3: Build to verify**

Run: `xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 4: Commit**

```bash
git add Treemux/Domain/StoredShortcut.swift
git commit -m "feat: add StoredShortcut data model with NSEvent recording support"
```

---

### Task 8: Create ShortcutAction Enum with Defaults

**Files:**
- Create: `Treemux/Domain/ShortcutAction.swift`

**Step 1: Create the ShortcutAction enum**

Create `Treemux/Domain/ShortcutAction.swift`:

```swift
//
//  ShortcutAction.swift
//  Treemux
//

import Foundation

// MARK: - Shortcut Category

enum ShortcutCategory: String, CaseIterable, Hashable, Identifiable {
    case general
    case panes
    case window

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .panes: return String(localized: "Panes")
        case .window: return String(localized: "Window")
        }
    }
}

// MARK: - Shortcut Action

enum ShortcutAction: String, CaseIterable, Hashable, Identifiable {
    case openSettings
    case commandPalette
    case toggleSidebar
    case openProject
    case splitHorizontal
    case splitVertical
    case closePane
    case focusNextPane
    case focusPreviousPane
    case zoomPane
    case newClaudeCode

    var id: String { rawValue }

    var category: ShortcutCategory {
        switch self {
        case .openSettings, .commandPalette, .toggleSidebar, .openProject:
            return .general
        case .splitHorizontal, .splitVertical, .closePane,
             .focusNextPane, .focusPreviousPane, .zoomPane, .newClaudeCode:
            return .panes
        }
    }

    var title: String {
        switch self {
        case .openSettings: return String(localized: "Settings")
        case .commandPalette: return String(localized: "Command Palette")
        case .toggleSidebar: return String(localized: "Toggle Sidebar")
        case .openProject: return String(localized: "Open Project")
        case .splitHorizontal: return String(localized: "Split Down")
        case .splitVertical: return String(localized: "Split Right")
        case .closePane: return String(localized: "Close Pane")
        case .focusNextPane: return String(localized: "Next Pane")
        case .focusPreviousPane: return String(localized: "Previous Pane")
        case .zoomPane: return String(localized: "Zoom Pane")
        case .newClaudeCode: return String(localized: "New Claude Code Session")
        }
    }

    var subtitle: String {
        switch self {
        case .openSettings: return String(localized: "Open the Treemux settings panel.")
        case .commandPalette: return String(localized: "Search and run commands.")
        case .toggleSidebar: return String(localized: "Show or hide the project sidebar.")
        case .openProject: return String(localized: "Open a directory as a project.")
        case .splitHorizontal: return String(localized: "Split the focused pane downward.")
        case .splitVertical: return String(localized: "Split the focused pane to the right.")
        case .closePane: return String(localized: "Close the focused pane.")
        case .focusNextPane: return String(localized: "Move focus to the next pane.")
        case .focusPreviousPane: return String(localized: "Move focus to the previous pane.")
        case .zoomPane: return String(localized: "Zoom or unzoom the focused pane.")
        case .newClaudeCode: return String(localized: "Open a new Claude Code terminal.")
        }
    }

    var defaultShortcut: StoredShortcut? {
        switch self {
        case .openSettings:
            return StoredShortcut(key: ",", command: true, shift: false, option: false, control: false)
        case .commandPalette:
            return StoredShortcut(key: "p", command: true, shift: true, option: false, control: false)
        case .toggleSidebar:
            return StoredShortcut(key: "b", command: true, shift: false, option: false, control: false)
        case .openProject:
            return StoredShortcut(key: "o", command: true, shift: false, option: false, control: false)
        case .splitHorizontal:
            return StoredShortcut(key: "d", command: true, shift: false, option: false, control: false)
        case .splitVertical:
            return StoredShortcut(key: "d", command: true, shift: true, option: false, control: false)
        case .closePane:
            return StoredShortcut(key: "w", command: true, shift: false, option: false, control: false)
        case .focusNextPane:
            return StoredShortcut(key: "]", command: true, shift: false, option: false, control: false)
        case .focusPreviousPane:
            return StoredShortcut(key: "[", command: true, shift: false, option: false, control: false)
        case .zoomPane:
            return StoredShortcut(key: "\r", command: true, shift: true, option: false, control: false)
        case .newClaudeCode:
            return StoredShortcut(key: "c", command: true, shift: true, option: false, control: false)
        }
    }
}
```

**Step 2: Build to verify**

Run: `xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add Treemux/Domain/ShortcutAction.swift
git commit -m "feat: add ShortcutAction enum with categories, titles, and defaults"
```

---

### Task 9: Create TreemuxKeyboardShortcuts Manager

**Files:**
- Create: `Treemux/Domain/TreemuxKeyboardShortcuts.swift`

**Step 1: Add shortcutOverrides to AppSettings**

In `Treemux/Domain/AppSettings.swift`, add to the `AppSettings` struct:

```swift
var shortcutOverrides: [String: ShortcutOverride] = [:]
```

**Step 2: Create the keyboard shortcuts manager**

Reference: Liney's `LineyKeyboardShortcuts` at `/Users/yanu/Documents/code/Terminal/liney/Liney/Domain/AppSettings.swift:832-940`

Create `Treemux/Domain/TreemuxKeyboardShortcuts.swift`:

```swift
//
//  TreemuxKeyboardShortcuts.swift
//  Treemux
//

import Foundation

// MARK: - Shortcut State

enum ShortcutState: Equatable {
    case `default`
    case custom
    case disabled
}

// MARK: - Keyboard Shortcuts Manager

enum TreemuxKeyboardShortcuts {

    /// Returns the effective shortcut for an action (override or default).
    static func effectiveShortcut(for action: ShortcutAction, in settings: AppSettings) -> StoredShortcut? {
        if let override = settings.shortcutOverrides[action.rawValue] {
            return override.shortcut
        }
        return action.defaultShortcut
    }

    /// Returns the current state of a shortcut binding.
    static func state(for action: ShortcutAction, in settings: AppSettings) -> ShortcutState {
        guard let override = settings.shortcutOverrides[action.rawValue] else {
            return .default
        }
        return override.shortcut == nil ? .disabled : .custom
    }

    /// Returns the display string for an action's current shortcut.
    static func displayString(for action: ShortcutAction, in settings: AppSettings) -> String {
        guard let shortcut = effectiveShortcut(for: action, in: settings) else {
            return String(localized: "Not Set")
        }
        return shortcut.displayString
    }

    /// Sets a custom shortcut for an action, automatically clearing conflicts.
    static func setShortcut(_ shortcut: StoredShortcut, for action: ShortcutAction, in settings: inout AppSettings) {
        // Clear any other action that uses this shortcut
        for otherAction in ShortcutAction.allCases where otherAction != action {
            if effectiveShortcut(for: otherAction, in: settings) == shortcut {
                settings.shortcutOverrides[otherAction.rawValue] = ShortcutOverride(shortcut: nil)
            }
        }

        // If the new shortcut matches the default, remove the override
        if shortcut == action.defaultShortcut {
            settings.shortcutOverrides.removeValue(forKey: action.rawValue)
        } else {
            settings.shortcutOverrides[action.rawValue] = ShortcutOverride(shortcut: shortcut)
        }

        settings.shortcutOverrides = normalizedOverrides(settings.shortcutOverrides)
    }

    /// Disables the shortcut for an action.
    static func disableShortcut(for action: ShortcutAction, in settings: inout AppSettings) {
        settings.shortcutOverrides[action.rawValue] = ShortcutOverride(shortcut: nil)
        settings.shortcutOverrides = normalizedOverrides(settings.shortcutOverrides)
    }

    /// Resets an action's shortcut to its default.
    static func resetShortcut(for action: ShortcutAction, in settings: inout AppSettings) {
        settings.shortcutOverrides.removeValue(forKey: action.rawValue)
        settings.shortcutOverrides = normalizedOverrides(settings.shortcutOverrides)
    }

    /// Resets all shortcuts to defaults.
    static func resetAll(in settings: inout AppSettings) {
        settings.shortcutOverrides = [:]
    }

    /// Removes redundant overrides and resolves conflicts.
    static func normalizedOverrides(_ overrides: [String: ShortcutOverride]) -> [String: ShortcutOverride] {
        var normalized: [String: ShortcutOverride] = [:]
        var seenShortcuts = Set<StoredShortcut>()

        for action in ShortcutAction.allCases {
            let override = overrides[action.rawValue]
            let effectiveShortcut: StoredShortcut?

            if let override {
                if let shortcut = override.shortcut {
                    // Custom shortcut — check if it matches default (redundant)
                    if shortcut == action.defaultShortcut {
                        effectiveShortcut = shortcut
                        // Don't store redundant override
                    } else {
                        effectiveShortcut = shortcut
                        normalized[action.rawValue] = override
                    }
                } else {
                    // Disabled
                    effectiveShortcut = nil
                    normalized[action.rawValue] = override
                }
            } else {
                effectiveShortcut = action.defaultShortcut
            }

            if let effectiveShortcut {
                if seenShortcuts.contains(effectiveShortcut) {
                    // Conflict — disable this one
                    normalized[action.rawValue] = ShortcutOverride(shortcut: nil)
                } else {
                    seenShortcuts.insert(effectiveShortcut)
                }
            }
        }

        return normalized
    }
}
```

**Step 3: Build to verify**

Run: `xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 4: Commit**

```bash
git add Treemux/Domain/AppSettings.swift Treemux/Domain/TreemuxKeyboardShortcuts.swift
git commit -m "feat: add TreemuxKeyboardShortcuts manager with conflict detection"
```

---

### Task 10: Create ShortcutRecorderButton

**Files:**
- Create: `Treemux/UI/Settings/ShortcutRecorderButton.swift`

**Step 1: Create the NSViewRepresentable wrapper and NSButton subclass**

Reference: Liney's `ShortcutRecorderField` + `ShortcutRecorderNSButton` at `/Users/yanu/Documents/code/Terminal/liney/Liney/UI/Sheets/SettingsSheet.swift:961-1087`

Create `Treemux/UI/Settings/ShortcutRecorderButton.swift`:

```swift
//
//  ShortcutRecorderButton.swift
//  Treemux
//

import AppKit
import SwiftUI

// MARK: - SwiftUI Wrapper

/// NSViewRepresentable that wraps a button for recording keyboard shortcuts.
struct ShortcutRecorderButton: NSViewRepresentable {
    @Binding var shortcut: StoredShortcut?
    let emptyTitle: String

    func makeNSView(context: Context) -> ShortcutRecorderNSButton {
        let button = ShortcutRecorderNSButton()
        button.shortcut = shortcut
        button.emptyTitle = emptyTitle
        button.onShortcutRecorded = { newShortcut in
            shortcut = newShortcut
        }
        return button
    }

    func updateNSView(_ nsView: ShortcutRecorderNSButton, context: Context) {
        nsView.shortcut = shortcut
        nsView.emptyTitle = emptyTitle
        nsView.updateTitle()
    }
}

// MARK: - AppKit Button

/// NSButton subclass that captures keyboard shortcuts when clicked.
/// Click to start recording, press any modifier+key combo to save,
/// press Escape to cancel.
final class ShortcutRecorderNSButton: NSButton {
    var shortcut: StoredShortcut?
    var emptyTitle = "Not Set"
    var onShortcutRecorded: ((StoredShortcut) -> Void)?

    private var isRecording = false
    private var eventMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(buttonClicked)
        updateTitle()
    }

    func updateTitle() {
        if isRecording {
            title = String(localized: "Press shortcut…")
        } else if let shortcut {
            title = shortcut.displayString
        } else {
            title = emptyTitle
        }
    }

    @objc private func buttonClicked() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        updateTitle()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // Escape cancels recording
            if event.keyCode == 53 {
                self.stopRecording()
                return nil
            }

            if let newShortcut = StoredShortcut.from(event: event) {
                self.shortcut = newShortcut
                self.onShortcutRecorded?(newShortcut)
                self.stopRecording()
                return nil
            }

            return nil
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowResigned),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    private func stopRecording() {
        isRecording = false
        updateTitle()

        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    @objc private func windowResigned() {
        stopRecording()
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }
}
```

**Step 2: Build to verify**

Run: `xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add Treemux/UI/Settings/ShortcutRecorderButton.swift
git commit -m "feat: add ShortcutRecorderButton with NSEvent-based recording"
```

---

### Task 11: Rewrite SettingsSheet Shortcuts Tab

**Files:**
- Modify: `Treemux/UI/Settings/SettingsSheet.swift:191-225` (ShortcutsSettingsView)

**Step 1: Replace the read-only shortcuts list with editable UI**

Replace the entire `ShortcutsSettingsView` struct (lines 193-225) with:

```swift
private struct ShortcutsSettingsView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        Form {
            ForEach(ShortcutCategory.allCases) { category in
                Section(category.title) {
                    let actions = ShortcutAction.allCases.filter { $0.category == category }
                    ForEach(actions) { action in
                        ShortcutRow(action: action, settings: $store.settings)
                    }
                }
            }

            Section {
                Button(String(localized: "Reset All to Defaults")) {
                    TreemuxKeyboardShortcuts.resetAll(in: &store.settings)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction
    @Binding var settings: AppSettings

    private var state: ShortcutState {
        TreemuxKeyboardShortcuts.state(for: action, in: settings)
    }

    private var effectiveShortcut: StoredShortcut? {
        TreemuxKeyboardShortcuts.effectiveShortcut(for: action, in: settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .font(.system(size: 13))
                    Text(action.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                ShortcutRecorderButton(
                    shortcut: Binding(
                        get: { effectiveShortcut },
                        set: { newShortcut in
                            if let shortcut = newShortcut {
                                TreemuxKeyboardShortcuts.setShortcut(shortcut, for: action, in: &settings)
                            }
                        }
                    ),
                    emptyTitle: String(localized: "Not Set")
                )
                .frame(width: 120)
            }

            HStack(spacing: 8) {
                if state == .custom {
                    Button(String(localized: "Reset")) {
                        TreemuxKeyboardShortcuts.resetShortcut(for: action, in: &settings)
                    }
                    .font(.system(size: 11))
                }

                if state != .disabled {
                    Button(String(localized: "Disable")) {
                        TreemuxKeyboardShortcuts.disableShortcut(for: action, in: &settings)
                    }
                    .font(.system(size: 11))
                }
            }
        }
        .padding(.vertical, 2)
    }
}
```

**Step 2: Build to verify**

Run: `xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add Treemux/UI/Settings/SettingsSheet.swift
git commit -m "feat: replace read-only shortcuts list with editable recorder UI"
```

---

### Task 12: Sync AppDelegate Menu Bar with Shortcut Settings

**Files:**
- Modify: `Treemux/AppDelegate.swift` (buildMainMenu method + add settings observation)

**Step 1: Create helper to get key equivalent from settings**

Add a private helper method to `AppDelegate`:

```swift
/// Returns the key equivalent and modifier mask for a shortcut action.
private func menuShortcut(for action: ShortcutAction) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
    guard let store,
          let shortcut = TreemuxKeyboardShortcuts.effectiveShortcut(for: action, in: store.settings),
          let keyEquiv = shortcut.menuItemKeyEquivalent else {
        return nil
    }
    return (keyEquiv, shortcut.modifierFlags)
}
```

**Step 2: Refactor buildMainMenu to use settings-based shortcuts**

Replace hardcoded `keyEquivalent` values with dynamic lookups. For each menu item that corresponds to a `ShortcutAction`, use the helper:

```swift
private func applyShortcut(_ action: ShortcutAction, to item: NSMenuItem) {
    if let binding = menuShortcut(for: action) {
        item.keyEquivalent = binding.key
        item.keyEquivalentModifierMask = binding.modifiers
    } else {
        item.keyEquivalent = ""
    }
}
```

Apply this to each relevant menu item in `buildMainMenu()`. For example:

```swift
let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
settingsItem.target = self
applyShortcut(.openSettings, to: settingsItem)
appMenu.addItem(settingsItem)
```

Do the same for: `openProject`, `closePane`, `toggleSidebar`, `toggleCommandPalette`, `splitHorizontal`, `splitVertical`, `focusNextPane`, `focusPreviousPane`, `zoomPane`.

**Step 3: Add settings change observation to rebuild menu**

In `applicationDidFinishLaunching`, after `buildMainMenu()`, add observation on settings changes. Since `WorkspaceStore.settings` is `@Published`, use Combine:

```swift
import Combine
```

Add a property to AppDelegate:

```swift
private var settingsCancellable: AnyCancellable?
```

In `applicationDidFinishLaunching`, after building the menu:

```swift
settingsCancellable = treemuxApp?.store.$settings
    .dropFirst()
    .receive(on: RunLoop.main)
    .sink { [weak self] _ in
        self?.buildMainMenu()
    }
```

This rebuilds the entire menu when settings change (including shortcut overrides). Menu rebuilding is cheap and ensures all shortcuts stay in sync.

**Step 4: Build to verify**

Run: `xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 5: Commit**

```bash
git add Treemux/AppDelegate.swift
git commit -m "feat: sync menu bar shortcuts with user-customized bindings"
```

---

### Task 13: Final Build Verification and Manual Test

**Step 1: Clean build**

Run: `xcodebuild -scheme Treemux -configuration Debug clean build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 2: Find the DerivedData build path**

Run: `find ~/Library/Developer/Xcode/DerivedData -name "Treemux.app" -path "*/Debug/*" 2>/dev/null | head -1`

**Step 3: Manual verification checklist**

Run the app and verify:
- [ ] Toolbar shows 4 right-side buttons: split down, split right, new terminal, settings gear
- [ ] Clicking gear opens SettingsSheet as a sheet
- [ ] ⌘, also opens SettingsSheet
- [ ] ⌘⇧P opens command palette overlay
- [ ] Command palette search works and commands execute
- [ ] General settings has Appearance picker (Follow System / Dark / Light)
- [ ] Switching appearance applies immediately
- [ ] Shortcuts tab shows all actions grouped by category
- [ ] Clicking a shortcut button enters recording mode ("Press shortcut…")
- [ ] Recording a new shortcut saves and displays it
- [ ] "Reset" button appears for custom shortcuts
- [ ] "Disable" button works
- [ ] "Reset All to Defaults" works
- [ ] Menu bar shortcuts update when settings change
- [ ] Split buttons create new terminal panes

**Step 4: Commit any final fixes**

```bash
git add -A
git commit -m "fix: final adjustments from manual testing"
```
