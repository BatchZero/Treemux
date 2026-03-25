//
//  ThemeManager.swift
//  Treemux
//

import Foundation
import SwiftUI

/// Manages theme loading, selection, and color publishing for the entire app.
@MainActor
final class ThemeManager: ObservableObject {

    /// Currently active theme.
    @Published private(set) var activeTheme: ThemeDefinition

    /// All available themes (built-in + user custom).
    @Published private(set) var availableThemes: [ThemeDefinition] = []

    /// Directory for user custom themes.
    private let themesDirectory: URL

    init(activeThemeID: String = "treemux-dark") {
        let baseDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".treemux/themes", isDirectory: true)
        self.themesDirectory = baseDir

        // Start with the requested built-in theme (or fallback to dark)
        self.activeTheme = ThemeDefinition.builtInThemes.first { $0.id == activeThemeID }
            ?? .treemuxDark

        loadAvailableThemes()
    }

    // MARK: - Public API

    /// Switch active theme by ID.
    func setActiveTheme(_ themeID: String) {
        if let theme = availableThemes.first(where: { $0.id == themeID }) {
            activeTheme = theme
        }
    }

    /// Reload themes from disk.
    func reloadThemes() {
        ensureBuiltInThemesExist()
        loadAvailableThemes()
        // Re-resolve active theme in case it was updated on disk
        if let refreshed = availableThemes.first(where: { $0.id == activeTheme.id }) {
            activeTheme = refreshed
        }
    }

    // MARK: - Resolved SwiftUI Colors

    var sidebarBackground: Color { Color(hex: activeTheme.ui.sidebarBackground) }
    var sidebarForeground: Color { Color(hex: activeTheme.ui.sidebarForeground) }
    var sidebarSelection: Color { Color(hex: activeTheme.ui.sidebarSelection) }
    var tabBarBackground: Color { Color(hex: activeTheme.ui.tabBarBackground) }
    var paneBackground: Color { Color(hex: activeTheme.ui.paneBackground) }
    var paneHeaderBackground: Color { Color(hex: activeTheme.ui.paneHeaderBackground) }
    var dividerColor: Color { Color(hex: activeTheme.ui.dividerColor) }
    var accentColor: Color { Color(hex: activeTheme.ui.accentColor) }
    var statusBarBackground: Color { Color(hex: activeTheme.ui.statusBarBackground) }
    var textPrimary: Color { Color(hex: activeTheme.ui.textPrimary) }
    var textSecondary: Color { Color(hex: activeTheme.ui.textSecondary) }
    var textMuted: Color { Color(hex: activeTheme.ui.textMuted) }
    var successColor: Color { Color(hex: activeTheme.ui.success) }
    var warningColor: Color { Color(hex: activeTheme.ui.warning) }
    var dangerColor: Color { Color(hex: activeTheme.ui.danger) }

    // MARK: - Private

    private func loadAvailableThemes() {
        var themes = ThemeDefinition.builtInThemes

        // Load user custom themes from disk
        let fm = FileManager.default
        if fm.fileExists(atPath: themesDirectory.path) {
            if let files = try? fm.contentsOfDirectory(
                at: themesDirectory,
                includingPropertiesForKeys: nil
            ) {
                let decoder = JSONDecoder()
                for file in files where file.pathExtension == "json" {
                    if let data = try? Data(contentsOf: file),
                       let theme = try? decoder.decode(ThemeDefinition.self, from: data) {
                        // Replace built-in if same ID, or append
                        if let idx = themes.firstIndex(where: { $0.id == theme.id }) {
                            themes[idx] = theme
                        } else {
                            themes.append(theme)
                        }
                    }
                }
            }
        }

        availableThemes = themes
    }

    /// Write built-in theme JSON files to ~/.treemux/themes/ if they don't exist.
    func ensureBuiltInThemesExist() {
        let fm = FileManager.default
        try? fm.createDirectory(at: themesDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for theme in ThemeDefinition.builtInThemes {
            let file = themesDirectory.appendingPathComponent("\(theme.id).json")
            if !fm.fileExists(atPath: file.path) {
                if let data = try? encoder.encode(theme) {
                    try? data.write(to: file)
                }
            }
        }
    }
}
