//
//  FileBrowserTabControllerTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

@MainActor
final class FileBrowserTabControllerTests: XCTestCase {
    func test_setShowsHiddenFiles_recoversHiddenAfterToggleOff() async {
        let mock = MockFileBrowserDataSource()
        let visible = FileNode(id: "/r/a", name: "a", path: "/r/a", kind: .file, sizeBytes: 0, modifiedAt: nil)
        let hidden  = FileNode(id: "/r/.b", name: ".b", path: "/r/.b", kind: .file, sizeBytes: 0, modifiedAt: nil)
        mock.directoryListings["/r"] = [visible, hidden]
        let state = FileBrowserTabState(rootPath: "/r", rootKind: .project, showsHiddenFiles: true)
        let ctrl = FileBrowserTabController(initial: state, dataSource: mock)
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

    // Stage D rewires file loading to operate on the active sub-tab. The tests
    // below now go through `openInTree`, which seeds a preview sub-tab and then
    // dispatches to the same metadata/content loading code path the previous
    // direct `selectFile` invocation hit.

    func testSelectSmallTextFile() async throws {
        let mock = MockFileBrowserDataSource()
        mock.fileMetas["/r/a.txt"] = FileMetadata(path: "/r/a.txt", sizeBytes: 5, modifiedAt: nil, isDirectory: false, isSymbolicLink: false)
        mock.fileContents["/r/a.txt"] = "hello".data(using: .utf8)!
        let ctrl = FileBrowserTabController(initial: FileBrowserTabState(rootPath: "/r", rootKind: .worktree), dataSource: mock)
        await ctrl.openInTree("/r/a.txt")
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
        await ctrl.openInTree("/r/big.bin")
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
        await ctrl.openInTree("/r/a.exe")
        if case .binary = ctrl.openFile {} else {
            XCTFail("expected .binary, got \(ctrl.openFile)")
        }
    }

    /// Regression: a Julia source file (.jl) larger than the sniff window must
    /// classify as text, not binary. Previously `loadUnknown` requested only
    /// 512 bytes via `readFile`, which threw `fileTooLarge` for anything over
    /// the limit and dropped the file into the binary path.
    func testSelectUnknownExtensionLargeTextFile() async {
        let mock = MockFileBrowserDataSource()
        let big = "function greet()\n  println(\"hello\")\nend\n".data(using: .utf8)!
            + Data(repeating: 0x20, count: 100_000) // padding so size >> sniff window
        mock.fileContents["/r/main.jl"] = big
        mock.fileMetas["/r/main.jl"] = FileMetadata(
            path: "/r/main.jl",
            sizeBytes: Int64(big.count),
            modifiedAt: nil,
            isDirectory: false,
            isSymbolicLink: false
        )
        let ctrl = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/r", rootKind: .worktree),
            dataSource: mock
        )
        await ctrl.openInTree("/r/main.jl")
        if case .text = ctrl.openFile {
            // ok
        } else {
            XCTFail("expected .text for a large .jl source file, got \(ctrl.openFile)")
        }
    }

    func testEditMarksDirty() async {
        let mock = MockFileBrowserDataSource()
        mock.fileMetas["/r/a.txt"] = FileMetadata(path: "/r/a.txt", sizeBytes: 1, modifiedAt: nil, isDirectory: false, isSymbolicLink: false)
        mock.fileContents["/r/a.txt"] = "x".data(using: .utf8)!
        let ctrl = FileBrowserTabController(initial: FileBrowserTabState(rootPath: "/r", rootKind: .worktree), dataSource: mock)
        await ctrl.openInTree("/r/a.txt")
        let id = ctrl.activeSubTabID!
        ctrl.updateBuffer(content: "edited", forSubTab: id)
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
        await ctrl.openInTree("/r/a.txt")
        let id = ctrl.activeSubTabID!
        ctrl.updateBuffer(content: "edited", forSubTab: id)
        try await ctrl.saveCurrentFile()
        XCTAssertEqual(mock.writes.count, 1)
        XCTAssertEqual(String(data: mock.writes[0].data, encoding: .utf8), "edited")
        if case .text(_, let content, _, let dirty) = ctrl.openFile {
            // The saved buffer content must survive the save.
            XCTAssertEqual(content, "edited")
            // Also guards the non-blocking-save contract: the git/diff refresh is
            // detached, so `dirty` must be cleared synchronously before
            // saveCurrentFile() returns.
            XCTAssertFalse(dirty)
        } else { XCTFail() }
    }

    func testIsDirty() async {
        let mock = MockFileBrowserDataSource()
        mock.fileMetas["/r/a.txt"] = FileMetadata(path: "/r/a.txt", sizeBytes: 1, modifiedAt: nil, isDirectory: false, isSymbolicLink: false)
        mock.fileContents["/r/a.txt"] = "x".data(using: .utf8)!
        let ctrl = FileBrowserTabController(initial: FileBrowserTabState(rootPath: "/r", rootKind: .worktree), dataSource: mock)
        XCTAssertFalse(ctrl.isDirty)
        await ctrl.openInTree("/r/a.txt")
        XCTAssertFalse(ctrl.isDirty)
        let id = ctrl.activeSubTabID!
        ctrl.updateBuffer(content: "edited", forSubTab: id)
        XCTAssertTrue(ctrl.isDirty)
    }

    // MARK: - LoadError surface (B1)

    func test_loadRoot_authFailed_setsNeedsPasswordError() async {
        let mock = MockFileBrowserDataSource()
        mock.listError = SFTPServiceError.authenticationFailed
        let state = FileBrowserTabState(rootPath: "/r", rootKind: .project)
        let ctrl = FileBrowserTabController(initial: state, dataSource: mock)
        await ctrl.loadRoot()
        if case .needsPassword = ctrl.loadError {
            // ok — host is empty here because mock isn't a RemoteFileBrowserDataSource;
            // real wiring is covered by retryWithPassword in production code.
        } else {
            XCTFail("expected .needsPassword, got \(String(describing: ctrl.loadError))")
        }
    }

    func test_loadRoot_noAuthMethodAvailable_setsNeedsPasswordError() async {
        let mock = MockFileBrowserDataSource()
        mock.listError = SFTPServiceError.noAuthMethodAvailable
        let ctrl = FileBrowserTabController(
            initial: .init(rootPath: "/r", rootKind: .project),
            dataSource: mock)
        await ctrl.loadRoot()
        if case .needsPassword = ctrl.loadError {
            // ok
        } else {
            XCTFail("expected .needsPassword, got \(String(describing: ctrl.loadError))")
        }
    }

    func test_loadRoot_genericError_setsGenericError() async {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
        let mock = MockFileBrowserDataSource()
        mock.listError = Boom()
        let ctrl = FileBrowserTabController(
            initial: .init(rootPath: "/r", rootKind: .project),
            dataSource: mock)
        await ctrl.loadRoot()
        if case .generic(let msg) = ctrl.loadError {
            XCTAssertEqual(msg, "boom")
        } else {
            XCTFail("expected .generic")
        }
    }

    func test_loadRoot_success_clearsLoadError() async {
        let mock = MockFileBrowserDataSource()
        mock.listError = SFTPServiceError.authenticationFailed
        let ctrl = FileBrowserTabController(
            initial: .init(rootPath: "/r", rootKind: .project),
            dataSource: mock)
        await ctrl.loadRoot()  // sets needsPassword
        XCTAssertNotNil(ctrl.loadError)
        mock.listError = nil
        await ctrl.loadRoot()  // resets to nil on entry, succeeds
        XCTAssertNil(ctrl.loadError)
    }
}

final class MockFileBrowserDataSource: FileBrowserDataSource {
    var supportsWrite = true
    var directoryListings: [String: [FileNode]] = [:]
    var fileContents: [String: Data] = [:]
    var fileMetas: [String: FileMetadata] = [:]
    var writes: [(path: String, data: Data)] = []
    /// When non-nil, `listDirectory` throws this error before returning.
    var listError: Error?

    func listDirectory(_ path: String) async throws -> [FileNode] {
        if let listError { throw listError }
        return directoryListings[path] ?? []
    }
    func fileMetadata(_ path: String) async throws -> FileMetadata {
        fileMetas[path] ?? FileMetadata(path: path, sizeBytes: Int64(fileContents[path]?.count ?? 0), modifiedAt: nil, isDirectory: false, isSymbolicLink: false)
    }
    func readFile(_ path: String, maxBytes: Int) async throws -> Data {
        guard let data = fileContents[path] else { throw FileBrowserError.notFound(path) }
        if data.count > maxBytes { throw FileBrowserError.fileTooLarge(path: path, sizeBytes: Int64(data.count), limit: Int64(maxBytes)) }
        return data
    }
    func readPrefix(_ path: String, maxBytes: Int) async throws -> Data {
        guard let data = fileContents[path] else { throw FileBrowserError.notFound(path) }
        return data.prefix(maxBytes)
    }
    func writeFile(_ path: String, data: Data) async throws {
        writes.append((path, data))
        fileContents[path] = data
    }
    func downloadForQuickLook(_ path: String, progress: @escaping (Double) -> Void) async throws -> URL {
        URL(fileURLWithPath: path)
    }
}
