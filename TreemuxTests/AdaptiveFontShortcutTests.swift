//
//  AdaptiveFontShortcutTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class AdaptiveFontShortcutTests: XCTestCase {

    func testIncreaseAction_defaultIsCmdEquals() {
        let shortcut = ShortcutAction.terminalFontSizeIncrease.defaultShortcut
        XCTAssertEqual(shortcut, StoredShortcut(key: "=", command: true, shift: false, option: false, control: false))
    }

    func testDecreaseAction_defaultIsCmdMinus() {
        let shortcut = ShortcutAction.terminalFontSizeDecrease.defaultShortcut
        XCTAssertEqual(shortcut, StoredShortcut(key: "-", command: true, shift: false, option: false, control: false))
    }

    func testResetAction_defaultIsCmdZero() {
        let shortcut = ShortcutAction.terminalFontSizeReset.defaultShortcut
        XCTAssertEqual(shortcut, StoredShortcut(key: "0", command: true, shift: false, option: false, control: false))
    }

    func testAllThreeActions_areInWindowCategory() {
        XCTAssertEqual(ShortcutAction.terminalFontSizeIncrease.category, .window)
        XCTAssertEqual(ShortcutAction.terminalFontSizeDecrease.category, .window)
        XCTAssertEqual(ShortcutAction.terminalFontSizeReset.category, .window)
    }

    func testAllThreeActions_haveTitles() {
        XCTAssertFalse(ShortcutAction.terminalFontSizeIncrease.title.isEmpty)
        XCTAssertFalse(ShortcutAction.terminalFontSizeDecrease.title.isEmpty)
        XCTAssertFalse(ShortcutAction.terminalFontSizeReset.title.isEmpty)
    }

    func testActions_areInAllCases() {
        XCTAssertTrue(ShortcutAction.allCases.contains(.terminalFontSizeIncrease))
        XCTAssertTrue(ShortcutAction.allCases.contains(.terminalFontSizeDecrease))
        XCTAssertTrue(ShortcutAction.allCases.contains(.terminalFontSizeReset))
    }
}
