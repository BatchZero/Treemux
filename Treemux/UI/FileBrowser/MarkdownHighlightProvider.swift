//
//  MarkdownHighlightProvider.swift
//  Treemux
//

import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView

/// Custom source highlighter for Markdown. The pinned source editor drops the
/// grammar's `text.*` captures, so this provider maps the scanner's elements to
/// supported capture slots styled by the Markdown-specific editor theme.
final class MarkdownHighlightProvider: HighlightProviding {
    static func captureName(for element: MarkdownElement) -> CaptureName {
        switch element {
        case .heading: return .keyword
        case .strong: return .type
        case .emphasis: return .comment
        case .code: return .string
        case .link: return .variable
        case .listMarker: return .number
        case .blockquote: return .typeAlternate
        }
    }

    func setUp(textView: TextView, codeLanguage: CodeLanguage) { }

    func willApplyEdit(textView: TextView, range: NSRange) { }

    func applyEdit(
        textView: TextView,
        range: NSRange,
        delta: Int,
        completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void
    ) {
        // Fence edits can change the meaning of every later line, so invalidate
        // from the edit point through the current end of the document.
        let length = (textView.string as NSString).length
        let start = min(range.location, length)
        completion(.success(IndexSet(integersIn: start..<length)))
    }

    func queryHighlightsFor(
        textView: TextView,
        range: NSRange,
        completion: @escaping @MainActor (Result<[HighlightRange], Error>) -> Void
    ) {
        let highlights: [HighlightRange] = MarkdownHighlightScanner.scan(textView.string).compactMap { token -> HighlightRange? in
            let intersection = NSIntersectionRange(token.range, range)
            guard intersection.length > 0 else { return nil }
            return HighlightRange(range: intersection, capture: Self.captureName(for: token.element))
        }
        completion(.success(highlights))
    }
}
