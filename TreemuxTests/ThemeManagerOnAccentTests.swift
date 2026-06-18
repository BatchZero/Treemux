//
//  ThemeManagerOnAccentTests.swift
//  TreemuxTests
//

import SwiftUI
import XCTest
@testable import Treemux

final class ThemeManagerOnAccentTests: XCTestCase {
    @MainActor
    func testOnAccentColorMatchesThemeUI() {
        let manager = ThemeManager()
        XCTAssertEqual(manager.onAccentColor, Color(hex: manager.activeTheme.ui.onAccent))
    }
}
