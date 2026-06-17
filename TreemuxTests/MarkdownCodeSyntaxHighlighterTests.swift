import SwiftUI
import XCTest
@testable import Treemux

final class MarkdownCodeSyntaxHighlighterTests: XCTestCase {
    func test_returnsTextForCode() {
        // Smoke test: the adapter produces a Text without throwing for known + unknown langs.
        let h = MarkdownCodeSyntaxHighlighter()
        _ = h.highlightCode("func f() {}", language: "swift")
        _ = h.highlightCode("plain text", language: nil)
        _ = h.highlightCode("x", language: "no-such-lang")
    }
}
