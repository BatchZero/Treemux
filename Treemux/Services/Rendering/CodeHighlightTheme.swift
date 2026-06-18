import SwiftUI

/// Builds a tree-sitter capture → color map from the active theme.
/// Structural roles come from `ui`; syntax accents from the 16-entry `ansi`.
/// Matching is longest-prefix on dot-separated capture components
/// (e.g. "keyword.function" -> "keyword" if no exact entry exists).
enum CodeHighlightTheme {

    /// Role → hex map resolved from a theme's ansi palette + ui colors.
    static func resolvedHex(ansi: [String], ui: ThemeUIColors) -> [String: String] {
        func a(_ i: Int) -> String { ansi.indices.contains(i) ? ansi[i] : ui.textPrimary }
        return [
            "keyword": a(5),
            "operator": a(5),
            "string": a(2),
            "number": a(3),
            "constant": a(3),
            "boolean": a(3),
            "comment": ui.textMuted,
            "function": a(4),
            "type": a(6),
            "attribute": a(6),
            "variable": ui.textPrimary,
            "property": ui.textPrimary,
            "punctuation": ui.textSecondary,
            "label": a(3),
            "tag": a(5)
        ]
    }

    /// Capture → Color table for the highlighter.
    static func table(ansi: [String], ui: ThemeUIColors) -> [String: Color] {
        resolvedHex(ansi: ansi, ui: ui).mapValues { Color(hex: $0) }
    }

    /// Longest-prefix match on dot-separated capture components.
    static func match<V>(capture name: String, in table: [String: V]) -> V? {
        var components = name.split(separator: ".").map(String.init)
        while !components.isEmpty {
            if let value = table[components.joined(separator: ".")] {
                return value
            }
            components.removeLast()
        }
        return nil
    }

    static func color(forCapture name: String, in table: [String: Color]) -> Color? {
        match(capture: name, in: table)
    }
}
