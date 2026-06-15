//
//  DirectoryTreeCacheTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

final class DirectoryTreeCacheTests: XCTestCase {
    func test_fileNode_codableRoundTrip_preservesAllKinds() throws {
        let nodes = [
            FileNode(id: "/r/dir", name: "dir", path: "/r/dir", kind: .directory, sizeBytes: nil, modifiedAt: nil),
            FileNode(id: "/r/f.txt", name: "f.txt", path: "/r/f.txt", kind: .file, sizeBytes: 12,
                     modifiedAt: Date(timeIntervalSince1970: 1_714_000_000)),
            FileNode(id: "/r/lnk", name: "lnk", path: "/r/lnk", kind: .symlink(target: "/r/f.txt"),
                     sizeBytes: 0, modifiedAt: nil)
        ]
        let data = try JSONEncoder().encode(nodes)
        let decoded = try JSONDecoder().decode([FileNode].self, from: data)
        XCTAssertEqual(decoded, nodes)
    }
}
