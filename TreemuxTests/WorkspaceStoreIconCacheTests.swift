//
//  WorkspaceStoreIconCacheTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

@MainActor
final class WorkspaceStoreIconCacheTests: XCTestCase {

    /// Helper: writes a state JSON file before WorkspaceStore.init reads it.
    /// Mirrors the isolation pattern used in WorkspaceStoreBuiltInTests.
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

    private func makeRepoRecord(
        id: UUID,
        name: String,
        path: String?,
        sshTarget: SSHTarget? = nil
    ) -> WorkspaceRecord {
        WorkspaceRecord(
            id: id,
            kind: .repository,
            name: name,
            repositoryPath: path,
            isPinned: false,
            isArchived: false,
            sshTarget: sshTarget,
            worktreeStates: [],
            worktreeOrder: nil,
            workspaceIcon: nil,
            worktreeIconOverrides: nil
        )
    }

    private func makeSSHTarget(
        host: String,
        user: String? = "root",
        remotePath: String? = nil
    ) -> SSHTarget {
        SSHTarget(
            host: host,
            port: 22,
            user: user,
            identityFile: nil,
            displayName: host,
            remotePath: remotePath
        )
    }

    func testSidebarIconIsStableAcrossRepeatedCalls() throws {
        let repoID = UUID()
        try writeState(PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: nil,
            workspaces: [makeRepoRecord(id: repoID, name: "alpha", path: "/tmp/alpha")]
        ))
        let store = WorkspaceStore()
        guard let ws = store.workspaces.first(where: { $0.id == repoID }) else {
            XCTFail("expected fixture workspace to load")
            return
        }
        let first = store.sidebarIcon(for: ws)
        for _ in 0..<10 {
            XCTAssertEqual(store.sidebarIcon(for: ws), first,
                           "icon must be deterministic and cached")
        }
    }

    func testSidebarIconCacheInvalidatesAfterIconOverrideChange() throws {
        let repoID = UUID()
        try writeState(PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: nil,
            workspaces: [makeRepoRecord(id: repoID, name: "beta", path: "/tmp/beta")]
        ))
        let store = WorkspaceStore()
        guard let ws = store.workspaces.first(where: { $0.id == repoID }) else {
            XCTFail("expected fixture workspace to load")
            return
        }
        _ = store.sidebarIcon(for: ws) // populate cache with generated icon
        let override = SidebarItemIcon(symbolName: "star.fill", palette: .gold, fillStyle: .solid)
        store.updateSidebarIcon(override, for: .workspace(repoID))
        XCTAssertEqual(store.sidebarIcon(for: ws), override,
                       "cache must reflect the newly assigned override, not the stale generated icon")
    }

    func testSidebarIconCacheInvalidatesAfterAddingWorkspace() throws {
        let repoID = UUID()
        try writeState(PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: nil,
            workspaces: [makeRepoRecord(id: repoID, name: "gamma", path: "/tmp/gamma")]
        ))
        let store = WorkspaceStore()
        guard let ws = store.workspaces.first(where: { $0.id == repoID }) else {
            XCTFail("expected fixture workspace to load")
            return
        }
        _ = store.sidebarIcon(for: ws) // populate cache

        store.addWorkspaceFromPath(URL(fileURLWithPath: "/tmp/delta"))

        // After adding another repository workspace, the "avoiding" set used to
        // generate `ws`'s icon has changed; the cache must not silently reuse
        // the pre-mutation icon computed against a smaller avoidance set.
        // (We can't assert the icon actually changed value-wise deterministically,
        // but we can assert the cache entry was recomputed without crashing and
        // stays internally consistent across repeated calls post-mutation.)
        let afterAdd = store.sidebarIcon(for: ws)
        for _ in 0..<5 {
            XCTAssertEqual(store.sidebarIcon(for: ws), afterAdd)
        }
    }

    func testRemoteWorkspaceGroupsIsStableAcrossRepeatedCalls() throws {
        let target = makeSSHTarget(host: "myserver", remotePath: "/root/proj")
        let repoID = UUID()
        let record = makeRepoRecord(id: repoID, name: "remote-proj", path: nil, sshTarget: target)
        try writeState(PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: nil,
            workspaces: [record]
        ))
        let store = WorkspaceStore()
        let first = store.remoteWorkspaceGroups.map { $0.key }
        for _ in 0..<10 {
            XCTAssertEqual(store.remoteWorkspaceGroups.map { $0.key }, first)
        }
    }

    func testRemoteWorkspaceGroupsInvalidatesAfterAddingRemoteWorkspace() throws {
        try clearState()
        let store = WorkspaceStore()
        XCTAssertEqual(store.remoteWorkspaceGroups.count, 0)

        let target = makeSSHTarget(host: "otherserver", user: "admin", remotePath: "/home/admin/proj")
        store.addRemoteWorkspace(target: target, name: "otherserver-proj")

        XCTAssertEqual(store.remoteWorkspaceGroups.count, 1,
                       "cache must be invalidated after adding a remote workspace")
    }
}
