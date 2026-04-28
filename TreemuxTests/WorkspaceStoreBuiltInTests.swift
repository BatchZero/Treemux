//
//  WorkspaceStoreBuiltInTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

@MainActor
final class WorkspaceStoreBuiltInTests: XCTestCase {

    /// Helper: writes a state JSON file before WorkspaceStore.init reads it.
    private func writeState(_ state: PersistedWorkspaceState) throws {
        let dir = treemuxStateDirectoryURL()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("workspace-state.json")
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
    }

    private func clearState() throws {
        let dir = treemuxStateDirectoryURL()
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    override func setUp() async throws {
        try clearState()
    }

    override func tearDown() async throws {
        try clearState()
    }

    func testInitInsertsBuiltInWhenAbsent() async throws {
        try writeState(PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: []))
        let store = WorkspaceStore()
        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertEqual(store.workspaces[0].id, WorkspaceModel.builtInDefaultTerminalID)
        XCTAssertTrue(store.workspaces[0].isBuiltInDefaultTerminal)
        XCTAssertEqual(store.workspaces[0].name, "~")
    }

    func testInitDeduplicatesBuiltInEntries() async throws {
        let builtinA = WorkspaceRecord(
            id: WorkspaceModel.builtInDefaultTerminalID,
            kind: .localTerminal,
            name: "~",
            repositoryPath: NSHomeDirectory(),
            isPinned: false,
            isArchived: false,
            sshTarget: nil,
            worktreeStates: [],
            worktreeOrder: nil,
            workspaceIcon: nil,
            worktreeIconOverrides: nil,
            isBuiltInDefaultTerminal: true
        )
        // Second copy with a different UUID but still flagged
        let builtinB = WorkspaceRecord(
            id: UUID(),
            kind: .localTerminal,
            name: "~",
            repositoryPath: NSHomeDirectory(),
            isPinned: false,
            isArchived: false,
            sshTarget: nil,
            worktreeStates: [],
            worktreeOrder: nil,
            workspaceIcon: nil,
            worktreeIconOverrides: nil,
            isBuiltInDefaultTerminal: true
        )
        try writeState(PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: [builtinA, builtinB]))
        let store = WorkspaceStore()
        let builtins = store.workspaces.filter { $0.isBuiltInDefaultTerminal }
        XCTAssertEqual(builtins.count, 1)
    }

    func testInitForcesBuiltInUnarchived() async throws {
        let archived = WorkspaceRecord(
            id: WorkspaceModel.builtInDefaultTerminalID,
            kind: .localTerminal,
            name: "~",
            repositoryPath: NSHomeDirectory(),
            isPinned: false,
            isArchived: true, // erroneously archived
            sshTarget: nil,
            worktreeStates: [],
            worktreeOrder: nil,
            workspaceIcon: nil,
            worktreeIconOverrides: nil,
            isBuiltInDefaultTerminal: true
        )
        try writeState(PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: [archived]))
        let store = WorkspaceStore()
        let builtin = store.workspaces.first(where: { $0.isBuiltInDefaultTerminal })
        XCTAssertNotNil(builtin)
        XCTAssertFalse(builtin?.isArchived ?? true)
    }

    func testLocalWorkspacesIncludesBuiltInWhenToggleOn() async throws {
        try writeState(PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: []))
        let store = WorkspaceStore()
        store.settings.showDefaultTerminal = true
        XCTAssertTrue(store.localWorkspaces.contains { $0.isBuiltInDefaultTerminal })
    }

    func testLocalWorkspacesFiltersBuiltInWhenToggleOffAndRealExists() async throws {
        let real = WorkspaceRecord(
            id: UUID(),
            kind: .repository,
            name: "real",
            repositoryPath: "/tmp/real",
            isPinned: false,
            isArchived: false,
            sshTarget: nil,
            worktreeStates: [],
            worktreeOrder: nil,
            workspaceIcon: nil,
            worktreeIconOverrides: nil,
            isBuiltInDefaultTerminal: false
        )
        try writeState(PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: [real]))
        let store = WorkspaceStore()
        store.settings.showDefaultTerminal = false
        XCTAssertFalse(store.localWorkspaces.contains { $0.isBuiltInDefaultTerminal })
        XCTAssertTrue(store.localWorkspaces.contains { $0.name == "real" })
    }

    func testLocalWorkspacesFallbackKeepsBuiltInWhenToggleOffAndNoOtherWorkspace() async throws {
        try writeState(PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: []))
        let store = WorkspaceStore()
        store.settings.showDefaultTerminal = false
        XCTAssertTrue(store.localWorkspaces.contains { $0.isBuiltInDefaultTerminal })
    }
}
