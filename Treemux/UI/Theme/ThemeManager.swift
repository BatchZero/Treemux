//
//  ThemeManager.swift
//  Treemux
//

import AppKit
import Foundation
import SwiftUI
import Yams

/// Manages YAML theme loading, selection, and color publishing for the app.
@MainActor
final class ThemeManager: ObservableObject {

    @Published private(set) var activeTheme: Theme
    @Published private(set) var availableThemes: [Theme] = []
    @Published private(set) var loadErrors: [ThemeLoadError] = []

    /// Directory holding all theme `.yaml` files.
    let themesDirectory: URL

    init(activeThemeID: String = "treemux-dark") {
        self.themesDirectory = treemuxStateDirectoryURL()
            .appendingPathComponent("themes", isDirectory: true)

        // Make sure built-ins exist on disk, then load.
        try? BuiltInThemes.ensureInstalled(in: themesDirectory)
        let result = ThemeLoader.load(from: themesDirectory)
        self.availableThemes = result.themes
        self.loadErrors = result.errors

        self.activeTheme = ThemeManager.resolve(
            id: activeThemeID, in: result.themes)
    }

    // MARK: - Loading

    private static func resolve(id: String, in themes: [Theme]) -> Theme {
        if let match = themes.first(where: { $0.id == id }) { return match }
        if let dark = themes.first(where: { $0.id == "treemux-dark" }) { return dark }
        if let first = themes.first { return first }
        return BuiltInThemes.fallbackDark()
    }

    func reloadThemes() {
        let result = ThemeLoader.load(from: themesDirectory)
        availableThemes = result.themes
        loadErrors = result.errors
        // Re-resolve active theme (it may have been deleted/edited).
        activeTheme = ThemeManager.resolve(id: activeTheme.id, in: result.themes)
    }

    func ensureBuiltInThemesExist() {
        try? BuiltInThemes.ensureInstalled(in: themesDirectory)
    }

    // MARK: - Switching

    func setActiveTheme(_ id: String) {
        let resolved = ThemeManager.resolve(id: id, in: availableThemes)
        activeTheme = resolved
        NotificationCenter.default.post(name: .themeDidChange, object: resolved)
    }

    // MARK: - Management

    func importTheme(from url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let theme = try YAMLDecoderShim.decode(text)   // throws on parse/validation
        let destination = themesDirectory
            .appendingPathComponent("\(theme.id).yaml")
        try FileManager.default.createDirectory(
            at: themesDirectory, withIntermediateDirectories: true)
        try text.write(to: destination, atomically: true, encoding: .utf8)
        reloadThemes()
    }

    func deleteTheme(_ id: String) throws {
        // Delete every file in the directory that declares this id
        // (file names are not guaranteed to equal the theme id).
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: themesDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in entries where ["yaml", "yml"].contains(file.pathExtension.lowercased()) {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let theme = try? YAMLDecoderShim.decodeWithoutValidation(text),
               theme.id == id {
                try FileManager.default.removeItem(at: file)
            }
        }
        reloadThemes()
    }

    func resetBuiltIns() {
        try? BuiltInThemes.restore(in: themesDirectory)
        reloadThemes()
    }

    // MARK: - Resolved SwiftUI Colors (accessor names kept stable for views)

    var sidebarBackground: Color { Color(hex: activeTheme.ui.sidebar) }
    var sidebarForeground: Color { Color(hex: activeTheme.ui.textPrimary) }
    var sidebarSelection: Color { Color(hex: activeTheme.ui.selection) }
    var tabBarBackground: Color { Color(hex: activeTheme.ui.tabBar) }
    var paneBackground: Color { Color(hex: activeTheme.ui.pane) }
    var paneHeaderBackground: Color { Color(hex: activeTheme.ui.paneHeader) }
    var dividerColor: Color { Color(hex: activeTheme.ui.hairline) }
    var accentColor: Color { Color(hex: activeTheme.ui.accent) }
    var statusBarBackground: Color { Color(hex: activeTheme.ui.statusBar) }
    var textPrimary: Color { Color(hex: activeTheme.ui.textPrimary) }
    var textSecondary: Color { Color(hex: activeTheme.ui.textSecondary) }
    var textMuted: Color { Color(hex: activeTheme.ui.textMuted) }
    var successColor: Color { Color(hex: activeTheme.ui.success) }
    var warningColor: Color { Color(hex: activeTheme.ui.warning) }
    var dangerColor: Color { Color(hex: activeTheme.ui.danger) }

    // MARK: - Resolved AppKit Colors (NSOutlineView sidebar)

    var sidebarSelectionFillNS: NSColor { NSColor(sidebarSelection) }
    var sidebarSelectionStrokeNS: NSColor {
        if let hex = activeTheme.ui.selectionStroke {
            return NSColor(Color(hex: hex)).withAlphaComponent(0.9)
        }
        return NSColor(accentColor).withAlphaComponent(0.9)
    }

    // MARK: - Window appearance

    var windowAppearance: NSAppearance? {
        switch activeTheme.appearance {
        case "light": return NSAppearance(named: .aqua)
        default: return NSAppearance(named: .darkAqua)
        }
    }

    var nsWindowBackgroundColor: NSColor {
        NSColor(Color(hex: activeTheme.ui.window))
    }
}

/// Small wrapper so ThemeManager doesn't import Yams directly at call sites.
private enum YAMLDecoderShim {
    static func decode(_ text: String) throws -> Theme {
        let theme = try decodeWithoutValidation(text)
        try theme.validate()
        return theme
    }
    static func decodeWithoutValidation(_ text: String) throws -> Theme {
        try YAMLDecoder().decode(Theme.self, from: text)
    }
}
