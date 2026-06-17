//
//  ThemeModelTests.swift
//  TreemuxTests
//

import XCTest
import Yams
@testable import Treemux

final class ThemeModelTests: XCTestCase {

    private let validYAML = """
    id: sample
    name: Sample
    author: tester
    appearance: dark
    ui:
      accent: "#418ADE"
      accentOnDark: "#2997FF"
      onAccent: "#FFFFFF"
      window: "#0F1114"
      sidebar: "#0F1114"
      pane: "#111317"
      paneHeader: "#151820"
      tabBar: "#0F1114"
      statusBar: "#0F1114"
      selection: "#1A2A42"
      selectionStroke: "#418ADE"
      hairline: "#FFFFFF1A"
      textPrimary: "#F0F0F2"
      textSecondary: "#C5C8C6"
      textMuted: "#7A7A7A"
      success: "#B5BD68"
      warning: "#F0C674"
      danger: "#CC6666"
    terminal:
      foreground: "#C5C8C6"
      background: "#111317"
      cursor: "#C5C8C6"
      selection: "#373B41"
      ansi:
        - "#1D1F21"
        - "#CC6666"
        - "#B5BD68"
        - "#F0C674"
        - "#81A2BE"
        - "#B294BB"
        - "#8ABEB7"
        - "#C5C8C6"
        - "#969896"
        - "#CC6666"
        - "#B5BD68"
        - "#F0C674"
        - "#81A2BE"
        - "#B294BB"
        - "#8ABEB7"
        - "#FFFFFF"
    """

    func testDecodeValidTheme() throws {
        let theme = try YAMLDecoder().decode(Theme.self, from: validYAML)
        XCTAssertEqual(theme.id, "sample")
        XCTAssertEqual(theme.ui.accent, "#418ADE")
        XCTAssertNil(theme.terminal.cursorText)
        XCTAssertEqual(theme.terminal.ansi.count, 16)
        XCTAssertNoThrow(try theme.validate())
    }

    func testValidateRejectsWrongAnsiCount() throws {
        let shortYAML = validYAML.replacingOccurrences(
            of: "    - \"#FFFFFF\"", with: "")  // remove last ansi entry -> 15
        let theme = try YAMLDecoder().decode(Theme.self, from: shortYAML)
        XCTAssertThrowsError(try theme.validate()) { error in
            XCTAssertEqual(error as? ThemeValidationError, .wrongAnsiCount(15))
        }
    }

    func testValidateRejectsBadHex() throws {
        let badYAML = validYAML.replacingOccurrences(
            of: "accent: \"#418ADE\"", with: "accent: \"not-a-color\"")
        let theme = try YAMLDecoder().decode(Theme.self, from: badYAML)
        XCTAssertThrowsError(try theme.validate()) { error in
            XCTAssertEqual(error as? ThemeValidationError, .badHex(field: "ui.accent", value: "not-a-color"))
        }
    }

    func testHexValidatorAcceptsThreeSixEight() {
        XCTAssertTrue(HexColor.isValid("#FFF"))
        XCTAssertTrue(HexColor.isValid("#FFFFFF"))
        XCTAssertTrue(HexColor.isValid("#FFFFFF1A"))
        XCTAssertTrue(HexColor.isValid("418ADE"))
        XCTAssertFalse(HexColor.isValid("#GG0000"))
        XCTAssertFalse(HexColor.isValid("#FF"))
    }

    func testValidateRejectsBadAppearance() throws {
        // "drak" is a typo — neither "dark" nor "light"
        let badAppearanceYAML = validYAML.replacingOccurrences(
            of: "appearance: dark", with: "appearance: drak")
        let theme = try YAMLDecoder().decode(Theme.self, from: badAppearanceYAML)
        XCTAssertThrowsError(try theme.validate()) { error in
            XCTAssertEqual(error as? ThemeValidationError, .badAppearance("drak"))
        }
    }

    func testValidateAcceptsDarkAndLight() throws {
        // "dark" is valid
        let darkTheme = try YAMLDecoder().decode(Theme.self, from: validYAML)
        XCTAssertNoThrow(try darkTheme.validate())

        // "light" is also valid
        let lightYAML = validYAML.replacingOccurrences(
            of: "appearance: dark", with: "appearance: light")
        let lightTheme = try YAMLDecoder().decode(Theme.self, from: lightYAML)
        XCTAssertNoThrow(try lightTheme.validate())
    }
}
