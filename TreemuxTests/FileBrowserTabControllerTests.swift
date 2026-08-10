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
        await ctrl.pendingHiddenFilterTask?.value
        XCTAssertEqual(ctrl.rootChildren.count, 1, "only visible file remains")

        ctrl.setShowsHiddenFiles(true)
        await ctrl.pendingHiddenFilterTask?.value
        XCTAssertEqual(ctrl.rootChildren.count, 2, "hidden file must reappear without re-fetch")
    }

    /// The hidden-file filter now re-derives off-main (Task 7), guarded by a
    /// generation counter. Two toggles fired back-to-back with no await in
    /// between must still converge to the *latest* requested state, not
    /// whichever background computation happens to finish last.
    func test_rapidHiddenToggleConvergesToLatestState() async {
        let mock = MockFileBrowserDataSource()
        mock.directoryListings["/r"] = [
            FileNode(id: "/r/.hidden", name: ".hidden", path: "/r/.hidden", kind: .file, sizeBytes: 0, modifiedAt: nil),
            FileNode(id: "/r/visible.txt", name: "visible.txt", path: "/r/visible.txt", kind: .file, sizeBytes: 0, modifiedAt: nil),
        ]
        let state = FileBrowserTabState(rootPath: "/r", rootKind: .project, showsHiddenFiles: true)
        let ctrl = FileBrowserTabController(initial: state, dataSource: mock)
        await ctrl.loadRoot()
        ctrl.setShowsHiddenFiles(false)
        ctrl.setShowsHiddenFiles(true)   // immediately toggle back, no await between
        await ctrl.pendingHiddenFilterTask?.value
        XCTAssertEqual(ctrl.rootChildren.count, 2, "latest toggle (show=true) must win")
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

    /// Feature 10, Task 6: `visibleRows()` must key the `expanded` decision off
    /// `isExpandableDirectory`, not `isDirectory`, so an expanded symlink-to-dir
    /// node renders its children rows.
    func testExpandSymlinkDirectoryShowsChildren() async {
        let mock = MockFileBrowserDataSource()
        let link = FileNode(id: "/root/dlink", name: "dlink", path: "/root/dlink",
                            kind: .symlink(target: "/root/real"), sizeBytes: nil,
                            modifiedAt: nil, symlinkTargetIsDirectory: true)
        let child = FileNode(id: "/root/dlink/inner.txt", name: "inner.txt",
                             path: "/root/dlink/inner.txt", kind: .file,
                             sizeBytes: 3, modifiedAt: nil)
        mock.directoryListings["/root"] = [link]
        mock.directoryListings["/root/dlink"] = [child]

        let controller = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/root", rootKind: .worktree,
                                         splitRatio: 0.3, expandedDirs: [],
                                         showsHiddenFiles: false, subTabs: [], activeSubTabID: nil),
            dataSource: mock)
        await controller.refreshTree()

        // Before expand: only the link row.
        XCTAssertEqual(controller.visibleRows().count, 1)

        await controller.toggleExpand("/root/dlink")
        let ids = controller.visibleRows().map(\.id)
        XCTAssertTrue(ids.contains("/root/dlink/inner.txt"),
                      "symlink-dir should list its target's children when expanded")
    }

    func testSelfSymlinkCycleStopsBeforeListingTarget() async throws {
        let mock = MockFileBrowserDataSource()
        let link = FileNode(
            id: "/root/self", name: "self", path: "/root/self",
            kind: .symlink(target: "."), sizeBytes: nil, modifiedAt: nil,
            symlinkTargetResolution: .directory(canonicalIdentity: "/canonical/root")
        )
        mock.directoryListings["/root"] = [link]
        mock.canonicalIdentities["/root"] = "/canonical/root"
        let controller = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/root", rootKind: .project),
            dataSource: mock
        )
        await controller.refreshTree()
        let callsBeforeExpand = mock.listDirectoryCalls.count

        await controller.toggleExpand("/root/self")

        XCTAssertFalse(controller.expandedDirs.contains("/root/self"))
        XCTAssertEqual(mock.listDirectoryCalls.count, callsBeforeExpand)
        let row = try XCTUnwrap(controller.visibleRows().first { $0.id == "/root/self" })
        XCTAssertNotNil(row.symlinkError)
    }

    func testNestedSymlinkCycleStopsWhenBrowserRootIsSlash() async throws {
        let mock = MockFileBrowserDataSource()
        let directory = FileNode(
            id: "/a", name: "a", path: "/a",
            kind: .directory, sizeBytes: nil, modifiedAt: nil
        )
        let backLink = FileNode(
            id: "/a/back-to-a", name: "back-to-a", path: "/a/back-to-a",
            kind: .symlink(target: "/a"), sizeBytes: nil, modifiedAt: nil,
            symlinkTargetResolution: .directory(canonicalIdentity: "/canonical/a")
        )
        mock.directoryListings["/"] = [directory]
        mock.directoryListings["/a"] = [backLink]
        mock.canonicalIdentities["/"] = "/canonical/root"
        mock.canonicalIdentities["/a"] = "/canonical/a"
        let controller = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/", rootKind: .project),
            dataSource: mock
        )
        await controller.refreshTree()
        await controller.toggleExpand("/a")

        await controller.toggleExpand("/a/back-to-a")

        XCTAssertFalse(controller.expandedDirs.contains("/a/back-to-a"))
        XCTAssertFalse(mock.listDirectoryCalls.contains("/a/back-to-a"))
        let row = try XCTUnwrap(controller.visibleRows().first { $0.id == "/a/back-to-a" })
        XCTAssertNotNil(row.symlinkError)
    }

    func testAliasesToSameTargetCanExpandInSeparateBranches() async {
        let mock = MockFileBrowserDataSource()
        let first = FileNode(
            id: "/root/one", name: "one", path: "/root/one",
            kind: .symlink(target: "/shared"), sizeBytes: nil, modifiedAt: nil,
            symlinkTargetResolution: .directory(canonicalIdentity: "/canonical/shared")
        )
        let second = FileNode(
            id: "/root/two", name: "two", path: "/root/two",
            kind: .symlink(target: "/shared"), sizeBytes: nil, modifiedAt: nil,
            symlinkTargetResolution: .directory(canonicalIdentity: "/canonical/shared")
        )
        mock.directoryListings["/root"] = [first, second]
        mock.directoryListings["/root/one"] = []
        mock.directoryListings["/root/two"] = []
        mock.canonicalIdentities["/root"] = "/canonical/root"
        let controller = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/root", rootKind: .project),
            dataSource: mock
        )
        await controller.refreshTree()

        await controller.toggleExpand("/root/one")
        await controller.toggleExpand("/root/two")

        XCTAssertTrue(controller.expandedDirs.contains("/root/one"))
        XCTAssertTrue(controller.expandedDirs.contains("/root/two"))
    }

    func testTwoDirectorySymlinkCycleStopsAtSecondLink() async throws {
        let mock = MockFileBrowserDataSource()
        let directoryA = FileNode(
            id: "/root/A", name: "A", path: "/root/A",
            kind: .directory, sizeBytes: nil, modifiedAt: nil
        )
        let linkToB = FileNode(
            id: "/root/A/to-B", name: "to-B", path: "/root/A/to-B",
            kind: .symlink(target: "/root/B"), sizeBytes: nil, modifiedAt: nil,
            symlinkTargetResolution: .directory(canonicalIdentity: "/canonical/B")
        )
        let linkBackToA = FileNode(
            id: "/root/A/to-B/back-to-A", name: "back-to-A",
            path: "/root/A/to-B/back-to-A",
            kind: .symlink(target: "/root/A"), sizeBytes: nil, modifiedAt: nil,
            symlinkTargetResolution: .directory(canonicalIdentity: "/canonical/A")
        )
        mock.directoryListings["/root"] = [directoryA]
        mock.directoryListings["/root/A"] = [linkToB]
        mock.directoryListings["/root/A/to-B"] = [linkBackToA]
        mock.canonicalIdentities["/root"] = "/canonical/root"
        mock.canonicalIdentities["/root/A"] = "/canonical/A"
        let controller = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/root", rootKind: .project),
            dataSource: mock
        )
        await controller.refreshTree()
        await controller.toggleExpand("/root/A")
        await controller.toggleExpand("/root/A/to-B")

        await controller.toggleExpand("/root/A/to-B/back-to-A")

        XCTAssertFalse(mock.listDirectoryCalls.contains("/root/A/to-B/back-to-A"))
        let row = try XCTUnwrap(controller.visibleRows().first {
            $0.id == "/root/A/to-B/back-to-A"
        })
        XCTAssertNotNil(row.symlinkError)
    }

    func testCancelledExpansionDoesNotApplyLateChildren() async {
        let mock = MockFileBrowserDataSource()
        let directory = FileNode(
            id: "/root/slow", name: "slow", path: "/root/slow",
            kind: .directory, sizeBytes: nil, modifiedAt: nil
        )
        mock.directoryListings["/root"] = [directory]
        mock.directoryListings["/root/slow"] = []
        let controller = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/root", rootKind: .project),
            dataSource: mock
        )
        await controller.refreshTree()
        mock.directoryListings["/root/slow"] = [
            FileNode(id: "/root/slow/late.txt", name: "late.txt",
                     path: "/root/slow/late.txt", kind: .file,
                     sizeBytes: 1, modifiedAt: nil)
        ]
        let entered = mock.armListDirectoryGate(path: "/root/slow")
        let expansion = Task { @MainActor in
            await controller.toggleExpand("/root/slow")
        }
        for await _ in entered { break }

        await controller.toggleExpand("/root/slow")
        mock.releaseListDirectoryGate()
        await expansion.value

        XCTAssertFalse(controller.expandedDirs.contains("/root/slow"))
        XCTAssertEqual(controller.childrenByPath["/root/slow"], [])
    }

    func testSecondToggleCancelsInFlightExpansionTask() async {
        let mock = MockFileBrowserDataSource()
        let link = FileNode(
            id: "/root/slow", name: "slow", path: "/root/slow",
            kind: .symlink(target: "/target"), sizeBytes: nil, modifiedAt: nil,
            symlinkTargetResolution: .directory(canonicalIdentity: "/canonical/target")
        )
        mock.directoryListings["/root"] = [link]
        mock.canonicalIdentities["/root"] = "/canonical/root"
        let controller = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/root", rootKind: .project),
            dataSource: mock
        )
        await controller.refreshTree()
        let signals = mock.armCancellableListDirectory(path: link.path)
        let expansion = Task { @MainActor in await controller.toggleExpand(link.path) }
        for await _ in signals.entered { break }

        await controller.toggleExpand(link.path)
        for await _ in signals.cancelled { break }
        await expansion.value

        XCTAssertFalse(controller.expandedDirs.contains(link.path))
        XCTAssertNil(controller.childrenByPath[link.path])
        XCTAssertNil(controller.loadError)
    }

    func testRefreshCancelsInFlightExpansionTask() async {
        let mock = MockFileBrowserDataSource()
        let link = FileNode(
            id: "/root/slow", name: "slow", path: "/root/slow",
            kind: .symlink(target: "/target"), sizeBytes: nil, modifiedAt: nil,
            symlinkTargetResolution: .directory(canonicalIdentity: "/canonical/target")
        )
        mock.directoryListings["/root"] = [link]
        mock.canonicalIdentities["/root"] = "/canonical/root"
        let controller = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/root", rootKind: .project),
            dataSource: mock
        )
        await controller.refreshTree()
        let signals = mock.armCancellableListDirectory(path: link.path)
        let expansion = Task { @MainActor in await controller.toggleExpand(link.path) }
        for await _ in signals.entered { break }

        await controller.refreshTree()
        for await _ in signals.cancelled { break }
        await expansion.value

        XCTAssertFalse(controller.expandedDirs.contains(link.path))
        XCTAssertNil(controller.childrenByPath[link.path])
        XCTAssertNil(controller.loadError)
    }

    func testRefreshDuringCanonicalLookupDoesNotCacheStaleIdentityOrError() async {
        let mock = MockFileBrowserDataSource()
        let link = FileNode(
            id: "/root/link", name: "link", path: "/root/link",
            kind: .symlink(target: "/target"), sizeBytes: nil, modifiedAt: nil,
            symlinkTargetResolution: .directory(canonicalIdentity: "/canonical/target")
        )
        mock.directoryListings["/root"] = [link]
        mock.directoryListings["/root/link"] = []
        mock.canonicalIdentities["/root"] = "/canonical/target"
        let controller = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/root", rootKind: .project),
            dataSource: mock
        )
        await controller.refreshTree()
        let entered = mock.armCanonicalIdentityGate(path: "/root")
        let staleExpansion = Task { @MainActor in
            await controller.toggleExpand("/root/link")
        }
        for await _ in entered { break }

        mock.canonicalIdentities["/root"] = "/canonical/root"
        await controller.refreshTree()
        mock.releaseCanonicalIdentityGate()
        await staleExpansion.value
        await controller.toggleExpand("/root/link")

        XCTAssertTrue(controller.expandedDirs.contains("/root/link"))
        let row = controller.visibleRows().first { $0.id == "/root/link" }
        XCTAssertNil(row?.symlinkError)
    }

    func testCollapseDuringCanonicalLookupDoesNotCacheStaleIdentityOrError() async {
        let mock = MockFileBrowserDataSource()
        let link = FileNode(
            id: "/root/link", name: "link", path: "/root/link",
            kind: .symlink(target: "/target"), sizeBytes: nil, modifiedAt: nil,
            symlinkTargetResolution: .directory(canonicalIdentity: "/canonical/target")
        )
        mock.directoryListings["/root"] = [link]
        mock.directoryListings["/root/link"] = []
        mock.canonicalIdentities["/root"] = "/canonical/target"
        let controller = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/root", rootKind: .project),
            dataSource: mock
        )
        await controller.refreshTree()
        let entered = mock.armCanonicalIdentityGate(path: "/root")
        let staleExpansion = Task { @MainActor in
            await controller.toggleExpand("/root/link")
        }
        for await _ in entered { break }

        await controller.toggleExpand("/root/link")
        mock.canonicalIdentities["/root"] = "/canonical/root"
        mock.releaseCanonicalIdentityGate()
        await staleExpansion.value
        await controller.toggleExpand("/root/link")

        XCTAssertTrue(controller.expandedDirs.contains("/root/link"))
        let row = controller.visibleRows().first { $0.id == "/root/link" }
        XCTAssertNil(row?.symlinkError)
    }

    func testBrokenSymlinkActivationReportsRowErrorInsteadOfOpeningFile() async throws {
        let mock = MockFileBrowserDataSource()
        let link = FileNode(
            id: "/root/broken", name: "broken", path: "/root/broken",
            kind: .symlink(target: "missing"), sizeBytes: nil, modifiedAt: nil,
            symlinkTargetResolution: .broken
        )
        mock.directoryListings["/root"] = [link]
        let controller = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/root", rootKind: .project),
            dataSource: mock
        )
        await controller.refreshTree()

        await controller.activateNode(link)

        XCTAssertTrue(controller.subTabs.isEmpty)
        let row = try XCTUnwrap(controller.visibleRows().first { $0.id == link.path })
        XCTAssertNotNil(row.symlinkError)
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
        // `openFile.content` intentionally stays pinned at the opened value —
        // Task 7 isolates per-keystroke edits into `liveBuffer(for:)` so they
        // don't publish through the controller-wide `subTabs` array. `dirty`
        // is still the one flag that flips (and publishes) on first edit.
        if case .text(_, let content, _, let dirty) = ctrl.openFile {
            XCTAssertEqual(content, "x")
            XCTAssertTrue(dirty)
        } else {
            XCTFail()
        }
        XCTAssertEqual(ctrl.liveBuffer(for: id), "edited")
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

    func test_treeScrollOffset_defaultsToZeroAndPersists() {
        let ctrl = FileBrowserTabController(
            initial: .init(rootPath: "/r", rootKind: .project),
            dataSource: GatedFileBrowserDataSource())
        XCTAssertEqual(ctrl.treeScrollOffset, 0)

        ctrl.treeScrollOffset = 142.5
        XCTAssertEqual(ctrl.treeScrollOffset, 142.5)
    }

    // MARK: - Large-file confirm (P2: single stat)

    /// P2: `confirmLargeFileLoad` must reuse the metadata already fetched by
    /// `selectFile` instead of paying a second remote stat round-trip.
    func test_confirmLargeFileLoad_reusesMetadata_noSecondStat() async {
        let mock = MockFileBrowserDataSource()
        let path = "/r/big.txt"
        mock.fileMetas[path] = FileMetadata(path: path, sizeBytes: 6 * 1024 * 1024,
                                            modifiedAt: nil, isDirectory: false, isSymbolicLink: false)
        mock.fileContents[path] = Data("hello".utf8)
        let ctrl = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/r", rootKind: .project),
            dataSource: mock
        )

        await ctrl.openInTree(path)
        guard case .confirmingLargeFile = ctrl.activeSubTab?.openFile else {
            return XCTFail("expected large-file prompt, got \(String(describing: ctrl.activeSubTab?.openFile))")
        }
        XCTAssertEqual(mock.fileMetadataCallCount, 1)

        await ctrl.confirmLargeFileLoad()

        XCTAssertEqual(mock.fileMetadataCallCount, 1, "confirm must not re-stat")
        guard case .text(_, let content, _, _) = ctrl.activeSubTab?.openFile else {
            return XCTFail("expected text content after confirm, got \(String(describing: ctrl.activeSubTab?.openFile))")
        }
        XCTAssertEqual(content, "hello")
    }

    /// Cancelling the prompt clears the stashed metadata and resets state, so
    /// a stray confirm afterwards is a harmless no-op (no dispatch, no stat).
    func test_cancelLargeFileLoad_clearsPendingMetadata() async {
        let mock = MockFileBrowserDataSource()
        let path = "/r/big.txt"
        mock.fileMetas[path] = FileMetadata(path: path, sizeBytes: 6 * 1024 * 1024,
                                            modifiedAt: nil, isDirectory: false, isSymbolicLink: false)
        mock.fileContents[path] = Data("hello".utf8)
        let ctrl = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/r", rootKind: .project),
            dataSource: mock
        )

        await ctrl.openInTree(path)
        ctrl.cancelLargeFileLoad()
        if case .empty = ctrl.activeSubTab?.openFile {} else {
            XCTFail("expected empty state after cancel")
        }

        await ctrl.confirmLargeFileLoad()
        XCTAssertEqual(mock.fileMetadataCallCount, 1, "stray confirm must not stat")
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
    var cacheIdentity: String? = nil
    var treeCacheIdentity: String? { cacheIdentity }
    var canonicalIdentities: [String: String] = [:]
    var listDirectoryCalls: [String] = []
    private var gatedListDirectoryPath: String?
    private var listDirectoryGate: CheckedContinuation<Void, Never>?
    private var listDirectoryEnteredContinuation: AsyncStream<Void>.Continuation?
    var cancellableListDirectoryPath: String?
    private var cancellableListEnteredContinuation: AsyncStream<Void>.Continuation?
    private var cancellableListCancelledContinuation: AsyncStream<Void>.Continuation?
    private var gatedCanonicalIdentityPath: String?
    private var canonicalIdentityGate: CheckedContinuation<Void, Never>?
    private var canonicalIdentityEnteredContinuation: AsyncStream<Void>.Continuation?

    func armListDirectoryGate(path: String) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        gatedListDirectoryPath = path
        listDirectoryEnteredContinuation = continuation
        return stream
    }

    func releaseListDirectoryGate() {
        listDirectoryGate?.resume()
        listDirectoryGate = nil
        gatedListDirectoryPath = nil
    }

    func armCancellableListDirectory(path: String) -> (entered: AsyncStream<Void>, cancelled: AsyncStream<Void>) {
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (cancelled, cancelledContinuation) = AsyncStream<Void>.makeStream()
        cancellableListDirectoryPath = path
        cancellableListEnteredContinuation = enteredContinuation
        cancellableListCancelledContinuation = cancelledContinuation
        return (entered, cancelled)
    }

    func armCanonicalIdentityGate(path: String) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        gatedCanonicalIdentityPath = path
        canonicalIdentityEnteredContinuation = continuation
        return stream
    }

    func releaseCanonicalIdentityGate() {
        canonicalIdentityGate?.resume()
        canonicalIdentityGate = nil
        gatedCanonicalIdentityPath = nil
    }

    func listDirectory(_ path: String) async throws -> [FileNode] {
        listDirectoryCalls.append(path)
        if gatedListDirectoryPath == path {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                listDirectoryGate = continuation
                listDirectoryEnteredContinuation?.yield(())
                listDirectoryEnteredContinuation?.finish()
                listDirectoryEnteredContinuation = nil
            }
        }
        if cancellableListDirectoryPath == path {
            cancellableListEnteredContinuation?.yield(())
            cancellableListEnteredContinuation?.finish()
            cancellableListEnteredContinuation = nil
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                cancellableListCancelledContinuation?.yield(())
                cancellableListCancelledContinuation?.finish()
                cancellableListCancelledContinuation = nil
                throw CancellationError()
            }
        }
        if let listError { throw listError }
        return directoryListings[path] ?? []
    }
    func canonicalDirectoryIdentity(_ path: String) async throws -> String {
        let identity = canonicalIdentities[path] ?? path
        if gatedCanonicalIdentityPath == path {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                canonicalIdentityGate = continuation
                canonicalIdentityEnteredContinuation?.yield(())
                canonicalIdentityEnteredContinuation?.finish()
                canonicalIdentityEnteredContinuation = nil
            }
        }
        return identity
    }
    var fileMetadataCallCount = 0
    func fileMetadata(_ path: String) async throws -> FileMetadata {
        fileMetadataCallCount += 1
        return fileMetas[path] ?? FileMetadata(path: path, sizeBytes: Int64(fileContents[path]?.count ?? 0), modifiedAt: nil, isDirectory: false, isSymbolicLink: false)
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
    var createdDirectories: [String] = []
    var createdFiles: [String] = []
    var createError: Error?
    func createDirectory(_ path: String) async throws {
        if let createError { throw createError }
        createdDirectories.append(path)
        // Make it visible to a subsequent listDirectory of the parent.
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        directoryListings[parent, default: []].append(
            FileNode(id: path, name: name, path: path, kind: .directory, sizeBytes: nil, modifiedAt: nil))
    }
    func createFile(_ path: String) async throws {
        if let createError { throw createError }
        createdFiles.append(path)
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        directoryListings[parent, default: []].append(
            FileNode(id: path, name: name, path: path, kind: .file, sizeBytes: 0, modifiedAt: nil))
    }

    var searchResultsToReturn: [FileNode] = []
    var searchError: Error?
    var searchCallCount = 0
    /// Records the `includeHidden` value passed on the most recent `searchNames`
    /// call, so tests can assert it was threaded through from the controller's
    /// `showsHiddenFiles`.
    var lastSearchIncludeHidden: Bool?

    /// Test seam: when armed (see `armSearchNamesGate()`), `searchNames` suspends
    /// on this continuation until `releaseSearchNamesGate()` resumes it. Lets tests
    /// deterministically observe/interact with an in-flight recursive search
    /// instead of racing a real async data source.
    private var searchNamesGate: CheckedContinuation<Void, Never>?
    private var searchNamesEnteredContinuationBox: AsyncStream<Void>.Continuation?

    /// Call before invoking `searchNames` to make it suspend until `releaseSearchNamesGate()`
    /// is called. Returns an async sequence the test awaits one element from to know the
    /// mock has entered `searchNames` and is now parked on the gate.
    func armSearchNamesGate() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        searchNamesEnteredContinuationBox = continuation
        return stream
    }

    func releaseSearchNamesGate() {
        searchNamesGate?.resume()
        searchNamesGate = nil
    }

    func searchNames(root: String, query: String, maxResults: Int, includeHidden: Bool) async throws -> [FileNode] {
        searchCallCount += 1
        lastSearchIncludeHidden = includeHidden
        if searchNamesEnteredContinuationBox != nil {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                searchNamesGate = cont
                searchNamesEnteredContinuationBox?.yield(())
                searchNamesEnteredContinuationBox?.finish()
                searchNamesEnteredContinuationBox = nil
            }
        }
        if let searchError { throw searchError }
        return Array(searchResultsToReturn.prefix(maxResults))
    }
}
