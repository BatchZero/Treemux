//
//  WorkspaceTabRecordMigrationTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

final class WorkspaceTabRecordMigrationTests: XCTestCase {
    func testLegacyDecodeWithoutKindDefaultsToTerminal() throws {
        // Legacy payload: pre-migration tabs serialized without `kind`.
        let legacyJSON = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "title": "Tab 1",
            "isManuallyNamed": false,
            "panes": [],
            "focusedPaneID": null,
            "zoomedPaneID": null
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(WorkspaceTabStateRecord.self, from: legacyJSON)
        XCTAssertEqual(decoded.kind, .terminal)
        XCTAssertNil(decoded.fileBrowserState)
        XCTAssertEqual(decoded.title, "Tab 1")
    }

    func testFileBrowserKindRoundTrip() throws {
        let state = FileBrowserTabState(rootPath: "/tmp/x", rootKind: .worktree)
        let record = WorkspaceTabStateRecord(
            title: "Files",
            kind: .fileBrowser,
            fileBrowserState: state
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(WorkspaceTabStateRecord.self, from: data)
        XCTAssertEqual(decoded.kind, .fileBrowser)
        XCTAssertEqual(decoded.fileBrowserState?.rootPath, "/tmp/x")
        XCTAssertNil(decoded.layout)
        XCTAssertEqual(decoded.panes.count, 0)
    }
}
