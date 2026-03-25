//
//  ThemeDefinition.swift
//  Treemux
//

import Foundation

// MARK: - Theme Definition

/// A complete theme definition for Treemux, covering terminal ANSI colors and UI chrome colors.
struct ThemeDefinition: Codable, Identifiable {
    let id: String
    let name: String
    let author: String?
    let terminal: TerminalColors
    let ui: UIColors
    let font: FontConfig?
}

/// Terminal ANSI and base colors used by Ghostty.
struct TerminalColors: Codable {
    let foreground: String
    let background: String
    let cursor: String
    let selection: String
    let ansi: [String] // 16 colors (8 normal + 8 bright)
}

/// UI chrome colors for sidebar, panes, toolbar, etc.
struct UIColors: Codable {
    let sidebarBackground: String
    let sidebarForeground: String
    let sidebarSelection: String
    let tabBarBackground: String
    let paneBackground: String
    let paneHeaderBackground: String
    let dividerColor: String
    let accentColor: String
    let statusBarBackground: String
    let textPrimary: String
    let textSecondary: String
    let textMuted: String
    let success: String
    let warning: String
    let danger: String
}

/// Optional font configuration within a theme.
struct FontConfig: Codable {
    let family: String?
    let size: Int?
}

// MARK: - Built-in Themes

extension ThemeDefinition {

    /// Deep blue-gray dark theme optimized for long coding sessions.
    static let treemuxDark = ThemeDefinition(
        id: "treemux-dark",
        name: "Treemux Dark",
        author: "BatchZero",
        terminal: TerminalColors(
            foreground: "#C5C8C6",
            background: "#111317",
            cursor: "#C5C8C6",
            selection: "#373B41",
            ansi: [
                "#1D1F21", "#CC6666", "#B5BD68", "#F0C674",
                "#81A2BE", "#B294BB", "#8ABEB7", "#C5C8C6",
                "#969896", "#CC6666", "#B5BD68", "#F0C674",
                "#81A2BE", "#B294BB", "#8ABEB7", "#FFFFFF"
            ]
        ),
        ui: UIColors(
            sidebarBackground: "#121417",
            sidebarForeground: "#C5C8C6",
            sidebarSelection: "#1C2838",
            tabBarBackground: "#0F1114",
            paneBackground: "#111317",
            paneHeaderBackground: "#121417",
            dividerColor: "#FFFFFF14",
            accentColor: "#418ADE",
            statusBarBackground: "#0F1114",
            textPrimary: "#E5E5E7",
            textSecondary: "#FFFFFFBD",
            textMuted: "#FFFFFF94",
            success: "#4FD67B",
            warning: "#F0A830",
            danger: "#EB6B57"
        ),
        font: nil
    )

    /// Clean light theme for daytime use.
    static let treemuxLight = ThemeDefinition(
        id: "treemux-light",
        name: "Treemux Light",
        author: "BatchZero",
        terminal: TerminalColors(
            foreground: "#1D1F21",
            background: "#FFFFFF",
            cursor: "#1D1F21",
            selection: "#D6D6D6",
            ansi: [
                "#1D1F21", "#CC6666", "#718C00", "#EAB700",
                "#4271AE", "#8959A8", "#3E999F", "#FFFFFF",
                "#969896", "#CC6666", "#718C00", "#EAB700",
                "#4271AE", "#8959A8", "#3E999F", "#FFFFFF"
            ]
        ),
        ui: UIColors(
            sidebarBackground: "#F5F5F7",
            sidebarForeground: "#1D1F21",
            sidebarSelection: "#D0E0F0",
            tabBarBackground: "#EDEDEF",
            paneBackground: "#FFFFFF",
            paneHeaderBackground: "#F5F5F7",
            dividerColor: "#00000014",
            accentColor: "#2F7DE1",
            statusBarBackground: "#EDEDEF",
            textPrimary: "#1D1F21",
            textSecondary: "#00000096",
            textMuted: "#0000005E",
            success: "#34A853",
            warning: "#D99116",
            danger: "#D93025"
        ),
        font: nil
    )

    /// All built-in themes.
    static let builtInThemes: [ThemeDefinition] = [treemuxDark, treemuxLight]
}
