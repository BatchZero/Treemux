import SwiftUI

/// Maps tree-sitter highlight capture names to colors, reusing the Phosphor design tokens.
/// Matching is longest-prefix on dot-separated capture components
/// (e.g. "keyword.function" -> "keyword" if no exact entry exists).
enum CodeHighlightTheme {
    private static let table: [String: Color] = [
        "keyword": DesignTokens.accentViolet,
        "operator": DesignTokens.accentViolet,
        "string": DesignTokens.accentGreen,
        "number": DesignTokens.accentAmber,
        "constant": DesignTokens.accentAmber,
        "boolean": DesignTokens.accentAmber,
        "comment": DesignTokens.faint,
        "function": DesignTokens.files,
        "type": DesignTokens.accentOrange,
        "variable": DesignTokens.text,
        "property": DesignTokens.text,
        "punctuation": DesignTokens.muted,
        "label": DesignTokens.accentAmber,
        "attribute": DesignTokens.accentOrange,
        "tag": DesignTokens.accentViolet
    ]

    static func color(forCapture name: String) -> Color? {
        var components = name.split(separator: ".").map(String.init)
        while !components.isEmpty {
            if let color = table[components.joined(separator: ".")] {
                return color
            }
            components.removeLast()
        }
        return nil
    }
}
