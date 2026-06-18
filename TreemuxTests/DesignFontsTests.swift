//
//  DesignFontsTests.swift
//  TreemuxTests
//

import SwiftUI
import XCTest
@testable import Treemux

final class DesignFontsTests: XCTestCase {
    func testChromeRolesMapToSystemFont() {
        XCTAssertEqual(DesignFonts.dialogTitle, .system(size: 20, weight: .semibold))
        XCTAssertEqual(DesignFonts.sectionTitle, .system(size: 13, weight: .semibold))
        XCTAssertEqual(DesignFonts.chromeBody, .system(size: 13, weight: .regular))
        XCTAssertEqual(DesignFonts.chromeStrong, .system(size: 11, weight: .semibold))
        XCTAssertEqual(DesignFonts.chromeCaption, .system(size: 11, weight: .regular))
    }

    func testEyebrowIsMonospaced() {
        XCTAssertEqual(DesignFonts.eyebrow, .system(size: 9, weight: .semibold, design: .monospaced))
    }

    func testDialogTitleTracking() {
        XCTAssertEqual(DesignFonts.dialogTitleTracking, -0.4)
    }
}
