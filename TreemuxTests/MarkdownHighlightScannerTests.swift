//
//  MarkdownHighlightScannerTests.swift
//  TreemuxTests
//

import CodeEditSourceEditor
import CodeEditTextView
import XCTest
@testable import Treemux

final class MarkdownHighlightScannerTests: XCTestCase {
    private func elements(_ text: String) -> [MarkdownElement] {
        MarkdownHighlightScanner.scan(text).map(\.element)
    }

    private func hasElement(_ text: String, _ element: MarkdownElement, over substring: String) -> Bool {
        let expected = (text as NSString).range(of: substring)
        return MarkdownHighlightScanner.scan(text).contains {
            $0.element == element && NSIntersectionRange($0.range, expected).length > 0
        }
    }

    func testATXHeading() {
        XCTAssertTrue(hasElement("# Title", .heading, over: "# Title"))
        XCTAssertTrue(hasElement("### Sub", .heading, over: "### Sub"))
    }

    func testSetextHeading() {
        let markdown = "Title\n====="
        XCTAssertTrue(hasElement(markdown, .heading, over: "Title"))
        XCTAssertTrue(hasElement(markdown, .heading, over: "====="))
    }

    func testStrong() {
        XCTAssertTrue(hasElement("a **bold** b", .strong, over: "**bold**"))
        XCTAssertTrue(hasElement("a __bold__ b", .strong, over: "__bold__"))
    }

    func testEmphasis() {
        XCTAssertTrue(hasElement("a *em* b", .emphasis, over: "*em*"))
        XCTAssertTrue(hasElement("a _em_ b", .emphasis, over: "_em_"))
    }

    func testInlineCode() {
        XCTAssertTrue(hasElement("use `code` here", .code, over: "`code`"))
    }

    func testBacktickFencedCode() {
        let markdown = "```swift\nlet x = 1\n```"
        XCTAssertTrue(hasElement(markdown, .code, over: "let x = 1"))
    }

    func testTildeFencedCode() {
        let markdown = "~~~\n*not emphasis*\n~~~"
        XCTAssertTrue(hasElement(markdown, .code, over: "*not emphasis*"))
        XCTAssertFalse(MarkdownHighlightScanner.scan(markdown).contains { $0.element == .emphasis })
    }

    func testLink() {
        XCTAssertTrue(hasElement("see [docs](https://x.y)", .link, over: "[docs](https://x.y)"))
        XCTAssertTrue(hasElement("see <https://x.y>", .link, over: "<https://x.y>"))
    }

    func testListMarkers() {
        XCTAssertTrue(hasElement("- item", .listMarker, over: "- "))
        XCTAssertTrue(hasElement("* item", .listMarker, over: "* "))
        XCTAssertTrue(hasElement("1. item", .listMarker, over: "1. "))
        XCTAssertTrue(hasElement("2) item", .listMarker, over: "2) "))
    }

    func testBlockquote() {
        XCTAssertTrue(hasElement("> quote", .blockquote, over: ">"))
    }

    func testPlainTextHasNoElements() {
        XCTAssertTrue(elements("just a normal paragraph.").isEmpty)
    }

    func testCodeSpanSuppressesEmphasisInside() {
        let markdown = "`a*b*c`"
        XCTAssertFalse(MarkdownHighlightScanner.scan(markdown).contains { $0.element == .emphasis })
    }

    func testRangesUseUTF16Offsets() {
        let markdown = "emoji 🦦 **bold**"
        let expected = (markdown as NSString).range(of: "**bold**")
        XCTAssertTrue(MarkdownHighlightScanner.scan(markdown).contains {
            $0.element == .strong && $0.range == expected
        })
    }
}

final class MarkdownHighlightMappingTests: XCTestCase {
    func testElementToCaptureMapping() {
        XCTAssertEqual(MarkdownHighlightProvider.captureName(for: .heading), .keyword)
        XCTAssertEqual(MarkdownHighlightProvider.captureName(for: .strong), .type)
        XCTAssertEqual(MarkdownHighlightProvider.captureName(for: .emphasis), .comment)
        XCTAssertEqual(MarkdownHighlightProvider.captureName(for: .code), .string)
        XCTAssertEqual(MarkdownHighlightProvider.captureName(for: .link), .variable)
        XCTAssertEqual(MarkdownHighlightProvider.captureName(for: .listMarker), .number)
        XCTAssertEqual(MarkdownHighlightProvider.captureName(for: .blockquote), .typeAlternate)
    }

    @MainActor
    func testProviderReturnsHighlightsInSourceOrder() {
        let markdown = "**bold** then `code`"

        let highlights = queryHighlights(markdown, range: NSRange(location: 0, length: 20))

        XCTAssertEqual(
            highlights,
            [
                HighlightRange(range: NSRange(location: 0, length: 8), capture: .type),
                HighlightRange(range: NSRange(location: 14, length: 6), capture: .string),
            ]
        )
    }

    @MainActor
    func testProviderClipsHighlightsToRequestedRange() {
        let markdown = "xx **bold** yy"
        let requestedRange = NSRange(location: 5, length: 3)

        let highlights = queryHighlights(markdown, range: requestedRange)

        XCTAssertEqual(
            highlights,
            [HighlightRange(range: requestedRange, capture: .type)]
        )
    }

    @MainActor
    private func queryHighlights(_ markdown: String, range: NSRange) -> [HighlightRange] {
        let textView = TextView(string: markdown)
        var highlights: [HighlightRange] = []

        MarkdownHighlightProvider().queryHighlightsFor(textView: textView, range: range) { result in
            switch result {
            case .success(let value):
                highlights = value
            case .failure(let error):
                XCTFail("Unexpected highlight error: \(error)")
            }
        }

        return highlights
    }
}
