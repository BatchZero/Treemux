//
//  Theme.swift
//  Treemux
//

import Foundation

// MARK: - Hex color validation

/// Validates hex color strings in #RGB / #RRGGBB / #RRGGBBAA form (# optional).
enum HexColor {
    static func isValid(_ raw: String) -> Bool {
        let s = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard s.count == 3 || s.count == 6 || s.count == 8 else { return false }
        return s.allSatisfy { $0.isHexDigit }
    }
}

// MARK: - Theme value types

/// App UI semantic colors. Field names follow DESIGN.md vocabulary.
struct ThemeUIColors: Codable, Equatable {
    let accent: String
    let accentOnDark: String
    let onAccent: String
    let window: String
    let sidebar: String
    let pane: String
    let paneHeader: String
    let tabBar: String
    let statusBar: String
    let selection: String
    let selectionStroke: String?   // optional -> falls back to accent
    let hairline: String
    let textPrimary: String
    let textSecondary: String
    let textMuted: String
    let success: String
    let warning: String
    let danger: String
}

/// Terminal colors consumed by Ghostty.
struct ThemeTerminalColors: Codable, Equatable {
    let foreground: String
    let background: String
    let cursor: String
    let cursorText: String?     // optional
    let selection: String
    let selectionText: String?  // optional
    let ansi: [String]          // exactly 16
}

/// A complete theme: metadata + UI colors + terminal colors.
struct Theme: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let author: String?
    let appearance: String      // "dark" | "light"
    let ui: ThemeUIColors
    let terminal: ThemeTerminalColors
}

// MARK: - Validation

enum ThemeValidationError: Error, Equatable {
    case badHex(field: String, value: String)
    case wrongAnsiCount(Int)
    case badAppearance(String)
}

extension Theme {
    /// Validates every color field, the appearance value, and the ansi count. Throws on first problem.
    func validate() throws {
        guard appearance == "dark" || appearance == "light" else {
            throw ThemeValidationError.badAppearance(appearance)
        }

        let uiFields: [(String, String)] = [
            ("ui.accent", ui.accent),
            ("ui.accentOnDark", ui.accentOnDark),
            ("ui.onAccent", ui.onAccent),
            ("ui.window", ui.window),
            ("ui.sidebar", ui.sidebar),
            ("ui.pane", ui.pane),
            ("ui.paneHeader", ui.paneHeader),
            ("ui.tabBar", ui.tabBar),
            ("ui.statusBar", ui.statusBar),
            ("ui.selection", ui.selection),
            ("ui.hairline", ui.hairline),
            ("ui.textPrimary", ui.textPrimary),
            ("ui.textSecondary", ui.textSecondary),
            ("ui.textMuted", ui.textMuted),
            ("ui.success", ui.success),
            ("ui.warning", ui.warning),
            ("ui.danger", ui.danger)
        ]
        for (field, value) in uiFields where !HexColor.isValid(value) {
            throw ThemeValidationError.badHex(field: field, value: value)
        }
        if let stroke = ui.selectionStroke, !HexColor.isValid(stroke) {
            throw ThemeValidationError.badHex(field: "ui.selectionStroke", value: stroke)
        }

        guard terminal.ansi.count == 16 else {
            throw ThemeValidationError.wrongAnsiCount(terminal.ansi.count)
        }
        var termFields: [(String, String)] = [
            ("terminal.foreground", terminal.foreground),
            ("terminal.background", terminal.background),
            ("terminal.cursor", terminal.cursor),
            ("terminal.selection", terminal.selection)
        ]
        if let c = terminal.cursorText { termFields.append(("terminal.cursorText", c)) }
        if let s = terminal.selectionText { termFields.append(("terminal.selectionText", s)) }
        for (i, hex) in terminal.ansi.enumerated() {
            termFields.append(("terminal.ansi[\(i)]", hex))
        }
        for (field, value) in termFields where !HexColor.isValid(value) {
            throw ThemeValidationError.badHex(field: field, value: value)
        }
    }
}
