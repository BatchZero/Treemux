//
//  SidebarDetachFilterTests.swift
//  TreemuxTests
//
//  Pure unit tests for `SidebarCoordinator.filterRootNodes(_:detached:)`.
//  Verifies that nodes marked detached in `WorkspaceStore.detachedNodes` are
//  hidden from the main sidebar tree while torn off into their own window.
//

import XCTest
@testable import Treemux

@MainActor
final class SidebarDetachFilterTests: XCTestCase {

    // MARK: - Workspace filtering

    func testDetachedWorkspaceIsFilteredOut() {
        let ws = WorkspaceModel(name: "a", kind: .repository)
        let node = SidebarNodeItem(kind: .workspace(ws))
        let filtered = SidebarCoordinator.filterRootNodes(
            [node],
            detached: [.workspace(ws.id)]
        )
        XCTAssertTrue(filtered.isEmpty, "a detached workspace must not appear in the sidebar")
    }

    func testNonDetachedWorkspaceStays() {
        let ws = WorkspaceModel(name: "a", kind: .repository)
        let node = SidebarNodeItem(kind: .workspace(ws))
        let filtered = SidebarCoordinator.filterRootNodes([node], detached: [])
        XCTAssertEqual(filtered.count, 1)
    }

    // MARK: - Local section filtering

    func testLocalSectionAlwaysKept() {
        let localSection = SidebarNodeItem(kind: .section(.local))
        let filtered = SidebarCoordinator.filterRootNodes([localSection], detached: [])
        XCTAssertEqual(filtered.count, 1)
        if case .section(let section) = filtered.first?.kind {
            if case .local = section { /* ok */ } else {
                XCTFail("expected .local section to be preserved")
            }
        } else {
            XCTFail("expected a section node")
        }
    }

    // MARK: - Remote group filtering

    func testDetachedRemoteGroupFiltersWholeSection() {
        let section = SidebarNodeItem(
            kind: .section(.remote(groupKey: "srv|u", displayTitle: "srv"))
        )
        let filtered = SidebarCoordinator.filterRootNodes(
            [section],
            detached: [.remoteGroup("srv|u")]
        )
        XCTAssertTrue(filtered.isEmpty, "a detached remote group must drop its whole section")
    }

    func testNonDetachedRemoteSectionStays() {
        let section = SidebarNodeItem(
            kind: .section(.remote(groupKey: "srv|u", displayTitle: "srv"))
        )
        let filtered = SidebarCoordinator.filterRootNodes([section], detached: [])
        XCTAssertEqual(filtered.count, 1)
    }

    // MARK: - Worktree (child) filtering

    func testDetachedWorktreeFiltersChildOnlyParentStays() {
        let ws = WorkspaceModel(name: "a", kind: .repository)
        let wt = WorktreeModel(
            id: UUID(),
            path: URL(fileURLWithPath: "/tmp/a-wt"),
            branch: "feature",
            headCommit: nil,
            isMainWorktree: false
        )
        let child = SidebarNodeItem(kind: .worktree(ws, wt))
        let parent = SidebarNodeItem(kind: .workspace(ws), children: [child])

        let filtered = SidebarCoordinator.filterRootNodes(
            [parent],
            detached: [.worktree(workspaceID: ws.id, worktreeID: wt.id)]
        )
        XCTAssertEqual(filtered.count, 1, "parent workspace must stay when only a child is detached")
        XCTAssertEqual(filtered.first?.children.count, 0, "detached worktree child must be removed")
    }

    func testNonDetachedWorktreeChildStays() {
        let ws = WorkspaceModel(name: "a", kind: .repository)
        let wt = WorktreeModel(
            id: UUID(),
            path: URL(fileURLWithPath: "/tmp/a-wt"),
            branch: "feature",
            headCommit: nil,
            isMainWorktree: false
        )
        let child = SidebarNodeItem(kind: .worktree(ws, wt))
        let parent = SidebarNodeItem(kind: .workspace(ws), children: [child])

        let filtered = SidebarCoordinator.filterRootNodes([parent], detached: [])
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.children.count, 1)
    }

    func testOnlyMatchingWorktreeChildRemovedSiblingStays() {
        let ws = WorkspaceModel(name: "a", kind: .repository)
        let keptWT = WorktreeModel(
            id: UUID(),
            path: URL(fileURLWithPath: "/tmp/a-main"),
            branch: "main",
            headCommit: nil,
            isMainWorktree: true
        )
        let detachedWT = WorktreeModel(
            id: UUID(),
            path: URL(fileURLWithPath: "/tmp/a-feat"),
            branch: "feature",
            headCommit: nil,
            isMainWorktree: false
        )
        let keptChild = SidebarNodeItem(kind: .worktree(ws, keptWT))
        let detachedChild = SidebarNodeItem(kind: .worktree(ws, detachedWT))
        let parent = SidebarNodeItem(kind: .workspace(ws), children: [keptChild, detachedChild])

        let filtered = SidebarCoordinator.filterRootNodes(
            [parent],
            detached: [.worktree(workspaceID: ws.id, worktreeID: detachedWT.id)]
        )
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.children.count, 1)
        // Remaining child should be the kept one.
        XCTAssertEqual(filtered.first?.children.first?.worktree?.id, keptWT.id)
    }

    // MARK: - Root-level worktree (unusual)

    func testRootLevelWorktreeKeptAsIs() {
        let ws = WorkspaceModel(name: "a", kind: .repository)
        let wt = WorktreeModel(
            id: UUID(),
            path: URL(fileURLWithPath: "/tmp/a-wt"),
            branch: "feature",
            headCommit: nil,
            isMainWorktree: false
        )
        let node = SidebarNodeItem(kind: .worktree(ws, wt))
        // No rule drops a root-level worktree today; keep as-is.
        let filtered = SidebarCoordinator.filterRootNodes([node], detached: [])
        XCTAssertEqual(filtered.count, 1)
    }
}
