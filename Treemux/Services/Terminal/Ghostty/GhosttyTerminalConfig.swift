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
        lines.append("cursor-style = \(cursorStyle)")
        return lines
    }
}
