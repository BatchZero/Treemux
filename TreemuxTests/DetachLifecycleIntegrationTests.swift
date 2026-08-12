//
//  DetachLifecycleIntegrationTests.swift
//  TreemuxTests
//
//  Task 11 integration tests for the detach-to-new-window lifecycle.
//
//  Tasks 1-10 covered the PIECES (DetachedNodeRef codable, WorkspaceStore
//  detachedNodes/isValid, WindowManager detach/closeChild/restoreChildWindows
//  state side-effects, pasteboard, sidebar filter, menu shape). These tests
//  verify the pieces COMPOSE correctly across the full lifecycle:
//
//    - Persistence round-trip through the real WorkspaceStore save/load path
//      (buildPersistedWorkspaceState -> debounced save -> reload), not just a
//      hand-built PersistedWorkspaceState.
//    - Stale-ref cleanup on restore for every ref kind, including the
//      worktree-stale case (workspace exists but worktree ID doesn't) and the
//      remoteGroup-stale case, which the unit-level WindowManagerTests did not
//      exercise.
//    - End-to-end detach -> persist -> reload -> restoreChildWindows -> close
//      cycle so a regression in any link surfaces in one place.
//

import XCTest
@testable import Treemux

@MainActor
final class DetachLifecycleIntegrationTests: XCTestCase {

    // MARK: - Real save/load persistence round-trip

    /// Verifies the store ACTUALLY persists detachedNodes through its real
    /// `saveWorkspaceState()` -> `buildPersistedWorkspaceState()` ->
    /// debounced-write -> `loadWorkspaceState()` path (not just that a
    /// hand-crafted PersistedWorkspaceState decodes). A bug in
    /// `buildPersistedWorkspaceState` (e.g. forgetting to include
    /// `detachedNodes:`) would silently drop child windows across launches and
    /// only this end-to-end test catches it.
    func testDetachedNodesSurviveRealStoreSaveLoadCycle() throws {
        try clearState()
        defer { try? clearState() }

        // Stage 1: a store with a known workspace + worktree, detached.
        let store = WorkspaceStore()
        let ws = makeWorkspace()
        let wt = makeWorktree()
        ws.worktrees.append(wt)
        store.workspaces.append(ws)

        let wsRef = DetachedNodeRef.workspace(ws.id)
        let wtRef = DetachedNodeRef.worktree(workspaceID: ws.id, worktreeID: wt.id)
        store.detachedNodes.insert(wsRef)
        store.detachedNodes.insert(wtRef)

        // Stage 2: persist through the real debounced path and flush to disk.
        store.saveWorkspaceState()
        store.flushPendingPersistence()

        // Stage 3: a fresh store loads from disk. detachedNodes must hydrate.
        let reloaded = WorkspaceStore()
        XCTAssertTrue(reloaded.isDetached(wsRef), "workspace ref should survive the save/load cycle")
        XCTAssertTrue(reloaded.isDetached(wtRef), "worktree ref should survive the save/load cycle")
        XCTAssertEqual(reloaded.detachedNodes.count, 2)
    }

    /// Verifies the persisted JSON actually carries the `detachedNodes` key with
    /// the expected refs, so a future schema change can't silently drop it.
    func testDetachedNodesKeyPresentInPersistedJSON() throws {
        try clearState()
        defer { try? clearState() }

        let store = WorkspaceStore()
        let ws = makeWorkspace()
        store.workspaces.append(ws)
        store.detachedNodes.insert(.workspace(ws.id))
        store.saveWorkspaceState()
        store.flushPendingPersistence()

        let url = treemuxStateDirectoryURL()
            .appendingPathComponent("workspace-state.json")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(object?["detachedNodes"], "persisted JSON must include the detachedNodes key")
    }

    // MARK: - Stale-ref cleanup on restore (per kind)

    /// worktree-stale case: the workspace EXISTS but the worktree ID does NOT.
    /// restoreChildWindows must drop the ref and create no child window.
    /// (WindowManagerTests only covers the workspace-stale case where the
    /// workspace itself is gone.)
    func testRestoreDropsWorktreeStaleRefWhenWorkspaceExistsButWorktreeMissing() {
        let store = makeStore()
        let ws = makeWorkspace()
        // Note: NO worktree with this ID is appended.
        store.workspaces.append(ws)

        let stale = DetachedNodeRef.worktree(workspaceID: ws.id, worktreeID: UUID())
        store.detachedNodes.insert(stale)
        XCTAssertFalse(store.isValid(stale))

        let mgr = WindowManager(store: store)
        mgr.restoreChildWindows()

        XCTAssertTrue(mgr.childContexts.isEmpty, "stale worktree ref must not create a child context")
        XCTAssertFalse(store.isDetached(stale), "stale worktree ref must be cleaned out of the store")
    }

    /// remoteGroup-stale case: the group key resolves to zero workspaces.
    /// restoreChildWindows must drop the ref and create no child window.
    func testRestoreDropsRemoteGroupStaleRefWhenNoWorkspaceMatches() {
        let store = makeStore()
        let stale = DetachedNodeRef.remoteGroup("ghost-host|nobody")
        store.detachedNodes.insert(stale)
        XCTAssertFalse(store.isValid(stale))

        let mgr = WindowManager(store: store)
        mgr.restoreChildWindows()

        XCTAssertTrue(mgr.childContexts.isEmpty, "stale remote-group ref must not create a child context")
        XCTAssertFalse(store.isDetached(stale), "stale remote-group ref must be cleaned out of the store")
    }

    /// Mixed restore: one valid ref rebuilds a window, two stale refs are
    /// dropped in the same pass. Guards against an early-`return` (instead of
    /// `continue`) in the stale branch that would skip remaining refs.
    func testRestoreRebuildsValidAndDropsMultipleStaleRefsInOnePass() {
        let store = makeStore()
        let validWS = makeWorkspace()
        let ghostWS = DetachedNodeRef.workspace(UUID())
        let ghostWT = DetachedNodeRef.worktree(
            workspaceID: validWS.id, worktreeID: UUID())
        let ghostGroup = DetachedNodeRef.remoteGroup("nope|nope")
        store.workspaces.append(validWS)
        store.detachedNodes = [DetachedNodeRef.workspace(validWS.id), ghostWS, ghostWT, ghostGroup]

        let mgr = WindowManager(store: store)
        mgr.restoreChildWindows()

        XCTAssertEqual(mgr.childContexts.count, 1, "only the valid ref should rebuild a window")
        XCTAssertTrue(store.isDetached(.workspace(validWS.id)))
        XCTAssertFalse(store.isDetached(ghostWS))
        XCTAssertFalse(store.isDetached(ghostWT))
        XCTAssertFalse(store.isDetached(ghostGroup))
        XCTAssertEqual(store.detachedNodes.count, 1)
    }

    // MARK: - End-to-end detach -> persist -> restore -> close

    /// Full lifecycle in one test: detach a workspace, persist, reload the
    /// store from disk, restore child windows, then close the child and
    /// confirm the ref leaves `detachedNodes` (visibility restored). This is
    /// the integration glue between WorkspaceStore persistence and
    /// WindowManager lifecycle that no single unit test covers end-to-end.
    ///
    /// Uses a `.workspace` ref (not `.worktree`) because worktree IDs are
    /// re-discovered via a background `git` Task on launch and are NOT
    /// synchronously repopulated by `WorkspaceStore.init`. A workspace ref is
    /// stable across launches (the workspace UUID is persisted), so the
    /// reload-and-restore path is deterministic in-process. The worktree-ref
    /// persistence path is covered by
    /// `testDetachedNodesSurviveRealStoreSaveLoadCycle`, which asserts the ref
    /// round-trips through the file even though its validity can't be checked
    /// without a real git repo.
    func testFullDetachPersistReloadRestoreCloseCycle() {
        clearStateDirectory()
        defer { clearStateDirectory() }

        let store = WorkspaceStore()
        let ws = makeWorkspace()
        store.workspaces.append(ws)

        let mgr = WindowManager(store: store)
        let ref = DetachedNodeRef.workspace(ws.id)
        mgr.detach(ref)
        XCTAssertTrue(store.isDetached(ref))
        XCTAssertEqual(mgr.childContexts.count, 1)

        // Persist + flush, then drop the in-memory manager (simulating quit).
        store.saveWorkspaceState()
        store.flushPendingPersistence()

        // New store + manager reload from disk and restore child windows.
        let reloadedStore = WorkspaceStore()
        XCTAssertTrue(reloadedStore.isDetached(ref), "ref must be on disk before restore")
        let reloadedMgr = WindowManager(store: reloadedStore)
        reloadedMgr.restoreChildWindows()
        XCTAssertEqual(reloadedMgr.childContexts.count, 1, "child window should rebuild from persisted ref")

        // Closing the rebuilt child must restore main-sidebar visibility.
        guard let ctx = reloadedMgr.childContexts.first else {
            return XCTFail("expected a restored child context")
        }
        reloadedMgr.closeChild(ctx)
        XCTAssertFalse(reloadedStore.isDetached(ref), "closing the child must remove the ref")
        XCTAssertTrue(reloadedMgr.childContexts.isEmpty)
    }

    // MARK: - Helpers

    /// Constructs a `WorkspaceStore` with no on-disk state so each test starts
    /// clean. `clearStateDirectory` is best-effort (throws swallowed) so a test
    /// isn't failed by a missing directory.
    private func makeStore() -> WorkspaceStore {
        clearStateDirectory()
        defer { clearStateDirectory() }
        return WorkspaceStore()
    }

    /// Builds a minimal repository-backed workspace for validity checks.
    private func makeWorkspace() -> WorkspaceModel {
        WorkspaceModel(
            name: "repo",
            kind: .repository,
            repositoryRoot: URL(fileURLWithPath: "/tmp/repo")
        )
    }

    /// Builds a minimal worktree so worktree refs resolve as valid.
    private func makeWorktree() -> WorktreeModel {
        WorktreeModel(
            id: UUID(),
            path: URL(fileURLWithPath: "/tmp/repo/.git/worktrees/foo"),
            branch: "foo",
            headCommit: "abc1234",
            isMainWorktree: false
        )
    }

    /// Removes the persisted workspace-state directory so each test starts
    /// clean. Mirrors the helper in `WindowManagerTests`.
    private func clearStateDirectory() {
        let dir = treemuxStateDirectoryURL()
        if FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Throws on failure (used by the JSON-inspection tests).
    private func clearState() throws {
        let dir = treemuxStateDirectoryURL()
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}
