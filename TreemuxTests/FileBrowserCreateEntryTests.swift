import XCTest
@testable import Treemux

@MainActor
final class FileBrowserCreateEntryTests: XCTestCase {
    private func makeController(_ mock: MockFileBrowserDataSource,
                               root: String = "/root") -> FileBrowserTabController {
        FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: root, rootKind: .worktree),
            dataSource: mock)
    }

    func testBeginNewEntryInjectsEditorRowAtRoot() async {
        let mock = MockFileBrowserDataSource()
        mock.directoryListings["/root"] = [
            FileNode(id: "/root/a.txt", name: "a.txt", path: "/root/a.txt",
                     kind: .file, sizeBytes: 1, modifiedAt: nil)]
        let c = makeController(mock)
        await c.refreshTree()

        await c.beginNewEntry(intent: .folder, in: "/root")
        let kinds = c.visibleRows().map(\.kind)
        let hasEditor = kinds.contains { if case .editor(let p, let i) = $0 { return p == "/root" && i == .folder }; return false }
        XCTAssertTrue(hasEditor, "editor row should be injected under the root")
    }

    func testCommitCreatesFolderAndRefreshes() async {
        let mock = MockFileBrowserDataSource()
        mock.directoryListings["/root"] = []
        let c = makeController(mock)
        await c.refreshTree()
        await c.beginNewEntry(intent: .folder, in: "/root")

        await c.commitNewEntry(name: "docs")

        XCTAssertEqual(mock.createdDirectories, ["/root/docs"])
        XCTAssertNil(c.newEntryDraft, "draft cleared after successful commit")
        XCTAssertTrue(c.visibleRows().map(\.id).contains("/root/docs"))
    }

    func testValidationRejectsEmptySlashAndDuplicate() async {
        let mock = MockFileBrowserDataSource()
        mock.directoryListings["/root"] = [
            FileNode(id: "/root/dup", name: "dup", path: "/root/dup",
                     kind: .directory, sizeBytes: nil, modifiedAt: nil)]
        let c = makeController(mock)
        await c.refreshTree()

        XCTAssertNotNil(c.validateNewEntryName("", in: "/root"))
        XCTAssertNotNil(c.validateNewEntryName("a/b", in: "/root"))
        XCTAssertNotNil(c.validateNewEntryName("dup", in: "/root"))
        XCTAssertNil(c.validateNewEntryName("fresh", in: "/root"))
    }

    func testCommitInvalidNameSetsErrorAndKeepsDraft() async {
        let mock = MockFileBrowserDataSource()
        mock.directoryListings["/root"] = []
        let c = makeController(mock)
        await c.refreshTree()
        await c.beginNewEntry(intent: .file, in: "/root")

        await c.commitNewEntry(name: "")
        XCTAssertNotNil(c.newEntryDraft?.errorMessage)
        XCTAssertEqual(mock.createdFiles, [])
    }

    func testTargetDirectoryForFileUsesParent() {
        let mock = MockFileBrowserDataSource()
        let c = makeController(mock)
        let file = FileNode(id: "/root/sub/a.txt", name: "a.txt", path: "/root/sub/a.txt",
                            kind: .file, sizeBytes: 1, modifiedAt: nil)
        XCTAssertEqual(c.targetDirectory(for: file), "/root/sub")
        let dir = FileNode(id: "/root/sub", name: "sub", path: "/root/sub",
                           kind: .directory, sizeBytes: nil, modifiedAt: nil)
        XCTAssertEqual(c.targetDirectory(for: dir), "/root/sub")
    }
}
