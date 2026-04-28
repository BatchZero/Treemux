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

    func testFreshLaunchAutoSelectsBuiltIn() async throws {
        // No state on disk → init must auto-select the built-in.
        try clearState()
        let store = WorkspaceStore()
        XCTAssertEqual(store.selectedWorkspaceID, WorkspaceModel.builtInDefaultTerminalID)
        XCTAssertNotNil(store.selectedWorkspace)
    }

    func testInitPreservesExistingSelection() async throws {
        // If state already has a valid selection, init must NOT overwrite it.
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
        try writeState(PersistedWorkspaceState(version: 1, selectedWorkspaceID: real.id, workspaces: [real]))
        let store = WorkspaceStore()
        XCTAssertEqual(store.selectedWorkspaceID, real.id)
    }

    func testRenameBuiltInIsNoOp() async throws {
        try writeState(PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: []))
        let store = WorkspaceStore()
        let originalName = store.workspaces.first(where: { $0.isBuiltInDefaultTerminal })?.name
        store.renameWorkspace(WorkspaceModel.builtInDefaultTerminalID, to: "renamed")
        let after = store.workspaces.first(where: { $0.isBuiltInDefaultTerminal })?.name
        XCTAssertEqual(after, originalName)
        XCTAssertEqual(after, "~")
    }

    func testRemoveBuiltInIsNoOp() async throws {
        try writeState(PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: []))
        let store = WorkspaceStore()
        XCTAssertTrue(store.workspaces.contains { $0.isBuiltInDefaultTerminal })
        store.removeWorkspace(WorkspaceModel.builtInDefaultTerminalID)
        XCTAssertTrue(store.workspaces.contains { $0.isBuiltInDefaultTerminal })
    }

    func testTogglingOffMovesSelectionAwayFromBuiltInWhenRealExists() async throws {
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
        store.selectedWorkspaceID = WorkspaceModel.builtInDefaultTerminalID

        var newSettings = store.settings
        newSettings.showDefaultTerminal = false
        store.updateSettings(newSettings)

        XCTAssertNotEqual(store.selectedWorkspaceID, WorkspaceModel.builtInDefaultTerminalID)
        XCTAssertEqual(store.selectedWorkspaceID, real.id)
    }

    func testTogglingOffKeepsBuiltInSelectionWhenNoRealExists() async throws {
        try writeState(PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: []))
        let store = WorkspaceStore()
        store.selectedWorkspaceID = WorkspaceModel.builtInDefaultTerminalID

        var newSettings = store.settings
        newSettings.showDefaultTerminal = false
        store.updateSettings(newSettings)

        // No real workspace → selection unchanged; fallback shows `~` in sidebar.
        XCTAssertEqual(store.selectedWorkspaceID, WorkspaceModel.builtInDefaultTerminalID)
    }

    func testMoveLocalWorkspacePersistsBuiltInPosition() async throws {
        // Two real workspaces; the built-in starts at the end (appended by ensureBuiltInDefaultTerminal).
        let real1 = WorkspaceRecord(
            id: UUID(),
            kind: .repository,
            name: "alpha",
            repositoryPath: "/tmp/alpha",
            isPinned: false,
            isArchived: false,
            sshTarget: nil,
            worktreeStates: [],
            worktreeOrder: nil,
            workspaceIcon: nil,
            worktreeIconOverrides: nil,
            isBuiltInDefaultTerminal: false
        )
        let real2 = WorkspaceRecord(
            id: UUID(),
            kind: .repository,
            name: "beta",
            repositoryPath: "/tmp/beta",
            isPinned: false,
            isArchived: false,
            sshTarget: nil,
            worktreeStates: [],
            worktreeOrder: nil,
            workspaceIcon: nil,
            worktreeIconOverrides: nil,
            isBuiltInDefaultTerminal: false
        )
        try writeState(PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: [real1, real2]))

        let store = WorkspaceStore()
        // After init: localWorkspaces is [alpha, beta, ~]. Move ~ to the front.
        XCTAssertTrue(store.settings.showDefaultTerminal)
        let local = store.localWorkspaces
        XCTAssertEqual(local.count, 3)
        let builtinIndex = local.firstIndex(where: { $0.isBuiltInDefaultTerminal })
        XCTAssertEqual(builtinIndex, 2)

        store.moveLocalWorkspace(from: IndexSet(integer: 2), to: 0)

        let afterMove = store.localWorkspaces
        XCTAssertTrue(afterMove.first?.isBuiltInDefaultTerminal ?? false, "Built-in should now be first after move")
        XCTAssertEqual(afterMove.map { $0.name }, ["~", "alpha", "beta"])

        // Verify position survives a re-init (encode → decode round-trip via disk).
        let store2 = WorkspaceStore()
        let restored = store2.localWorkspaces
        XCTAssertTrue(restored.first?.isBuiltInDefaultTerminal ?? false, "Built-in position must persist across restart")
        XCTAssertEqual(restored.map { $0.name }, ["~", "alpha", "beta"])
    }
}
