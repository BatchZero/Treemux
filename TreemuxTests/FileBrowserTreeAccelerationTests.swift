//
//  FileBrowserTreeAccelerationTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

@MainActor
final class FileBrowserTreeAccelerationTests: XCTestCase {
    private func tempCacheDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("treemux-accel-\(UUID().uuidString)")
    }

    func test_loadRoot_rendersDiskCacheWhenRefreshFails() async throws {
        let dir = tempCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DirectoryTreeCachePersistence(baseDirectory: dir)
        let cachedNode = FileNode(id: "/r/cached.txt", name: "cached.txt", path: "/r/cached.txt",
                                  kind: .file, sizeBytes: 1, modifiedAt: nil)
        try store.save(DirectoryTreeSnapshot(rootPath: "/r",
                                             childrenByPath: ["/r": [cachedNode]],
                                             truncatedDirs: [],
                                             fetchedAt: Date()), identity: "h:22:me")

        let mock = MockFileBrowserDataSource()
        mock.cacheIdentity = "h:22:me"
        mock.listError = FileBrowserError.notFound("/r")

        let ctrl = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/r", rootKind: .project),
            dataSource: mock,
            treeCache: store
        )
        await ctrl.loadRoot()
        XCTAssertEqual(ctrl.rootChildren.map(\.name), ["cached.txt"])
    }

    func test_refresh_persistsSnapshotToDisk() async throws {
        let dir = tempCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DirectoryTreeCachePersistence(baseDirectory: dir)

        let mock = MockFileBrowserDataSource()
        mock.cacheIdentity = "h:22:me"
        mock.directoryListings["/r"] = [
            FileNode(id: "/r/live.txt", name: "live.txt", path: "/r/live.txt", kind: .file, sizeBytes: 2, modifiedAt: nil)
        ]
        let ctrl = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/r", rootKind: .project),
            dataSource: mock,
            treeCache: store
        )
        await ctrl.loadRoot()
        XCTAssertEqual(ctrl.rootChildren.map(\.name), ["live.txt"])

        let snap = store.load(identity: "h:22:me", rootPath: "/r")
        XCTAssertEqual(snap?.childrenByPath["/r"]?.map(\.name), ["live.txt"])
    }

    func test_prefetchChildren_populatesGrandchildren() async {
        let mock = MockFileBrowserDataSource()
        mock.directoryListings["/r"] = [
            FileNode(id: "/r/sub", name: "sub", path: "/r/sub", kind: .directory, sizeBytes: nil, modifiedAt: nil)
        ]
        mock.directoryListings["/r/sub"] = [
            FileNode(id: "/r/sub/inner", name: "inner", path: "/r/sub/inner", kind: .directory, sizeBytes: nil, modifiedAt: nil)
        ]
        mock.directoryListings["/r/sub/inner"] = [
            FileNode(id: "/r/sub/inner/leaf.txt", name: "leaf.txt", path: "/r/sub/inner/leaf.txt", kind: .file, sizeBytes: 1, modifiedAt: nil)
        ]
        let ctrl = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/r", rootKind: .project),
            dataSource: mock)
        await ctrl.loadRoot()

        await ctrl.toggleExpand("/r/sub")
        await ctrl.prefetchChildren(of: "/r/sub")
        XCTAssertEqual(ctrl.childrenByPath["/r/sub/inner"]?.map(\.name), ["leaf.txt"])
    }
}
