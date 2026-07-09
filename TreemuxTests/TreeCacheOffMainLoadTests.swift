//
//  TreeCacheOffMainLoadTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

/// Data source whose `listTree` suspends until the test calls `release()`,
/// simulating a slow remote bulk fetch. All other operations are unused by
/// `loadRoot` and just throw.
private final class GatedTreeDataSource: FileBrowserDataSource {
    let supportsWrite = false
    var treeCacheIdentity: String? { "test-host:22:tester" }

    private let stream: AsyncStream<Void>
    private let releaseFn: () -> Void

    init() {
        var cont: AsyncStream<Void>.Continuation!
        stream = AsyncStream { cont = $0 }
        let c = cont!
        releaseFn = { c.finish() }
    }

    func release() { releaseFn() }

    func listTree(_ root: String, maxDepth: Int, entryCap: Int) async throws -> DirectoryTreeFetch {
        for await _ in stream { } // suspends until release()
        let fresh = FileNode(id: "/r/fresh.txt", name: "fresh.txt", path: "/r/fresh.txt",
                             kind: .file, sizeBytes: 1, modifiedAt: nil)
        return DirectoryTreeFetch(childrenByPath: ["/r": [fresh]], truncatedDirs: [])
    }

    func listDirectory(_ path: String) async throws -> [FileNode] { [] }
    func fileMetadata(_ path: String) async throws -> FileMetadata { throw FileBrowserError.notFound(path) }
    func readFile(_ path: String, maxBytes: Int) async throws -> Data { throw FileBrowserError.notFound(path) }
    func readPrefix(_ path: String, maxBytes: Int) async throws -> Data { throw FileBrowserError.notFound(path) }
    func writeFile(_ path: String, data: Data) async throws { throw FileBrowserError.notFound(path) }
    func downloadForQuickLook(_ path: String, progress: @escaping (Double) -> Void) async throws -> URL {
        throw FileBrowserError.notFound(path)
    }
}

@MainActor
final class TreeCacheOffMainLoadTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree-cache-offmain-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Polls `condition` every 10 ms for up to 2 s; fails the test on timeout.
    private func pollUntil(
        _ message: String, file: StaticString = #filePath, line: UInt = #line,
        condition: () -> Bool
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for: \(message)", file: file, line: line)
    }

    /// The cached snapshot must render while the (gated) network fetch is
    /// still pending — the cache read moved off the main actor must not break
    /// the cache-first-then-refresh ordering inside `loadRoot`.
    func test_loadRoot_rendersCachedSnapshotWhileFetchStillPending() async throws {
        let cache = DirectoryTreeCachePersistence(baseDirectory: tmp)
        let cachedNode = FileNode(id: "/r/cached.txt", name: "cached.txt", path: "/r/cached.txt",
                                  kind: .file, sizeBytes: 1, modifiedAt: nil)
        try cache.save(
            DirectoryTreeSnapshot(rootPath: "/r", childrenByPath: ["/r": [cachedNode]],
                                  truncatedDirs: [], fetchedAt: Date()),
            identity: "test-host:22:tester")

        let source = GatedTreeDataSource()
        let ctrl = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/r", rootKind: .project),
            dataSource: source,
            treeCache: cache
        )

        let load = Task { await ctrl.loadRoot() }

        await pollUntil("cached snapshot rendered before fetch completes") {
            ctrl.rootChildren.map(\.name) == ["cached.txt"]
        }

        source.release()
        await load.value
        XCTAssertEqual(ctrl.rootChildren.map(\.name), ["fresh.txt"],
                       "fresh fetch must supersede the cached snapshot")
    }
}
