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
}
