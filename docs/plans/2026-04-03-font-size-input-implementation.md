# Font Size TextField + Stepper Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow users to type a font size directly in the Settings terminal tab, in addition to using the existing Stepper +/- buttons.

**Architecture:** Replace the read-only `Text` label inside the existing `Stepper` with an editable `TextField`. A local `@State` string buffer handles editing; on commit (Enter / focus lost), the value is parsed, clamped to 6…72, and written back to `settings.terminal.fontSize`. The Stepper range is widened from 8…32 to 6…72.

**Tech Stack:** SwiftUI (macOS), `@FocusState`

---

### Task 1: Widen Stepper range to 6…72

**Files:**
- Modify: `Treemux/UI/Settings/SettingsSheet.swift:188`

**Step 1: Change the Stepper range**

In `TerminalSettingsView`, change:

```swift
Stepper(
    value: $settings.terminal.fontSize, in: 8...32
```

to:

```swift
Stepper(
    value: $settings.terminal.fontSize, in: 6...72
```

**Step 2: Build to verify no compile errors**

Run: `xcodebuild -scheme Treemux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add Treemux/UI/Settings/SettingsSheet.swift
git commit -m "feat(settings): widen font size range to 6…72"
```

---

### Task 2: Add local state and @FocusState for TextField editing

**Files:**
- Modify: `Treemux/UI/Settings/SettingsSheet.swift:180-206` (the `TerminalSettingsView` struct)

**Step 1: Add state properties**

Add three properties to `TerminalSettingsView`, right after the `@Binding var settings`:

```swift
@State private var fontSizeText: String = ""
@FocusState private var isFontSizeFieldFocused: Bool
```

**Step 2: Initialize `fontSizeText` from settings on appear**

Add `.onAppear` to the `Form`:

```swift
.onAppear {
    fontSizeText = "\(settings.terminal.fontSize)"
}
```

**Step 3: Build to verify**

Run: `xcodebuild -scheme Treemux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 4: Commit**

```bash
git add Treemux/UI/Settings/SettingsSheet.swift
git commit -m "feat(settings): add local state for font size text editing"
```

---

### Task 3: Replace Text with TextField inside Stepper label

**Files:**
- Modify: `Treemux/UI/Settings/SettingsSheet.swift:187-196`

**Step 1: Replace the Stepper block**

Replace the entire Stepper (lines 187-196) with:

```swift
Stepper(
    value: $settings.terminal.fontSize, in: 6...72
) {
    HStack {
        Text("Font Size")
        Spacer()
        TextField("", text: $fontSizeText)
            .focused($isFontSizeFieldFocused)
            .frame(width: 40)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .onSubmit {
                commitFontSize()
            }
            .onChange(of: isFontSizeFieldFocused) { _, focused in
                if !focused {
                    commitFontSize()
                }
            }
    }
}
.onChange(of: settings.terminal.fontSize) { _, newValue in
    if !isFontSizeFieldFocused {
        fontSizeText = "\(newValue)"
    }
}
```

**Step 2: Add the `commitFontSize()` helper**

Add a private method to `TerminalSettingsView`, after `body`:

```swift
private func commitFontSize() {
    if let value = Int(fontSizeText) {
        let clamped = min(max(value, 6), 72)
        settings.terminal.fontSize = clamped
        fontSizeText = "\(clamped)"
    } else {
        fontSizeText = "\(settings.terminal.fontSize)"
    }
}
```

**Step 3: Build to verify**

Run: `xcodebuild -scheme Treemux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 4: Manual test**

Run the app and verify in Settings → Terminal:
1. The font size field shows the current value (e.g. 14)
2. Clicking +/- updates the displayed number
3. Clicking on the number, typing a new value, and pressing Enter updates the font size
4. Typing an out-of-range value (e.g. 3 or 100) gets clamped to 6 or 72
5. Typing non-numeric text (e.g. "abc") reverts to the current value
6. Tabbing away from the field (losing focus) commits the value

**Step 5: Commit**

```bash
git add Treemux/UI/Settings/SettingsSheet.swift
git commit -m "feat(settings): add inline TextField for font size input with clamp validation"
```
