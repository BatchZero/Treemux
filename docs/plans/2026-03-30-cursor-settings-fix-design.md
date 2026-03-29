# Fix: Terminal Cursor Settings Not Taking Effect

**Date:** 2026-03-30
**Status:** Approved

## Problem

The cursor style setting in Settings > Terminal has no effect on the actual terminal. The `cursorStyle` value is saved to `AppSettings` JSON correctly, but never propagated to the Ghostty terminal engine. The same issue applies to `fontSize`.

## Root Cause

- `TreemuxGhosttyRuntime.init()` creates a Ghostty config using only `ghostty_config_load_default_files`, without injecting Treemux's own `AppSettings`.
- `WorkspaceStore.updateSettings()` persists settings to disk but does not notify the Ghostty runtime to reload.
- `withSurfaceConfig` in `TreemuxGhosttyTerminalView` does not set `font_size` on the `ghostty_surface_config_s` struct.

## Approach: Temporary Config File Injection (Approach A)

### Initialization

1. Read current `AppSettings` from `AppSettingsPersistence`.
2. Generate a temporary file with Ghostty config format (e.g., `cursor-style = bar\nfont-size = 14\n`).
3. After `ghostty_config_load_default_files`, call `ghostty_config_load_file` with the temp file path (Treemux settings override user's ghostty defaults).
4. Call `ghostty_config_finalize`.
5. Delete the temporary file.
6. Set `font_size` on `ghostty_surface_config_s` in `withSurfaceConfig` from current `AppSettings`.

### Runtime Hot-Reload

1. After `WorkspaceStore.updateSettings()` saves, post a `Notification` (e.g., `terminalSettingsDidChange`).
2. `TreemuxGhosttyRuntime` observes this notification and:
   - Creates a new `ghostty_config_t` via `ghostty_config_new()`.
   - Loads default files + temporary Treemux settings file.
   - Finalizes and calls `ghostty_app_update_config(app, newConfig)`.
   - Cleans up the temporary file.

### Config Key Mapping

| AppSettings field | Ghostty config key | Value mapping |
|---|---|---|
| `terminal.cursorStyle` ("block"/"bar"/"underline") | `cursor-style` | Direct 1:1 |
| `terminal.fontSize` (Int) | `font-size` | Int to String |

### Helper Method

`TreemuxGhosttyRuntime.writeTemporaryConfig(for: TerminalSettings) -> URL` — writes the temp file, returns its path. Caller is responsible for deletion.
