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
    /// The macOS appearance this theme targets: "dark" or "light".
    let appearance: String
    let terminal: TerminalColors
    let ui: UIColors
    let font: FontConfig?
}

// Backward-compatible decoding: defaults `appearance` to "dark" when missing.
extension ThemeDefinition {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        appearance = try container.decodeIfPresent(String.self, forKey: .appearance) ?? "dark"
        terminal = try container.decode(TerminalColors.self, forKey: .terminal)
        ui = try container.decode(UIColors.self, forKey: .ui)
        font = try container.decodeIfPresent(FontConfig.self, forKey: .font)
    }
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
    /// Window background color for NSWindow / toolbar tinting.
    let windowBackground: String
}

// Backward-compatible decoding: defaults `windowBackground` to `paneBackground` when missing.
extension UIColors {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sidebarBackground = try container.decode(String.self, forKey: .sidebarBackground)
        sidebarForeground = try container.decode(String.self, forKey: .sidebarForeground)
        sidebarSelection = try container.decode(String.self, forKey: .sidebarSelection)
        tabBarBackground = try container.decode(String.self, forKey: .tabBarBackground)
        paneBackground = try container.decode(String.self, forKey: .paneBackground)
        paneHeaderBackground = try container.decode(String.self, forKey: .paneHeaderBackground)
        dividerColor = try container.decode(String.self, forKey: .dividerColor)
        accentColor = try container.decode(String.self, forKey: .accentColor)
        statusBarBackground = try container.decode(String.self, forKey: .statusBarBackground)
        textPrimary = try container.decode(String.self, forKey: .textPrimary)
        textSecondary = try container.decode(String.self, forKey: .textSecondary)
        textMuted = try container.decode(String.self, forKey: .textMuted)
        success = try container.decode(String.self, forKey: .success)
        warning = try container.decode(String.self, forKey: .warning)
        danger = try container.decode(String.self, forKey: .danger)
        windowBackground = try container.decodeIfPresent(String.self, forKey: .windowBackground) ?? paneBackground
    }
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
        appearance: "dark",
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
            sidebarBackground: "#0F1114",
            sidebarForeground: "#E5E5E7",
            sidebarSelection: "#1A2A42",
            tabBarBackground: "#0F1114",
            paneBackground: "#111317",
            paneHeaderBackground: "#151820",
            dividerColor: "#FFFFFF1A",
            accentColor: "#418ADE",
            statusBarBackground: "#0F1114",
            textPrimary: "#F0F0F2",
            textSecondary: "#A0A8B8",
            textMuted: "#6B7280",
            success: "#4FD67B",
            warning: "#F0A830",
            danger: "#EB6B57",
            windowBackground: "#111317"
        ),
        font: nil
    )

    /// Clean light theme for daytime use.
    static let treemuxLight = ThemeDefinition(
        id: "treemux-light",
        name: "Treemux Light",
        author: "BatchZero",
        appearance: "light",
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
            textSecondary: "#6B7280",
            textMuted: "#9CA3AF",
            success: "#34A853",
            warning: "#D99116",
            danger: "#D93025",
            windowBackground: "#FFFFFF"
        ),
        font: nil
    )

    /// All built-in themes.
    static let builtInThemes: [ThemeDefinition] = [treemuxDark, treemuxLight]
}
