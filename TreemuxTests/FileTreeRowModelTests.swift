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

    /// `activateSubTab(_:)` flips `activeSubTabID`, which feeds `selectedFilePath`
    /// (and therefore each row's `isSelected`) independently of any `subTabs`
    /// mutation — pin two files first so both stay resident, then switch the
    /// active one without touching `subTabs` itself.
    func testVisibleRowsCacheInvalidatesOnActiveSubTabChange() async throws {
        let root = try makeTempTree()
        let c = makeController(root: root)
        await c.loadRoot()
        await c.toggleExpand(root + "/sub") // so b.txt's row is visible for the isSelected checks below
        await c.pinFile(root + "/a.txt")
        guard let firstID = c.activeSubTabID else {
            XCTFail("expected an active sub-tab after pinFile")
            return
        }
        await c.pinFile(root + "/sub/b.txt")
        guard let secondID = c.activeSubTabID, secondID != firstID else {
            XCTFail("expected a second, distinct active sub-tab after pinFile")
            return
        }

        _ = c.visibleRows() // prime the cache
        let countBefore = c.visibleRowsComputeCount
        _ = c.visibleRows() // repeat call before the change must stay cached
        XCTAssertEqual(c.visibleRowsComputeCount, countBefore,
                        "repeat call with no state change must not recompute")

        c.activateSubTab(firstID)
        let rows = c.visibleRows()

        XCTAssertEqual(c.visibleRowsComputeCount, countBefore + 1)
        XCTAssertEqual(rows.first(where: { $0.id == root + "/a.txt" })?.isSelected, true)
        XCTAssertEqual(rows.first(where: { $0.id == root + "/sub/b.txt" })?.isSelected, false)
    }

    /// `markTruncatedForTesting` mutates `truncatedDirs` directly — the same
    /// property `refreshTree`/`applyFetch` populate from a real capped
    /// listing — so it must invalidate the cache on its own, independent of
    /// any expand/collapse or sub-tab change.
    func testVisibleRowsCacheInvalidatesOnTruncatedDirsChange() async throws {
        let root = try makeTempTree()
        let c = makeController(root: root)
        await c.loadRoot()
        await c.toggleExpand(root + "/sub")

        _ = c.visibleRows() // prime the cache
        let countBefore = c.visibleRowsComputeCount
        _ = c.visibleRows() // repeat call before the change must stay cached
        XCTAssertEqual(c.visibleRowsComputeCount, countBefore,
                        "repeat call with no state change must not recompute")

        c.markTruncatedForTesting(root + "/sub")
        let rows = c.visibleRows()

        XCTAssertEqual(c.visibleRowsComputeCount, countBefore + 1)
        XCTAssertTrue(rows.map(\.id).contains("loadMore:" + root + "/sub"))
    }

    /// `refreshGitStatus()` writes `fileStatusByPath`, which feeds each row's
    /// `status` badge. Wires a stub `GitDiffService` so the refresh is
    /// isolated from any other published-state mutation.
    func testVisibleRowsCacheInvalidatesOnGitStatusRefresh() async throws {
        let root = try makeTempTree()
        let stub = StubGitDiffService()
        let c = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: root, rootKind: .project),
            dataSource: LocalFileBrowserDataSource(),
            gitDiffService: stub,
            repoRoot: root
        )
        // loadRoot() -> refreshTree() already calls refreshGitStatus() once
        // internally; let that settle (with an empty stub status map) before
        // priming the cache so it isn't mistaken for the change under test.
        await c.loadRoot()

        _ = c.visibleRows() // prime the cache
        let countBefore = c.visibleRowsComputeCount
        _ = c.visibleRows() // repeat call before the change must stay cached
        XCTAssertEqual(c.visibleRowsComputeCount, countBefore,
                        "repeat call with no state change must not recompute")

        stub.statusToReturn = ["a.txt": .modified]
        await c.refreshGitStatus()
        let rows = c.visibleRows()

        XCTAssertEqual(c.visibleRowsComputeCount, countBefore + 1)
        XCTAssertEqual(rows.first(where: { $0.id == root + "/a.txt" })?.status, .modified)
    }

    /// Task 7 moves the hidden-file re-filter off-main. Applying it still
    /// writes `childrenByPath`/`rootChildren`, whose existing `didSet`
    /// invalidates `visibleRowsCache` — this must keep working once the
    /// filter itself runs on a detached task and is applied asynchronously.
    func testVisibleRowsCacheInvalidatesOnHiddenFilterApply() async throws {
        let root = try makeTempTree()
        FileManager.default.createFile(atPath: root + "/.hidden", contents: Data())
        let c = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: root, rootKind: .project, showsHiddenFiles: true),
            dataSource: LocalFileBrowserDataSource()
        )
        await c.loadRoot()

        _ = c.visibleRows() // prime the cache
        let countBefore = c.visibleRowsComputeCount

        c.setShowsHiddenFiles(false)
        await c.pendingHiddenFilterTask?.value
        let rows = c.visibleRows()

        XCTAssertEqual(c.visibleRowsComputeCount, countBefore + 1, "filter apply must invalidate the memo")
        XCTAssertFalse(rows.contains { $0.id.hasSuffix("/.hidden") })
    }

    // MARK: - .editor row kind (Task 3)

    func testEditorKindEquatable() {
        let a = FileTreeRowModel(id: "newEntry:/r", kind: .editor(parentPath: "/r", intent: .folder),
                                 depth: 0, isSelected: false, isExpanded: false, status: nil)
        let b = FileTreeRowModel(id: "newEntry:/r", kind: .editor(parentPath: "/r", intent: .folder),
                                 depth: 0, isSelected: false, isExpanded: false, status: nil)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a.kind, .editor(parentPath: "/r", intent: .file))
    }
}

/// Minimal `GitDiffService` stub for isolating `fileStatusByPath` invalidation
/// from real `git` subprocess calls. `fileStatus(in:)` returns whatever test
/// code stashes in `statusToReturn`, keyed by repo-relative path — matching
/// the porcelain-parsed shape `FileBrowserTabController.refreshGitStatus()`
/// expects.
private final class StubGitDiffService: GitDiffService {
    var statusToReturn: [String: FileStatus] = [:]

    func diffHunks(forFile path: String, repoRoot: String) async throws -> [DiffHunk] { [] }

    func fileStatus(in repoRoot: String) async throws -> [String: FileStatus] {
        statusToReturn
    }
}
