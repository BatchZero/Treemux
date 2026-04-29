//
//  FileBrowserTabControllerSubTabTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

@MainActor
final class FileBrowserTabControllerSubTabTests: XCTestCase {
    private func makeController(rootPath: String = "/r") -> FileBrowserTabController {
        let mock = MockFileBrowserDataSource()
        mock.directoryListings[rootPath] = []
        return FileBrowserTabController(
            initial: .init(rootPath: rootPath, rootKind: .project),
            dataSource: mock
        )
    }

    func test_singleClick_emptyTabs_opensPreview() async {
        let c = makeController()
        await c.openInTree("/r/a.swift")
        XCTAssertEqual(c.subTabs.count, 1)
        XCTAssertFalse(c.subTabs[0].isPinned)
        XCTAssertEqual(c.subTabs[0].path, "/r/a.swift")
        XCTAssertEqual(c.activeSubTabID, c.subTabs[0].id)
    }

    func test_singleClick_existingPreview_replacesPath() async {
        let c = makeController()
        await c.openInTree("/r/a.swift")
        let firstID = c.subTabs[0].id
        await c.openInTree("/r/b.swift")
        XCTAssertEqual(c.subTabs.count, 1)
        XCTAssertEqual(c.subTabs[0].id, firstID, "same preview tab reused")
        XCTAssertEqual(c.subTabs[0].path, "/r/b.swift")
        XCTAssertFalse(c.subTabs[0].isPinned)
    }

    func test_singleClick_alreadyPinned_focusesExisting() async {
        let c = makeController()
        await c.openInTree("/r/a.swift")
        c.pinActiveSubTab()
        let pinnedID = c.subTabs[0].id
        await c.openInTree("/r/b.swift")
        XCTAssertEqual(c.subTabs.count, 2, "pinned + new preview")
        await c.openInTree("/r/a.swift")
        XCTAssertEqual(c.activeSubTabID, pinnedID, "focuses existing pinned")
        XCTAssertEqual(c.subTabs.count, 2, "no extra tab created")
    }

    func test_doubleClick_promotesPreview() async {
        let c = makeController()
        await c.openInTree("/r/a.swift")
        await c.pinFile("/r/a.swift")
        XCTAssertTrue(c.subTabs[0].isPinned)
    }

    func test_closeActive_picksRightNeighbor() async {
        let c = makeController()
        await c.openInTree("/r/a.swift"); c.pinActiveSubTab()
        await c.openInTree("/r/b.swift"); c.pinActiveSubTab()
        await c.openInTree("/r/c.swift"); c.pinActiveSubTab()
        // pinned: [a, b, c], active = c
        c.activateSubTab(c.subTabs[1].id)  // active = b
        c.closeSubTabImmediate(c.subTabs[1].id)
        XCTAssertEqual(c.subTabs.count, 2)
        XCTAssertEqual(c.subTabs.last?.path, "/r/c.swift")
        XCTAssertEqual(c.activeSubTabID, c.subTabs.last?.id, "right neighbor selected")
    }

    func test_closeRightmost_picksLeftNeighbor() async {
        let c = makeController()
        await c.openInTree("/r/a.swift"); c.pinActiveSubTab()
        await c.openInTree("/r/b.swift"); c.pinActiveSubTab()
        c.closeSubTabImmediate(c.subTabs.last!.id)
        XCTAssertEqual(c.subTabs.count, 1)
        XCTAssertEqual(c.activeSubTabID, c.subTabs.first?.id)
    }

    func test_persistableSnapshot_dropsPreviewTabs() async {
        let c = makeController()
        await c.openInTree("/r/a.swift"); c.pinActiveSubTab()
        await c.openInTree("/r/b.swift")  // preview
        let snap = c.snapshot()
        XCTAssertEqual(snap.subTabs.count, 1, "preview not persisted")
        XCTAssertEqual(snap.subTabs.first?.path, "/r/a.swift")
    }

    func test_handleCloseShortcut_closesSubTabBeforeOuter() async {
        let c = makeController()
        await c.openInTree("/r/a.swift")
        XCTAssertTrue(c.handleCloseShortcut(), "claimed shortcut, closed sub-tab")
        XCTAssertEqual(c.subTabs.count, 0)
        XCTAssertFalse(c.handleCloseShortcut(), "no sub-tabs left, did not claim")
    }

    func test_reorderSubTabs() async {
        let c = makeController()
        await c.openInTree("/r/a.swift"); c.pinActiveSubTab()
        await c.openInTree("/r/b.swift"); c.pinActiveSubTab()
        await c.openInTree("/r/c.swift"); c.pinActiveSubTab()
        c.reorderSubTabs(from: IndexSet(integer: 0), to: 3)  // move first to end
        XCTAssertEqual(c.subTabs.map(\.path), ["/r/b.swift", "/r/c.swift", "/r/a.swift"])
    }
}
