//
//  TreemuxTabSizingTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

final class TreemuxTabSizingTests: XCTestCase {

    func testMinimumWidth() {
        let width = TreemuxTabSizing.width(for: "T", paneCount: 1)
        XCTAssertEqual(width, 100, "Short title should clamp to minimum 100pt")
    }

    func testMaximumWidth() {
        let longTitle = String(repeating: "A", count: 100)
        let width = TreemuxTabSizing.width(for: longTitle, paneCount: 1)
        XCTAssertEqual(width, 260, "Long title should clamp to maximum 260pt")
    }

    func testBadgeAddsWidth() {
        let title = "A Longer Tab Name"
        let withoutBadge = TreemuxTabSizing.width(for: title, paneCount: 1)
        let withBadge = TreemuxTabSizing.width(for: title, paneCount: 3)
        XCTAssertGreaterThan(withBadge, withoutBadge, "Badge should increase tab width")
    }

    func testTypicalTabWidth() {
        let width = TreemuxTabSizing.width(for: "Tab 1", paneCount: 1)
        XCTAssertGreaterThanOrEqual(width, 100)
        XCTAssertLessThanOrEqual(width, 260)
    }

    func testWidthIncreasesWithTitle() {
        let shortWidth = TreemuxTabSizing.width(for: "Tab", paneCount: 1)
        let longWidth = TreemuxTabSizing.width(for: "My Long Tab Name", paneCount: 1)
        XCTAssertGreaterThan(longWidth, shortWidth)
    }
}
