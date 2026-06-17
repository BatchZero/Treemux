//
//  FileTreeSettingsTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class FileTreeSettingsTests: XCTestCase {

    func testDefaultDensityIsComfortable() {
        XCTAssertEqual(FileTreeSettings().density, .comfortable)
        XCTAssertEqual(AppSettings().fileTree.density, .comfortable)
    }

    func testRowHeightMapping() {
        XCTAssertEqual(TreeDensity.compact.rowHeight, 28)
        XCTAssertEqual(TreeDensity.comfortable.rowHeight, 32)
        XCTAssertEqual(TreeDensity.spacious.rowHeight, 38)
    }

    func testFontSizeMapping() {
        XCTAssertEqual(TreeDensity.compact.fontSize, 12)
        XCTAssertEqual(TreeDensity.comfortable.fontSize, 13)
        XCTAssertEqual(TreeDensity.spacious.fontSize, 15)
    }

    func testAllDensitiesHavePositiveMetrics() {
        XCTAssertEqual(TreeDensity.allCases.count, 3)
        XCTAssertTrue(TreeDensity.allCases.allSatisfy { $0.rowHeight > 0 && $0.fontSize > 0 })
    }

    func testAppSettingsCodableRoundTripIncludesFileTree() throws {
        var settings = AppSettings()
        settings.fileTree.density = .spacious
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.fileTree.density, .spacious)
    }

    func testBackwardCompatDecodeMissingFileTree() throws {
        let legacy = Data("{\"version\":1}".utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertEqual(decoded.fileTree.density, .comfortable)
    }
}
