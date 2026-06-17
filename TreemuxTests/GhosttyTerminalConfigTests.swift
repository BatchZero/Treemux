//
//  GhosttyTerminalConfigTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class GhosttyTerminalConfigTests: XCTestCase {

    private func sampleColors() -> ThemeTerminalColors {
        ThemeTerminalColors(
            foreground: "#C5C8C6",
            background: "#111317",
            cursor: "#C5C8C6",
            cursorText: "#111317",
            selection: "#373B41",
            selectionText: "#C5C8C6",
            ansi: (0..<16).map { _ in "#1D1F21" })
    }

    func testNormalizeExpandsThreeDigit() {
        XCTAssertEqual(GhosttyHex.normalize("#FFF"), "#FFFFFF")
    }

    func testNormalizeStripsAlpha() {
        XCTAssertEqual(GhosttyHex.normalize("#11223344"), "#112233")
    }

    func testNormalizeAddsHash() {
        XCTAssertEqual(GhosttyHex.normalize("418ADE"), "#418ADE")
    }

    func testLinesContainCoreColors() {
        let lines = GhosttyTerminalConfig.lines(for: sampleColors(), cursorStyle: "bar")
        XCTAssertTrue(lines.contains("background = #111317"))
        XCTAssertTrue(lines.contains("foreground = #C5C8C6"))
        XCTAssertTrue(lines.contains("cursor-color = #C5C8C6"))
        XCTAssertTrue(lines.contains("cursor-text = #111317"))
        XCTAssertTrue(lines.contains("selection-background = #373B41"))
        XCTAssertTrue(lines.contains("selection-foreground = #C5C8C6"))
        XCTAssertTrue(lines.contains("cursor-style = bar"))
    }

    func testLinesContainSixteenPaletteEntries() {
        let lines = GhosttyTerminalConfig.lines(for: sampleColors(), cursorStyle: "bar")
        for i in 0..<16 {
            XCTAssertTrue(lines.contains("palette = \(i)=#1D1F21"),
                          "missing palette entry \(i)")
        }
    }

    func testOptionalColorsOmittedWhenNil() {
        let colors = ThemeTerminalColors(
            foreground: "#FFFFFF", background: "#000000", cursor: "#FFFFFF",
            cursorText: nil, selection: "#222222", selectionText: nil,
            ansi: (0..<16).map { _ in "#FFFFFF" })
        let lines = GhosttyTerminalConfig.lines(for: colors, cursorStyle: "block")
        XCTAssertFalse(lines.contains(where: { $0.hasPrefix("cursor-text") }))
        XCTAssertFalse(lines.contains(where: { $0.hasPrefix("selection-foreground") }))
    }
}
