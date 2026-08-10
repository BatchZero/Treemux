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

    /// Regression test for the `sidebarIconCache` invalidation in `saveWorkspaceState()`.
    ///
    /// This does NOT test `ws`'s own override (that path short-circuits *before*
    /// the cache is even consulted — see `sidebarIcon(for:)`'s
    /// `if let override = workspace.workspaceIcon { return override }` — so it can
    /// never exercise `sidebarIconCache`). Instead it targets the one place where a
    /// sibling workspace's icon override actually feeds back into `ws`'s own
    /// *generated* icon: `sidebarIcon(for:)` builds its "avoiding" set from
    /// `workspaces.compactMap { $0.workspaceIcon ?? generatedRepositoryIcon(for: $0) }`,
    /// so giving a sibling workspace an override changes what `ws` must avoid.
    ///
    /// Both workspaces share the same seed ("widgets", from their identical
    /// `lastPathComponent`), which — because `.randomRepository(preferredSeed:avoiding:)`
    /// is fully deterministic (stableHash + mix64, no `shuffled`/`randomElement`) —
    /// guarantees `sibling`'s pre-override generated icon collides exactly with
    /// `ws`'s own top-ranked candidate. That collision is what forces `ws`'s icon to
    /// change once the collision is removed (sibling gets an override that isn't in
    /// the repository icon catalog at all, so it can never collide with anything).
    /// Verified empirically with a standalone harness driving the real
    /// `SidebarIconCatalog`/`SidebarItemIcon` sources:
    ///   - ws solo (avoiding: [])                      -> binoculars.fill / plum
    ///   - ws primed while sibling still generated       -> paintpalette.fill / mocha (collision penalty)
    ///   - ws recomputed after sibling gets an override  -> binoculars.fill / plum (matches solo again)
    /// i.e. priming captures a *different* value than the correct post-invalidation
    /// value, which is exactly the shape needed to catch a missing cache-clear.
    func testSidebarIconCacheInvalidatesAfterIconOverrideChange() throws {
        let repoID = UUID()
        let siblingID = UUID()
        try writeState(PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: nil,
            workspaces: [
                makeRepoRecord(id: repoID, name: "beta", path: "/tmp/proj1/widgets"),
                makeRepoRecord(id: siblingID, name: "beta-sibling", path: "/tmp/proj2/widgets")
            ]
        ))
        let store = WorkspaceStore()
        guard let ws = store.workspaces.first(where: { $0.id == repoID }) else {
            XCTFail("expected fixture workspace to load")
            return
        }

        // Sanity check: a workspace's own override still short-circuits generation.
        // (Valid behavior, but not itself proof of cache invalidation — see doc comment above.)
        let ownOverride = SidebarItemIcon(symbolName: "star.fill", palette: .gold, fillStyle: .solid)
        store.updateSidebarIcon(ownOverride, for: .workspace(repoID))
        XCTAssertEqual(store.sidebarIcon(for: ws), ownOverride)
        store.resetSidebarIcon(for: .workspace(repoID))

        // Prime `ws`'s cache while `sibling` still has its own (colliding) generated icon.
        let stalePrimed = store.sidebarIcon(for: ws)

        // Give the sibling an override that cannot collide with any catalog candidate,
        // changing the "avoiding" set `ws`'s generated icon must be recomputed against.
        let siblingOverride = SidebarItemIcon(symbolName: "star.fill", palette: .gold, fillStyle: .solid)
        store.updateSidebarIcon(siblingOverride, for: .workspace(siblingID))

        // Workspace-state writes are now debounced (P3); force the pending write
        // to disk before the oracle store below re-reads it.
        store.flushPendingPersistence()

        // Oracle: a brand-new store reading the same persisted state has an empty
        // cache, so its answer is always freshly computed — never stale.
        let oracleStore = WorkspaceStore()
        guard let oracleWs = oracleStore.workspaces.first(where: { $0.id == repoID }) else {
            XCTFail("expected fixture workspace to load in oracle store")
            return
        }
        let freshValue = oracleStore.sidebarIcon(for: oracleWs)

        XCTAssertNotEqual(stalePrimed, freshValue,
                          "fixture must be constructed so the pre- and post-mutation icons actually differ, " +
                          "otherwise this test cannot distinguish a missing cache invalidation from a no-op")
        XCTAssertEqual(store.sidebarIcon(for: ws), freshValue,
                       "cache must be invalidated so `ws`'s icon is recomputed against the sibling's new " +
                       "override rather than replaying the stale pre-override generated icon")
    }

    /// Regression test for the `sidebarIconCache` invalidation in `saveWorkspaceState()`.
    ///
    /// Uses the same deterministic-seed-collision trick as the override test above:
    /// `ws` and the newly added workspace share the seed "widgets" (identical
    /// `lastPathComponent`), so the newcomer's generated icon is guaranteed to collide
    /// with `ws`'s own top-ranked candidate, which guarantees `ws`'s generated icon
    /// actually changes once it must avoid that collision. Verified with the same
    /// standalone harness (see above): ws solo == binoculars.fill/plum,
    /// ws-after-collision == paintpalette.fill/mocha.
    func testSidebarIconCacheInvalidatesAfterAddingWorkspace() throws {
        let repoID = UUID()
        try writeState(PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: nil,
            workspaces: [makeRepoRecord(id: repoID, name: "gamma", path: "/tmp/proj1/widgets")]
        ))
        let store = WorkspaceStore()
        guard let ws = store.workspaces.first(where: { $0.id == repoID }) else {
            XCTFail("expected fixture workspace to load")
            return
        }
        let stalePrimed = store.sidebarIcon(for: ws) // populate cache while `ws` is the only repository

        // Same lastPathComponent ("widgets") as `ws`, so its generated icon collides
        // with `ws`'s top candidate and forces `ws`'s own icon to change once the
        // cache is correctly invalidated.
        store.addWorkspaceFromPath(URL(fileURLWithPath: "/tmp/proj2/widgets"))

        // Workspace-state writes are now debounced (P3); force the pending write
        // to disk before the oracle store below re-reads it.
        store.flushPendingPersistence()

        // Oracle: a brand-new store reading the same (now-updated) persisted state
        // has an empty cache, so its answer is always freshly computed — never stale.
        let oracleStore = WorkspaceStore()
        guard let oracleWs = oracleStore.workspaces.first(where: { $0.id == repoID }) else {
            XCTFail("expected fixture workspace to load in oracle store")
            return
        }
        let freshValue = oracleStore.sidebarIcon(for: oracleWs)

        XCTAssertNotEqual(stalePrimed, freshValue,
                          "fixture must be constructed so the pre- and post-mutation icons actually differ, " +
                          "otherwise this test cannot distinguish a missing cache invalidation from a no-op")
        XCTAssertEqual(store.sidebarIcon(for: ws), freshValue,
                       "cache must be invalidated so `ws`'s icon is recomputed against the newly added " +
                       "sibling's icon rather than replaying the stale pre-add generated icon")
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

    func testRemoteGroupsUseAlphabeticalOrderForLegacyState() throws {
        try writeState(PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: nil,
            workspaces: remoteRecords(hosts: ["charlie", "alpha", "bravo"])
        ))

        let store = WorkspaceStore()

        XCTAssertEqual(store.remoteWorkspaceGroups.map(\.key), ["alpha|root", "bravo|root", "charlie|root"])
    }

    func testRemoteGroupsUseSavedOrderAndAppendNewGroupsAlphabetically() throws {
        try writeState(PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: nil,
            workspaces: remoteRecords(hosts: ["delta", "bravo", "charlie", "alpha"]),
            remoteGroupOrder: ["bravo|root", "alpha|root"]
        ))

        let store = WorkspaceStore()

        XCTAssertEqual(
            store.remoteWorkspaceGroups.map(\.key),
            ["bravo|root", "alpha|root", "charlie|root", "delta|root"]
        )
    }

    func testMoveRemoteGroupForwardAndBackward() throws {
        try writeState(PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: nil,
            workspaces: remoteRecords(hosts: ["alpha", "bravo", "charlie"])
        ))
        let store = WorkspaceStore()

        store.moveRemoteGroup("charlie|root", to: 0)
        XCTAssertEqual(store.remoteWorkspaceGroups.map(\.key), ["charlie|root", "alpha|root", "bravo|root"])

        store.moveRemoteGroup("charlie|root", to: 3)
        XCTAssertEqual(store.remoteWorkspaceGroups.map(\.key), ["alpha|root", "bravo|root", "charlie|root"])
    }

    func testMovedRemoteGroupOrderSurvivesRestart() throws {
        try writeState(PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: nil,
            workspaces: remoteRecords(hosts: ["alpha", "bravo", "charlie"])
        ))
        let store = WorkspaceStore()

        store.moveRemoteGroup("charlie|root", to: 0)
        store.flushPendingPersistence()
        let restarted = WorkspaceStore()

        XCTAssertEqual(restarted.remoteWorkspaceGroups.map(\.key), ["charlie|root", "alpha|root", "bravo|root"])
    }

    func testRemoteGroupOrderPrunesStaleKeysOnSaveAndSurvivesRestart() throws {
        try writeState(PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: nil,
            workspaces: remoteRecords(hosts: ["alpha", "bravo"]),
            remoteGroupOrder: ["missing|root", "bravo|root"]
        ))
        let store = WorkspaceStore()

        store.saveWorkspaceState()
        store.flushPendingPersistence()
        let restarted = WorkspaceStore()

        XCTAssertEqual(restarted.remoteWorkspaceGroups.map(\.key), ["bravo|root", "alpha|root"])
        XCTAssertEqual(WorkspaceStatePersistence().load().remoteGroupOrder, ["bravo|root", "alpha|root"])
    }

    func testChangedRemoteGroupIdentityAppendsAsNewGroup() throws {
        try writeState(PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: nil,
            workspaces: remoteRecords(hosts: ["stable", "renamed"]),
            remoteGroupOrder: ["old-name|root", "stable|root"]
        ))

        let store = WorkspaceStore()

        XCTAssertEqual(store.remoteWorkspaceGroups.map(\.key), ["stable|root", "renamed|root"])
    }

    private func remoteRecords(hosts: [String]) -> [WorkspaceRecord] {
        hosts.map { host in
            makeRepoRecord(
                id: UUID(),
                name: "\(host)-project",
                path: nil,
                sshTarget: makeSSHTarget(host: host, remotePath: "/srv/\(host)")
            )
        }
    }
}
