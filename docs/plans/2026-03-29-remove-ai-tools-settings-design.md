# Remove AI Tools Settings UI

**Date:** 2026-03-29
**Approach:** Option B — clean removal of UI + dead code

## Summary

Remove the "AI Tools" tab from the Settings sheet and delete the unused `AIToolSettings` model. The underlying AI tool detection (`AIToolService`, `ShellSession.detectAITool`) and agent preset loading (`~/.treemux/agents/`) continue to work automatically without user configuration.

## Changes

### 1. `SettingsSheet.swift`
- Remove `.aiTools` case from `SettingsSection` enum
- Remove associated `title`, `subtitle`, `icon`, and `settingsContent` switch entries
- Delete `AIToolsSettingsView` struct

### 2. `AppSettings.swift`
- Delete `AIToolSettings` struct
- Delete `var aiTools: AIToolSettings` property from `AppSettings`

## Not Changed

- `AIToolService` — auto-detection and preset loading remain
- `AIToolModels.swift` — `AIToolDetection`, `AIToolKind` extensions remain
- `SessionBackend.swift` — `AIToolKind`, `AgentSessionConfig` remain
- `ShellSession.detectAITool(fromTitle:)` — continues to run unconditionally

## Backward Compatibility

Swift `Codable` silently ignores unknown keys during decoding. Existing persisted JSON containing an `aiTools` key will decode without error — no migration needed.
