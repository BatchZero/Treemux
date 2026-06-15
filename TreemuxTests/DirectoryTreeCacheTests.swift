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

    func test_snapshot_codableRoundTrip() throws {
        let snap = DirectoryTreeSnapshot(
            rootPath: "/r",
            childrenByPath: [
                "/r": [FileNode(id: "/r/a", name: "a", path: "/r/a", kind: .directory, sizeBytes: nil, modifiedAt: nil)],
                "/r/a": [FileNode(id: "/r/a/b.txt", name: "b.txt", path: "/r/a/b.txt", kind: .file, sizeBytes: 3, modifiedAt: nil)]
            ],
            truncatedDirs: ["/r/a"],
            fetchedAt: Date(timeIntervalSince1970: 1_714_000_000)
        )
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(DirectoryTreeSnapshot.self, from: data)
        XCTAssertEqual(decoded, snap)
    }

    func test_persistence_saveThenLoad_roundTrips() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("treemux-treecache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = DirectoryTreeCachePersistence(baseDirectory: tmp)
        let snap = DirectoryTreeSnapshot(
            rootPath: "/r",
            childrenByPath: ["/r": [FileNode(id: "/r/a", name: "a", path: "/r/a", kind: .file, sizeBytes: 1, modifiedAt: nil)]],
            truncatedDirs: [],
            fetchedAt: Date(timeIntervalSince1970: 1_714_000_000)
        )
        try store.save(snap, identity: "host:22:me")
        let loaded = store.load(identity: "host:22:me", rootPath: "/r")
        XCTAssertEqual(loaded, snap)
    }

    func test_persistence_load_missingReturnsNil() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("treemux-treecache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = DirectoryTreeCachePersistence(baseDirectory: tmp)
        XCTAssertNil(store.load(identity: "nope:22:me", rootPath: "/r"))
    }

    func test_persistence_load_wrongRootReturnsNil() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("treemux-treecache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = DirectoryTreeCachePersistence(baseDirectory: tmp)
        let snap = DirectoryTreeSnapshot(rootPath: "/r", childrenByPath: [:], truncatedDirs: [], fetchedAt: Date())
        try store.save(snap, identity: "host:22:me")
        XCTAssertNil(store.load(identity: "host:22:me", rootPath: "/other"))
    }
}
