//
//  FileTreeRowModelTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

@MainActor
final class FileTreeRowModelTests: XCTestCase {
    /// Builds a controller over a real temp directory tree via
    /// LocalFileBrowserDataSource — same fixture pattern as
    /// LocalFileBrowserDataSourceTests, adapted to feed a
    /// FileBrowserTabController the way FileBrowserTabControllerTests does.
    private func makeController(root: String) -> FileBrowserTabController {
        FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: root, rootKind: .project),
            dataSource: LocalFileBrowserDataSource()
        )
    }

    private func makeTempTree() throws -> String {
        let root = NSTemporaryDirectory() + "rowmodel-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/sub", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/a.txt", contents: Data())
        fm.createFile(atPath: root + "/sub/b.txt", contents: Data())
        return root
    }

    func testFlattensExpandedDirsDepthFirst() async throws {
        let root = try makeTempTree()
        let c = makeController(root: root)
        await c.loadRoot()
        await c.toggleExpand(root + "/sub")

        let rows = c.visibleRows()
        let ids = rows.map(\.id)
        // buildNodes sorts directories first, then alphabetically, so at the
        // root level "sub" (directory) sorts before "a.txt" (file). Depth-first
        // flattening therefore visits: sub, then its child, then the sibling file.
        XCTAssertEqual(ids, [root + "/sub", root + "/sub/b.txt", root + "/a.txt"])
        XCTAssertEqual(rows[0].depth, 0)
        XCTAssertEqual(rows[1].depth, 1)
        XCTAssertTrue(rows[0].isExpanded)
    }

    func testCollapsedDirHidesChildren() async throws {
        let root = try makeTempTree()
        let c = makeController(root: root)
        await c.loadRoot()
        XCTAssertFalse(c.visibleRows().map(\.id).contains(root + "/sub/b.txt"))
    }

    func testRowModelEqualityIsValueBased() async throws {
        let root = try makeTempTree()
        let c = makeController(root: root)
        await c.loadRoot()
        // Two computations with no state change must be element-wise equal —
        // this is what lets the view layer skip unchanged rows.
        XCTAssertEqual(c.visibleRows(), c.visibleRows())
    }

    /// A truncated expanded directory must surface a `.loadMore` row
    /// immediately after its children, at depth+1 — this is the row the
    /// "Load more" button renders in FileTreePanelView. Uses the
    /// `markTruncatedForTesting` seam rather than constructing a real
    /// 500+ entry directory (too heavy for a unit test).
    func testTruncatedExpandedDirInsertsLoadMoreRowAfterChildren() async throws {
        let root = try makeTempTree()
        let c = makeController(root: root)
        await c.loadRoot()
        await c.toggleExpand(root + "/sub")
        c.markTruncatedForTesting(root + "/sub")

        let rows = c.visibleRows()
        let ids = rows.map(\.id)
        // Depth-first order: sub, sub's child, then sub's load-more row,
        // then the sibling file at the root.
        XCTAssertEqual(ids, [
            root + "/sub",
            root + "/sub/b.txt",
            "loadMore:" + root + "/sub",
            root + "/a.txt",
        ])
        let loadMoreRow = rows[2]
        XCTAssertEqual(loadMoreRow.depth, 1)
        if case .loadMore(let parentPath) = loadMoreRow.kind {
            XCTAssertEqual(parentPath, root + "/sub")
        } else {
            XCTFail("expected .loadMore kind, got \(loadMoreRow.kind)")
        }
    }

    // MARK: - visibleRows() memoization (Task 8 Part B)

    /// A second call with no intervening state change must hit the cache
    /// instead of recomputing — `visibleRowsComputeCount` (DEBUG-only test
    /// seam) only advances on an actual flatten.
    func testVisibleRowsCachesUntilInvalidated() async throws {
        let root = try makeTempTree()
        let c = makeController(root: root)
        await c.loadRoot()
        let countBefore = c.visibleRowsComputeCount
        _ = c.visibleRows()
        _ = c.visibleRows()
        XCTAssertEqual(c.visibleRowsComputeCount, countBefore + 1,
                        "second call should hit the cache, not recompute")
    }

    /// Expanding a directory mutates `expandedDirs` (and `childrenByPath`),
    /// which must invalidate the cache so the newly revealed rows show up.
    func testVisibleRowsCacheInvalidatesOnExpand() async throws {
        let root = try makeTempTree()
        let c = makeController(root: root)
        await c.loadRoot()
        _ = c.visibleRows() // prime the cache
        let countBefore = c.visibleRowsComputeCount

        await c.toggleExpand(root + "/sub")
        let rows = c.visibleRows()

        XCTAssertEqual(c.visibleRowsComputeCount, countBefore + 1)
        XCTAssertTrue(rows.map(\.id).contains(root + "/sub/b.txt"))
    }

    /// `updateBuffer` mutates `subTabs` (the `dirty` flip), which feeds
    /// `selectedFilePath` via `activeSubTab`. That must also invalidate.
    func testVisibleRowsCacheInvalidatesOnSubTabsChange() async throws {
        let root = try makeTempTree()
        let c = makeController(root: root)
        await c.loadRoot()
        await c.openInTree(root + "/a.txt")
        _ = c.visibleRows() // prime the cache
        let countBefore = c.visibleRowsComputeCount

        guard let activeID = c.activeSubTabID else {
            XCTFail("expected an active sub-tab after openInTree")
            return
        }
        c.updateBuffer(content: "hello", forSubTab: activeID)
        _ = c.visibleRows()

        XCTAssertEqual(c.visibleRowsComputeCount, countBefore + 1)
    }
}
