//
//  ThemeTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class ThemeTests: XCTestCase {

    func testThemeDefinitionCodableRoundTrip() throws {
        let theme = ThemeDefinition.treemuxDark
        let encoder = JSONEncoder()
        let data = try encoder.encode(theme)
        let decoded = try JSONDecoder().decode(ThemeDefinition.self, from: data)
        XCTAssertEqual(decoded.id, "treemux-dark")
        XCTAssertEqual(decoded.name, "Treemux Dark")
        XCTAssertEqual(decoded.terminal.ansi.count, 16)
    }

    func testLightThemeCodableRoundTrip() throws {
        let theme = ThemeDefinition.treemuxLight
        let data = try JSONEncoder().encode(theme)
        let decoded = try JSONDecoder().decode(ThemeDefinition.self, from: data)
        XCTAssertEqual(decoded.id, "treemux-light")
        XCTAssertEqual(decoded.ui.paneBackground, "#FFFFFF")
    }

    func testBuiltInThemesContainsBoth() {
        let themes = ThemeDefinition.builtInThemes
        XCTAssertEqual(themes.count, 2)
        XCTAssertTrue(themes.contains(where: { $0.id == "treemux-dark" }))
        XCTAssertTrue(themes.contains(where: { $0.id == "treemux-light" }))
    }

    func testTerminalColorsHas16AnsiEntries() {
        XCTAssertEqual(ThemeDefinition.treemuxDark.terminal.ansi.count, 16)
        XCTAssertEqual(ThemeDefinition.treemuxLight.terminal.ansi.count, 16)
    }

    @MainActor
    func testThemeManagerDefaultsToDark() {
        let manager = ThemeManager()
        XCTAssertEqual(manager.activeTheme.id, "treemux-dark")
    }

    @MainActor
    func testThemeManagerSwitchTheme() {
        let manager = ThemeManager()
        manager.setActiveTheme("treemux-light")
        XCTAssertEqual(manager.activeTheme.id, "treemux-light")
    }

    @MainActor
    func testThemeManagerFallbackForUnknownID() {
        let manager = ThemeManager(activeThemeID: "nonexistent")
        XCTAssertEqual(manager.activeTheme.id, "treemux-dark")
    }
}
