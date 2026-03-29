//
//  ShortcutAction.swift
//  Treemux
//

import Foundation

// MARK: - Shortcut Category

enum ShortcutCategory: String, CaseIterable, Hashable, Identifiable {
    case general
    case tabs
    case panes
    case window

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .tabs: return "Tabs"
        case .panes: return "Panes"
        case .window: return "Window"
        }
    }
}

// MARK: - Shortcut Action

enum ShortcutAction: String, CaseIterable, Hashable, Identifiable {
    case openSettings
    case commandPalette
    case toggleSidebar
    case openProject
    case newTab
    case closeTab
    case nextTab
    case previousTab
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
        case .newTab, .closeTab, .nextTab, .previousTab:
            return .tabs
        case .splitHorizontal, .splitVertical, .closePane,
             .focusNextPane, .focusPreviousPane, .zoomPane, .newClaudeCode:
            return .panes
        }
    }

    var title: String {
        switch self {
        case .openSettings: return "Settings"
        case .commandPalette: return "Command Palette"
        case .toggleSidebar: return "Toggle Sidebar"
        case .openProject: return "Open Project"
        case .newTab: return "New Tab"
        case .closeTab: return "Close Tab"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
        case .splitHorizontal: return "Split Down"
        case .splitVertical: return "Split Right"
        case .closePane: return "Close Pane"
        case .focusNextPane: return "Next Pane"
        case .focusPreviousPane: return "Previous Pane"
        case .zoomPane: return "Zoom Pane"
        case .newClaudeCode: return "New Claude Code Session"
        }
    }

    var subtitle: String {
        switch self {
        case .openSettings: return "Open the Treemux settings panel."
        case .commandPalette: return "Search and run commands."
        case .toggleSidebar: return "Show or hide the project sidebar."
        case .openProject: return "Open a directory as a project."
        case .newTab: return "Create a new terminal tab."
        case .closeTab: return "Close the current tab."
        case .nextTab: return "Switch to the next tab."
        case .previousTab: return "Switch to the previous tab."
        case .splitHorizontal: return "Split the focused pane downward."
        case .splitVertical: return "Split the focused pane to the right."
        case .closePane: return "Close the focused pane."
        case .focusNextPane: return "Move focus to the next pane."
        case .focusPreviousPane: return "Move focus to the previous pane."
        case .zoomPane: return "Zoom or unzoom the focused pane."
        case .newClaudeCode: return "Open a new Claude Code terminal."
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
        case .newTab:
            return StoredShortcut(key: "t", command: true, shift: false, option: false, control: false)
        case .closeTab:
            return StoredShortcut(key: "w", command: true, shift: true, option: false, control: false)
        case .nextTab:
            return StoredShortcut(key: "]", command: true, shift: true, option: false, control: false)
        case .previousTab:
            return StoredShortcut(key: "[", command: true, shift: true, option: false, control: false)
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
