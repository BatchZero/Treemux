//
//  TreemuxTabLayoutTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class TreemuxTabLayoutTests: XCTestCase {
    // Few tabs: (viewport - chrome) / count exceeds max → capped at maxWidth.
    func testFewTabs_capsAtMaxWidth() {
        let w = TabBarLayout.uniformWidth(
            viewport: 1000, tabCount: 2, reservedChrome: 40, minWidth: 64, maxWidth: 240)
        XCTAssertEqual(w, 240)
    }

    // Medium: result lands strictly inside [min, max] and equals the exact share.
    func testMediumTabs_returnsExactShare() {
        // (700 - 40) / 6 = 110
        let w = TabBarLayout.uniformWidth(
            viewport: 700, tabCount: 6, reservedChrome: 40, minWidth: 64, maxWidth: 240)
        XCTAssertEqual(w, 110)
    }

    // Many tabs: share drops below min → floored at minWidth (overflow → scroll).
    func testManyTabs_floorsAtMinWidth() {
        // (600 - 40) / 20 = 28 → clamps up to 64
        let w = TabBarLayout.uniformWidth(
            viewport: 600, tabCount: 20, reservedChrome: 40, minWidth: 64, maxWidth: 240)
        XCTAssertEqual(w, 64)
    }

    // Zero tabs: no division by zero, returns maxWidth.
    func testZeroTabs_returnsMaxWidth() {
        let w = TabBarLayout.uniformWidth(
            viewport: 800, tabCount: 0, reservedChrome: 40, minWidth: 64, maxWidth: 240)
        XCTAssertEqual(w, 240)
    }

    // Chrome wider than viewport: negative usable → clamps up to minWidth.
    func testChromeExceedsViewport_clampsToMinWidth() {
        let w = TabBarLayout.uniformWidth(
            viewport: 30, tabCount: 3, reservedChrome: 100, minWidth: 64, maxWidth: 240)
        XCTAssertEqual(w, 64)
    }

    func testConstants() {
        XCTAssertEqual(TabBarLayout.minTabWidth, 64)
        XCTAssertEqual(TabBarLayout.maxTabWidth, 240)
    }
}
