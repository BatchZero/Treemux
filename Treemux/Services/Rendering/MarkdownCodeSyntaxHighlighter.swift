import SwiftUI
import MarkdownUI

/// Bridges our tree-sitter highlighter into MarkdownUI's code-block rendering.
struct MarkdownCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    static let treeSitter = MarkdownCodeSyntaxHighlighter()

    private let highlighter = TreeSitterCodeHighlighter()

    func highlightCode(_ code: String, language: String?) -> Text {
        // Strip a single trailing newline MarkdownUI appends to fenced blocks.
        let trimmed = code.hasSuffix("\n") ? String(code.dropLast()) : code
        let attributed = highlighter.attributed(code: trimmed, languageName: language)
        return Text(attributed)
            .font(DesignFonts.dataLayer(size: 12))
    }
}
