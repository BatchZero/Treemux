//
//  DesignTokensTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class DesignTokensTests: XCTestCase {

    func testCorePaletteHex() {
        XCTAssertEqual(DesignTokens.Hex.ink, "#13161D")
        XCTAssertEqual(DesignTokens.Hex.panel, "#191D26")
        XCTAssertEqual(DesignTokens.Hex.surface, "#232936")
        XCTAssertEqual(DesignTokens.Hex.line, "#2C333F")
    }

    func testTextRampHex() {
        XCTAssertEqual(DesignTokens.Hex.text, "#D7DCE4")
        XCTAssertEqual(DesignTokens.Hex.muted, "#7C8694")
        XCTAssertEqual(DesignTokens.Hex.faint, "#525B69")
    }

    func testSemanticAccentsHex() {
        XCTAssertEqual(DesignTokens.Hex.shell, "#54D38B")
        XCTAssertEqual(DesignTokens.Hex.files, "#5BA6F2")
    }

    func testTabAccentMapping() {
        XCTAssertEqual(DesignTokens.tabAccentHex(for: .fileBrowser), DesignTokens.Hex.files)
        XCTAssertEqual(DesignTokens.tabAccentHex(for: .terminal), DesignTokens.Hex.shell)
    }

    func testTypeAccentPaletteHex() {
        XCTAssertEqual(DesignTokens.Hex.accentOrange, "#E8865A")
        XCTAssertEqual(DesignTokens.Hex.accentAmber,  "#E2A55C")
        XCTAssertEqual(DesignTokens.Hex.accentGreen,  "#5FC98A")
        XCTAssertEqual(DesignTokens.Hex.accentViolet, "#A98BFA")
    }
}
