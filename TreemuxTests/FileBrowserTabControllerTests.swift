//
//  FileBrowserTabControllerTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

@MainActor
final class FileBrowserTabControllerTests: XCTestCase {
    func testLoadRootPopulatesChildren() async {
        let mock = MockFileBrowserDataSource()
        mock.directoryListings["/r"] = [
            FileNode(id: "/r/a", name: "a", path: "/r/a", kind: .directory, sizeBytes: nil, modifiedAt: nil),
            FileNode(id: "/r/b.txt", name: "b.txt", path: "/r/b.txt", kind: .file, sizeBytes: 5, modifiedAt: nil)
        ]
        let ctrl = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/r", rootKind: .worktree),
            dataSource: mock
        )
        await ctrl.loadRoot()
        XCTAssertEqual(ctrl.rootChildren.map(\.name), ["a", "b.txt"])
    }

    func testToggleExpandLoadsChildren() async {
        let mock = MockFileBrowserDataSource()
        mock.directoryListings["/r"] = [
            FileNode(id: "/r/sub", name: "sub", path: "/r/sub", kind: .directory, sizeBytes: nil, modifiedAt: nil)
        ]
        mock.directoryListings["/r/sub"] = [
            FileNode(id: "/r/sub/child.txt", name: "child.txt", path: "/r/sub/child.txt", kind: .file, sizeBytes: 1, modifiedAt: nil)
        ]
        let ctrl = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/r", rootKind: .worktree),
            dataSource: mock
        )
        await ctrl.loadRoot()
        await ctrl.toggleExpand("/r/sub")
        XCTAssertTrue(ctrl.expandedDirs.contains("/r/sub"))
        XCTAssertEqual(ctrl.childrenByPath["/r/sub"]?.map(\.name), ["child.txt"])
    }
}

final class MockFileBrowserDataSource: FileBrowserDataSource {
    var supportsWrite = true
    var directoryListings: [String: [FileNode]] = [:]
    var fileContents: [String: Data] = [:]
    var fileMetas: [String: FileMetadata] = [:]
    var writes: [(path: String, data: Data)] = []

    func listDirectory(_ path: String) async throws -> [FileNode] {
        directoryListings[path] ?? []
    }
    func fileMetadata(_ path: String) async throws -> FileMetadata {
        fileMetas[path] ?? FileMetadata(path: path, sizeBytes: Int64(fileContents[path]?.count ?? 0), modifiedAt: nil, isDirectory: false, isSymbolicLink: false)
    }
    func readFile(_ path: String, maxBytes: Int) async throws -> Data {
        guard let data = fileContents[path] else { throw FileBrowserError.notFound(path) }
        if data.count > maxBytes { throw FileBrowserError.fileTooLarge(path: path, sizeBytes: Int64(data.count), limit: Int64(maxBytes)) }
        return data
    }
    func writeFile(_ path: String, data: Data) async throws {
        writes.append((path, data))
        fileContents[path] = data
    }
    func downloadForQuickLook(_ path: String, progress: @escaping (Double) -> Void) async throws -> URL {
        URL(fileURLWithPath: path)
    }
}
