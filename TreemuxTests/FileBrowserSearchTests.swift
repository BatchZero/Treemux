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
        // `showsHiddenFiles` defaults to false, so the data source must be told
        // not to include hidden entries unless the user has toggled it on.
        XCTAssertEqual(mock.lastSearchIncludeHidden, false)
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

    // MARK: - Regression: FIX 1 (isSearching stuck true after cancel)

    /// Deterministically covers FIX 1: `searchQuery`'s `didSet` cancels the
    /// in-flight search task, but a cancelled task's own cleanup
    /// (`if !Task.isCancelled { isSearching = false }` in
    /// `performRecursiveSearch`) never runs — so `didSet` itself must clear
    /// `isSearching`, or it stays stuck `true` forever.
    ///
    /// This uses a real gate on the mock's `searchNames` (not a sleep) so the
    /// test deterministically observes the search mid-flight: the mock only
    /// resumes once `releaseSearchNamesGate()` is called, and the stream
    /// returned by `armSearchNamesGate()` only yields once `searchNames` has
    /// actually been entered and suspended on that gate.
    func testEditingQueryDuringSearchResetsIsSearching() async {
        let mock = MockFileBrowserDataSource(); seedTree(mock)
        mock.searchResultsToReturn = [
            FileNode(id: "/root/deep/buried.log", name: "buried.log",
                     path: "/root/deep/buried.log", kind: .file, sizeBytes: 1, modifiedAt: nil)]
        let c = controller(mock)
        await c.refreshTree()
        c.searchQuery = "buried"

        let entered = mock.armSearchNamesGate()
        let searchTask = Task { await c.performRecursiveSearch() }

        // Wait until the mock has actually entered searchNames and parked on
        // the gate — not a sleep, a real signal.
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()

        XCTAssertTrue(c.isSearching, "search should be in-flight while parked on the gate")
        XCTAssertTrue(c.showingRecursiveResults)

        // Editing the query mid-search cancels the task via didSet.
        c.searchQuery = "different"

        XCTAssertFalse(c.isSearching, "FIX 1: didSet must clear isSearching itself — a cancelled task can't")
        XCTAssertFalse(c.showingRecursiveResults)

        // Release the parked mock call and let the original task unwind.
        mock.releaseSearchNamesGate()
        await searchTask.value

        XCTAssertTrue(c.searchResults.isEmpty, "no stale results from the cancelled search should leak in")
        XCTAssertFalse(c.isSearching)
    }

    // MARK: - Regression: FIX 2 (recursive results ignoring showsHiddenFiles)

    func testRecursiveResultsRespectHiddenFiles() async {
        let mock = MockFileBrowserDataSource(); seedTree(mock)
        mock.searchResultsToReturn = [
            FileNode(id: "/root/.secret.log", name: ".secret.log",
                     path: "/root/.secret.log", kind: .file, sizeBytes: 1, modifiedAt: nil),
            FileNode(id: "/root/buried.log", name: "buried.log",
                     path: "/root/buried.log", kind: .file, sizeBytes: 1, modifiedAt: nil)]
        let c = controller(mock)
        await c.refreshTree()
        XCTAssertFalse(c.showsHiddenFiles, "default should be hidden files off")
        c.searchQuery = "log"
        await c.performRecursiveSearch()

        let idsHidden = c.visibleRows().map(\.id)
        XCTAssertTrue(idsHidden.contains("result:/root/buried.log"))
        XCTAssertFalse(idsHidden.contains("result:/root/.secret.log"),
                        "FIX 2: hidden entries must not leak into recursive results")

        c.setShowsHiddenFiles(true)
        let idsShown = c.visibleRows().map(\.id)
        XCTAssertTrue(idsShown.contains("result:/root/buried.log"))
        XCTAssertTrue(idsShown.contains("result:/root/.secret.log"),
                      "toggling showsHiddenFiles on should re-reveal hidden results without a re-search")
    }

    // MARK: - Regression: FIX 3 (revealInTree bail on failed expand)

    func testRevealInTreeExpandsAncestorsAndClearsSearch() async {
        let mock = MockFileBrowserDataSource(); seedTree(mock)
        mock.searchResultsToReturn = [
            FileNode(id: "/root/src/main.swift", name: "main.swift",
                     path: "/root/src/main.swift", kind: .file, sizeBytes: 1, modifiedAt: nil)]
        let c = controller(mock)
        await c.refreshTree()
        c.searchQuery = "main"
        await c.performRecursiveSearch()
        XCTAssertTrue(c.showingRecursiveResults)

        await c.revealInTree("/root/src/main.swift")

        XCTAssertEqual(c.searchQuery, "")
        XCTAssertFalse(c.showingRecursiveResults)
        XCTAssertTrue(c.expandedDirs.contains("/root/src"))
        XCTAssertTrue(c.visibleRows().map(\.id).contains("/root/src/main.swift"))
    }
}
