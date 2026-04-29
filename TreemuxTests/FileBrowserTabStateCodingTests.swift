//
//  FileBrowserTabStateCodingTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

final class FileBrowserTabStateCodingTests: XCTestCase {
    // MARK: - Round-trip via the shim selectedFilePath setter

    func testRoundTripWithDefaults() throws {
        // Use the shim setter so the resulting state still encodes as a single
        // pinned sub-tab. The shim getter reads back the same path.
        var state = FileBrowserTabState(
            rootPath: "/tmp/foo",
            rootKind: .worktree,
            splitRatio: 0.3,
            expandedDirs: ["/tmp/foo", "/tmp/foo/sub"],
            showsHiddenFiles: true
        )
        state.selectedFilePath = "/tmp/foo/bar.txt"

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
        // Minimal payload — defaults should fill in. No selectedFilePath, no
        // subTabs => empty sub-tab list, nil active id.
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
        XCTAssertEqual(decoded.subTabs, [])
        XCTAssertNil(decoded.activeSubTabID)
    }

    // MARK: - Stage D migration paths

    func test_legacyDecode_withSelectedFilePath_migratesToPinnedSubTab() throws {
        let json = """
        {
            "rootPath": "/r",
            "rootKind": "project",
            "selectedFilePath": "/r/foo.swift",
            "splitRatio": 0.3,
            "expandedDirs": [],
            "showsHiddenFiles": false
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(FileBrowserTabState.self, from: json)
        XCTAssertEqual(s.subTabs.count, 1)
        XCTAssertEqual(s.subTabs.first?.path, "/r/foo.swift")
        XCTAssertEqual(s.subTabs.first?.isPinned, true)
        XCTAssertEqual(s.activeSubTabID, s.subTabs.first?.id)
    }

    func test_newDecode_withSubTabs() throws {
        let id = UUID().uuidString
        let json = """
        {
            "rootPath": "/r",
            "rootKind": "project",
            "splitRatio": 0.3,
            "expandedDirs": [],
            "showsHiddenFiles": false,
            "subTabs": [{"id":"\(id)","path":"/r/x.swift","isPinned":true}],
            "activeSubTabID": "\(id)"
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(FileBrowserTabState.self, from: json)
        XCTAssertEqual(s.subTabs.count, 1)
        XCTAssertEqual(s.activeSubTabID?.uuidString, id)
    }

    func test_legacyDecode_noSelectedFile_emptySubTabs() throws {
        let json = """
        {"rootPath":"/r","rootKind":"project","splitRatio":0.3,
         "expandedDirs":[],"showsHiddenFiles":false}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(FileBrowserTabState.self, from: json)
        XCTAssertEqual(s.subTabs, [])
        XCTAssertNil(s.activeSubTabID)
    }
}
