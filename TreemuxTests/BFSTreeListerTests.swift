//
//  BFSTreeListerTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

final class BFSTreeListerTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("treemux-bfs-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: tmp.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: tmp.appendingPathComponent("root.txt"))
        try Data("y".utf8).write(to: tmp.appendingPathComponent("sub/mid.txt"))
        try Data("z".utf8).write(to: tmp.appendingPathComponent("sub/deep/leaf.txt"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_listTree_depth2_fetchesRootAndImmediateSubdirs_butNotDeeper() async throws {
        let source = LocalFileBrowserDataSource()
        let root = tmp.path
        let fetch = try await source.listTree(root, maxDepth: 2, entryCap: 500)

        XCTAssertEqual(Set(fetch.childrenByPath[root]?.map(\.name) ?? []), ["root.txt", "sub"])
        XCTAssertEqual(Set(fetch.childrenByPath[root + "/sub"]?.map(\.name) ?? []), ["mid.txt", "deep"])
        XCTAssertNil(fetch.childrenByPath[root + "/sub/deep"])
        XCTAssertTrue(fetch.truncatedDirs.isEmpty)
    }

    func test_listTree_entryCap_marksTruncated() async throws {
        let source = LocalFileBrowserDataSource()
        let fetch = try await source.listTree(tmp.path, maxDepth: 1, entryCap: 1)
        XCTAssertEqual(fetch.childrenByPath[tmp.path]?.count, 1)
        XCTAssertTrue(fetch.truncatedDirs.contains(tmp.path))
    }

    // A subdirectory that can't be enumerated (e.g. the TCC-protected
    // ~/.Trash, or ~/Desktop without Full Disk Access) must not abort the
    // whole tree fetch — it is skipped and the rest of the tree still loads.
    func test_listTree_skipsSubdirectoryThatFailsToList() async throws {
        let source = ScriptedDataSource()
        source.listing["/r"] = .success([source.dir("/r/good"), source.dir("/r/bad")])
        source.listing["/r/good"] = .success([source.file("/r/good/a.txt")])
        source.listing["/r/bad"] = .failure(
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError))

        let fetch = try await source.listTree("/r", maxDepth: 2, entryCap: 500)

        XCTAssertEqual(Set(fetch.childrenByPath["/r"]?.map(\.name) ?? []), ["good", "bad"])
        XCTAssertEqual(fetch.childrenByPath["/r/good"]?.map(\.name), ["a.txt"])
        XCTAssertNil(fetch.childrenByPath["/r/bad"])  // skipped, no throw
    }

    // The root the user explicitly opened is different: if it can't be listed
    // at all, that is a real error worth surfacing.
    func test_listTree_propagatesRootListingFailure() async {
        let source = ScriptedDataSource()
        source.listing["/r"] = .failure(
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError))
        do {
            _ = try await source.listTree("/r", maxDepth: 2, entryCap: 500)
            XCTFail("expected root listing failure to propagate")
        } catch {
            // expected
        }
    }
}

/// In-memory data source whose per-path listing is scripted, so BFS error
/// handling can be tested deterministically. Only `listDirectory` is exercised
/// by `BFSTreeLister`; the other members are inert stubs.
private final class ScriptedDataSource: FileBrowserDataSource {
    let supportsWrite = false
    var listing: [String: Result<[FileNode], Error>] = [:]

    func dir(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, path: path,
                 kind: .directory, sizeBytes: nil, modifiedAt: nil)
    }

    func file(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, path: path,
                 kind: .file, sizeBytes: nil, modifiedAt: nil)
    }

    func listDirectory(_ path: String) async throws -> [FileNode] {
        switch listing[path] {
        case .success(let nodes): return nodes
        case .failure(let error): throw error
        case nil: return []
        }
    }

    func fileMetadata(_ path: String) async throws -> FileMetadata { throw FileBrowserError.notFound(path) }
    func readFile(_ path: String, maxBytes: Int) async throws -> Data { Data() }
    func readPrefix(_ path: String, maxBytes: Int) async throws -> Data { Data() }
    func writeFile(_ path: String, data: Data) async throws {}
    func downloadForQuickLook(_ path: String, progress: @escaping (Double) -> Void) async throws -> URL {
        URL(fileURLWithPath: path)
    }
}
