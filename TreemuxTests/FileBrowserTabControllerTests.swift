//
//  FileBrowserTabControllerTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

@MainActor
final class FileBrowserTabControllerTests: XCTestCase {
    final class FakeDataSource: FileBrowserDataSource {
        let supportsWrite = true
        var entries: [String: [FileNode]] = [:]
        func listDirectory(_ path: String) async throws -> [FileNode] {
            entries[path] ?? []
        }
        func fileMetadata(_ path: String) async throws -> FileMetadata {
            FileMetadata(path: path, sizeBytes: 0, modifiedAt: nil,
                         isDirectory: false, isSymbolicLink: false)
        }
        func readFile(_ path: String, maxBytes: Int) async throws -> Data { Data() }
        func writeFile(_ path: String, data: Data) async throws {}
        func downloadForQuickLook(_ path: String,
                                  progress: @escaping (Double) -> Void) async throws -> URL {
            URL(fileURLWithPath: "/tmp/x")
        }
    }

    func test_setShowsHiddenFiles_recoversHiddenAfterToggleOff() async {
        let ds = FakeDataSource()
        let visible = FileNode(id: "/r/a", name: "a", path: "/r/a", kind: .file, sizeBytes: 0, modifiedAt: nil)
        let hidden  = FileNode(id: "/r/.b", name: ".b", path: "/r/.b", kind: .file, sizeBytes: 0, modifiedAt: nil)
        ds.entries["/r"] = [visible, hidden]
        let state = FileBrowserTabState(rootPath: "/r", rootKind: .project, showsHiddenFiles: true)
        let ctrl = FileBrowserTabController(initial: state, dataSource: ds)
        await ctrl.loadRoot()
        XCTAssertEqual(ctrl.rootChildren.count, 2)

        ctrl.setShowsHiddenFiles(false)
        XCTAssertEqual(ctrl.rootChildren.count, 1, "only visible file remains")

        ctrl.setShowsHiddenFiles(true)
        XCTAssertEqual(ctrl.rootChildren.count, 2, "hidden file must reappear without re-fetch")
    }

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

    func testSelectSmallTextFile() async throws {
        let mock = MockFileBrowserDataSource()
        mock.fileMetas["/r/a.txt"] = FileMetadata(path: "/r/a.txt", sizeBytes: 5, modifiedAt: nil, isDirectory: false, isSymbolicLink: false)
        mock.fileContents["/r/a.txt"] = "hello".data(using: .utf8)!
        let ctrl = FileBrowserTabController(initial: FileBrowserTabState(rootPath: "/r", rootKind: .worktree), dataSource: mock)
        await ctrl.selectFile("/r/a.txt")
        if case .text(let path, let content, _, let dirty) = ctrl.openFile {
            XCTAssertEqual(path, "/r/a.txt")
            XCTAssertEqual(content, "hello")
            XCTAssertFalse(dirty)
        } else {
            XCTFail("expected .text, got \(ctrl.openFile)")
        }
    }

    func testSelectLargeFilePromptsConfirmation() async {
        let mock = MockFileBrowserDataSource()
        let big: Int64 = 6 * 1024 * 1024
        mock.fileMetas["/r/big.bin"] = FileMetadata(path: "/r/big.bin", sizeBytes: big, modifiedAt: nil, isDirectory: false, isSymbolicLink: false)
        let ctrl = FileBrowserTabController(initial: FileBrowserTabState(rootPath: "/r", rootKind: .worktree), dataSource: mock)
        await ctrl.selectFile("/r/big.bin")
        if case .confirmingLargeFile(let path, let size) = ctrl.openFile {
            XCTAssertEqual(path, "/r/big.bin")
            XCTAssertEqual(size, big)
        } else {
            XCTFail("expected .confirmingLargeFile")
        }
    }

    func testSelectBinaryFile() async {
        let mock = MockFileBrowserDataSource()
        mock.fileMetas["/r/a.exe"] = FileMetadata(path: "/r/a.exe", sizeBytes: 100, modifiedAt: nil, isDirectory: false, isSymbolicLink: false)
        let ctrl = FileBrowserTabController(initial: FileBrowserTabState(rootPath: "/r", rootKind: .worktree), dataSource: mock)
        await ctrl.selectFile("/r/a.exe")
        if case .binary = ctrl.openFile {} else {
            XCTFail("expected .binary, got \(ctrl.openFile)")
        }
    }

    func testEditMarksDirty() async {
        let mock = MockFileBrowserDataSource()
        mock.fileMetas["/r/a.txt"] = FileMetadata(path: "/r/a.txt", sizeBytes: 1, modifiedAt: nil, isDirectory: false, isSymbolicLink: false)
        mock.fileContents["/r/a.txt"] = "x".data(using: .utf8)!
        let ctrl = FileBrowserTabController(initial: FileBrowserTabState(rootPath: "/r", rootKind: .worktree), dataSource: mock)
        await ctrl.selectFile("/r/a.txt")
        ctrl.updateBuffer(content: "edited")
        if case .text(_, let content, _, let dirty) = ctrl.openFile {
            XCTAssertEqual(content, "edited")
            XCTAssertTrue(dirty)
        } else {
            XCTFail()
        }
    }

    func testSaveWritesAndClearsDirty() async throws {
        let mock = MockFileBrowserDataSource()
        mock.fileMetas["/r/a.txt"] = FileMetadata(path: "/r/a.txt", sizeBytes: 1, modifiedAt: nil, isDirectory: false, isSymbolicLink: false)
        mock.fileContents["/r/a.txt"] = "x".data(using: .utf8)!
        let ctrl = FileBrowserTabController(initial: FileBrowserTabState(rootPath: "/r", rootKind: .worktree), dataSource: mock)
        await ctrl.selectFile("/r/a.txt")
        ctrl.updateBuffer(content: "edited")
        try await ctrl.saveCurrentFile()
        XCTAssertEqual(mock.writes.count, 1)
        XCTAssertEqual(String(data: mock.writes[0].data, encoding: .utf8), "edited")
        if case .text(_, _, _, let dirty) = ctrl.openFile {
            XCTAssertFalse(dirty)
        } else { XCTFail() }
    }

    func testIsDirty() async {
        let mock = MockFileBrowserDataSource()
        mock.fileMetas["/r/a.txt"] = FileMetadata(path: "/r/a.txt", sizeBytes: 1, modifiedAt: nil, isDirectory: false, isSymbolicLink: false)
        mock.fileContents["/r/a.txt"] = "x".data(using: .utf8)!
        let ctrl = FileBrowserTabController(initial: FileBrowserTabState(rootPath: "/r", rootKind: .worktree), dataSource: mock)
        XCTAssertFalse(ctrl.isDirty)
        await ctrl.selectFile("/r/a.txt")
        XCTAssertFalse(ctrl.isDirty)
        ctrl.updateBuffer(content: "edited")
        XCTAssertTrue(ctrl.isDirty)
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
