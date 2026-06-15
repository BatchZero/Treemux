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
}
