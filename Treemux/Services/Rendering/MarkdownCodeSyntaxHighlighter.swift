import SwiftUI
import MarkdownUI

/// Bridges our tree-sitter highlighter into MarkdownUI's code-block rendering.
/// Constructed per render with the active theme's capture colors + code font.
struct MarkdownCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    private let highlighter: TreeSitterCodeHighlighter
    private let font: Font

    init(captureColors: [String: Color], font: Font) {
        self.highlighter = TreeSitterCodeHighlighter(captureColors: captureColors)
        self.font = font
    }

    func highlightCode(_ code: String, language: String?) -> Text {
        // Strip a single trailing newline MarkdownUI appends to fenced blocks.
        let trimmed = code.hasSuffix("\n") ? String(code.dropLast()) : code
        let attributed = highlighter.attributed(code: trimmed, languageName: language)
        return Text(attributed).font(font)
    }
}
