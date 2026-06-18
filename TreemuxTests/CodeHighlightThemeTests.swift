import SwiftUI
import XCTest
@testable import Treemux

final class CodeHighlightThemeTests: XCTestCase {
    private let ansi = Array(repeating: "#123456", count: 16)
    private let ui = ThemeUIColors(
        accent: "#AA0000", accentOnDark: "#AA0001", onAccent: "#FFFFFF",
        window: "#111111", sidebar: "#121212", pane: "#131313",
        paneHeader: "#141414", tabBar: "#151515", statusBar: "#161616",
        selection: "#171717", selectionStroke: nil, hairline: "#181818",
        textPrimary: "#AAAAAA", textSecondary: "#BBBBBB", textMuted: "#CCCCCC",
        success: "#00AA00", warning: "#AAAA00", danger: "#AA0000")
    private var table: [String: Color] { CodeHighlightTheme.table(ansi: ansi, ui: ui) }

    func test_exactCaptureResolves() {
        XCTAssertNotNil(CodeHighlightTheme.color(forCapture: "keyword", in: table))
        XCTAssertNotNil(CodeHighlightTheme.color(forCapture: "string", in: table))
        XCTAssertNotNil(CodeHighlightTheme.color(forCapture: "comment", in: table))
    }

    func test_dottedCaptureFallsBackToPrefix() {
        // "keyword.function" has no exact entry -> falls back to "keyword"
        XCTAssertEqual(
            CodeHighlightTheme.color(forCapture: "keyword.function", in: table),
            CodeHighlightTheme.color(forCapture: "keyword", in: table)
        )
    }

    func test_unknownCaptureReturnsNil() {
        XCTAssertNil(CodeHighlightTheme.color(forCapture: "totally.unknown.capture", in: table))
    }
}
