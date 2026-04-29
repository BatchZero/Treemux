//
//  FileBrowserTabStateCodingTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

final class FileBrowserTabStateCodingTests: XCTestCase {
    // MARK: - Round-trip via the sub-tab API

    func testRoundTripWithDefaults() throws {
        // Construct a state with a single pinned sub-tab and round-trip it
        // through JSON. The decoder should give back the same sub-tab list.
        let pinned = FileSubTabRecord(path: "/tmp/foo/bar.txt", isPinned: true)
        let state = FileBrowserTabState(
            rootPath: "/tmp/foo",
            rootKind: .worktree,
            splitRatio: 0.3,
            expandedDirs: ["/tmp/foo", "/tmp/foo/sub"],
            showsHiddenFiles: true,
            subTabs: [pinned],
            activeSubTabID: pinned.id
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(FileBrowserTabState.self, from: data)
        XCTAssertEqual(decoded.rootPath, "/tmp/foo")
        XCTAssertEqual(decoded.rootKind, .worktree)
        XCTAssertEqual(decoded.subTabs.first?.path, "/tmp/foo/bar.txt")
        XCTAssertEqual(decoded.activeSubTabID, pinned.id)
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
