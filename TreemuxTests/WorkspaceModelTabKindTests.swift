//
//  WorkspaceModelTabKindTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

@MainActor
final class WorkspaceModelTabKindTests: XCTestCase {
    func testCreateFileBrowserTabAppendsAndActivates() {
        let model = WorkspaceModel(
            name: "tmp",
            kind: .repository,
            repositoryRoot: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        let initialCount = model.tabs.count
        model.createFileBrowserTab(rootPath: NSTemporaryDirectory(), rootKind: .worktree, title: "Files")
        XCTAssertEqual(model.tabs.count, initialCount + 1)
        let last = model.tabs.last!
        XCTAssertEqual(last.kind, .fileBrowser)
        XCTAssertNotNil(last.fileBrowserState)
        XCTAssertEqual(model.activeTabID, last.id)
    }

    func testFileBrowserTabRoundTripsThroughRecord() {
        let model = WorkspaceModel(
            name: "tmp",
            kind: .repository,
            repositoryRoot: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        model.createFileBrowserTab(rootPath: "/x", rootKind: .project, title: "Files")
        let record = model.toRecord()
        let restored = WorkspaceModel(from: record)
        let fbTab = restored.tabs.first { $0.kind == .fileBrowser }
        XCTAssertNotNil(fbTab)
        XCTAssertEqual(fbTab?.fileBrowserState?.rootPath, "/x")
    }
}
