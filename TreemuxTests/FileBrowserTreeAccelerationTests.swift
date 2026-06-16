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

    func test_loadMore_fetchesFullListingAndClearsTruncation() async {
        let mock = MockFileBrowserDataSource()
        mock.directoryListings["/r"] = (0..<3).map {
            FileNode(id: "/r/f\($0)", name: "f\($0)", path: "/r/f\($0)", kind: .file, sizeBytes: 1, modifiedAt: nil)
        }
        let ctrl = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/r", rootKind: .project),
            dataSource: mock)
        await ctrl.loadRoot()
        ctrl.markTruncatedForTesting("/r")
        XCTAssertTrue(ctrl.truncatedDirs.contains("/r"))

        await ctrl.loadMore("/r")
        XCTAssertFalse(ctrl.truncatedDirs.contains("/r"))
        XCTAssertEqual(ctrl.childrenByPath["/r"]?.count, 3)
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

    func test_refresh_preservesDeepTruncationFlag() async {
        let mock = MockFileBrowserDataSource()
        mock.directoryListings["/r"] = [
            FileNode(id: "/r/sub", name: "sub", path: "/r/sub", kind: .directory, sizeBytes: nil, modifiedAt: nil)
        ]
        let ctrl = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/r", rootKind: .project), dataSource: mock)
        await ctrl.loadRoot()
        // Simulate a deep dir (not covered by the root bulk fetch) being truncated.
        ctrl.markTruncatedForTesting("/r/sub/deep")
        XCTAssertTrue(ctrl.truncatedDirs.contains("/r/sub/deep"))
        // A root-level refresh must NOT erase the deep truncation flag.
        await ctrl.refreshTree()
        XCTAssertTrue(ctrl.truncatedDirs.contains("/r/sub/deep"),
                      "deep truncation flag must survive a root-scoped refresh")
    }

    func test_refreshTree_clearsStaleLoadErrorOnSuccess() async {
        let mock = MockFileBrowserDataSource()
        mock.directoryListings["/r"] = [
            FileNode(id: "/r/a.txt", name: "a.txt", path: "/r/a.txt", kind: .file, sizeBytes: 1, modifiedAt: nil)
        ]
        let ctrl = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/r", rootKind: .project), dataSource: mock)
        // Force an error state first.
        mock.listError = FileBrowserError.notFound("/r")
        await ctrl.loadRoot()
        XCTAssertNotNil(ctrl.loadError)
        // A subsequent successful refresh must clear it.
        mock.listError = nil
        await ctrl.refreshTree()
        XCTAssertNil(ctrl.loadError)
    }

    func test_refreshTree_surfacesNeedsPasswordEvenWithCache() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("treemux-accel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DirectoryTreeCachePersistence(baseDirectory: dir)
        try store.save(DirectoryTreeSnapshot(
            rootPath: "/r",
            childrenByPath: ["/r": [FileNode(id: "/r/c.txt", name: "c.txt", path: "/r/c.txt", kind: .file, sizeBytes: 1, modifiedAt: nil)]],
            truncatedDirs: [], fetchedAt: Date()), identity: "h:22:me")

        let mock = MockFileBrowserDataSource()
        mock.cacheIdentity = "h:22:me"
        mock.listError = SFTPServiceError.authenticationFailed   // maps to .needsPassword

        let ctrl = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/r", rootKind: .project),
            dataSource: mock, treeCache: store)
        await ctrl.loadRoot()
        // Cache rendered, but the auth failure must still surface as needsPassword.
        XCTAssertEqual(ctrl.rootChildren.map(\.name), ["c.txt"])
        if case .needsPassword = ctrl.loadError {} else {
            XCTFail("expected .needsPassword, got \(String(describing: ctrl.loadError))")
        }
    }
}
