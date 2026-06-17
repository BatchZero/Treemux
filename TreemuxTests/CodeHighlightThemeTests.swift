import SwiftUI
import XCTest
@testable import Treemux

final class CodeHighlightThemeTests: XCTestCase {
    func test_exactCaptureResolves() {
        XCTAssertNotNil(CodeHighlightTheme.color(forCapture: "keyword"))
        XCTAssertNotNil(CodeHighlightTheme.color(forCapture: "string"))
        XCTAssertNotNil(CodeHighlightTheme.color(forCapture: "comment"))
    }

    func test_dottedCaptureFallsBackToPrefix() {
        // "keyword.function" has no exact entry -> falls back to "keyword"
        XCTAssertEqual(
            CodeHighlightTheme.color(forCapture: "keyword.function"),
            CodeHighlightTheme.color(forCapture: "keyword")
        )
    }

    func test_unknownCaptureReturnsNil() {
        XCTAssertNil(CodeHighlightTheme.color(forCapture: "totally.unknown.capture"))
    }
}
