//
//  DesignSystemTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class DesignSystemTests: XCTestCase {
    func testSpacingScaleMatchesDesignMd() {
        XCTAssertEqual(Spacing.xxs, 4)
        XCTAssertEqual(Spacing.xs, 8)
        XCTAssertEqual(Spacing.sm, 12)
        XCTAssertEqual(Spacing.md, 17)
        XCTAssertEqual(Spacing.lg, 24)
        XCTAssertEqual(Spacing.xl, 32)
        XCTAssertEqual(Spacing.xxl, 48)
        XCTAssertEqual(Spacing.section, 80)
    }

    func testRadiusScaleMatchesDesignMd() {
        XCTAssertEqual(Radius.xs, 5)
        XCTAssertEqual(Radius.sm, 8)
        XCTAssertEqual(Radius.md, 11)
        XCTAssertEqual(Radius.lg, 18)
        XCTAssertEqual(Radius.pill, 9999)
    }
}
