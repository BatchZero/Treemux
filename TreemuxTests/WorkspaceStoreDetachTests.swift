//
//  WorkspaceStoreDetachTests.swift
//  TreemuxTests
//
//  Tests for `detachedNodes` state, validity helpers, remote-group filtering,
//  and backward-compatible persistence on `WorkspaceStore` (Task 2).
//

import XCTest
@testable import Treemux

@MainActor
final class WorkspaceStoreDetachTests: XCTestCase {

    func testInitialRefreshIncludesRemoteWorkspaceWithDetachedWorktree() {
        let local = WorkspaceModel(
            name: "local",
            kind: .repository,
            repositoryRoot: URL(fileURLWithPath: "/tmp/local")
        )
        let detachedRemote = WorkspaceModel(
            name: "detached-remote",
            kind: .repository,
            sshTarget: makeSSHTarget(user: "detached")
        )
        let unrelatedRemote = WorkspaceModel(
            name: "unrelated-remote",
            kind: .repository,
            sshTarget: makeSSHTarget(user: "unrelated")
        )
        let ref = DetachedNodeRef.worktree(
            workspaceID: detachedRemote.id,
            worktreeID: UUID()
        )

        let ids = WorkspaceStore.initialWorkspaceIDsToRefresh(
            workspaces: [local, detachedRemote, unrelatedRemote],
            detachedNodes: [ref]
        )

        XCTAssertEqual(ids, [local.id, detachedRemote.id])
    }

    // MARK: - isDetached

    func testIsDetachedReturnsFalseByDefault() {
        let store = makeStore()
        let ref = DetachedNodeRef.workspace(UUID())
        XCTAssertFalse(store.isDetached(ref))
    }

    func testInsertAndQueryDetached() {
        let store = makeStore()
        let ref = DetachedNodeRef.workspace(UUID())
        store.detachedNodes.insert(ref)
        XCTAssertTrue(store.isDetached(ref))
    }

    func testRemoveDetachedRestoresVisibility() {
        let store = makeStore()
        let ref = DetachedNodeRef.workspace(UUID())
        store.detachedNodes.insert(ref)
        store.detachedNodes.remove(ref)
        XCTAssertFalse(store.isDetached(ref))
    }

    // MARK: - isValid

    func testIsValidReturnsFalseForUnknownWorkspace() {
        let store = makeStore()
        let ref = DetachedNodeRef.workspace(UUID())
        XCTAssertFalse(store.isValid(ref))
    }

    func testIsValidReturnsTrueForKnownWorkspace() {
        let store = makeStore()
        let ws = WorkspaceModel(
            name: "repo",
            kind: .repository,
            repositoryRoot: URL(fileURLWithPath: "/tmp/repo")
        )
        store.workspaces.append(ws)
        XCTAssertTrue(store.isValid(.workspace(ws.id)))
    }

    func testIsValidReturnsFalseForUnknownWorktree() {
        let store = makeStore()
        let ws = WorkspaceModel(
            name: "repo",
            kind: .repository,
            repositoryRoot: URL(fileURLWithPath: "/tmp/repo")
        )
        store.workspaces.append(ws)
        // No worktrees exist on the workspace, so the ref is invalid.
        XCTAssertFalse(store.isValid(.worktree(workspaceID: ws.id, worktreeID: UUID())))
    }

    func testIsValidReturnsTrueForKnownWorktree() {
        let store = makeStore()
        let ws = WorkspaceModel(
            name: "repo",
            kind: .repository,
            repositoryRoot: URL(fileURLWithPath: "/tmp/repo")
        )
        let wt = WorktreeModel(
            id: UUID(),
            path: URL(fileURLWithPath: "/tmp/repo/.git/worktrees/foo"),
            branch: "foo",
            headCommit: "abc",
            isMainWorktree: false
        )
        ws.worktrees.append(wt)
        store.workspaces.append(ws)
        XCTAssertTrue(store.isValid(.worktree(workspaceID: ws.id, worktreeID: wt.id)))
    }

    func testIsValidReturnsFalseForUnknownRemoteGroup() {
        let store = makeStore()
        let ref = DetachedNodeRef.remoteGroup("nonexistent|user")
        XCTAssertFalse(store.isValid(ref))
    }

    func testIsValidReturnsTrueForKnownRemoteGroup() {
        let store = makeStore()
        let target = makeSSHTarget(user: "root")
        let ws = WorkspaceModel(
            name: "remote",
            kind: .repository,
            sshTarget: target
        )
        store.workspaces.append(ws)
        // remoteGroupKey for SSHTarget produces "<displayName>|<user>".
        let key = WorkspaceStore.remoteGroupKey(for: target)
        XCTAssertTrue(store.isValid(.remoteGroup(key)))
    }

    // MARK: - workspacesInRemoteGroup

    func testWorkspacesInRemoteGroupReturnsEmptyForUnknownKey() {
        let store = makeStore()
        XCTAssertTrue(store.workspacesInRemoteGroup("nope|nobody").isEmpty)
    }

    func testWorkspacesInRemoteGroupReturnsMatchingWorkspaces() {
        let store = makeStore()
        let target = makeSSHTarget(user: "root")
        let wsA = WorkspaceModel(name: "a", kind: .repository, sshTarget: target)
        let wsB = WorkspaceModel(name: "b", kind: .repository, sshTarget: target)
        // A local workspace that must NOT appear in the remote group.
        let local = WorkspaceModel(
            name: "local",
            kind: .repository,
            repositoryRoot: URL(fileURLWithPath: "/tmp/local")
        )
        store.workspaces.append(contentsOf: [wsA, wsB, local])
        let key = WorkspaceStore.remoteGroupKey(for: target)
        let result = store.workspacesInRemoteGroup(key)
        XCTAssertEqual(Set(result.map(\.id)), Set([wsA.id, wsB.id]))
    }

    // MARK: - Persistence round-trip

    func testDetachedNodesRoundTripThroughPersistence() throws {
        try clearState()
        defer { try? clearState() }

        // Stage 1: write a state file that includes a detached workspace ref.
        let wsID = UUID()
        let detached: Set<DetachedNodeRef> = [
            .workspace(wsID),
            .remoteGroup("host|user")
        ]
        let state = PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: nil,
            workspaces: [],
            detachedNodes: detached
        )
        try writeState(state)

        // Stage 2: load via the persistence layer directly and confirm decode.
        let loaded = WorkspaceStatePersistence().load()
        XCTAssertEqual(loaded.detachedNodes, detached)

        // Stage 3: WorkspaceStore should hydrate its `detachedNodes` from disk.
        let store = WorkspaceStore()
        XCTAssertEqual(store.detachedNodes, detached)
    }

    func testOldStateFileWithoutDetachedNodesDecodesToEmpty() throws {
        try clearState()
        defer { try? clearState() }

        // Synthesize an old-format JSON file that lacks the `detachedNodes` key
        // entirely, exactly like files written before this feature shipped.
        let oldJSON = """
        {
          "version": 1,
          "selectedWorkspaceID": null,
          "workspaces": []
        }
        """
        let dir = treemuxStateDirectoryURL()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("workspace-state.json")
        try oldJSON.data(using: .utf8)!.write(to: url, options: .atomic)

        let loaded = WorkspaceStatePersistence().load()
        XCTAssertNil(loaded.detachedNodes)
        XCTAssertTrue((loaded.detachedNodes ?? []).isEmpty)

        let store = WorkspaceStore()
        XCTAssertTrue(store.detachedNodes.isEmpty)
    }

    // MARK: - removeWorkspace cleans stale detachedNodes refs (I2)

    /// Removing a workspace must also drop its `.workspace(id)` ref from
    /// `detachedNodes`. Without this, the stale ref would persist in
    /// workspace-state.json until the next launch (isValid is only checked at
    /// restore time) and the torn-off child window would point at a node that
    /// no longer exists.
    func testRemoveWorkspaceDropsWorkspaceDetachedRef() {
        let store = makeStore()
        let ws = WorkspaceModel(
            name: "repo",
            kind: .repository,
            repositoryRoot: URL(fileURLWithPath: "/tmp/repo")
        )
        store.workspaces.append(ws)
        let ref = DetachedNodeRef.workspace(ws.id)
        store.detachedNodes.insert(ref)
        XCTAssertTrue(store.isDetached(ref))

        store.removeWorkspace(ws.id)

        XCTAssertFalse(store.isDetached(ref), "removing the workspace must drop its detached ref")
        XCTAssertNil(store.workspaces.first(where: { $0.id == ws.id }))
    }

    /// Removing a workspace must also drop any `.worktree(workspaceID: ws.id, _)`
    /// refs that pointed at one of its worktrees — the worktree no longer exists.
    func testRemoveWorkspaceDropsWorktreeDetachedRefs() {
        let store = makeStore()
        let ws = WorkspaceModel(
            name: "repo",
            kind: .repository,
            repositoryRoot: URL(fileURLWithPath: "/tmp/repo")
        )
        let wt = WorktreeModel(
            id: UUID(),
            path: URL(fileURLWithPath: "/tmp/repo/.git/worktrees/foo"),
            branch: "foo",
            headCommit: "abc",
            isMainWorktree: false
        )
        ws.worktrees.append(wt)
        store.workspaces.append(ws)
        let wtRef = DetachedNodeRef.worktree(workspaceID: ws.id, worktreeID: wt.id)
        store.detachedNodes.insert(wtRef)
        XCTAssertTrue(store.isDetached(wtRef))

        store.removeWorkspace(ws.id)

        XCTAssertFalse(store.isDetached(wtRef), "removing the workspace must drop its worktree refs")
    }

    /// Removing one workspace must NOT drop detached refs for OTHER workspaces
    /// or for remote groups (which may still have members). Only the removed
    /// workspace's own refs and its worktree refs are cleaned up.
    func testRemoveWorkspaceLeavesUnrelatedDetachedRefs() {
        let store = makeStore()
        let wsA = WorkspaceModel(
            name: "repo-a",
            kind: .repository,
            repositoryRoot: URL(fileURLWithPath: "/tmp/repo-a")
        )
        let wsB = WorkspaceModel(
            name: "repo-b",
            kind: .repository,
            repositoryRoot: URL(fileURLWithPath: "/tmp/repo-b")
        )
        store.workspaces.append(contentsOf: [wsA, wsB])
        let keepRef = DetachedNodeRef.workspace(wsB.id)
        let groupRef = DetachedNodeRef.remoteGroup("host|root")
        store.detachedNodes = [DetachedNodeRef.workspace(wsA.id), keepRef, groupRef]

        store.removeWorkspace(wsA.id)

        XCTAssertFalse(store.isDetached(.workspace(wsA.id)), "removed workspace's ref should be gone")
        XCTAssertTrue(store.isDetached(keepRef), "unrelated workspace ref must survive")
        XCTAssertTrue(store.isDetached(groupRef), "remote-group ref must survive (group may have other members)")
    }

    // MARK: - Helpers

    /// Constructs a `WorkspaceStore` with no on-disk state so tests start clean.
    private func makeStore() -> WorkspaceStore {
        try? clearState()
        defer { try? clearState() }
        return WorkspaceStore()
    }

    private func writeState(_ state: PersistedWorkspaceState) throws {
        let dir = treemuxStateDirectoryURL()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("workspace-state.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
    }

    private func clearState() throws {
        let stateFile = treemuxStateDirectoryURL()
            .appendingPathComponent("workspace-state.json")
        if FileManager.default.fileExists(atPath: stateFile.path) {
            try FileManager.default.removeItem(at: stateFile)
        }
    }

    /// Builds an `SSHTarget` with defaults for the fields not relevant to
    /// detachment/grouping logic.
    private func makeSSHTarget(user: String?) -> SSHTarget {
        SSHTarget(
            host: "1.2.3.4",
            port: 22,
            user: user,
            identityFile: nil,
            displayName: "host",
            remotePath: "/srv"
        )
    }
}
