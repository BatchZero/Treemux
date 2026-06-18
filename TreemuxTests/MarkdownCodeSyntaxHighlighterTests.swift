import SwiftUI
import XCTest
@testable import Treemux

final class MarkdownCodeSyntaxHighlighterTests: XCTestCase {
    // Minimal table for construction — colors not under test here.
    private let captureColors: [String: Color] = [:]

    func test_returnsTextForCode() {
        // Smoke test: the adapter produces a Text without throwing for known + unknown langs.
        let h = MarkdownCodeSyntaxHighlighter(
            captureColors: captureColors,
            font: .system(size: 12, design: .monospaced))
        _ = h.highlightCode("func f() {}", language: "swift")
        _ = h.highlightCode("plain text", language: nil)
        _ = h.highlightCode("x", language: "no-such-lang")
    }
}
