//
//  SidebarContextMenuTests.swift
//  TreemuxTests
//

import AppKit
import XCTest
@testable import Treemux

@MainActor
final class SidebarContextMenuTests: XCTestCase {

    // Localized expected titles. We resolve them with String(localized:) so the
    // assertions hold regardless of whether the test host loads the app's
    // localized resources (e.g. zh-Hans) or falls back to the source language.
    private let changeIconTitle = String(localized: "Change Icon…")
    private let renameTitle = String(localized: "Rename…")
    private let deleteTitle = String(localized: "Delete")

    private func nonSeparatorTitles(_ items: [NSMenuItem]) -> [String] {
        items.filter { !$0.isSeparatorItem }.map { $0.title }
    }

    private func makeCoordinator() -> SidebarCoordinator {
        // The coordinator's container/store/theme dependencies are not used by
        // workspaceContextMenuItems(for:), so a default SidebarCoordinator is sufficient.
        return SidebarCoordinator()
    }

    func testBuiltInTerminalShowsOnlyChangeIcon() {
        let coordinator = makeCoordinator()
        let builtin = WorkspaceModel(
            id: WorkspaceModel.builtInDefaultTerminalID,
            name: "~",
            kind: .localTerminal,
            repositoryRoot: URL(fileURLWithPath: NSHomeDirectory()),
            isBuiltInDefaultTerminal: true
        )
        let items = coordinator.workspaceContextMenuItems(for: builtin)
        XCTAssertEqual(nonSeparatorTitles(items), [changeIconTitle])
        XCTAssertFalse(items.contains { $0.isSeparatorItem }, "Built-in menu must not contain a trailing separator")
    }

    func testRepositoryShowsAllThreeItems() {
        let coordinator = makeCoordinator()
        let repo = WorkspaceModel(
            id: UUID(),
            name: "myproj",
            kind: .repository,
            repositoryRoot: URL(fileURLWithPath: "/tmp/myproj")
        )
        let items = coordinator.workspaceContextMenuItems(for: repo)
        XCTAssertEqual(nonSeparatorTitles(items), [changeIconTitle, renameTitle, deleteTitle])
        XCTAssertTrue(items.contains { $0.isSeparatorItem }, "Repository menu should contain a separator before Delete")
    }

    func testNonBuiltInLocalTerminalShowsChangeIconAndDelete() {
        let coordinator = makeCoordinator()
        let localTerm = WorkspaceModel(
            id: UUID(),
            name: "scratch",
            kind: .localTerminal,
            repositoryRoot: URL(fileURLWithPath: "/tmp/scratch")
        )
        let items = coordinator.workspaceContextMenuItems(for: localTerm)
        XCTAssertEqual(nonSeparatorTitles(items), [changeIconTitle, deleteTitle])
    }

    func testOnlyRemoteSectionsWriteTheDedicatedServerGroupDragPayload() {
        let coordinator = makeCoordinator()
        let outlineView = NSOutlineView()
        let workspace = WorkspaceModel(
            id: UUID(),
            name: "remote-project",
            kind: .repository,
            sshTarget: SSHTarget(
                host: "example.test",
                port: 22,
                user: "root",
                identityFile: nil,
                displayName: "example",
                remotePath: "/srv/project"
            )
        )
        let remoteSection = SidebarNodeItem(
            kind: .section(.remote(groupKey: "example|root", displayTitle: "example (root@example.test)"))
        )
        let localSection = SidebarNodeItem(kind: .section(.local))
        let workspaceNode = SidebarNodeItem(kind: .workspace(workspace))

        let remoteWriter = coordinator.outlineView(outlineView, pasteboardWriterForItem: remoteSection)
            as? NSPasteboardItem
        XCTAssertEqual(remoteWriter?.string(forType: NSPasteboard.PasteboardType("com.treemux.remote-group.key")), "example|root")
        XCTAssertNil(remoteWriter?.string(forType: NSPasteboard.PasteboardType("com.treemux.workspace.ids")))

        XCTAssertNil(coordinator.outlineView(outlineView, pasteboardWriterForItem: localSection))

        let workspaceWriter = coordinator.outlineView(outlineView, pasteboardWriterForItem: workspaceNode)
            as? NSPasteboardItem
        XCTAssertEqual(workspaceWriter?.string(forType: NSPasteboard.PasteboardType("com.treemux.workspace.ids")), workspace.id.uuidString)
        XCTAssertNil(workspaceWriter?.string(forType: NSPasteboard.PasteboardType("com.treemux.remote-group.key")))
    }

    func testRemoteGroupRootDropKeepsLocalSectionPinned() {
        let sections: [SidebarSection] = [
            .local,
            .remote(groupKey: "alpha|root", displayTitle: "Alpha"),
            .remote(groupKey: "bravo|root", displayTitle: "Bravo")
        ]

        XCTAssertNil(
            SidebarCoordinator.remoteGroupInsertionIndex(
                for: "bravo|root",
                rootSections: sections,
                rootIndex: 0
            ),
            "a remote header must never move above the local section"
        )
        XCTAssertEqual(
            SidebarCoordinator.remoteGroupInsertionIndex(
                for: "bravo|root",
                rootSections: sections,
                rootIndex: 1
            ),
            0,
            "the root insertion point immediately after local is before the first remote group"
        )
        XCTAssertEqual(
            SidebarCoordinator.remoteGroupInsertionIndex(
                for: "alpha|root",
                rootSections: sections,
                rootIndex: 3
            ),
            2,
            "the final root insertion point is after every remote group"
        )
    }
}
