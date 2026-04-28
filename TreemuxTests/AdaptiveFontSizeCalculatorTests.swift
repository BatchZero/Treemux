//
//  AdaptiveFontSizeCalculatorTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class AdaptiveFontSizeCalculatorTests: XCTestCase {

    // MARK: - Pure formula

    func testReferencePPI_offsetZero_returnsBase() {
        XCTAssertEqual(AdaptiveFontSizeCalculator.fontSize(forPPI: 109, offset: 0), 14)
    }

    func testReferencePPI_positiveOffset_addsToBase() {
        XCTAssertEqual(AdaptiveFontSizeCalculator.fontSize(forPPI: 109, offset: 3), 17)
    }

    func testReferencePPI_negativeOffset_subtractsFromBase() {
        XCTAssertEqual(AdaptiveFontSizeCalculator.fontSize(forPPI: 109, offset: -2), 12)
    }

    func testHighPPI_scalesUp() {
        // MBP 14" effective PPI ~121 → 14 × 121 / 109 = 15.54 → 16
        XCTAssertEqual(AdaptiveFontSizeCalculator.fontSize(forPPI: 121, offset: 0), 16)
    }

    func testLowPPI_scalesDown() {
        // 24" 1080p ~92 PPI → 14 × 92 / 109 = 11.81 → 12
        XCTAssertEqual(AdaptiveFontSizeCalculator.fontSize(forPPI: 92, offset: 0), 12)
    }

    func testVeryHighPPI_scalesUpFurther() {
        // 4K 27" "More Space" ~163 PPI → 14 × 163 / 109 = 20.94 → 21
        XCTAssertEqual(AdaptiveFontSizeCalculator.fontSize(forPPI: 163, offset: 0), 21)
    }

    // MARK: - Offset clamp

    func testOffsetAbove_clampsToUpperBound() {
        let result = AdaptiveFontSizeCalculator.fontSize(forPPI: 109, offset: 99)
        // (14 + 12) × 1 = 26
        XCTAssertEqual(result, 26)
    }

    func testOffsetBelow_clampsToLowerBound() {
        let result = AdaptiveFontSizeCalculator.fontSize(forPPI: 109, offset: -99)
        // (14 - 8) × 1 = 6
        XCTAssertEqual(result, 6)
    }

    func testClampOffset_within_returnsValue() {
        XCTAssertEqual(AdaptiveFontSizeCalculator.clampOffset(5), 5)
    }

    func testClampOffset_above_returnsUpper() {
        XCTAssertEqual(AdaptiveFontSizeCalculator.clampOffset(100), 12)
    }

    func testClampOffset_below_returnsLower() {
        XCTAssertEqual(AdaptiveFontSizeCalculator.clampOffset(-100), -8)
    }

    // MARK: - Final clamp [6, 72]

    func testExtremeUpward_clampsTo72() {
        // (14 + 12) × 600 / 109 = 143.1 → 143 → clamp 72
        let result = AdaptiveFontSizeCalculator.fontSize(forPPI: 600, offset: 12)
        XCTAssertEqual(result, 72)
    }

    func testExtremeDownward_clampsTo6() {
        // (14 - 8) × 30 / 109 = 1.65 → 2 → clamp 6
        let result = AdaptiveFontSizeCalculator.fontSize(forPPI: 30, offset: -8)
        XCTAssertEqual(result, 6)
    }

    // MARK: - Constants

    func testBase_is14() {
        XCTAssertEqual(AdaptiveFontSizeCalculator.base, 14)
    }

    func testReferencePPI_is109() {
        XCTAssertEqual(AdaptiveFontSizeCalculator.referencePPI, 109)
    }

    func testOffsetRange_isMinus8To12() {
        XCTAssertEqual(AdaptiveFontSizeCalculator.offsetRange, -8 ... 12)
    }

    // MARK: - NSScreen helpers (nil paths)

    func testEffectivePPI_nilScreen_returnsNil() {
        XCTAssertNil(AdaptiveFontSizeCalculator.effectivePPI(for: nil))
    }

    func testFontSizeForScreen_nilScreen_usesReferencePPI() {
        // (14 + 0) × 109 / 109 = 14
        XCTAssertEqual(AdaptiveFontSizeCalculator.fontSize(for: nil, offset: 0), 14)
        // (14 + 3) × 109 / 109 = 17
        XCTAssertEqual(AdaptiveFontSizeCalculator.fontSize(for: nil, offset: 3), 17)
    }
}
