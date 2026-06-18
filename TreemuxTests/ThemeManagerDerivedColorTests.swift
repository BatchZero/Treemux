//
//  ThemeManagerDerivedColorTests.swift
//  TreemuxTests
//

import SwiftUI
import XCTest
@testable import Treemux

final class ThemeManagerDerivedColorTests: XCTestCase {

    @MainActor
    func testShellAccentIsAnsiIndex2() {
        let manager = ThemeManager()  // defaults to treemux-dark
        XCTAssertEqual(manager.shellAccent, manager.ansiColor(2))
    }

    @MainActor
    func testAnsiColorMatchesThemePalette() {
        let manager = ThemeManager()
        let hex = manager.activeTheme.terminal.ansi[2]
        XCTAssertEqual(manager.ansiColor(2), Color(hex: hex))
    }

    @MainActor
    func testAnsiColorOutOfBoundsFallsBackToTextPrimary() {
        let manager = ThemeManager()
        XCTAssertEqual(manager.ansiColor(999), manager.textPrimary)
        XCTAssertEqual(manager.ansiColor(-1), manager.textPrimary)
    }

    @MainActor
    func testFileIconTintRoles() {
        let manager = ThemeManager()
        XCTAssertEqual(manager.fileIconTint(.folder), manager.accentColor)
        XCTAssertEqual(manager.fileIconTint(.muted), manager.textSecondary)
    }
}
