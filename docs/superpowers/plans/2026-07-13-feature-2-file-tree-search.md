# Feature 2 — File-Tree Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A single search field in the file-tree toolbar whose scope escalates on demand (Cyberduck-style): typing filters the already-loaded tree live (zero network); pressing Enter runs a bounded, cancellable recursive search (server-side `find` on remote) and shows a flat result list.

**Architecture:** A pure `FileTreeSearch.filter` computes which loaded nodes to show (matches + ancestors) for the live filter. `visibleRows()` branches into three modes: normal, live-filter, and recursive-results. Recursive search goes through a new `FileBrowserDataSource.searchNames(root:query:maxResults:)` returning a bounded `[FileNode]` — local walks the FS off-thread; remote runs one `find` round-trip (system-SSH). The controller owns `searchQuery` and cancels the in-flight search when the query changes.

**Tech Stack:** Swift, SwiftUI, XCTest, Xcode (`Treemux.xcodeproj`), macOS, Citadel (SFTP fallback).

## Global Constraints

- **Worktree rule:** All code changes happen in a git worktree. Create it at execution start: `git worktree add -b feat/feature-2-file-tree-search .worktrees/feat+feature-2-file-tree-search main`. Main checkout stays on `main`. (Branch from merged `main` if Features 10/8 land first.)
- **i18n:** new user-visible strings use `LocalizedStringKey`/`String(localized:)` with `zh-Hans` entries in `Treemux/Localizable.xcstrings`. New strings: `Search`, `Press ⏎ to search all files`, `Press ⏎ to search the server`, `Searching…`, `No matches`, `%d matches`.
- **No hardcoded colors** — the field and result rows use existing theme tokens.
- **Unit test command:** `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/<Class>/<method> test 2>&1 | tail -40`
- **Full test run:** `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation test 2>&1 | tail -40`
- **Build:** `xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug -skipPackagePluginValidation build 2>&1 | tail -20`
- Commit after each task.

## File Structure

- `Treemux/Services/FileBrowser/FileTreeSearch.swift` (new) — pure live-filter helper.
- `Treemux/Services/FileBrowser/FileBrowserDataSource.swift` — `searchNames` protocol method + throwing default.
- `Treemux/Services/FileBrowser/LocalFileBrowserDataSource.swift` — local recursive search.
- `Treemux/Services/SFTP/SFTPService.swift` — `recursiveSearchCommand`, `parseFindResults`, `searchNames(root:query:maxResults:)`.
- `Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift` — remote forward.
- `Treemux/UI/FileBrowser/FileBrowserTabController.swift` — search state, `visibleRows()` modes, `performRecursiveSearch`, `clearSearch`, `revealInTree`.
- `Treemux/UI/FileBrowser/FileTreePanelView.swift` — search field, escalation hint, result-row routing, match highlight.
- `Treemux/Localizable.xcstrings` — zh-Hans entries.
- Tests: `TreemuxTests/FileTreeSearchTests.swift` (new), `TreemuxTests/FileBrowserSearchTests.swift` (new), `LocalFileBrowserDataSourceTests.swift`, `SFTPServiceTests.swift`, `MockFileBrowserDataSource` extension.

**Constants** (on `FileBrowserTabController`): `static let searchMaxResults = 500`, `static let searchMaxDepth = 12`.

---

### Task 1: Pure live-filter helper

**Files:**
- Create: `Treemux/Services/FileBrowser/FileTreeSearch.swift`
- Test: `TreemuxTests/FileTreeSearchTests.swift` (create)

**Interfaces:**
- Produces: `enum FileTreeSearch` with `static func matches(_ name: String, query: String) -> Bool` (case-insensitive substring) and `static func filter(rootChildren: [FileNode], childrenByPath: [String: [FileNode]], query: String) -> (visible: Set<String>, expanded: Set<String>)`. `visible` = paths of matches plus every ancestor of a match; `expanded` = ancestor directories that must be force-opened to reveal a descendant match.

- [ ] **Step 1: Write the failing test**

Create `TreemuxTests/FileTreeSearchTests.swift`:

```swift
import XCTest
@testable import Treemux

final class FileTreeSearchTests: XCTestCase {
    private func dir(_ path: String, _ name: String) -> FileNode {
        FileNode(id: path, name: name, path: path, kind: .directory, sizeBytes: nil, modifiedAt: nil)
    }
    private func file(_ path: String, _ name: String) -> FileNode {
        FileNode(id: path, name: name, path: path, kind: .file, sizeBytes: 1, modifiedAt: nil)
    }

    func testMatchesIsCaseInsensitiveSubstring() {
        XCTAssertTrue(FileTreeSearch.matches("ReadMe.md", query: "readme"))
        XCTAssertTrue(FileTreeSearch.matches("ReadMe.md", query: "me.m"))
        XCTAssertFalse(FileTreeSearch.matches("ReadMe.md", query: "xyz"))
    }

    func testFilterRevealsMatchAndAncestors() {
        // /r ├ src (dir) ├─ main.swift ; ├ notes.txt
        let root = [dir("/r/src", "src"), file("/r/notes.txt", "notes.txt")]
        let children = ["/r/src": [file("/r/src/main.swift", "main.swift")]]
        let (visible, expanded) = FileTreeSearch.filter(
            rootChildren: root, childrenByPath: children, query: "main")
        XCTAssertTrue(visible.contains("/r/src/main.swift"))
        XCTAssertTrue(visible.contains("/r/src"), "ancestor dir is visible")
        XCTAssertTrue(expanded.contains("/r/src"), "ancestor dir is force-expanded")
        XCTAssertFalse(visible.contains("/r/notes.txt"), "non-matching sibling hidden")
    }

    func testFilterMatchingDirectoryItselfIsVisibleNotForceExpanded() {
        let root = [dir("/r/src", "src")]
        let children = ["/r/src": [file("/r/src/a.txt", "a.txt")]]
        let (visible, expanded) = FileTreeSearch.filter(
            rootChildren: root, childrenByPath: children, query: "src")
        XCTAssertTrue(visible.contains("/r/src"))
        XCTAssertFalse(expanded.contains("/r/src"),
                       "a dir that matches by its own name isn't force-expanded")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/FileTreeSearchTests test 2>&1 | tail -40`
Expected: FAIL to compile (`FileTreeSearch` undefined).

- [ ] **Step 3: Implement `FileTreeSearch.swift`**

```swift
//
//  FileTreeSearch.swift
//  Treemux

import Foundation

/// Pure helpers for the file-tree live filter. Operates only on the tree already
/// loaded in memory — never touches the data source.
enum FileTreeSearch {
    static func matches(_ name: String, query: String) -> Bool {
        name.range(of: query, options: [.caseInsensitive]) != nil
    }

    /// Returns the node paths to show (matches + their ancestor directories) and
    /// the ancestor directory paths to force-open, for a case-insensitive
    /// substring query over the loaded tree.
    static func filter(rootChildren: [FileNode],
                       childrenByPath: [String: [FileNode]],
                       query: String) -> (visible: Set<String>, expanded: Set<String>) {
        var visible: Set<String> = []
        var expanded: Set<String> = []

        // Returns true when the subtree rooted at `node` contains a match.
        func walk(_ node: FileNode) -> Bool {
            let selfMatch = matches(node.name, query: query)
            var descendantMatch = false
            if let kids = childrenByPath[node.path] {
                for kid in kids {
                    // Call walk for every child (side effects populate `visible`).
                    if walk(kid) { descendantMatch = true }
                }
            }
            if selfMatch || descendantMatch {
                visible.insert(node.path)
                if descendantMatch { expanded.insert(node.path) }
                return true
            }
            return false
        }

        for node in rootChildren { _ = walk(node) }
        return (visible, expanded)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/FileTreeSearchTests test 2>&1 | tail -40`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Treemux/Services/FileBrowser/FileTreeSearch.swift TreemuxTests/FileTreeSearchTests.swift
git commit -m "feat(file-tree): pure live-filter helper"
```

---

### Task 2: `searchNames` protocol + local implementation

**Files:**
- Modify: `Treemux/Services/FileBrowser/FileBrowserDataSource.swift`
- Modify: `Treemux/Services/FileBrowser/LocalFileBrowserDataSource.swift`
- Test: `TreemuxTests/LocalFileBrowserDataSourceTests.swift`

**Interfaces:**
- Produces: `func searchNames(root: String, query: String, maxResults: Int) async throws -> [FileNode]` on the protocol, with a default returning `[]`. Local walks the FS recursively, case-insensitive substring on each entry's last path component, stopping at `maxResults`.

- [ ] **Step 1: Write the failing test**

Add to `TreemuxTests/LocalFileBrowserDataSourceTests.swift`:

```swift
func testSearchNamesFindsNestedMatches() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sub = root.appendingPathComponent("sub")
    try fm.createDirectory(at: sub, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try Data("x".utf8).write(to: root.appendingPathComponent("alpha.txt"))
    try Data("x".utf8).write(to: sub.appendingPathComponent("alphabet.md"))
    try Data("x".utf8).write(to: sub.appendingPathComponent("other.txt"))

    let source = LocalFileBrowserDataSource()
    let results = try await source.searchNames(root: root.path, query: "ALPHA", maxResults: 100)
    let names = Set(results.map(\.name))
    XCTAssertTrue(names.contains("alpha.txt"))
    XCTAssertTrue(names.contains("alphabet.md"))
    XCTAssertFalse(names.contains("other.txt"))
}

func testSearchNamesHonorsMaxResults() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    for i in 0..<10 { try Data("x".utf8).write(to: root.appendingPathComponent("match\(i).txt")) }
    let source = LocalFileBrowserDataSource()
    let results = try await source.searchNames(root: root.path, query: "match", maxResults: 3)
    XCTAssertEqual(results.count, 3)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/LocalFileBrowserDataSourceTests/testSearchNamesFindsNestedMatches test 2>&1 | tail -40`
Expected: FAIL to compile (`searchNames` not in protocol).

- [ ] **Step 3a: Add protocol method + default**

In `FileBrowserDataSource.swift`, add to the protocol:

```swift
    /// Recursively searches names under `root`, returning up to `maxResults`
    /// nodes whose name contains `query` (case-insensitive). Bounded — remote
    /// uses a single server-side `find`; local walks the FS off-thread.
    func searchNames(root: String, query: String, maxResults: Int) async throws -> [FileNode]
```

And a default in the extension:

```swift
    func searchNames(root: String, query: String, maxResults: Int) async throws -> [FileNode] {
        []
    }
```

- [ ] **Step 3b: Implement locally**

In `LocalFileBrowserDataSource.swift`:

```swift
    func searchNames(root: String, query: String, maxResults: Int) async throws -> [FileNode] {
        try await runOnQueue {
            let fm = FileManager.default
            let rootURL = URL(fileURLWithPath: root)
            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []) else { return [] }

            var results: [FileNode] = []
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                guard name.range(of: query, options: [.caseInsensitive]) != nil else { continue }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                results.append(FileNode(
                    id: url.path, name: name, path: url.path,
                    kind: isDir ? .directory : .file, sizeBytes: nil, modifiedAt: nil))
                if results.count >= maxResults { break }
            }
            return results
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/LocalFileBrowserDataSourceTests test 2>&1 | tail -40`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Treemux/Services/FileBrowser/FileBrowserDataSource.swift Treemux/Services/FileBrowser/LocalFileBrowserDataSource.swift TreemuxTests/LocalFileBrowserDataSourceTests.swift
git commit -m "feat(file-tree): searchNames on data source + local impl"
```

---

### Task 3: Remote recursive search (SFTPService + RemoteFileBrowserDataSource)

**Files:**
- Modify: `Treemux/Services/SFTP/SFTPService.swift`
- Modify: `Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift`
- Test: `TreemuxTests/SFTPServiceTests.swift`

**Interfaces:**
- Consumes: `parseFindResults`, `node(from:)`.
- Produces: `SFTPService.recursiveSearchCommand(root:query:maxDepth:maxResults:)` (pure), `SFTPService.parseFindResults(_:) -> [SFTPRichEntry]` (pure), `SFTPService.searchNames(root:query:maxDepth:maxResults:) async throws -> [SFTPRichEntry]` (`.ssh` → find; `.citadel` → throws `.commandFailed`). `RemoteFileBrowserDataSource.searchNames(...)` maps entries to `FileNode` via `node(from:)`.

- [ ] **Step 1: Write the failing test**

Add to `TreemuxTests/SFTPServiceTests.swift`:

```swift
func testParseFindResultsTypePrefixed() {
    let out = "f /home/u/alpha.txt\nd /home/u/sub/alphadir\n\nf /home/u/beta\n"
    let entries = SFTPService.parseFindResults(out)
    let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
    XCTAssertEqual(entries.count, 3)
    XCTAssertEqual(byName["alpha.txt"]?.path, "/home/u/alpha.txt")
    XCTAssertTrue(byName["alphadir"]!.isDirectory)
    XCTAssertFalse(byName["alpha.txt"]!.isDirectory)
}

func testRecursiveSearchCommandShapes() {
    let cmd = SFTPService.recursiveSearchCommand(
        root: "/home/u", query: "log", maxDepth: 12, maxResults: 500)
    XCTAssertTrue(cmd.contains("find '/home/u' -maxdepth 12 -iname '*log*'"))
    XCTAssertTrue(cmd.contains("head -n 500"))
}
```

(Adjust the expected `find …` prefix to match `shellEscape`'s real quoting after reading it.)

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/SFTPServiceTests/testParseFindResultsTypePrefixed test 2>&1 | tail -40`
Expected: FAIL to compile.

- [ ] **Step 3a: Add the command builder + parser + method to `SFTPService`**

```swift
    /// One-round-trip recursive name search. `find` matches the glob; the
    /// `-exec sh -c` classifies each hit as `d`/`f` portably (GNU + BSD), and
    /// `head` caps the result count (and stops `find` early via SIGPIPE).
    static func recursiveSearchCommand(root: String, query: String,
                                       maxDepth: Int, maxResults: Int) -> String {
        let escRoot = shellEscape(root)
        let glob = shellEscape("*\(query)*")
        return "find \(escRoot) -maxdepth \(maxDepth) -iname \(glob) 2>/dev/null "
            + "-exec sh -c 'for p; do if [ -d \"$p\" ]; then printf \"d %s\\n\" \"$p\"; "
            + "else printf \"f %s\\n\" \"$p\"; fi; done' _ {} + | head -n \(maxResults)"
    }

    /// Parses `d <path>` / `f <path>` lines from `recursiveSearchCommand`.
    static func parseFindResults(_ output: String) -> [SFTPRichEntry] {
        var out: [SFTPRichEntry] = []
        for line in output.components(separatedBy: "\n") {
            guard line.count > 2 else { continue }
            let typeChar = line.first!
            guard typeChar == "d" || typeChar == "f" else { continue }
            let path = String(line.dropFirst(2))
            guard !path.isEmpty else { continue }
            let name = (path as NSString).lastPathComponent
            out.append(SFTPRichEntry(
                name: name, path: path,
                kind: typeChar == "d" ? .directory : .file,
                sizeBytes: nil, modifiedAt: nil))
        }
        return out
    }

    func searchNames(root: String, query: String,
                     maxDepth: Int, maxResults: Int) async throws -> [SFTPRichEntry] {
        guard let mode else { throw SFTPServiceError.notConnected }
        switch mode {
        case .ssh(let target):
            let cmd = Self.recursiveSearchCommand(
                root: root, query: query, maxDepth: maxDepth, maxResults: maxResults)
            let result = try await runSSH(target: target, command: cmd, timeout: Self.listingCommandTimeout)
            // `head` closing the pipe yields exit 141 (SIGPIPE); treat any output
            // as success rather than gating on exitCode.
            return Self.parseFindResults(result.output)
        case .citadel:
            // No arbitrary exec on the Citadel password path.
            throw SFTPServiceError.commandFailed(
                "Recursive search requires key-based (system SSH) auth")
        }
    }
```

`shellEscape` is already `private static func shellEscape(_:)` in `SFTPService` (single-quote wrapping, merged via Feature 8) — call it directly. The methods here are inside `SFTPService`, so no visibility change is needed.

- [ ] **Step 3b: Forward from `RemoteFileBrowserDataSource`**

```swift
    func searchNames(root: String, query: String, maxResults: Int) async throws -> [FileNode] {
        try await ensureConnected()
        let entries = try await service.searchNames(
            root: root, query: query,
            maxDepth: FileBrowserTabController.searchMaxDepth, maxResults: maxResults)
        return entries.map(Self.node(from:))
    }
```

(If referencing `FileBrowserTabController.searchMaxDepth` here creates an awkward UI→service dependency, add a local `RemoteFileBrowserDataSource` constant `searchMaxDepth = 12` instead and use it. Prefer the local constant.)

- [ ] **Step 4: Run tests to verify they pass + build**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/SFTPServiceTests test 2>&1 | tail -40`
Expected: PASS. Then build: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug -skipPackagePluginValidation build 2>&1 | tail -20` → BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Treemux/Services/SFTP/SFTPService.swift Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift TreemuxTests/SFTPServiceTests.swift
git commit -m "feat(sftp): one-round-trip recursive name search (find)"
```

---

### Task 4: Controller search state + three-mode `visibleRows()`

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift`
- Modify: `TreemuxTests/FileBrowserTabControllerTests.swift` (extend `MockFileBrowserDataSource`)
- Test: `TreemuxTests/FileBrowserSearchTests.swift` (create)

**Interfaces:**
- Consumes: `FileTreeSearch.filter` (Task 1), `searchNames` (Tasks 2–3).
- Produces on `FileBrowserTabController`:
  - `var searchQuery: String` (bindable; changing it cancels the in-flight recursive search and returns to live-filter mode)
  - `private(set) var isSearching: Bool`, `private(set) var showingRecursiveResults: Bool`, `private(set) var searchResults: [FileNode]`, `private(set) var searchError: String?`
  - `static let searchMaxResults = 500`, `static let searchMaxDepth = 12`
  - `func performRecursiveSearch() async`, `func clearSearch()`, `func revealInTree(_ path: String) async`
  - `visibleRows()` gains live-filter and recursive-result modes.

- [ ] **Step 1a: Extend the mock**

In `MockFileBrowserDataSource` (in `FileBrowserTabControllerTests.swift`):

```swift
    var searchResultsToReturn: [FileNode] = []
    var searchError: Error?
    var searchCallCount = 0
    func searchNames(root: String, query: String, maxResults: Int) async throws -> [FileNode] {
        searchCallCount += 1
        if let searchError { throw searchError }
        return Array(searchResultsToReturn.prefix(maxResults))
    }
```

- [ ] **Step 1b: Write the failing tests**

Create `TreemuxTests/FileBrowserSearchTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/FileBrowserSearchTests test 2>&1 | tail -40`
Expected: FAIL to compile.

- [ ] **Step 3a: Add search state + methods to the controller**

Add constants near the other `static let` config:

```swift
    static let searchMaxResults = 500
    static let searchMaxDepth = 12
```

Add state (near `truncatedDirs`):

```swift
    /// Live search field text. Typing filters the loaded tree; changing it
    /// cancels any in-flight recursive search and returns to live-filter mode.
    var searchQuery: String = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            showingRecursiveResults = false
            searchResults = []
            searchError = nil
            searchTask?.cancel()
            searchTask = nil
            visibleRowsCache = nil
        }
    }
    private(set) var isSearching = false { didSet { visibleRowsCache = nil } }
    private(set) var showingRecursiveResults = false { didSet { visibleRowsCache = nil } }
    private(set) var searchResults: [FileNode] = [] { didSet { visibleRowsCache = nil } }
    private(set) var searchError: String?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// True when this tab browses a remote host (system-SSH or Citadel). Drives
    /// the local-vs-remote escalation-hint copy. `rootKind` (.project/.worktree)
    /// is orthogonal — both are local — so it MUST NOT be used for this.
    var isRemote: Bool { dataSource is RemoteFileBrowserDataSource }
```

Add methods (new `// MARK: - Search` section):

```swift
    /// Escalate to a bounded, cancellable recursive search (Enter).
    func performRecursiveSearch() async {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        searchTask?.cancel()
        isSearching = true
        searchError = nil
        searchResults = []
        showingRecursiveResults = true
        let ds = dataSource
        let root = rootPath
        let cap = Self.searchMaxResults
        let task = Task { [weak self] in
            do {
                let results = try await ds.searchNames(root: root, query: query, maxResults: cap)
                guard !Task.isCancelled else { return }
                self?.searchResults = results
            } catch {
                guard !Task.isCancelled else { return }
                self?.searchError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            if !Task.isCancelled { self?.isSearching = false }
        }
        searchTask = task
        await task.value
    }

    func clearSearch() {
        searchQuery = ""   // didSet resets the rest
    }

    /// Reveal a recursive-result path back in the tree: clear the search and
    /// expand every ancestor directory so the path becomes visible.
    func revealInTree(_ path: String) async {
        clearSearch()
        let rel = relativePath(path)
        guard rel != path else { return }   // not under root; nothing to expand
        var current = rootPath
        for component in rel.split(separator: "/").dropLast() {
            current += "/" + component
            if !expandedDirs.contains(current) {
                await toggleExpand(current)
            }
        }
    }
```

- [ ] **Step 3b: Add the two search modes to `visibleRows()`**

At the top of `visibleRows()`, add the new inputs to the "touch every input" block:

```swift
        _ = searchQuery
        _ = showingRecursiveResults
        _ = searchResults
```

After the cache-hit early return and the `#if DEBUG` counter, before the normal `emit(...)`, insert the two modes:

```swift
        var rows: [FileTreeRowModel] = []
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespaces)

        // Mode 3: flat recursive results.
        if showingRecursiveResults {
            for node in searchResults {
                rows.append(FileTreeRowModel(
                    id: "result:" + node.path,
                    kind: .node(node),
                    depth: 0,
                    isSelected: selectedFilePath == node.path,
                    isExpanded: false,
                    status: fileStatusByPath[node.path]))
            }
            visibleRowsCache = rows
            return rows
        }

        // Mode 2: live filter of the loaded tree.
        if !trimmedQuery.isEmpty {
            let (visible, expanded) = FileTreeSearch.filter(
                rootChildren: rootChildren, childrenByPath: childrenByPath, query: trimmedQuery)
            func emitFiltered(_ nodes: [FileNode], depth: Int) {
                for node in nodes where visible.contains(node.path) {
                    let isExp = node.isExpandableDirectory && expanded.contains(node.path)
                    rows.append(FileTreeRowModel(
                        id: node.path,
                        kind: .node(node),
                        depth: depth,
                        isSelected: selectedFilePath == node.path,
                        isExpanded: isExp,
                        status: fileStatusByPath[node.path]))
                    if isExp, let kids = childrenByPath[node.path] {
                        emitFiltered(kids, depth: depth + 1)
                    }
                }
            }
            emitFiltered(rootChildren, depth: 0)
            visibleRowsCache = rows
            return rows
        }

        // Mode 1: normal tree (existing code path below — the `emit(...)` closure).
```

Keep the existing normal-mode `emit(...)` code exactly as-is beneath this (it runs only when neither search mode returned). If Feature 8's editor-row injection is merged, its `emit` change stays in mode 1 only; searching and the new-entry editor are mutually exclusive UI states, which is acceptable. (`node.isExpandableDirectory` above requires Feature 10; use `node.isDirectory` if not merged.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/FileBrowserSearchTests test 2>&1 | tail -40`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift TreemuxTests/FileBrowserTabControllerTests.swift TreemuxTests/FileBrowserSearchTests.swift
git commit -m "feat(file-tree): search state + live-filter/recursive-result modes"
```

---

### Task 5: Search field UI, escalation hint, result routing, highlight, i18n

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileTreePanelView.swift`
- Modify: `Treemux/Localizable.xcstrings`
- Test: manual.

**Interfaces:**
- Consumes: `controller.searchQuery` (binding), `performRecursiveSearch()`, `clearSearch()`, `revealInTree(_:)`, `openInTree(_:)`, `isSearching`, `searchResults`, `searchError`, `rootKind`.

- [ ] **Step 1: Add the search field to `FileTreeToolbar`**

Bind a `TextField` to `controller.searchQuery`. Because `searchQuery` is on an `@Observable` controller, wrap the toolbar in `@Bindable var controller` or thread a binding. Add below the existing toolbar row (so it becomes a two-row toolbar), or inline. Minimal form:

```swift
        // In FileTreeToolbar, add @Bindable and a second row:
        @Bindable var c = controller
        // ...
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10)).foregroundStyle(theme.textMuted)
            TextField(LocalizedStringKey("Search"), text: $c.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($searchFocused)
                .onSubmit { Task { await controller.performRecursiveSearch() } }
            if !controller.searchQuery.isEmpty {
                Button { controller.clearSearch() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10)).foregroundStyle(theme.textMuted)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
```

Add `@FocusState private var searchFocused: Bool` to the toolbar view, and a Cmd+F handler at the panel level:

```swift
        // On FileTreePanelView's outer VStack:
        .onKeyPress(.init("f"), phases: .down) { press in
            if press.modifiers.contains(.command) { searchFocused = true; return .handled }
            return .ignored
        }
```

(If wiring `@FocusState` from the panel down into the toolbar is awkward, keep the field always focusable and bind `searchFocused` inside the toolbar; Cmd+F focus is a nicety — a plain always-visible field is acceptable if the focus plumbing is heavy.)

- [ ] **Step 2: Escalation hint + status line**

Below the field, when `searchQuery` is non-empty and not yet showing recursive results, show a hint whose copy depends on local vs remote:

```swift
        if !controller.searchQuery.isEmpty && !controller.showingRecursiveResults {
            Text(controller.isRemote
                 ? LocalizedStringKey("Press ⏎ to search the server")
                 : LocalizedStringKey("Press ⏎ to search all files"))
                .font(.system(size: 10)).foregroundStyle(theme.textMuted)
                .padding(.horizontal, 10).padding(.bottom, 2)
        }
        if controller.isSearching {
            Text(LocalizedStringKey("Searching…"))
                .font(.system(size: 10)).foregroundStyle(theme.textMuted)
                .padding(.horizontal, 10)
        } else if controller.showingRecursiveResults {
            Text(controller.searchResults.isEmpty
                 ? LocalizedStringKey("No matches")
                 : LocalizedStringKey("\(controller.searchResults.count) matches"))
                .font(.system(size: 10)).foregroundStyle(theme.textMuted)
                .padding(.horizontal, 10)
        }
        if let err = controller.searchError {
            Text(err).font(.system(size: 10)).foregroundStyle(theme.dangerColor)
                .padding(.horizontal, 10).lineLimit(2)
        }
```

`controller.isRemote` (added in Task 4) drives the local-vs-remote copy. Do NOT use `rootKind` — `FileBrowserRootKind` is only `.project`/`.worktree` (both local); remote-ness is `dataSource is RemoteFileBrowserDataSource`.

- [ ] **Step 3: Route clicks on recursive-result rows**

Result rows have ids prefixed `result:` but render as `.node`. The existing single-click gesture calls `toggleExpand`/`openInTree` by `node.isDirectory`. For a result row, a directory should reveal-in-tree and a file should open then clear search. Distinguish result rows via a flag on the row model OR via `showingRecursiveResults`. Simplest: in the row view's tap handler, branch on `controller.showingRecursiveResults`:

```swift
        TapGesture(count: 1).onEnded {
            if controller.showingRecursiveResults {
                if node.isExpandableDirectory {
                    Task { await controller.revealInTree(node.path) }
                } else {
                    Task { await controller.openInTree(node.path); controller.clearSearch() }
                }
            } else if node.isExpandableDirectory {
                Task { await controller.toggleExpand(node.path) }
            } else {
                Task { await controller.openInTree(node.path) }
            }
        }
```

- [ ] **Step 4: Highlight the matched span (live-filter mode)**

In the row's name rendering, when `!controller.searchQuery.isEmpty && !controller.showingRecursiveResults`, highlight the matched substring. Replace the `Text(node.name)` with an `AttributedString` that bolds/tints the matched range:

```swift
    private func nameText(_ name: String) -> Text {
        let query = controller.searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !controller.showingRecursiveResults,
              let range = name.range(of: query, options: [.caseInsensitive]) else {
            return Text(name)
        }
        var attr = AttributedString(name)
        if let lower = AttributedString.Index(range.lowerBound, within: attr),
           let upper = AttributedString.Index(range.upperBound, within: attr) {
            attr[lower..<upper].foregroundColor = theme.accentColor
            attr[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(attr)
    }
```

Use `nameText(node.name)` in place of `Text(node.name)` (keep the existing `.font`/`.lineLimit`/`.truncationMode` modifiers). (If the `AttributedString.Index` bridging proves fiddly, a simpler acceptable fallback is to tint the whole name of a matching node via `FileTreeSearch.matches`.)

- [ ] **Step 5: Add zh-Hans entries to `Localizable.xcstrings`**

| key | zh-Hans |
|---|---|
| `Search` | 搜索 |
| `Press ⏎ to search all files` | 按 ⏎ 搜索全部文件 |
| `Press ⏎ to search the server` | 按 ⏎ 在服务器上搜索 |
| `Searching…` | 搜索中… |
| `No matches` | 无匹配 |
| `%d matches` | %d 个匹配 |

- [ ] **Step 6: Build + manual verification**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug -skipPackagePluginValidation build 2>&1 | tail -20` → BUILD SUCCEEDED. Then run the app and verify:
- Typing filters the loaded tree live; ancestors auto-expand; matched span is highlighted; non-matches hidden.
- The escalation hint appears; pressing Enter runs recursive search and shows a flat result list with a match count.
- Clicking a file result opens it and clears the search; clicking a directory result reveals it in the tree.
- Editing the query returns to live-filter mode.
- Remote (system-SSH) recursive search returns results; a huge tree stays bounded (≤500) and does not hang.
- On a Citadel (password-auth) remote, typing still filters the loaded tree; Enter surfaces the "requires key-based auth" message rather than hanging.
- Clearing the field (× or empty) restores the normal tree.
- Interface is fully Chinese under zh-Hans locale.

- [ ] **Step 7: Commit**

```bash
git add Treemux/UI/FileBrowser/FileTreePanelView.swift Treemux/Localizable.xcstrings
git commit -m "feat(file-tree): search field, escalation, results, highlight, i18n"
```

---

### Task 6: Full regression

- [ ] **Step 1: Run the whole suite**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation test 2>&1 | tail -40`
Expected: all tests PASS (including existing `FileBrowserTabControllerTests`, `FileTreeRowModelTests` — verify the `visibleRows()` changes didn't regress normal-mode flattening or the memoization-count assertions in `FileBrowserTreeAccelerationTests`).

- [ ] **Step 2: Commit any fixups**

```bash
git add -A && git commit -m "test(file-tree): green after search feature" || echo "nothing to commit"
```

---

## Notes / Design Decisions (carry into review)

- **Escalating single field (Cyberduck model).** Type = live filter of the loaded tree (zero network); Enter = bounded recursive search. Chosen over an indexed fuzzy palette (needs the whole tree in memory — impossible for remote) and over auto-recurse-on-keystroke (universally avoided by SFTP browsers for round-trip cost). See the batch-A spec's research section.
- **Recursive results are flat.** A flat result list (Cyberduck/FileZilla style) avoids materializing deep hits back into the lazy tree. Clicking a file opens it; clicking a directory reveals it in the tree via `revealInTree`.
- **Return array, not streaming.** `searchNames` returns a bounded `[FileNode]` rather than a streaming callback — simpler and free of cross-thread data races on the collector. Bounded by `searchMaxResults` (500) and `searchMaxDepth` (12); remote `head` also stops `find` early via SIGPIPE. Incremental streaming is a possible future enhancement.
- **Cancellation.** Editing `searchQuery` cancels the in-flight `searchTask` (its result is dropped via `Task.isCancelled`) and returns to live-filter mode. Local FS walk is bounded by `maxResults` rather than fine-grained cancellation (the `runOnQueue` body is outside the Task's cancellation scope) — acceptable given the cap.
- **Citadel limitation.** Recursive (Enter) search needs arbitrary exec, unavailable on the Citadel password path; it surfaces a clear message. Live filter (typing) works on every backend.
- **Search vs new-entry (Feature 8).** Both use `visibleRows()`; they are mutually exclusive UI states (searching hides the new-entry editor row, which only renders in normal mode). Acceptable.
