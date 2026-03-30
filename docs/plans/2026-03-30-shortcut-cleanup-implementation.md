# Shortcut Settings Cleanup Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove the `newClaudeCode` shortcut action and fix all missing zh-Hans translations in the keyboard shortcut settings UI.

**Architecture:** Two independent changes — (1) delete `newClaudeCode` from `ShortcutAction` enum and all references, (2) add missing Chinese translations to `Localizable.xcstrings`. Both are safe, isolated edits.

**Tech Stack:** Swift, SwiftUI, Xcode xcstrings localization

---

### Task 1: Remove `newClaudeCode` from ShortcutAction

**Files:**
- Modify: `Treemux/Domain/ShortcutAction.swift:45,56,77,97,131-132`

**Step 1: Remove the enum case and all switch branches**

In `ShortcutAction.swift`, make these deletions:

1. Delete line 45: `case newClaudeCode`

2. In `category` (line 56), remove `.newClaudeCode` from the panes list:
```swift
// BEFORE
case .splitHorizontal, .splitVertical, .closePane,
     .focusNextPane, .focusPreviousPane, .zoomPane, .newClaudeCode:
    return .panes

// AFTER
case .splitHorizontal, .splitVertical, .closePane,
     .focusNextPane, .focusPreviousPane, .zoomPane:
    return .panes
```

3. In `title` (line 77), delete:
```swift
case .newClaudeCode: return "New Claude Code Session"
```

4. In `subtitle` (line 97), delete:
```swift
case .newClaudeCode: return "Open a new Claude Code terminal."
```

5. In `defaultShortcut` (lines 131-132), delete:
```swift
case .newClaudeCode:
    return StoredShortcut(key: "c", command: true, shift: true, option: false, control: false)
```

**Step 2: Build to verify no compile errors**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/Domain/ShortcutAction.swift
git commit -m "refactor: remove newClaudeCode shortcut action"
```

---

### Task 2: Remove Claude Code from Command Palette

**Files:**
- Modify: `Treemux/UI/Components/CommandPaletteView.swift:194-199`

**Step 1: Delete the Claude Code palette command**

Remove these lines (194-199):
```swift
PaletteCommand(
    title: "New Claude Code Session",
    subtitle: "claude", icon: "brain.head.profile",
    shortcut: "⌘⇧C",
    action: {}
),
```

**Step 2: Build to verify**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/UI/Components/CommandPaletteView.swift
git commit -m "refactor: remove Claude Code from command palette"
```

---

### Task 3: Add missing zh-Hans translations to Localizable.xcstrings

**Files:**
- Modify: `Treemux/Localizable.xcstrings`

**Step 1: Add all missing translation entries**

Add zh-Hans translations for the following keys. Each entry needs to be added to the `strings` object in `Localizable.xcstrings` with the standard xcstrings JSON structure:

**Category titles (3):**
| Key | zh-Hans |
|-----|---------|
| `Tabs` | `标签页` |
| `Panes` | `窗格` |
| `Window` | `窗口` |

**Action titles (6):**
| Key | zh-Hans |
|-----|---------|
| `Command Palette` | `命令面板` |
| `Next Tab` | `下一个标签页` |
| `Previous Tab` | `上一个标签页` |
| `Next Pane` | `下一个窗格` |
| `Previous Pane` | `上一个窗格` |
| `Zoom Pane` | `缩放窗格` |

**Action subtitles (14, but subtract the Claude Code one = 13):**
| Key | zh-Hans |
|-----|---------|
| `Open the Treemux settings panel.` | `打开 Treemux 设置面板。` |
| `Search and run commands.` | `搜索并运行命令。` |
| `Show or hide the project sidebar.` | `显示或隐藏项目侧边栏。` |
| `Open a directory as a project.` | `将目录作为项目打开。` |
| `Create a new terminal tab.` | `创建新的终端标签页。` |
| `Close the current tab.` | `关闭当前标签页。` |
| `Switch to the next tab.` | `切换到下一个标签页。` |
| `Switch to the previous tab.` | `切换到上一个标签页。` |
| `Split the focused pane downward.` | `将当前窗格向下分屏。` |
| `Split the focused pane to the right.` | `将当前窗格向右分屏。` |
| `Close the focused pane.` | `关闭当前窗格。` |
| `Move focus to the next pane.` | `将焦点移动到下一个窗格。` |
| `Move focus to the previous pane.` | `将焦点移动到上一个窗格。` |
| `Zoom or unzoom the focused pane.` | `缩放或取消缩放当前窗格。` |

**Button text (1):**
| Key | zh-Hans |
|-----|---------|
| `Press shortcut…` | `请按快捷键…` |

Each entry in xcstrings JSON format:
```json
"<English Key>" : {
  "localizations" : {
    "zh-Hans" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "<Chinese Translation>"
      }
    }
  }
}
```

**Step 2: Also remove the `New Claude Code Session` and `Open a new Claude Code terminal.` entries from xcstrings** (if they exist).

**Step 3: Build to verify**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Treemux/Localizable.xcstrings
git commit -m "i18n: add missing zh-Hans translations for shortcut settings"
```

---

### Task 4: Final verification

**Step 1: Full clean build**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -configuration Debug clean build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 2: Grep for any remaining `newClaudeCode` references**

Run: `grep -r "newClaudeCode" Treemux/`
Expected: No output (no remaining references)

**Step 3: Commit design doc updates if needed, then squash or leave as-is per user preference**
