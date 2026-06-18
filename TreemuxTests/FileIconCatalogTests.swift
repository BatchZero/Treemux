//
//  FileIconCatalogTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class FileIconCatalogTests: XCTestCase {

    func testDirectoryIconUsesFolderRole() {
        XCTAssertEqual(FileIconCatalog.directoryIcon(isExpanded: false).tintRole, .folder)
        XCTAssertEqual(FileIconCatalog.directoryIcon(isExpanded: true).tintRole, .folder)
    }

    func testSymlinkAndDefaultUseMutedRole() {
        XCTAssertEqual(FileIconCatalog.symlinkIcon.tintRole, .muted)
        XCTAssertEqual(FileIconCatalog.defaultFileIcon.tintRole, .muted)
    }

    func testKnownColorfulFileHasNoTintRole() {
        // A mapped extension uses the colorful Material asset (original rendering, no tint).
        XCTAssertEqual(FileIconCatalog.assetForFile(named: "main.swift"), "swift")
    }
}
