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

    /// Regression: external observers may touch `workspace.sessionController`
    /// on every objectWillChange. With a file-browser tab active, the previous
    /// implementation lazily created a terminal controller for the FB tab id and
    /// stored it in tabControllers. The next saveActiveTabState() then overwrote
    /// the FB tab record with a default WorkspaceTabStateRecord (kind defaults to
    /// .terminal, fileBrowserState nil) — corrupting the FB tab into a terminal tab.
    func test_saveActiveTabState_doesNotCorruptFileBrowserTab() {
        let ws = WorkspaceModel(
            name: "tmp",
            kind: .repository,
            repositoryRoot: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        ws.createFileBrowserTab(rootPath: "/tmp", rootKind: .project, title: "tmp")
        let fbID = ws.activeTabID!
        XCTAssertEqual(ws.tabs.first(where: { $0.id == fbID })?.kind, .fileBrowser)

        // Simulate an external-observer code path that touches
        // sessionController while a file-browser tab is active. With the bug,
        // this lazy-creates a terminal controller for the FB tab id.
        _ = ws.sessionController

        // saveActiveTabState used to overwrite the FB tab as a terminal tab.
        ws.saveActiveTabState()

        let after = ws.tabs.first(where: { $0.id == fbID })
        XCTAssertEqual(after?.kind, .fileBrowser, "FB tab kind must survive sessionController access + save")
        XCTAssertNotNil(after?.fileBrowserState, "fileBrowserState must survive")
    }
}
