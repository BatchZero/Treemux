//
//  WorkspaceModelsTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class WorkspaceModelsTests: XCTestCase {

    func testWorkspaceRecordCodableRoundTrip() throws {
        let record = WorkspaceRecord(
            id: UUID(),
            kind: .repository,
            name: "my-project",
            repositoryPath: "/Users/test/code/my-project",
            isPinned: false,
            isArchived: false,
            sshTarget: nil,
            worktreeStates: [],
            worktreeOrder: nil
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(WorkspaceRecord.self, from: data)
        XCTAssertEqual(decoded.name, "my-project")
        XCTAssertEqual(decoded.kind, .repository)
    }

    func testRemoteWorkspaceRecordCodable() throws {
        let target = SSHTarget(
            host: "server1", port: 22, user: "user1",
            identityFile: nil, displayName: "server1", remotePath: "/home/user1/proj"
        )
        let record = WorkspaceRecord(
            id: UUID(),
            kind: .remote,
            name: "proj",
            repositoryPath: nil,
            isPinned: false,
            isArchived: false,
            sshTarget: target,
            worktreeStates: [],
            worktreeOrder: nil
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(WorkspaceRecord.self, from: data)
        XCTAssertEqual(decoded.kind, .remote)
        XCTAssertEqual(decoded.sshTarget?.host, "server1")
    }

    func testPersistedWorkspaceStateCodable() throws {
        let state = PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: nil,
            workspaces: []
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PersistedWorkspaceState.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertTrue(decoded.workspaces.isEmpty)
    }

    func testTabStateRecordCodableRoundTrip() throws {
        let tab = WorkspaceTabStateRecord(
            id: UUID(),
            title: "My Tab",
            isManuallyNamed: true,
            layout: .pane(PaneLeaf(paneID: UUID())),
            panes: [],
            focusedPaneID: nil,
            zoomedPaneID: nil
        )
        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(WorkspaceTabStateRecord.self, from: data)
        XCTAssertEqual(decoded.title, "My Tab")
        XCTAssertTrue(decoded.isManuallyNamed)
    }

    func testTabStateRecordDefaultIsManuallyNamed() throws {
        let tab = WorkspaceTabStateRecord(
            id: UUID(),
            title: "Tab 1",
            layout: nil,
            panes: [],
            focusedPaneID: nil,
            zoomedPaneID: nil
        )
        XCTAssertFalse(tab.isManuallyNamed)
    }

    func testTabStateRecordMakeDefault() throws {
        let tab = WorkspaceTabStateRecord.makeDefault(workingDirectory: "/tmp/test")
        XCTAssertEqual(tab.title, "Tab 1")
        XCTAssertFalse(tab.isManuallyNamed)
        XCTAssertNotNil(tab.layout)
        XCTAssertEqual(tab.panes.count, 1)
        XCTAssertNotNil(tab.focusedPaneID)
    }

    func testTabStateRecordBackwardCompatibleDecoding() throws {
        // Simulate old JSON without isManuallyNamed
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","title":"Old Tab","panes":[]}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WorkspaceTabStateRecord.self, from: data)
        XCTAssertEqual(decoded.title, "Old Tab")
        XCTAssertFalse(decoded.isManuallyNamed)
    }

    func testPaneSnapshotCodable() throws {
        let snapshot = PaneSnapshot(
            id: UUID(),
            backend: .localShell(LocalShellConfig.defaultShell()),
            workingDirectory: "/Users/test/code"
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(PaneSnapshot.self, from: data)
        XCTAssertEqual(decoded.workingDirectory, "/Users/test/code")
    }

    // MARK: - WorkspaceModel Tab Management Tests

    @MainActor
    func testWorkspaceModelInitializesWithOneDefaultTab() {
        let ws = WorkspaceModel(name: "test", kind: .localTerminal)
        XCTAssertEqual(ws.tabs.count, 1)
        XCTAssertNotNil(ws.activeTabID)
        XCTAssertEqual(ws.tabs.first?.id, ws.activeTabID)
    }

    @MainActor
    func testCreateTabAddsAndActivates() {
        let ws = WorkspaceModel(name: "test", kind: .localTerminal)
        let originalTabID = ws.activeTabID
        ws.createTab()
        XCTAssertEqual(ws.tabs.count, 2)
        XCTAssertNotEqual(ws.activeTabID, originalTabID)
    }

    @MainActor
    func testCloseTabRemovesAndSelectsAdjacent() {
        let ws = WorkspaceModel(name: "test", kind: .localTerminal)
        ws.createTab()
        ws.createTab()
        XCTAssertEqual(ws.tabs.count, 3)
        let middleTab = ws.tabs[1]
        ws.selectTab(middleTab.id)
        ws.closeTab(middleTab.id)
        XCTAssertEqual(ws.tabs.count, 2)
        XCTAssertNotNil(ws.activeTabID)
        XCTAssertFalse(ws.tabs.contains { $0.id == middleTab.id })
    }

    @MainActor
    func testCloseLastTabResultsInEmptyState() {
        let ws = WorkspaceModel(name: "test", kind: .localTerminal)
        let tabID = ws.tabs[0].id
        ws.closeTab(tabID)
        XCTAssertTrue(ws.tabs.isEmpty)
        XCTAssertNil(ws.activeTabID)
    }

    @MainActor
    func testRenameTabSetsManuallyNamed() {
        let ws = WorkspaceModel(name: "test", kind: .localTerminal)
        let tabID = ws.tabs[0].id
        ws.renameTab(tabID, title: "My Terminal")
        XCTAssertEqual(ws.tabs[0].title, "My Terminal")
        XCTAssertTrue(ws.tabs[0].isManuallyNamed)
    }

    @MainActor
    func testMoveTab() {
        let ws = WorkspaceModel(name: "test", kind: .localTerminal)
        ws.createTab()
        ws.createTab()
        let firstID = ws.tabs[0].id
        ws.moveTab(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(ws.tabs.last?.id, firstID)
    }

    @MainActor
    func testSelectNextAndPreviousTabWraps() {
        let ws = WorkspaceModel(name: "test", kind: .localTerminal)
        ws.createTab()
        ws.createTab()
        ws.selectTab(ws.tabs[0].id)
        ws.selectPreviousTab()
        XCTAssertEqual(ws.activeTabID, ws.tabs[2].id)
        ws.selectNextTab()
        XCTAssertEqual(ws.activeTabID, ws.tabs[0].id)
    }

    @MainActor
    func testSelectTabByNumber() {
        let ws = WorkspaceModel(name: "test", kind: .localTerminal)
        ws.createTab()
        ws.createTab()
        let secondTabID = ws.tabs[1].id
        ws.selectTabByNumber(2)
        XCTAssertEqual(ws.activeTabID, secondTabID)
    }

    @MainActor
    func testRestoreTabStatePopulatesAllWorktrees() {
        let mainTab = WorkspaceTabStateRecord.makeDefault(workingDirectory: "/tmp/project", title: "Main Tab")
        let featureTab = WorkspaceTabStateRecord.makeDefault(workingDirectory: "/tmp/project-feature", title: "Feature Tab")

        let record = WorkspaceRecord(
            id: UUID(),
            kind: .repository,
            name: "test",
            repositoryPath: "/tmp/project",
            isPinned: false,
            isArchived: false,
            sshTarget: nil,
            worktreeStates: [
                WorktreeSessionStateRecord(
                    worktreePath: "/tmp/project",
                    branch: "main",
                    tabs: [mainTab],
                    selectedTabID: mainTab.id
                ),
                WorktreeSessionStateRecord(
                    worktreePath: "/tmp/project-feature",
                    branch: "feature",
                    tabs: [featureTab],
                    selectedTabID: featureTab.id
                )
            ],
            worktreeOrder: nil
        )

        let ws = WorkspaceModel(from: record)

        // Active worktree (main) should have its tabs loaded
        XCTAssertEqual(ws.tabs.count, 1)
        XCTAssertEqual(ws.tabs[0].title, "Main Tab")

        // Switch to feature worktree — should restore saved tabs, not create default
        ws.switchToWorktree("/tmp/project-feature")
        XCTAssertEqual(ws.tabs.count, 1)
        XCTAssertEqual(ws.tabs[0].title, "Feature Tab")
    }

    @MainActor
    func testToRecordSerializesTabs() {
        let ws = WorkspaceModel(name: "test", kind: .localTerminal)
        ws.createTab()
        let record = ws.toRecord()
        XCTAssertFalse(record.worktreeStates.isEmpty)
        XCTAssertEqual(record.worktreeStates[0].tabs.count, 2)
        XCTAssertNotNil(record.worktreeStates[0].selectedTabID)
    }
}
