# Shortcut Settings Cleanup Design

Date: 2026-03-30

## Goal

1. Remove the "New Claude Code Session" shortcut action entirely
2. Fix mixed Chinese/English text in the keyboard shortcut settings UI

## Part 1: Remove `newClaudeCode`

Delete `case newClaudeCode` from `ShortcutAction` and clean up all references:

| File | Action |
|------|--------|
| `Treemux/Domain/ShortcutAction.swift` | Remove `case newClaudeCode` and all switch branches |
| `Treemux/UI/Components/CommandPaletteView.swift` | Remove "New Claude Code Session" palette command |
| `Treemux/AppDelegate.swift` | Remove Claude Code menu item (if present) |
| `Treemux/Localizable.xcstrings` | Remove related localization entries |

## Part 2: Fix Localization

### Missing Category Titles

| Key | zh-Hans |
|-----|---------|
| Tabs | 标签页 |
| Panes | 窗格 |
| Window | 窗口 |

### Missing Action Titles

| Key | zh-Hans |
|-----|---------|
| Command Palette | 命令面板 |
| Next Tab | 下一个标签页 |
| Previous Tab | 上一个标签页 |
| Next Pane | 下一个窗格 |
| Previous Pane | 上一个窗格 |
| Zoom Pane | 缩放窗格 |

### Missing Action Subtitles (all 14)

| Key | zh-Hans |
|-----|---------|
| Open the Treemux settings panel. | 打开 Treemux 设置面板。 |
| Search and run commands. | 搜索并运行命令。 |
| Show or hide the project sidebar. | 显示或隐藏项目侧边栏。 |
| Open a directory as a project. | 将目录作为项目打开。 |
| Create a new terminal tab. | 创建新的终端标签页。 |
| Close the current tab. | 关闭当前标签页。 |
| Switch to the next tab. | 切换到下一个标签页。 |
| Switch to the previous tab. | 切换到上一个标签页。 |
| Split the focused pane downward. | 将当前窗格向下分屏。 |
| Split the focused pane to the right. | 将当前窗格向右分屏。 |
| Close the focused pane. | 关闭当前窗格。 |
| Move focus to the next pane. | 将焦点移动到下一个窗格。 |
| Move focus to the previous pane. | 将焦点移动到上一个窗格。 |
| Zoom or unzoom the focused pane. | 缩放或取消缩放当前窗格。 |

### Missing Button Text

| Key | zh-Hans |
|-----|---------|
| Press shortcut… | 请按快捷键… |

## Approach

- Method A (chosen): Delete `newClaudeCode` entirely, add all missing zh-Hans translations to `Localizable.xcstrings`
- No dead code, no hidden flags
