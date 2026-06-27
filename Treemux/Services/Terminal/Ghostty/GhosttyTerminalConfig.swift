//
//  GhosttyTerminalConfig.swift
//  Treemux
//

import Foundation

/// Normalizes theme hex strings into the `#RRGGBB` form ghostty expects.
enum GhosttyHex {
    static func normalize(_ raw: String) -> String {
        var s = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()   // RGB -> RRGGBB
        } else if s.count == 8 {
            s = String(s.prefix(6))               // drop alpha
        }
        return "#\(s.uppercased())"
    }
}

/// Builds ghostty config lines from a theme's terminal colors.
enum GhosttyTerminalConfig {
    static func lines(for colors: ThemeTerminalColors, cursorStyle: String) -> [String] {
        var lines: [String] = []
        lines.append("background = \(GhosttyHex.normalize(colors.background))")
        lines.append("foreground = \(GhosttyHex.normalize(colors.foreground))")
        lines.append("cursor-color = \(GhosttyHex.normalize(colors.cursor))")
        if let cursorText = colors.cursorText {
            lines.append("cursor-text = \(GhosttyHex.normalize(cursorText))")
        }
        lines.append("selection-background = \(GhosttyHex.normalize(colors.selection))")
        if let selectionText = colors.selectionText {
            lines.append("selection-foreground = \(GhosttyHex.normalize(selectionText))")
        }
        for (i, hex) in colors.ansi.enumerated() {
            lines.append("palette = \(i)=\(GhosttyHex.normalize(hex))")
        }
        // Light themes intentionally map "bright white" (ANSI 15) and the default
        // foreground to the same dark color so white text stays readable on the light
        // background. The downside: when a program paints bright white onto a dark fill
        // (e.g. Claude Code's reverse-video user message box) the cell becomes
        // dark-on-dark (contrast ratio 1.0) and unreadable. A static palette cannot
        // satisfy both cases, so we let ghostty raise the foreground at render time to
        // guarantee a minimum contrast ratio against whatever the actual cell background
        // is. Normal dark-on-light text is already well above this threshold and stays
        // untouched.
        lines.append("minimum-contrast = 1.4")
        lines.append("cursor-style = \(cursorStyle)")
        return lines
    }
}
