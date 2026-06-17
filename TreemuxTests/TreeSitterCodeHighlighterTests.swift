import SwiftUI
import XCTest
@testable import Treemux

final class TreeSitterCodeHighlighterTests: XCTestCase {
    func test_unknownLanguageReturnsPlainAttributedString() {
        let h = TreeSitterCodeHighlighter()
        let out = h.attributed(code: "hello world", languageName: "no-such-lang")
        XCTAssertEqual(String(out.characters), "hello world")
    }

    func test_nilLanguageReturnsPlainAttributedString() {
        let h = TreeSitterCodeHighlighter()
        let out = h.attributed(code: "x = 1", languageName: nil)
        XCTAssertEqual(String(out.characters), "x = 1")
    }

    func test_languageNamedMapsAliases() {
        XCTAssertEqual(TreeSitterCodeHighlighter.language(named: "swift")?.tsName, "swift")
        XCTAssertEqual(TreeSitterCodeHighlighter.language(named: "py")?.tsName, "python")
        XCTAssertEqual(TreeSitterCodeHighlighter.language(named: "js")?.tsName, "javascript")
        XCTAssertNil(TreeSitterCodeHighlighter.language(named: "no-such-lang"))
    }

    func test_swiftCodeProducesAtLeastOneColoredRun() {
        let h = TreeSitterCodeHighlighter()
        let out = h.attributed(code: "func main() {}", languageName: "swift")
        // The full text is preserved...
        XCTAssertEqual(String(out.characters), "func main() {}")
        // ...and at least one run carries a non-nil foreground color (the `func` keyword).
        let hasColoredRun = out.runs.contains { $0.foregroundColor != nil }
        XCTAssertTrue(hasColoredRun, "expected at least one highlighted run for Swift code")
    }
}
