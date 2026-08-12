//
//  DetachedNodeRefTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

final class DetachedNodeRefTests: XCTestCase {
    func testWorkspaceCodableRoundTrip() throws {
        let id = UUID()
        let ref = DetachedNodeRef.workspace(id)
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(DetachedNodeRef.self, from: data)
        XCTAssertEqual(decoded, ref)
    }

    func testWorktreeCodableRoundTrip() throws {
        let wsID = UUID()
        let wtID = UUID()
        let ref = DetachedNodeRef.worktree(workspaceID: wsID, worktreeID: wtID)
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(DetachedNodeRef.self, from: data)
        XCTAssertEqual(decoded, ref)
    }

    func testRemoteGroupCodableRoundTrip() throws {
        let ref = DetachedNodeRef.remoteGroup("my-server|root")
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(DetachedNodeRef.self, from: data)
        XCTAssertEqual(decoded, ref)
    }

    func testHashableDistinguishesCases() {
        let id = UUID()
        let a = DetachedNodeRef.workspace(id)
        let b = DetachedNodeRef.remoteGroup("x")
        XCTAssertNotEqual(a, b)
    }

    func testWorktreeWithSameWorkspaceButDifferentWorktreeNotEqual() {
        let wsID = UUID()
        let a = DetachedNodeRef.worktree(workspaceID: wsID, worktreeID: UUID())
        let b = DetachedNodeRef.worktree(workspaceID: wsID, worktreeID: UUID())
        XCTAssertNotEqual(a, b)
    }

    func testAutosaveKeySuffixIsStableAndDistinct() {
        // Autosave suffixes must be stable for a given ref and distinct across cases.
        let wsID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let wtID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let ws = DetachedNodeRef.workspace(wsID)
        let wt = DetachedNodeRef.worktree(workspaceID: wsID, worktreeID: wtID)
        let rg = DetachedNodeRef.remoteGroup("my-server|root")

        XCTAssertEqual(ws.autosaveKeySuffix, ws.autosaveKeySuffix)
        XCTAssertEqual(wt.autosaveKeySuffix, wt.autosaveKeySuffix)
        XCTAssertEqual(rg.autosaveKeySuffix, rg.autosaveKeySuffix)

        XCTAssertNotEqual(ws.autosaveKeySuffix, wt.autosaveKeySuffix)
        XCTAssertNotEqual(ws.autosaveKeySuffix, rg.autosaveKeySuffix)
        XCTAssertNotEqual(wt.autosaveKeySuffix, rg.autosaveKeySuffix)

        // Workspace suffix should embed the UUID so different workspaces differ.
        let wsOther = DetachedNodeRef.workspace(
            UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        XCTAssertNotEqual(ws.autosaveKeySuffix, wsOther.autosaveKeySuffix)

        // Remote group suffix should embed the string so different groups differ.
        let rgOther = DetachedNodeRef.remoteGroup("my-server|home")
        XCTAssertNotEqual(rg.autosaveKeySuffix, rgOther.autosaveKeySuffix)
    }
}
