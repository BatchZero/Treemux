# Task 12 Report — Reshape 7 Dialogs to New Design Language

## Per-Dialog Summary

### 1. OpenProjectSheet.swift
- **Already had** `@EnvironmentObject private var theme: ThemeManager` — no addition needed.
- **Buttons**: "Open" → `PillButtonStyle`; "Cancel" → `UtilityButtonStyle`; "Choose…" (localModeView) → `UtilityButtonStyle`.
- **Spacing**: `.padding(20)` → `.padding(Spacing.lg)`; `spacing: 8` → `spacing: Spacing.xs`; `spacing: 12` → `spacing: Spacing.sm`; `.padding(8)` → `.padding(Spacing.xs)`.
- **No Dividers** in this file to replace.

### 2. SSHServerEditSheet.swift
- **Added** `@EnvironmentObject private var theme: ThemeManager`.
- **Buttons**: "Save" → `PillButtonStyle` (removed `.borderedProminent`); "Cancel" → `UtilityButtonStyle`; "Test Connection" → `UtilityButtonStyle`; "Choose…" (identity file) → `UtilityButtonStyle`.
- **Spacing**: `.padding(20)` → `.padding(Spacing.lg)`.
- **No Dividers** to replace.

### 3. SettingsSheet.swift
- **Already had** `@EnvironmentObject private var theme: ThemeManager` — no addition needed.
- **Font**: `Text(selection.title).font(.system(size: 20, weight: .semibold))` → `.font(DesignFonts.dialogTitle).tracking(DesignFonts.dialogTitleTracking)`; subtitle `font(.system(size: 12, weight: .medium))` → `DesignFonts.chromeCaption`.
- **Buttons**: "Save" → `PillButtonStyle` (removed `.borderedProminent`); "Cancel" → `UtilityButtonStyle`.
- **Dividers**: Sidebar→detail `Divider()` → `.hairline(.trailing)` on the List; header-bottom `Divider()` → `.hairline(.bottom)` on header VStack; footer-top `Divider()` → `.hairline(.top)` on footer HStack.
- **Spacing**: `.padding(20)` → `.padding(Spacing.lg)` (footer); `.padding(.horizontal, 20)` → `.padding(.horizontal, Spacing.lg)` (header).

### 4. SSHRawConfigSheet.swift
- **Added** `@EnvironmentObject private var theme: ThemeManager`.
- **Font**: `Text("Edit Raw Config File").font(.headline)` → `.font(DesignFonts.dialogTitle).tracking(DesignFonts.dialogTitleTracking)`; `Text(path).font(.caption)` → `.font(DesignFonts.chromeCaption)`; error `font(.caption)` → `DesignFonts.chromeCaption`.
- **Buttons**: "Save" → `PillButtonStyle` (removed `.borderedProminent`); "Cancel" → `UtilityButtonStyle`.
- **Spacing**: `.padding(20)` → `.padding(Spacing.lg)`; `spacing: 12` → `spacing: Spacing.sm`.
- **Monospaced TextEditor** intentionally preserved (data layer — SSH config file content).

### 5. RemoteDirectoryBrowser.swift
- **Added** `@EnvironmentObject private var theme: ThemeManager`.
- **Font (titleBar)**: `Text("Select Remote Directory").font(.headline)` → `.font(DesignFonts.dialogTitle).tracking(DesignFonts.dialogTitleTracking)`.
- **Font (bottomBar)**: `.font(.system(size: 11))` → `DesignFonts.chromeCaption`; `.font(.system(size: 11, weight: .medium))` → `DesignFonts.chromeStrong`.
- **Buttons**: "Open" (bottomBar) → `PillButtonStyle`; "Cancel" → `UtilityButtonStyle`; "Connect" (passwordPromptView inline CTA) → `PillButtonStyle`.
- **Dividers**: All 3 structural `Divider()` calls replaced — pathBar `.hairline(.top).hairline(.bottom)`; bottomBar `.hairline(.top)`.
- **Spacing**: `.padding(.horizontal, 20)` → `.padding(.horizontal, Spacing.lg)`; `.padding(.vertical, 12)` → `.padding(.vertical, Spacing.sm)`; `spacing: 8` → `spacing: Spacing.xs` in pathBar and bottomBar.

### 6. SidebarIconCustomizationSheet.swift
- **Added** `@EnvironmentObject private var theme: ThemeManager` to both `SidebarIconEditorCard` and `SidebarIconCustomizationSheet`.
- **Font (customization sheet title)**: `.font(.system(size: 20, weight: .semibold))` → `DesignFonts.dialogTitle + .tracking(dialogTitleTracking)`; subtitle `.font(.system(size: 12, weight: .medium))` → `DesignFonts.chromeCaption`.
- **Buttons**: "Save" → `PillButtonStyle` (removed `.borderedProminent`); "Cancel" → `UtilityButtonStyle`; "Reset" → `UtilityButtonStyle`; "Random" (in EditorCard) → `UtilityButtonStyle`.
- **Color swaps**: `Color.white.opacity(0.9)` (selected border) → `theme.accentColor`; `Color.white.opacity(0.035)` (card bg) → `theme.sidebarSelection.opacity(0.5)`.
- **Radius**: `cornerRadius: 8` → `Radius.sm` (palette swatches); `cornerRadius: 10` → `Radius.md` (card container).
- **Spacing**: `.padding(20)` → `.padding(Spacing.lg)` (main sheet); `.padding(12)` → `.padding(Spacing.sm)` (card inner).

### 7. BatchUnsavedChangesSheet.swift
- **Added** `@EnvironmentObject private var theme: ThemeManager`.
- **Font**: `font(.headline)` → `DesignFonts.dialogTitle + .tracking(dialogTitleTracking)`.
- **Buttons**: "Save All" → `PillButtonStyle`; "Cancel" → `UtilityButtonStyle`; "Don't Save" → `UtilityButtonStyle`.
- **Spacing**: `.padding(20)` → `.padding(Spacing.lg)`; `spacing: 12` → `spacing: Spacing.sm`.
- **Monospaced file-path Text** intentionally preserved (data layer — file path display).

## New User-Visible Strings
None added. All transformations were purely restyle with no new strings.

## Final Grep Output
```
$ grep -rn "\.white\.opacity\|borderedProminent" Treemux/UI/Sheets Treemux/UI/Settings Treemux/UI/FileBrowser/BatchUnsavedChangesSheet.swift
(empty — clean)
```

## Build Result
`** BUILD SUCCEEDED **` (xcodebuild build -scheme Treemux -configuration Debug -skipPackagePluginValidation)

## Self-Review
- All 7 dialogs restyled. No interaction logic, validation, or layout skeletons changed.
- Each dialog's single primary CTA became `PillButtonStyle`; all secondary/cancel/utility actions became `UtilityButtonStyle`.
- `Divider()` removed in SettingsSheet (3 instances) and RemoteDirectoryBrowser (3 instances); replaced with `.hairline(edge)` on adjacent containers.
- `Spacing.lg` (24) replaces all `.padding(20)` outer literals. Nearest tokens applied for inner literals.
- `DesignFonts.dialogTitle` + `tracking` applied to all dialog title `Text` nodes that had `.system(size:20...)`.
- Monospaced fonts (TextEditor in SSHRawConfigSheet, file-path list in BatchUnsavedChangesSheet) intentionally preserved as data-layer fonts.
- `theme.sidebarSelection` token availability: confirmed present in ThemeManager from Phase A work.

## Concerns
None. All 7 dialogs transformed cleanly with BUILD SUCCEEDED and empty grep.
