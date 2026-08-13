//
//  SidebarDetachFilterTests.swift
//  TreemuxTests
//
//  Pure unit tests for `SidebarCoordinator.filterRootNodes(_:detached:)`.
//  Verifies that nodes marked detached in `WorkspaceStore.detachedNodes` are
//  hidden from the main sidebar tree while torn off into their own window.
//

import AppKit
import SwiftUI
import XCTest
@testable import Treemux

@MainActor
final class SidebarDetachFilterTests: XCTestCase {

    func testLiveSidebarRemovesWorkspaceWhenDetachedSetChanges() throws {
        let store = WorkspaceStore()
        let workspace = WorkspaceModel(name: "visible", kind: .repository)
        store.workspaces = [workspace]
        store.selectedWorkspaceID = workspace.id

        let theme = ThemeManager(activeThemeID: store.settings.activeThemeID)
        let language = LanguageManager(languageCode: "en")
        let manager = WindowManager(store: store)
        let root = WorkspaceSidebarView()
            .environment(store)
            .environment(theme)
            .environment(language)
            .environment(manager)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let outline = try XCTUnwrap(findOutlineView(in: hostingView))
        XCTAssertEqual(outline.numberOfRows, 1)

        manager.detach(.workspace(workspace.id))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(
            outline.numberOfRows,
            0,
            "changing detachedNodes must invalidate the SwiftUI/AppKit bridge and hide the row"
        )

        let child = try XCTUnwrap(manager.childContexts.first)
        manager.closeChild(child)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(outline.numberOfRows, 1, "closing the child must restore the sidebar row")
    }

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

    func testDetachedWorkspaceIsFilteredInsideLocalSection() {
        let workspace = WorkspaceModel(name: "local", kind: .repository)
        let section = SidebarNodeItem(
            kind: .section(.local),
            children: [SidebarNodeItem(kind: .workspace(workspace))]
        )

        let filtered = SidebarCoordinator.filterRootNodes(
            [section],
            detached: [.workspace(workspace.id)]
        )

        XCTAssertTrue(filtered.isEmpty, "an empty local section must disappear with its detached child")
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

    func testDetachedWorkspaceIsFilteredInsideRemoteSection() {
        let workspace = WorkspaceModel(name: "remote", kind: .repository)
        let sibling = WorkspaceModel(name: "sibling", kind: .repository)
        let section = SidebarNodeItem(
            kind: .section(.remote(groupKey: "srv|u", displayTitle: "srv")),
            children: [
                SidebarNodeItem(kind: .workspace(workspace)),
                SidebarNodeItem(kind: .workspace(sibling))
            ]
        )

        let filtered = SidebarCoordinator.filterRootNodes(
            [section],
            detached: [.workspace(workspace.id)]
        )

        XCTAssertEqual(filtered.first?.children.map(\.workspace?.id), [sibling.id])
    }

    func testDetachedWorktreeIsFilteredInsideSectionWorkspace() {
        let workspace = WorkspaceModel(name: "local", kind: .repository)
        let worktree = WorktreeModel(
            id: UUID(),
            path: URL(fileURLWithPath: "/tmp/local-feature"),
            branch: "feature",
            headCommit: nil,
            isMainWorktree: false
        )
        let workspaceNode = SidebarNodeItem(
            kind: .workspace(workspace),
            children: [SidebarNodeItem(kind: .worktree(workspace, worktree))]
        )
        let section = SidebarNodeItem(kind: .section(.local), children: [workspaceNode])

        let filtered = SidebarCoordinator.filterRootNodes(
            [section],
            detached: [.worktree(workspaceID: workspace.id, worktreeID: worktree.id)]
        )

        XCTAssertEqual(filtered.first?.children.first?.children.count, 0)
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

    private func findOutlineView(in view: NSView) -> SidebarOutlineView? {
        if let outline = view as? SidebarOutlineView { return outline }
        for child in view.subviews {
            if let outline = findOutlineView(in: child) { return outline }
        }
        return nil
    }
}
