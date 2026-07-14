import XCTest
@testable import Treemux

@MainActor
final class FileBrowserSearchTests: XCTestCase {
    private func controller(_ mock: MockFileBrowserDataSource) -> FileBrowserTabController {
        FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/root", rootKind: .worktree),
            dataSource: mock)
    }

    private func seedTree(_ mock: MockFileBrowserDataSource) {
        mock.directoryListings["/root"] = [
            FileNode(id: "/root/src", name: "src", path: "/root/src",
                     kind: .directory, sizeBytes: nil, modifiedAt: nil),
            FileNode(id: "/root/notes.txt", name: "notes.txt", path: "/root/notes.txt",
                     kind: .file, sizeBytes: 1, modifiedAt: nil)]
        mock.directoryListings["/root/src"] = [
            FileNode(id: "/root/src/main.swift", name: "main.swift", path: "/root/src/main.swift",
                     kind: .file, sizeBytes: 1, modifiedAt: nil)]
    }

    func testLiveFilterHidesNonMatchesAndRevealsMatch() async {
        let mock = MockFileBrowserDataSource(); seedTree(mock)
        let c = controller(mock)
        await c.refreshTree()
        await c.toggleExpand("/root/src")   // load nested level into memory

        c.searchQuery = "main"
        let ids = c.visibleRows().map(\.id)
        XCTAssertTrue(ids.contains("/root/src"), "ancestor shown")
        XCTAssertTrue(ids.contains("/root/src/main.swift"), "match shown")
        XCTAssertFalse(ids.contains("/root/notes.txt"), "non-match hidden")
    }

    func testEmptyQueryRestoresNormalTree() async {
        let mock = MockFileBrowserDataSource(); seedTree(mock)
        let c = controller(mock)
        await c.refreshTree()
        c.searchQuery = "main"
        c.searchQuery = ""
        XCTAssertTrue(c.visibleRows().map(\.id).contains("/root/notes.txt"))
    }

    func testRecursiveSearchPopulatesFlatResults() async {
        let mock = MockFileBrowserDataSource(); seedTree(mock)
        mock.searchResultsToReturn = [
            FileNode(id: "/root/deep/buried.log", name: "buried.log",
                     path: "/root/deep/buried.log", kind: .file, sizeBytes: 1, modifiedAt: nil)]
        let c = controller(mock)
        await c.refreshTree()
        c.searchQuery = "buried"
        await c.performRecursiveSearch()

        XCTAssertTrue(c.showingRecursiveResults)
        XCTAssertEqual(c.searchResults.map(\.name), ["buried.log"])
        XCTAssertEqual(c.visibleRows().map(\.id), ["result:/root/deep/buried.log"])
    }

    func testEditingQueryExitsRecursiveMode() async {
        let mock = MockFileBrowserDataSource(); seedTree(mock)
        mock.searchResultsToReturn = [
            FileNode(id: "/root/x.log", name: "x.log", path: "/root/x.log",
                     kind: .file, sizeBytes: 1, modifiedAt: nil)]
        let c = controller(mock)
        await c.refreshTree()
        c.searchQuery = "x"
        await c.performRecursiveSearch()
        XCTAssertTrue(c.showingRecursiveResults)

        c.searchQuery = "xy"   // typing again
        XCTAssertFalse(c.showingRecursiveResults)
        XCTAssertTrue(c.searchResults.isEmpty)
    }

    func testRecursiveSearchSurfacesError() async {
        let mock = MockFileBrowserDataSource(); seedTree(mock)
        mock.searchError = FileBrowserError.notReadable("/root")
        let c = controller(mock)
        await c.refreshTree()
        c.searchQuery = "z"
        await c.performRecursiveSearch()
        XCTAssertNotNil(c.searchError)
    }
}
