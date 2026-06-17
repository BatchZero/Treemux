//
//  DocumentViewerViewTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

@MainActor
final class DocumentViewerViewTests: XCTestCase {
    // MARK: - Controller hook

    func test_setViewModeUpdatesSubTabRecord() {
        // Arrange: seed a pinned sub-tab and build a controller (mirrors FileBrowserTabSnapshotViewModeTests pattern).
        let record = FileSubTabRecord(id: UUID(), path: "/r/readme.md", isPinned: true, viewMode: nil)
        let initial = FileBrowserTabState(
            rootPath: "/r",
            rootKind: .project,
            subTabs: [record],
            activeSubTabID: record.id
        )
        let mock = MockFileBrowserDataSource()
        mock.directoryListings["/r"] = []
        let controller = FileBrowserTabController(initial: initial, dataSource: mock)

        let id = controller.subTabs.first!.id
        XCTAssertNil(controller.subTabs.first?.viewMode, "initial viewMode should be nil")

        // Act
        controller.setViewMode(.render, forSubTab: id)

        // Assert
        XCTAssertEqual(
            controller.subTabs.first(where: { $0.id == id })?.viewMode,
            .render,
            "setViewMode should update the matching sub-tab's viewMode to .render"
        )
    }

    func test_setViewModeUnknownIDIsNoOp() {
        // Arrange
        let record = FileSubTabRecord(id: UUID(), path: "/r/file.md", isPinned: true, viewMode: nil)
        let initial = FileBrowserTabState(
            rootPath: "/r",
            rootKind: .project,
            subTabs: [record],
            activeSubTabID: record.id
        )
        let mock = MockFileBrowserDataSource()
        mock.directoryListings["/r"] = []
        let controller = FileBrowserTabController(initial: initial, dataSource: mock)

        // Act: use a random unknown UUID
        controller.setViewMode(.split, forSubTab: UUID())

        // Assert: existing sub-tab untouched
        XCTAssertNil(controller.subTabs.first?.viewMode, "unknown id should leave existing sub-tabs unchanged")
    }

    func test_setViewModePersistedViaSnapshot() {
        // Verifies that setting view mode on a pinned tab survives a snapshot round-trip.
        let record = FileSubTabRecord(id: UUID(), path: "/r/page.html", isPinned: true, viewMode: nil)
        let initial = FileBrowserTabState(
            rootPath: "/r",
            rootKind: .project,
            subTabs: [record],
            activeSubTabID: record.id
        )
        let mock = MockFileBrowserDataSource()
        mock.directoryListings["/r"] = []
        let controller = FileBrowserTabController(initial: initial, dataSource: mock)

        controller.setViewMode(.source, forSubTab: record.id)
        let snap = controller.snapshot()

        XCTAssertEqual(snap.subTabs.first?.viewMode, .source,
                       "viewMode set via setViewMode must survive snapshot() for pinned tabs")
    }
}
