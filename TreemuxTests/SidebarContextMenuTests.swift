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
    private let openInNewWindowTitle = String(localized: "Open in New Window")
    private let alreadyInNewWindowTitle = String(localized: "Already in New Window")

    private func nonSeparatorTitles(_ items: [NSMenuItem]) -> [String] {
        items.filter { !$0.isSeparatorItem }.map { $0.title }
    }

    private func makeCoordinator() -> SidebarCoordinator {
        // The coordinator's container/store/theme dependencies are not used by
        // workspaceContextMenuItems(for:), so a default SidebarCoordinator is sufficient.
        return SidebarCoordinator()
    }

    /// Builds a coordinator wired to a fresh WorkspaceStore so the "Open in New
    /// Window" / "Already in New Window" menu item state (driven by
    /// `store.isDetached`) can be exercised.
    @discardableResult
    private func makeCoordinatorWithStore() -> (SidebarCoordinator, WorkspaceStore) {
        let coordinator = SidebarCoordinator()
        let store = WorkspaceStore()
        coordinator.store = store
        return (coordinator, store)
    }

    func testBuiltInTerminalShowsChangeIconAndOpenInNewWindow() {
        let coordinator = makeCoordinator()
        let builtin = WorkspaceModel(
            id: WorkspaceModel.builtInDefaultTerminalID,
            name: "~",
            kind: .localTerminal,
            repositoryRoot: URL(fileURLWithPath: NSHomeDirectory()),
            isBuiltInDefaultTerminal: true
        )
        let items = coordinator.workspaceContextMenuItems(for: builtin)
        XCTAssertEqual(nonSeparatorTitles(items), [changeIconTitle, openInNewWindowTitle])
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
        XCTAssertEqual(nonSeparatorTitles(items), [changeIconTitle, openInNewWindowTitle, renameTitle, deleteTitle])
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
        XCTAssertEqual(nonSeparatorTitles(items), [changeIconTitle, openInNewWindowTitle, deleteTitle])
    }

    func testWorkspaceContextMenuIncludesOpenInNewWindow() {
        let (coordinator, _) = makeCoordinatorWithStore()
        let repo = WorkspaceModel(
            id: UUID(),
            name: "myproj",
            kind: .repository,
            repositoryRoot: URL(fileURLWithPath: "/tmp/myproj")
        )
        let items = coordinator.workspaceContextMenuItems(for: repo)
        let titles = nonSeparatorTitles(items)
        XCTAssertTrue(titles.contains(openInNewWindowTitle), "workspace menu should include 'Open in New Window'")
        // Placement: directly after "Change Icon…", before "Rename…".
        let openIndex = titles.firstIndex(of: openInNewWindowTitle)!
        let changeIconIndex = titles.firstIndex(of: changeIconTitle)!
        let renameIndex = titles.firstIndex(of: renameTitle)!
        XCTAssertEqual(openIndex, changeIconIndex + 1, "Open in New Window should immediately follow Change Icon")
        XCTAssertEqual(openIndex, renameIndex - 1, "Open in New Window should immediately precede Rename")
        // When not detached the item must be enabled.
        let openItem = items.first { $0.title == openInNewWindowTitle }
        XCTAssertEqual(openItem?.isEnabled, true)
        XCTAssertNil(titles.first { $0 == alreadyInNewWindowTitle }, "should not show 'Already' when not detached")
    }

    func testWorkspaceContextMenuShowsAlreadyWhenDetached() {
        let (coordinator, store) = makeCoordinatorWithStore()
        let repo = WorkspaceModel(
            id: UUID(),
            name: "myproj",
            kind: .repository,
            repositoryRoot: URL(fileURLWithPath: "/tmp/myproj")
        )
        store.detachedNodes.insert(.workspace(repo.id))
        let items = coordinator.workspaceContextMenuItems(for: repo)
        let alreadyItem = items.first { $0.title == alreadyInNewWindowTitle }
        XCTAssertNotNil(alreadyItem, "detached workspace should show 'Already in New Window'")
        XCTAssertEqual(alreadyItem?.isEnabled, false, "'Already in New Window' must be disabled")
        let titles = nonSeparatorTitles(items)
        XCTAssertFalse(titles.contains(openInNewWindowTitle), "should not show 'Open in New Window' when detached")
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

        // `pasteboardWriterForItem` now returns a `DetachPasteboardItem`
        // (NSPasteboardWriting) that carries both the legacy reorder payload
        // and the new detach ref. Probe the legacy types via the
        // `pasteboardPropertyList(forType:)` API the pasteboard would call.
        let remoteWriter = coordinator.outlineView(outlineView, pasteboardWriterForItem: remoteSection)
            as? DetachPasteboardItem
        let remoteGroupType = NSPasteboard.PasteboardType("com.treemux.remote-group.key")
        let workspaceType = NSPasteboard.PasteboardType("com.treemux.workspace.ids")
        XCTAssertEqual(remoteWriter?.pasteboardPropertyList(forType: remoteGroupType) as? String, "example|root")
        XCTAssertNil(remoteWriter?.pasteboardPropertyList(forType: workspaceType))
        // The detach ref for a remote section is a `.remoteGroup`.
        XCTAssertEqual(remoteWriter?.ref, .remoteGroup("example|root"))

        XCTAssertNil(coordinator.outlineView(outlineView, pasteboardWriterForItem: localSection))

        let workspaceWriter = coordinator.outlineView(outlineView, pasteboardWriterForItem: workspaceNode)
            as? DetachPasteboardItem
        XCTAssertEqual(workspaceWriter?.pasteboardPropertyList(forType: workspaceType) as? String, workspace.id.uuidString)
        XCTAssertNil(workspaceWriter?.pasteboardPropertyList(forType: remoteGroupType))
        // The detach ref for a workspace node is a `.workspace`.
        XCTAssertEqual(workspaceWriter?.ref, .workspace(workspace.id))
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
