# Terminal Cursor/Font Settings Fix — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the terminal cursor style and font size settings in Settings > Terminal actually take effect in the Ghostty terminal engine, both at startup and via runtime hot-reload.

**Architecture:** Write `AppSettings.terminal` values into a temporary Ghostty config file, load it after default files so Treemux settings win. On settings change, rebuild the full config and push it to the Ghostty app via `ghostty_app_update_config`. Also set `font_size` on `ghostty_surface_config_s` for new surfaces.

**Tech Stack:** Swift, GhosttyKit C API, NotificationCenter

---

### Task 1: Add Notification name and post it on settings save

**Files:**
- Modify: `Treemux/App/WorkspaceStore.swift:21-28`

**Step 1: Add a static Notification.Name extension**

At the top of `WorkspaceStore.swift`, after imports, add:

```swift
extension Notification.Name {
    static let treemuxTerminalSettingsDidChange = Notification.Name("treemuxTerminalSettingsDidChange")
}
```

**Step 2: Post the notification in `updateSettings`**

Change `updateSettings` to:

```swift
func updateSettings(_ newSettings: AppSettings) {
    let terminalChanged = settings.terminal != newSettings.terminal
    settings = newSettings
    if terminalChanged {
        NotificationCenter.default.post(name: .treemuxTerminalSettingsDidChange, object: newSettings.terminal)
    }
}
```

**Step 3: Commit**

```bash
git add Treemux/App/WorkspaceStore.swift
git commit -m "feat: post notification when terminal settings change"
```

---

### Task 2: Add temp config helper and inject settings at init

**Files:**
- Modify: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyRuntime.swift:23-31`

**Step 1: Add `writeTemporaryGhosttyConfig` helper**

Add this private method to `TreemuxGhosttyRuntime`:

```swift
/// Writes Treemux terminal settings as a temporary Ghostty config file.
/// Caller must delete the returned URL after use.
private func writeTemporaryGhosttyConfig(for terminal: TerminalSettings) -> URL? {
    let lines = [
        "cursor-style = \(terminal.cursorStyle)",
        "font-size = \(terminal.fontSize)",
    ]
    let content = lines.joined(separator: "\n") + "\n"
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("treemux-ghostty-\(UUID().uuidString).conf")
    do {
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    } catch {
        return nil
    }
}
```

**Step 2: Inject settings in `init()`**

Replace the config creation block in `init()`:

```swift
guard let configuration = ghostty_config_new() else {
    fatalError("Unable to allocate libghostty config")
}
ghostty_config_load_default_files(configuration)

// Override with Treemux terminal settings
let terminalSettings = AppSettingsPersistence().load().terminal
if let tempURL = writeTemporaryGhosttyConfig(for: terminalSettings) {
    ghostty_config_load_file(configuration, tempURL.path)
    try? FileManager.default.removeItem(at: tempURL)
}

ghostty_config_finalize(configuration)
config = configuration
```

**Step 3: Commit**

```bash
git add Treemux/Services/Terminal/Ghostty/TreemuxGhosttyRuntime.swift
git commit -m "feat: inject terminal settings into Ghostty config at init"
```

---

### Task 3: Add runtime hot-reload on settings change

**Files:**
- Modify: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyRuntime.swift:59-79`

**Step 1: Add observer in `installObservers()`**

Add to the end of `installObservers()`:

```swift
center.addObserver(
    self,
    selector: #selector(terminalSettingsDidChange(_:)),
    name: .treemuxTerminalSettingsDidChange,
    object: nil
)
```

**Step 2: Add the handler method**

Add a new method to `TreemuxGhosttyRuntime`:

```swift
@objc private func terminalSettingsDidChange(_ notification: Notification) {
    guard let terminal = notification.object as? TerminalSettings else { return }
    reloadGhosttyConfig(with: terminal)
}

private func reloadGhosttyConfig(with terminal: TerminalSettings) {
    guard let newConfig = ghostty_config_new() else { return }
    ghostty_config_load_default_files(newConfig)

    if let tempURL = writeTemporaryGhosttyConfig(for: terminal) {
        ghostty_config_load_file(newConfig, tempURL.path)
        try? FileManager.default.removeItem(at: tempURL)
    }

    ghostty_config_finalize(newConfig)
    ghostty_app_update_config(app, newConfig)
}
```

**Step 3: Commit**

```bash
git add Treemux/Services/Terminal/Ghostty/TreemuxGhosttyRuntime.swift
git commit -m "feat: hot-reload Ghostty config when terminal settings change"
```

---

### Task 4: Set font_size on surface config for new surfaces

**Files:**
- Modify: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift:1104-1112`

**Step 1: Set `font_size` in `withSurfaceConfig`**

After `configuration.scale_factor = ...` (line 1110), add:

```swift
configuration.font_size = Float(AppSettingsPersistence().load().terminal.fontSize)
```

**Step 2: Commit**

```bash
git add Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift
git commit -m "feat: set font_size on new Ghostty surfaces from settings"
```

---

### Task 5: Manual smoke test

**Step 1: Build and run**

Build the project in Xcode, then run:
```bash
rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<id>/Build/Products/Debug/Treemux.app
```

**Step 2: Verify initial settings**

1. Open Settings > Terminal
2. Change cursor style to "Bar", save
3. Quit and relaunch the app
4. Open a terminal — cursor should be a bar, not a block

**Step 3: Verify hot-reload**

1. With a terminal open, go to Settings > Terminal
2. Change cursor style from "Bar" to "Underline", save
3. The existing terminal should immediately show an underline cursor (no restart needed)

**Step 4: Verify font size**

1. Open Settings > Terminal
2. Change font size to 20, save
3. The terminal font should update immediately
4. Open a new terminal tab — it should also use font size 20
