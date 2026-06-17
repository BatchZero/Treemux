//
//  ThemeTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class ThemeTests: XCTestCase {

    @MainActor
    func testDefaultsToDark() {
        let manager = ThemeManager()
        XCTAssertEqual(manager.activeTheme.id, "treemux-dark")
    }

    @MainActor
    func testSwitchTheme() {
        let manager = ThemeManager()
        manager.setActiveTheme("treemux-light")
        XCTAssertEqual(manager.activeTheme.id, "treemux-light")
    }

    @MainActor
    func testFallbackForUnknownID() {
        let manager = ThemeManager(activeThemeID: "nonexistent")
        XCTAssertEqual(manager.activeTheme.id, "treemux-dark")
    }

    @MainActor
    func testAvailableThemesIncludeBuiltIns() {
        let manager = ThemeManager()
        XCTAssertTrue(manager.availableThemes.contains(where: { $0.id == "treemux-dark" }))
        XCTAssertTrue(manager.availableThemes.contains(where: { $0.id == "treemux-light" }))
    }

    @MainActor
    func testSetActiveThemePostsNotification() {
        let manager = ThemeManager()
        let expectation = expectation(forNotification: .themeDidChange, object: nil)
        manager.setActiveTheme("treemux-light")
        wait(for: [expectation], timeout: 1.0)
    }
}
