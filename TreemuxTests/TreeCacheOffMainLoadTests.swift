//
//  TreeCacheOffMainLoadTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

/// Thread-safe call counter. `@unchecked Sendable` because access is
/// serialized internally with a lock; used so a plain (non-actor) test double
/// can publish a call count that's readable from the test's polling loop
/// while `listTree` runs on another task.
private final class CallCountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    /// Increments and returns the new count. Called at the very top of
    /// `listTree`, before any suspension, so once the test observes the
    /// expected count it knows that invocation has definitely been entered.
    @discardableResult
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        _count += 1
        return _count
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _count
    }
}

/// Data source whose `listTree` suspends until the test calls `release()`,
/// simulating a slow remote bulk fetch. All other operations are unused by
/// `loadRoot` and just throw.
///
/// By default (`firstCallImmediate: false`, matching the original fixture)
/// every call — including the first — gates on `stream` until `release()`
/// is called, and the gated call returns `fresh.txt`.
///
/// When `firstCallImmediate: true`, the FIRST call instead returns
/// immediately with `fresh.txt` (no gating), and the SECOND (and any later)
/// call gates on `stream` and returns `refreshed.txt` once released. This
/// lets a test drive one `loadRoot()` to completion synchronously, then pause
/// a second, concurrent `loadRoot()` mid-fetch. `listTreeCallCount` is bumped
/// before the gate, so once it reaches 2 the test knows the second
/// `listTree` call has been entered — and therefore that `loadRoot()`'s
/// preceding cache-apply stage has already run to completion, making an
/// assertion about that stage race-free.
private final class GatedTreeDataSource: FileBrowserDataSource {
    let supportsWrite = false
    var treeCacheIdentity: String? { "test-host:22:tester" }

    private let stream: AsyncStream<Void>
    private let releaseFn: () -> Void
    private let callCountBox = CallCountBox()
    private let firstCallImmediate: Bool

    init(firstCallImmediate: Bool = false) {
        var cont: AsyncStream<Void>.Continuation!
        stream = AsyncStream { cont = $0 }
        let c = cont!
        releaseFn = { c.finish() }
        self.firstCallImmediate = firstCallImmediate
    }

    func release() { releaseFn() }

    var listTreeCallCount: Int { callCountBox.count }

    private static func fetch(named name: String) -> DirectoryTreeFetch {
        let node = FileNode(id: "/r/\(name)", name: name, path: "/r/\(name)",
                            kind: .file, sizeBytes: 1, modifiedAt: nil)
        return DirectoryTreeFetch(childrenByPath: ["/r": [node]], truncatedDirs: [])
    }

    func listTree(_ root: String, maxDepth: Int, entryCap: Int) async throws -> DirectoryTreeFetch {
        let callIndex = callCountBox.increment()
        if firstCallImmediate && callIndex == 1 {
            return Self.fetch(named: "fresh.txt")
        }
        for await _ in stream { } // suspends until release()
        return Self.fetch(named: callIndex == 1 ? "fresh.txt" : "refreshed.txt")
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

    /// `loadRoot()`'s cache read is a detached (off-main) task, so it's a
    /// suspension point. If a concurrent `refreshTree()` (e.g. manual
    /// Refresh/Retry) lands fresher data during that await, the delayed
    /// cache-apply must not clobber it with the older on-disk snapshot.
    func test_loadRoot_delayedCacheApplyNeverClobbersAlreadyPopulatedTree() async throws {
        let cache = DirectoryTreeCachePersistence(baseDirectory: tmp)
        let staleNode = FileNode(id: "/r/stale.txt", name: "stale.txt", path: "/r/stale.txt",
                                 kind: .file, sizeBytes: 1, modifiedAt: nil)
        try cache.save(
            DirectoryTreeSnapshot(rootPath: "/r", childrenByPath: ["/r": [staleNode]],
                                  truncatedDirs: [], fetchedAt: Date()),
            identity: "test-host:22:tester")

        let source = GatedTreeDataSource(firstCallImmediate: true)
        let ctrl = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/r", rootKind: .project),
            dataSource: source,
            treeCache: cache
        )

        // First loadRoot(): cache (stale.txt) applies transiently, then the
        // ungated first listTree call overwrites it with fresh.txt. The tree
        // is now populated with fresh.txt.
        await ctrl.loadRoot()
        XCTAssertEqual(ctrl.rootChildren.map(\.name), ["fresh.txt"])

        // refreshTree() persists the just-fetched tree back to the on-disk
        // cache, so at this point the cache file holds fresh.txt, not
        // stale.txt anymore. Re-seed the cache with stale.txt directly so the
        // second loadRoot()'s cache read genuinely reads stale data again —
        // otherwise the second call's cache-apply would be a no-op that
        // can't reveal the clobbering bug regardless of the guard.
        try cache.save(
            DirectoryTreeSnapshot(rootPath: "/r", childrenByPath: ["/r": [staleNode]],
                                  truncatedDirs: [], fetchedAt: Date()),
            identity: "test-host:22:tester")

        // Second loadRoot(): its cache read will load the *same* stale
        // snapshot again (stale.txt) while rootChildren is already
        // populated with fresh.txt from the first call.
        let second = Task { await ctrl.loadRoot() }

        // Wait until the second listTree call has been entered. loadRoot()
        // always awaits the cache load and applies it (or not) *before*
        // calling refreshTree() -> listTree(), so once listTreeCallCount
        // reaches 2 the cache-apply stage of this second loadRoot() has
        // unconditionally already run to completion — this assertion is
        // race-free.
        await pollUntil("second listTree call entered") {
            source.listTreeCallCount == 2
        }

        XCTAssertEqual(
            ctrl.rootChildren.map(\.name), ["fresh.txt"],
            "stale cached snapshot must not clobber the already-populated tree")

        // Let the second listTree call complete and confirm its fetch result
        // (not the stale cache) is the final state.
        source.release()
        await second.value
        XCTAssertEqual(ctrl.rootChildren.map(\.name), ["refreshed.txt"])
    }
}
