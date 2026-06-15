//
//  FileIconCatalogTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class FileIconCatalogTests: XCTestCase {

    func testKnownExtensionsMapToColorAssets() {
        XCTAssertEqual(FileIconCatalog.assetForFile(named: "main.swift"), "swift")
        XCTAssertEqual(FileIconCatalog.assetForFile(named: "app.tsx"), "react")
        XCTAssertEqual(FileIconCatalog.assetForFile(named: "index.ts"), "typescript")
        XCTAssertEqual(FileIconCatalog.assetForFile(named: "README.md"), "markdown")
        XCTAssertEqual(FileIconCatalog.assetForFile(named: "page.html"), "html")
        XCTAssertEqual(FileIconCatalog.assetForFile(named: "data.json"), "json")
        XCTAssertEqual(FileIconCatalog.assetForFile(named: "photo.PNG"), "image")
    }

    func testKnownFilenamesMapByName() {
        XCTAssertEqual(FileIconCatalog.assetForFile(named: "Dockerfile"), "docker")
        XCTAssertEqual(FileIconCatalog.assetForFile(named: ".gitignore"), "git")
        XCTAssertEqual(FileIconCatalog.assetForFile(named: "package.json"), "nodejs")
        XCTAssertEqual(FileIconCatalog.assetForFile(named: "Cargo.lock"), "lock")
    }

    func testUnknownExtensionReturnsNil() {
        XCTAssertNil(FileIconCatalog.assetForFile(named: "mystery.qqq"))
        XCTAssertNil(FileIconCatalog.assetForFile(named: "noext"))
    }

    func testDirectoryIconIsTemplateTinted() {
        let closed = FileIconCatalog.directoryIcon(isExpanded: false)
        let open = FileIconCatalog.directoryIcon(isExpanded: true)
        XCTAssertEqual(closed.asset, "folder")
        XCTAssertEqual(open.asset, "folder-open")
        XCTAssertTrue(closed.isTemplate)
        XCTAssertNotNil(closed.tint)
    }

    func testDefaultFileIconIsTemplate() {
        let icon = FileIconCatalog.defaultFileIcon
        XCTAssertEqual(icon.asset, "file-document-outline")
        XCTAssertTrue(icon.isTemplate)
    }
}
