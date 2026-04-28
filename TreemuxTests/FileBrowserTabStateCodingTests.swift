//
//  FileBrowserTabStateCodingTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

final class FileBrowserTabStateCodingTests: XCTestCase {
    func testRoundTripWithDefaults() throws {
        let state = FileBrowserTabState(
            rootPath: "/tmp/foo",
            rootKind: .worktree,
            selectedFilePath: "/tmp/foo/bar.txt",
            splitRatio: 0.3,
            expandedDirs: ["/tmp/foo", "/tmp/foo/sub"],
            showsHiddenFiles: true
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(FileBrowserTabState.self, from: data)
        XCTAssertEqual(decoded.rootPath, "/tmp/foo")
        XCTAssertEqual(decoded.rootKind, .worktree)
        XCTAssertEqual(decoded.selectedFilePath, "/tmp/foo/bar.txt")
        XCTAssertEqual(decoded.splitRatio, 0.3, accuracy: 0.0001)
        XCTAssertEqual(decoded.expandedDirs, ["/tmp/foo", "/tmp/foo/sub"])
        XCTAssertTrue(decoded.showsHiddenFiles)
    }

    func testDecodeMissingOptionalFields() throws {
        // Minimal payload — defaults should fill in.
        let json = """
        {"rootPath": "/x", "rootKind": "project"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FileBrowserTabState.self, from: json)
        XCTAssertEqual(decoded.rootPath, "/x")
        XCTAssertEqual(decoded.rootKind, .project)
        XCTAssertNil(decoded.selectedFilePath)
        XCTAssertEqual(decoded.splitRatio, 0.28, accuracy: 0.0001)
        XCTAssertEqual(decoded.expandedDirs, [])
        XCTAssertFalse(decoded.showsHiddenFiles)
    }
}
