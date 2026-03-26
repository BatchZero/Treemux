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
