//
//  FileBrowserTabSnapshotViewModeTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

@MainActor
final class FileBrowserTabSnapshotViewModeTests: XCTestCase {
    /// Verifies that a pinned sub-tab's `viewMode` survives a round-trip through
    /// `snapshot()`. Constructs the controller from an initial `FileBrowserTabState`
    /// that already carries a pinned record with `viewMode: .render`, matching the
    /// same init pattern used throughout `FileBrowserTabControllerSubTabTests`.
    func test_snapshotPreservesViewMode() {
        // Arrange: seed a pinned record with an explicit viewMode
        let record = FileSubTabRecord(id: UUID(), path: "/r/readme.md", isPinned: true, viewMode: .render)
        let initial = FileBrowserTabState(
            rootPath: "/r",
            rootKind: .project,
            subTabs: [record],
            activeSubTabID: record.id
        )
        let mock = MockFileBrowserDataSource()
        mock.directoryListings["/r"] = []
        let c = FileBrowserTabController(initial: initial, dataSource: mock)

        // Act
        let snap = c.snapshot()

        // Assert: viewMode must survive the SubTabRuntime → FileSubTabRecord round-trip
        XCTAssertEqual(snap.subTabs.count, 1, "pinned sub-tab must be in snapshot")
        XCTAssertEqual(snap.subTabs.first?.viewMode, .render,
                       "snapshot must preserve viewMode for pinned sub-tabs")
    }
}
