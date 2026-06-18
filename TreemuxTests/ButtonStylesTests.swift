//
//  ButtonStylesTests.swift
//  TreemuxTests
//

import SwiftUI
import XCTest
@testable import Treemux

final class ButtonStylesTests: XCTestCase {
    func testPillStoresColors() {
        let style = PillButtonStyle(accent: Color(hex: "#0066CC"), onAccent: Color(hex: "#FFFFFF"))
        XCTAssertEqual(style.accent, Color(hex: "#0066CC"))
        XCTAssertEqual(style.onAccent, Color(hex: "#FFFFFF"))
    }

    func testUtilityStoresColorsAndActiveDefaultsFalse() {
        let style = UtilityButtonStyle(
            tint: Color(hex: "#C5C8C6"),
            activeTint: Color(hex: "#0066CC"),
            border: Color(hex: "#FFFFFF1A"))
        XCTAssertEqual(style.tint, Color(hex: "#C5C8C6"))
        XCTAssertEqual(style.activeTint, Color(hex: "#0066CC"))
        XCTAssertFalse(style.isActive)
    }

    func testUtilityFillDefaultsNil() {
        let style = UtilityButtonStyle(
            tint: Color(hex: "#C5C8C6"),
            activeTint: Color(hex: "#0066CC"),
            border: Color(hex: "#FFFFFF1A"))
        XCTAssertNil(style.fill)
    }

    func testUtilityStoresFillVariant() {
        let style = UtilityButtonStyle(
            tint: Color(hex: "#C5C8C6"),
            activeTint: Color(hex: "#0066CC"),
            border: Color(hex: "#FFFFFF1A"),
            fill: Color(hex: "#0066CC"),
            onFill: Color(hex: "#FFFFFF"))
        XCTAssertEqual(style.fill, Color(hex: "#0066CC"))
        XCTAssertEqual(style.onFill, Color(hex: "#FFFFFF"))
    }
}
