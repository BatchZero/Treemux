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
}
