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
