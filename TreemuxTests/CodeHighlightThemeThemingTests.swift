//
//  CodeHighlightThemeThemingTests.swift
//  TreemuxTests
//

import SwiftUI
import XCTest
@testable import Treemux

final class CodeHighlightThemeThemingTests: XCTestCase {

    // 16 distinct ansi hexes so each index is identifiable by value.
    private let ansi = [
        "#000000", "#010101", "#020202", "#030303",
        "#040404", "#050505", "#060606", "#070707",
        "#080808", "#090909", "#0A0A0A", "#0B0B0B",
        "#0C0C0C", "#0D0D0D", "#0E0E0E", "#0F0F0F"
    ]
    private let ui = ThemeUIColors(
        accent: "#AA0000", accentOnDark: "#AA0001", onAccent: "#FFFFFF",
        window: "#111111", sidebar: "#121212", pane: "#131313",
        paneHeader: "#141414", tabBar: "#151515", statusBar: "#161616",
        selection: "#171717", selectionStroke: nil, hairline: "#181818",
        textPrimary: "#AAAAAA", textSecondary: "#BBBBBB", textMuted: "#CCCCCC",
        success: "#00AA00", warning: "#AAAA00", danger: "#AA0000")

    func testResolvedHexMapsRolesToAnsiAndUI() {
        let map = CodeHighlightTheme.resolvedHex(ansi: ansi, ui: ui)
        XCTAssertEqual(map["keyword"], ansi[5])
        XCTAssertEqual(map["operator"], ansi[5])
        XCTAssertEqual(map["string"], ansi[2])
        XCTAssertEqual(map["number"], ansi[3])
        XCTAssertEqual(map["constant"], ansi[3])
        XCTAssertEqual(map["boolean"], ansi[3])
        XCTAssertEqual(map["function"], ansi[4])
        XCTAssertEqual(map["type"], ansi[6])
        XCTAssertEqual(map["attribute"], ansi[6])
        XCTAssertEqual(map["label"], ansi[3])
        XCTAssertEqual(map["tag"], ansi[5])
        XCTAssertEqual(map["comment"], ui.textMuted)
        XCTAssertEqual(map["variable"], ui.textPrimary)
        XCTAssertEqual(map["property"], ui.textPrimary)
        XCTAssertEqual(map["punctuation"], ui.textSecondary)
    }

    func testMatchLongestPrefix() {
        let table = ["keyword": "K", "keyword.function": "KF"]
        XCTAssertEqual(CodeHighlightTheme.match(capture: "keyword.function", in: table), "KF")
        XCTAssertEqual(CodeHighlightTheme.match(capture: "keyword.return", in: table), "K")
        XCTAssertEqual(CodeHighlightTheme.match(capture: "string", in: table), nil)
    }

    func testTableProducesColorsForKnownCaptures() {
        let table = CodeHighlightTheme.table(ansi: ansi, ui: ui)
        XCTAssertEqual(table["keyword"], Color(hex: ansi[5]))
        XCTAssertNotNil(CodeHighlightTheme.color(forCapture: "string.special", in: table))
    }
}
