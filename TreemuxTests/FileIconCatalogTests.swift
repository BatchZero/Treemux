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

        // Verify the Icon has no tint role for colorful file icons.
        let node = FileNode(id: "/x/main.swift", name: "main.swift", path: "/x/main.swift",
                            kind: .file, sizeBytes: nil, modifiedAt: nil)
        XCTAssertNil(FileIconCatalog.icon(for: node, isExpanded: false).tintRole)
    }
}
