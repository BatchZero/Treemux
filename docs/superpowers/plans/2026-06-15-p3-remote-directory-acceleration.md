# P3 — Remote Directory Acceleration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make remote (SSH/SFTP) file-browser trees open instantly from an on-disk cache, then refresh in the background, by adding bulk multi-level fetching, persistent caching, expand-time prefetch, and a per-directory entry cap with "load more".

**Architecture:** Keep the data sources stateless. Add a `listTree(root:maxDepth:entryCap:)` method to `FileBrowserDataSource` (default = sequential BFS via `listDirectory`, reused by Local + Citadel paths). The remote SSH path overrides it with a **single** `find … -exec ls -ld …` round-trip parsed by a new pure `parseRecursiveListing`. `FileBrowserTabController` orchestrates: render-from-disk-cache first → bulk `listTree` refresh → diff/apply without collapsing the user's expansion → persist snapshot to `~/.treemux[-debug]/directory-tree-cache/`. Expanding a folder prefetches its grandchildren in the background. Directories with more than the entry cap are truncated and surface a "Load more" row.

**Tech Stack:** Swift, async/await + actors (`SFTPService`), AppKit/SwiftUI, XCTest. `Crypto` (`Insecure.MD5`, already linked) for cache filenames. JSON `Codable` + atomic `Data.write` for persistence (mirrors `AppSettingsPersistence`).

**Decisions pinned at plan time (confirmed with 卡皮巴拉):**
- Scope: all five sub-features (cache, bulk fetch, background refresh+diff, prefetch-on-expand, entry-cap + load-more).
- `maxDepth` default = **2** (lists the root *and* every immediate subdirectory's contents in one bulk fetch).
- Cache freshness: **no TTL** — always render the disk cache instantly, then unconditionally background-refresh.
- Per-directory entry cap = **500** (constant `treeEntryCap`).
- Portable bulk command: `find . -mindepth 1 -maxdepth D \( -type d -o -type f -o -type l \) -exec ls -ldn --time-style=+%s {} +` with a BSD fallback to `ls -ldnT` (no GNU-only `-printf`). The Citadel password path (no arbitrary exec) uses the default **sequential** BFS; parallel-per-dir Citadel listing is intentionally out of scope (single SFTP channel serializes anyway; avoids channel-concurrency hazards).

---

## File Structure

**New files**
- `Treemux/Services/FileBrowser/DirectoryTreeFetch.swift` — `DirectoryTreeFetch` (in-memory bulk result) + `BFSTreeLister` (shared default-fetch helper).
- `Treemux/Domain/DirectoryTreeSnapshot.swift` — `DirectoryTreeSnapshot` (Codable on-disk shape).
- `Treemux/Persistence/DirectoryTreeCachePersistence.swift` — disk save/load keyed by `(identity, rootPath)`.
- `TreemuxTests/DirectoryTreeCacheTests.swift` — snapshot Codable + persistence round-trip.
- `TreemuxTests/BFSTreeListerTests.swift` — default `listTree` over a real temp tree.
- `TreemuxTests/SFTPRecursiveListingTests.swift` — `bulkListCommand` + `parseRecursiveListing`.
- `TreemuxTests/FileBrowserTreeAccelerationTests.swift` — controller cache/refresh/prefetch/load-more.

**Modified files**
- `Treemux/Domain/FileNode.swift` — add `Codable, Sendable`.
- `Treemux/Services/FileBrowser/FileBrowserDataSource.swift` — add `treeCacheIdentity` + `listTree` requirements with default impls.
- `Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift` — `node(from:)` helper, `treeCacheIdentity`, `listTree` override.
- `Treemux/Services/SFTP/SFTPService.swift` — `supportsBulkCommand`, `listTreeViaCommand`, static `bulkListCommand`, static `parseRecursiveListing`.
- `Treemux/UI/FileBrowser/FileBrowserTabController.swift` — cache-first `loadRoot`, `refreshTree`, `applyFetch`/`applySnapshot`/`persistTree`, `prefetchChildren`, `truncatedDirs`, `loadMore`, constants, `treeCache` injection.
- `Treemux/UI/FileBrowser/FileTreePanelView.swift` — "Load more" row.
- `Treemux/Localizable.xcstrings` — `"Load more"` → zh-Hans `"加载更多"`.
- `TreemuxTests/FileBrowserTabControllerTests.swift` (or wherever `MockFileBrowserDataSource` lives) — add settable `cacheIdentity`.

**Build/test commands** (run from the worktree root `/Users/yanu/Documents/code/Terminal/treemux/.worktrees/<this-branch>/`):

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux \
  -destination 'platform=macOS' -skipPackagePluginValidation test 2>&1 | tail -40
```

To run a single test class, append `-only-testing:TreemuxTests/<ClassName>`.

---

## Task 1: Make `FileNode` Codable + Sendable

**Files:**
- Modify: `Treemux/Domain/FileNode.swift:9-12`
- Test: `TreemuxTests/DirectoryTreeCacheTests.swift` (created here, extended in Task 4)

- [ ] **Step 1: Write the failing test**

Create `TreemuxTests/DirectoryTreeCacheTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild ... test -only-testing:TreemuxTests/DirectoryTreeCacheTests`
Expected: COMPILE FAILURE — `FileNode` does not conform to `Codable`/`Encodable`.

- [ ] **Step 3: Add the conformances**

In `Treemux/Domain/FileNode.swift`, change the struct and enum declarations:

```swift
struct FileNode: Identifiable, Equatable, Codable, Sendable {
    enum Kind: Equatable, Codable, Sendable {
        case directory
        case file
        case symlink(target: String?)
    }
```

(Leave the rest of the struct unchanged.)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild ... test -only-testing:TreemuxTests/DirectoryTreeCacheTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Treemux/Domain/FileNode.swift TreemuxTests/DirectoryTreeCacheTests.swift
git commit -m "feat(p3): make FileNode Codable + Sendable for tree cache"
```

---

## Task 2: `DirectoryTreeSnapshot` (Codable on-disk shape)

**Files:**
- Create: `Treemux/Domain/DirectoryTreeSnapshot.swift`
- Test: `TreemuxTests/DirectoryTreeCacheTests.swift` (extend)

- [ ] **Step 1: Write the failing test**

Append to `TreemuxTests/DirectoryTreeCacheTests.swift` inside the class:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild ... test -only-testing:TreemuxTests/DirectoryTreeCacheTests`
Expected: COMPILE FAILURE — `DirectoryTreeSnapshot` undefined.

- [ ] **Step 3: Create the model**

Create `Treemux/Domain/DirectoryTreeSnapshot.swift`:

```swift
//
//  DirectoryTreeSnapshot.swift
//  Treemux

import Foundation

/// The on-disk shape of a cached remote directory tree. Persisted per
/// `(cache identity, root path)` so a project reopens instantly from cache
/// before the live background refresh lands. `childrenByPath` stores the
/// **unfiltered** listing for each visited directory (including the root);
/// directories in `truncatedDirs` had their listing capped at fetch time.
struct DirectoryTreeSnapshot: Codable, Equatable, Sendable {
    var rootPath: String
    var childrenByPath: [String: [FileNode]]
    var truncatedDirs: [String]
    var fetchedAt: Date

    init(rootPath: String,
         childrenByPath: [String: [FileNode]],
         truncatedDirs: [String],
         fetchedAt: Date) {
        self.rootPath = rootPath
        self.childrenByPath = childrenByPath
        self.truncatedDirs = truncatedDirs
        self.fetchedAt = fetchedAt
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild ... test -only-testing:TreemuxTests/DirectoryTreeCacheTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Treemux/Domain/DirectoryTreeSnapshot.swift TreemuxTests/DirectoryTreeCacheTests.swift
git commit -m "feat(p3): add DirectoryTreeSnapshot codable model"
```

---

## Task 3: `DirectoryTreeCachePersistence` (disk save/load)

**Files:**
- Create: `Treemux/Persistence/DirectoryTreeCachePersistence.swift`
- Test: `TreemuxTests/DirectoryTreeCacheTests.swift` (extend)

Note: `treemuxStateDirectoryURL(fileManager:)` already exists in `Treemux/Persistence/AppSettingsPersistence.swift` — reuse it as the default base.

- [ ] **Step 1: Write the failing test**

Append to `TreemuxTests/DirectoryTreeCacheTests.swift` inside the class:

```swift
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
        // Different root path hashes to a different file → miss.
        XCTAssertNil(store.load(identity: "host:22:me", rootPath: "/other"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild ... test -only-testing:TreemuxTests/DirectoryTreeCacheTests`
Expected: COMPILE FAILURE — `DirectoryTreeCachePersistence` undefined.

- [ ] **Step 3: Create the persistence type**

Create `Treemux/Persistence/DirectoryTreeCachePersistence.swift`:

```swift
//
//  DirectoryTreeCachePersistence.swift
//  Treemux

import Foundation
import Crypto

/// Persists `DirectoryTreeSnapshot`s to `~/.treemux[-debug]/directory-tree-cache/`,
/// one JSON file per `(identity, rootPath)`. The filename is an MD5 of the key
/// so arbitrarily long/odd remote paths map to a safe, fixed-length name.
/// Mirrors `AppSettingsPersistence`'s atomic-write pattern.
struct DirectoryTreeCachePersistence {
    private let fileManager: FileManager
    private let baseDirectory: URL?

    init(fileManager: FileManager = .default, baseDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory
    }

    func save(_ snapshot: DirectoryTreeSnapshot, identity: String) throws {
        let dir = cacheDirectoryURL()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL(identity: identity, rootPath: snapshot.rootPath), options: .atomic)
    }

    func load(identity: String, rootPath: String) -> DirectoryTreeSnapshot? {
        let url = fileURL(identity: identity, rootPath: rootPath)
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(DirectoryTreeSnapshot.self, from: data),
              snap.rootPath == rootPath
        else { return nil }
        return snap
    }

    // MARK: - Paths

    private func cacheDirectoryURL() -> URL {
        let base = baseDirectory ?? treemuxStateDirectoryURL(fileManager: fileManager)
        return base.appendingPathComponent("directory-tree-cache", isDirectory: true)
    }

    private func fileURL(identity: String, rootPath: String) -> URL {
        let key = identity + "|" + rootPath
        let digest = Insecure.MD5.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDirectoryURL().appendingPathComponent(hex + ".json")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild ... test -only-testing:TreemuxTests/DirectoryTreeCacheTests`
Expected: PASS (all four cache tests).

- [ ] **Step 5: Commit**

```bash
git add Treemux/Persistence/DirectoryTreeCachePersistence.swift TreemuxTests/DirectoryTreeCacheTests.swift
git commit -m "feat(p3): add DirectoryTreeCachePersistence (disk save/load)"
```

---

## Task 4: `DirectoryTreeFetch` + `BFSTreeLister` + protocol `listTree`/`treeCacheIdentity`

**Files:**
- Create: `Treemux/Services/FileBrowser/DirectoryTreeFetch.swift`
- Modify: `Treemux/Services/FileBrowser/FileBrowserDataSource.swift:28-54`
- Test: `TreemuxTests/BFSTreeListerTests.swift`

- [ ] **Step 1: Write the failing test**

Create `TreemuxTests/BFSTreeListerTests.swift`. This drives the **default** `listTree` through the real `LocalFileBrowserDataSource` over a temp tree:

```swift
//
//  BFSTreeListerTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

final class BFSTreeListerTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("treemux-bfs-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: tmp.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: tmp.appendingPathComponent("root.txt"))
        try Data("y".utf8).write(to: tmp.appendingPathComponent("sub/mid.txt"))
        try Data("z".utf8).write(to: tmp.appendingPathComponent("sub/deep/leaf.txt"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_listTree_depth2_fetchesRootAndImmediateSubdirs_butNotDeeper() async throws {
        let source = LocalFileBrowserDataSource()
        let root = tmp.path
        let fetch = try await source.listTree(root, maxDepth: 2, entryCap: 500)

        // Root listing present.
        XCTAssertEqual(Set(fetch.childrenByPath[root]?.map(\.name) ?? []), ["root.txt", "sub"])
        // Immediate subdir listing present (depth 2 reached its children).
        XCTAssertEqual(Set(fetch.childrenByPath[root + "/sub"]?.map(\.name) ?? []), ["mid.txt", "deep"])
        // The grandchild dir was NOT listed (beyond depth 2).
        XCTAssertNil(fetch.childrenByPath[root + "/sub/deep"])
        XCTAssertTrue(fetch.truncatedDirs.isEmpty)
    }

    func test_listTree_entryCap_marksTruncated() async throws {
        let source = LocalFileBrowserDataSource()
        let fetch = try await source.listTree(tmp.path, maxDepth: 1, entryCap: 1)
        // Root has 2 entries (root.txt, sub) but cap is 1 → truncated.
        XCTAssertEqual(fetch.childrenByPath[tmp.path]?.count, 1)
        XCTAssertTrue(fetch.truncatedDirs.contains(tmp.path))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild ... test -only-testing:TreemuxTests/BFSTreeListerTests`
Expected: COMPILE FAILURE — `listTree` / `DirectoryTreeFetch` undefined.

- [ ] **Step 3: Create the fetch model + BFS helper**

Create `Treemux/Services/FileBrowser/DirectoryTreeFetch.swift`:

```swift
//
//  DirectoryTreeFetch.swift
//  Treemux

import Foundation

/// The in-memory result of a bulk multi-level directory fetch. `childrenByPath`
/// maps each visited directory path (including the root) to its immediate
/// children. Directories deeper than the fetch reached simply have no key.
/// `truncatedDirs` holds directories whose listing was capped at `entryCap`.
struct DirectoryTreeFetch: Equatable, Sendable {
    var childrenByPath: [String: [FileNode]]
    var truncatedDirs: Set<String>

    init(childrenByPath: [String: [FileNode]] = [:], truncatedDirs: Set<String> = []) {
        self.childrenByPath = childrenByPath
        self.truncatedDirs = truncatedDirs
    }
}

/// Default bulk-fetch strategy: breadth-first over `listDirectory`, one level at
/// a time, up to `maxDepth` levels of directory listings. Used by the local FS
/// source and the Citadel (password-auth) remote path. The system-SSH remote
/// path overrides this with a single `find` round-trip instead.
///
/// Listing is sequential by design: the Citadel SFTP path multiplexes one
/// channel (parallel requests serialize there anyway), and sequential keeps the
/// code free of `Sendable` plumbing around the non-Sendable data sources.
enum BFSTreeLister {
    static func list(using source: any FileBrowserDataSource,
                     root: String,
                     maxDepth: Int,
                     entryCap: Int) async throws -> DirectoryTreeFetch {
        var result: [String: [FileNode]] = [:]
        var truncated: Set<String> = []
        var frontier = [root]
        var depth = 0
        while !frontier.isEmpty && depth < maxDepth {
            var next: [String] = []
            for dir in frontier {
                let kids = try await source.listDirectory(dir)
                let capped: [FileNode]
                if kids.count > entryCap {
                    capped = Array(kids.prefix(entryCap))
                    truncated.insert(dir)
                } else {
                    capped = kids
                }
                result[dir] = capped
                for child in capped where child.isDirectory { next.append(child.path) }
            }
            frontier = next
            depth += 1
        }
        return DirectoryTreeFetch(childrenByPath: result, truncatedDirs: truncated)
    }
}
```

- [ ] **Step 4: Add the protocol requirements + defaults**

In `Treemux/Services/FileBrowser/FileBrowserDataSource.swift`, add two requirements to the protocol body (after `var supportsWrite: Bool { get }`):

```swift
    /// A stable identity for the on-disk directory-tree cache, or `nil` to
    /// disable caching for this source. Local sources return `nil` (the local
    /// FS is already fast); remote sources return a host/port/user-scoped key.
    var treeCacheIdentity: String? { get }

    /// Bulk-fetch multiple directory levels in as few round-trips as possible.
    /// Returns each visited directory's immediate children keyed by directory
    /// path (including `root`). Listings exceeding `entryCap` are truncated and
    /// the directory is added to `truncatedDirs`.
    func listTree(_ root: String, maxDepth: Int, entryCap: Int) async throws -> DirectoryTreeFetch
```

Then add default implementations in an extension at the bottom of the same file:

```swift
extension FileBrowserDataSource {
    var treeCacheIdentity: String? { nil }

    func listTree(_ root: String, maxDepth: Int, entryCap: Int) async throws -> DirectoryTreeFetch {
        try await BFSTreeLister.list(using: self, root: root, maxDepth: maxDepth, entryCap: entryCap)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild ... test -only-testing:TreemuxTests/BFSTreeListerTests`
Expected: PASS (both tests).

- [ ] **Step 6: Commit**

```bash
git add Treemux/Services/FileBrowser/DirectoryTreeFetch.swift \
        Treemux/Services/FileBrowser/FileBrowserDataSource.swift \
        TreemuxTests/BFSTreeListerTests.swift
git commit -m "feat(p3): add DirectoryTreeFetch + BFS listTree default"
```

---

## Task 5: SFTP `bulkListCommand` + `parseRecursiveListing` (pure, testable)

**Files:**
- Modify: `Treemux/Services/SFTP/SFTPService.swift` (add two static methods near the existing static `parseListing`)
- Test: `TreemuxTests/SFTPRecursiveListingTests.swift`

- [ ] **Step 1: Write the failing test**

Create `TreemuxTests/SFTPRecursiveListingTests.swift`:

```swift
//
//  SFTPRecursiveListingTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

final class SFTPRecursiveListingTests: XCTestCase {
    func test_bulkListCommand_hasMindepthMaxdepthAndBsdFallback() {
        let cmd = SFTPService.bulkListCommand(maxDepth: 2)
        XCTAssertTrue(cmd.contains("-mindepth 1"))
        XCTAssertTrue(cmd.contains("-maxdepth 2"))
        XCTAssertTrue(cmd.contains("--time-style=+%s"))   // GNU primary
        XCTAssertTrue(cmd.contains("ls -ldnT"))           // BSD fallback
        XCTAssertTrue(cmd.contains("||"))
    }

    func test_parseRecursive_GNU_nestedPaths_groupedByParent() {
        // `find . -exec ls -ldn --time-style=+%s {} +` style output, relative names.
        let output = """
        drwxr-xr-x 2 0 0 4096 1714000000 ./src
        -rw-r--r-- 1 0 0 12 1714000001 ./README.md
        -rw-r--r-- 1 0 0 34 1714000002 ./src/main.swift
        """
        let grouped = SFTPService.parseRecursiveListing(output: output, root: "/home/me/proj")

        XCTAssertEqual(grouped["/home/me/proj"]?.map(\.name), ["src", "README.md"]) // dirs first
        XCTAssertEqual(grouped["/home/me/proj/src"]?.map(\.name), ["main.swift"])

        let readme = grouped["/home/me/proj"]?.first(where: { $0.name == "README.md" })
        XCTAssertEqual(readme?.path, "/home/me/proj/README.md")
        XCTAssertEqual(readme?.sizeBytes, 12)
        XCTAssertEqual(readme?.modifiedAt, Date(timeIntervalSince1970: 1714000001))
        if case .file = readme?.kind {} else { XCTFail("expected file kind") }
    }

    func test_parseRecursive_symlink_capturesTarget() {
        let output = "lrwxr-xr-x 1 0 0 7 1714000000 ./link -> ../dest"
        let grouped = SFTPService.parseRecursiveListing(output: output, root: "/r")
        let link = grouped["/r"]?.first
        XCTAssertEqual(link?.name, "link")
        XCTAssertEqual(link?.path, "/r/link")
        if case .symlink(let target) = link?.kind {
            XCTAssertEqual(target, "../dest")
        } else {
            XCTFail("expected symlink kind")
        }
    }

    func test_parseRecursive_BSD_fourFieldDate() {
        // `ls -ldnT` BSD: month day time year as four tokens, then name.
        let output = "-rw-r--r-- 1 0 0 5 Apr 24 12:00:00 2024 ./a.txt"
        let grouped = SFTPService.parseRecursiveListing(output: output, root: "/r")
        XCTAssertEqual(grouped["/r"]?.first?.name, "a.txt")
        XCTAssertEqual(grouped["/r"]?.first?.path, "/r/a.txt")
        XCTAssertEqual(grouped["/r"]?.first?.sizeBytes, 5)
    }

    func test_parseRecursive_nameWithSpaces_GNU() {
        let output = "-rw-r--r-- 1 0 0 5 1714000000 ./my file.txt"
        let grouped = SFTPService.parseRecursiveListing(output: output, root: "/r")
        XCTAssertEqual(grouped["/r"]?.first?.name, "my file.txt")
        XCTAssertEqual(grouped["/r"]?.first?.path, "/r/my file.txt")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild ... test -only-testing:TreemuxTests/SFTPRecursiveListingTests`
Expected: COMPILE FAILURE — `bulkListCommand` / `parseRecursiveListing` undefined.

- [ ] **Step 3: Implement both static methods**

In `Treemux/Services/SFTP/SFTPService.swift`, add inside the `actor SFTPService { … }` body (place next to the existing static `parseListing`):

```swift
    /// Builds the portable bulk-listing command run on the system-SSH path.
    /// One `find` enumerates entries to `maxDepth`, then `ls -ld` stats each in
    /// a batched `-exec … +`. GNU `--time-style=+%s` is tried first; on BSD/macOS
    /// (which lacks it) the `||` fallback uses `ls -ldnT`. `-n` keeps owner/group
    /// numeric so they never introduce spaces that would break tokenization.
    /// The leading `cd <root>` is supplied by `runCommand(_:in:)`, so names come
    /// back relative (`./sub/file`).
    static func bulkListCommand(maxDepth: Int) -> String {
        let sel = "\\( -type d -o -type f -o -type l \\)"
        let gnu = "find . -mindepth 1 -maxdepth \(maxDepth) \(sel) -exec ls -ldn --time-style=+%s {} +"
        let bsd = "find . -mindepth 1 -maxdepth \(maxDepth) \(sel) -exec ls -ldnT {} +"
        return "\(gnu) 2>/dev/null || \(bsd)"
    }

    /// Parses the recursive `ls -ld` output produced by `bulkListCommand`.
    /// Names arrive as paths relative to `root` (`./a/b.txt`); each entry is
    /// reassembled into an absolute path and grouped under its parent directory.
    /// Each group is sorted directories-first, then case-insensitive by name —
    /// matching `RemoteFileBrowserDataSource.listDirectory`'s ordering.
    static func parseRecursiveListing(output: String, root: String) -> [String: [SFTPRichEntry]] {
        let normalizedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        var grouped: [String: [SFTPRichEntry]] = [:]

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("total ") { continue }

            let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 7 else { continue }

            let perms = tokens[0]
            guard let typeChar = perms.first else { continue }
            let baseKind: SFTPRichEntry.Kind
            switch typeChar {
            case "d": baseKind = .directory
            case "l": baseKind = .symlink(target: nil)
            default:  baseKind = .file
            }

            guard let size = Int64(tokens[4]) else { continue }

            let mtime: Date?
            let nameStartIdx: Int
            if let epoch = Int64(tokens[5]) {
                mtime = Date(timeIntervalSince1970: TimeInterval(epoch))
                nameStartIdx = 6
            } else if tokens.count >= 10 {
                let stamp = "\(tokens[5]) \(tokens[6]) \(tokens[7]) \(tokens[8])"
                let fmt = DateFormatter()
                fmt.locale = Locale(identifier: "en_US_POSIX")
                fmt.dateFormat = "MMM d HH:mm:ss yyyy"
                mtime = fmt.date(from: stamp)
                nameStartIdx = 9
            } else {
                continue
            }

            let rest = tokens[nameStartIdx...].joined(separator: " ")
            let (relName, linkTarget): (String, String?) = {
                if case .symlink = baseKind, let arrow = rest.range(of: " -> ") {
                    return (String(rest[..<arrow.lowerBound]), String(rest[arrow.upperBound...]))
                }
                return (rest, nil)
            }()

            // Strip the leading "./" find prints for relative names.
            var rel = relName
            if rel.hasPrefix("./") { rel.removeFirst(2) }
            if rel.isEmpty || rel == "." || rel == ".." { continue }

            let absolutePath = normalizedRoot + "/" + rel
            let name = (absolutePath as NSString).lastPathComponent
            let parent = (absolutePath as NSString).deletingLastPathComponent

            let kind: SFTPRichEntry.Kind = {
                if case .symlink = baseKind { return .symlink(target: linkTarget) }
                return baseKind
            }()

            grouped[parent, default: []].append(
                SFTPRichEntry(name: name, path: absolutePath, kind: kind, sizeBytes: size, modifiedAt: mtime)
            )
        }

        for (parent, entries) in grouped {
            grouped[parent] = entries.sorted { a, b in
                let aDir = a.isDirectory, bDir = b.isDirectory
                if aDir != bDir { return aDir }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
        return grouped
    }
```

Note: this uses `SFTPRichEntry.isDirectory`. If that computed property does not already exist, add it to `SFTPRichEntry` in `Treemux/Services/SFTP/SFTPDirectoryEntry.swift`:

```swift
    var isDirectory: Bool {
        if case .directory = kind { return true }
        return false
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild ... test -only-testing:TreemuxTests/SFTPRecursiveListingTests`
Expected: PASS (all five tests).

- [ ] **Step 5: Commit**

```bash
git add Treemux/Services/SFTP/SFTPService.swift Treemux/Services/SFTP/SFTPDirectoryEntry.swift \
        TreemuxTests/SFTPRecursiveListingTests.swift
git commit -m "feat(p3): add portable bulk-list command + recursive ls parser"
```

---

## Task 6: SFTP `supportsBulkCommand` + `listTreeViaCommand`

**Files:**
- Modify: `Treemux/Services/SFTP/SFTPService.swift`
- Test: build-only (the SSH process path can't be unit-tested without a server; the pure parser/command are covered by Task 5; the actor wiring below is verified by build + the integration in Task 11).

- [ ] **Step 1: Add the actor methods**

In `Treemux/Services/SFTP/SFTPService.swift`, add to the `actor SFTPService { … }` body (near `runCommand`):

```swift
    /// Whether the active connection can run arbitrary shell commands (system-SSH
    /// path). Citadel password-auth cannot, so callers fall back to per-dir BFS.
    var supportsBulkCommand: Bool {
        if case .ssh = mode { return true }
        return false
    }

    /// Bulk-fetch a directory tree in one SSH round-trip. Only valid on the
    /// system-SSH path (`supportsBulkCommand == true`). Returns each directory's
    /// children keyed by parent path, plus the set of directories whose listing
    /// was capped at `entryCap`.
    func listTreeViaCommand(root: String, maxDepth: Int, entryCap: Int)
        async throws -> (childrenByPath: [String: [SFTPRichEntry]], truncated: Set<String>) {
        let output = try await runCommand(Self.bulkListCommand(maxDepth: maxDepth), in: root)
        var grouped = Self.parseRecursiveListing(output: output, root: root)
        var truncated: Set<String> = []
        for (dir, entries) in grouped where entries.count > entryCap {
            grouped[dir] = Array(entries.prefix(entryCap))
            truncated.insert(dir)
        }
        return (grouped, truncated)
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Treemux/Services/SFTP/SFTPService.swift
git commit -m "feat(p3): add SFTPService.listTreeViaCommand (bulk SSH fetch)"
```

---

## Task 7: `RemoteFileBrowserDataSource` — `node(from:)`, `treeCacheIdentity`, `listTree` override

**Files:**
- Modify: `Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift`
- Test: build-only (live SSH path); `treeCacheIdentity` string format is asserted in Task 11's controller tests via a mock, and the SSH branch is covered by Task 5's pure tests.

- [ ] **Step 1: Extract the entry→node mapping**

In `RemoteFileBrowserDataSource.swift`, add a static helper and refactor `listDirectory` to use it. Replace the existing `.map { entry in … }` closure body in `listDirectory` with `.map(Self.node(from:))`, and add:

```swift
    /// Maps an SFTP rich entry to a file-tree node. Shared by `listDirectory`
    /// and the bulk `listTree` path so both produce identical node shapes.
    static func node(from entry: SFTPRichEntry) -> FileNode {
        let kind: FileNode.Kind
        switch entry.kind {
        case .directory: kind = .directory
        case .file: kind = .file
        case .symlink(let target): kind = .symlink(target: target)
        }
        return FileNode(id: entry.path, name: entry.name, path: entry.path,
                        kind: kind, sizeBytes: entry.sizeBytes, modifiedAt: entry.modifiedAt)
    }
```

After refactor, `listDirectory` ends with:

```swift
        let rich = try await service.listAllEntries(at: path)
        return rich.map(Self.node(from:)).sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
```

- [ ] **Step 2: Add `treeCacheIdentity` and `listTree`**

Add to the `RemoteFileBrowserDataSource` body:

```swift
    /// Host/port/user-scoped cache identity. Stable across sessions so a project
    /// reopens from the same on-disk cache file.
    var treeCacheIdentity: String? {
        "\(sshTarget.host):\(sshTarget.port):\(sshTarget.user ?? NSUserName())"
    }

    func listTree(_ root: String, maxDepth: Int, entryCap: Int) async throws -> DirectoryTreeFetch {
        try await ensureConnected()
        if await service.supportsBulkCommand {
            let (grouped, truncated) = try await service.listTreeViaCommand(
                root: root, maxDepth: maxDepth, entryCap: entryCap)
            var byPath: [String: [FileNode]] = [:]
            for (dir, entries) in grouped {
                byPath[dir] = entries.map(Self.node(from:))
            }
            return DirectoryTreeFetch(childrenByPath: byPath, truncatedDirs: truncated)
        }
        // Citadel password path: no arbitrary exec → sequential per-dir BFS.
        return try await BFSTreeLister.list(using: self, root: root, maxDepth: maxDepth, entryCap: entryCap)
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild ... build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift
git commit -m "feat(p3): RemoteFileBrowserDataSource bulk listTree + cache identity"
```

---

## Task 8: Controller — cache-first `loadRoot` + `refreshTree` + persist

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift:53-88` (config + init), `:166-187` (`loadRoot`)
- Modify: `TreemuxTests/FileBrowserTabControllerTests.swift` — add `cacheIdentity` to `MockFileBrowserDataSource`
- Test: `TreemuxTests/FileBrowserTreeAccelerationTests.swift`

- [ ] **Step 1: Add a settable cache identity to the mock**

In the file defining `MockFileBrowserDataSource` (`TreemuxTests/FileBrowserTabControllerTests.swift`), add a stored property and the protocol override:

```swift
    var cacheIdentity: String? = nil
    var treeCacheIdentity: String? { cacheIdentity }
```

(The mock inherits `listTree` from the protocol default — sequential BFS over `directoryListings` — so no extra mock wiring is needed.)

- [ ] **Step 2: Write the failing test**

Create `TreemuxTests/FileBrowserTreeAccelerationTests.swift`:

```swift
//
//  FileBrowserTreeAccelerationTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

@MainActor
final class FileBrowserTreeAccelerationTests: XCTestCase {
    private func tempCacheDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("treemux-accel-\(UUID().uuidString)")
    }

    func test_loadRoot_rendersDiskCacheWhenRefreshFails() async throws {
        let dir = tempCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DirectoryTreeCachePersistence(baseDirectory: dir)
        // Pre-seed the cache for identity "h:22:me", root "/r".
        let cachedNode = FileNode(id: "/r/cached.txt", name: "cached.txt", path: "/r/cached.txt",
                                  kind: .file, sizeBytes: 1, modifiedAt: nil)
        try store.save(DirectoryTreeSnapshot(rootPath: "/r",
                                             childrenByPath: ["/r": [cachedNode]],
                                             truncatedDirs: [],
                                             fetchedAt: Date()), identity: "h:22:me")

        let mock = MockFileBrowserDataSource()
        mock.cacheIdentity = "h:22:me"
        mock.listError = FileBrowserError.notFound("/r")   // refresh fails → cache must remain

        let ctrl = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/r", rootKind: .project),
            dataSource: mock,
            treeCache: store
        )
        await ctrl.loadRoot()
        XCTAssertEqual(ctrl.rootChildren.map(\.name), ["cached.txt"])
    }

    func test_refresh_persistsSnapshotToDisk() async throws {
        let dir = tempCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DirectoryTreeCachePersistence(baseDirectory: dir)

        let mock = MockFileBrowserDataSource()
        mock.cacheIdentity = "h:22:me"
        mock.directoryListings["/r"] = [
            FileNode(id: "/r/live.txt", name: "live.txt", path: "/r/live.txt", kind: .file, sizeBytes: 2, modifiedAt: nil)
        ]
        let ctrl = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/r", rootKind: .project),
            dataSource: mock,
            treeCache: store
        )
        await ctrl.loadRoot()
        XCTAssertEqual(ctrl.rootChildren.map(\.name), ["live.txt"])

        // The refresh should have written a snapshot we can read back.
        let snap = store.load(identity: "h:22:me", rootPath: "/r")
        XCTAssertEqual(snap?.childrenByPath["/r"]?.map(\.name), ["live.txt"])
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild ... test -only-testing:TreemuxTests/FileBrowserTreeAccelerationTests`
Expected: COMPILE FAILURE — `FileBrowserTabController.init` has no `treeCache:` parameter.

- [ ] **Step 4: Add config, injection, and rewrite `loadRoot`**

In `FileBrowserTabController.swift`, add constants alongside the existing ones (`:54-56`):

```swift
    static let treeFetchDepth: Int = 2
    static let treeEntryCap: Int = 500
```

Add a stored property near `dataSource` (`:58`):

```swift
    let treeCache: DirectoryTreeCachePersistence
    @Published private(set) var truncatedDirs: Set<String> = []
```

Add a `treeCache` parameter to `init` (default a real store) and assign it:

```swift
    init(
        initial state: FileBrowserTabState,
        dataSource: any FileBrowserDataSource,
        gitDiffService: GitDiffService? = nil,
        repoRoot: String? = nil,
        treeCache: DirectoryTreeCachePersistence = DirectoryTreeCachePersistence()
    ) {
        // ... existing assignments ...
        self.treeCache = treeCache
        // ... rest unchanged ...
    }
```

Replace the body of `loadRoot()` (`:166-187`) with:

```swift
    func loadRoot() async {
        loadError = nil
        // 1. Instant render from the on-disk cache if present.
        if let identity = dataSource.treeCacheIdentity,
           let snap = treeCache.load(identity: identity, rootPath: rootPath) {
            applySnapshot(snap)
        }
        // 2. Background-refresh via bulk fetch (also the only fetch path on a cache miss).
        await refreshTree()
    }

    /// Bulk-fetch the tree, diff/apply it onto the live state without collapsing
    /// the user's expansion, restore any expanded dirs deeper than the fetch
    /// reached, then persist the snapshot. Refresh errors are swallowed when a
    /// cache is already on screen.
    func refreshTree() async {
        do {
            let fetch = try await dataSource.listTree(
                rootPath, maxDepth: Self.treeFetchDepth, entryCap: Self.treeEntryCap)
            applyFetch(fetch)
            for path in expandedDirs where path != rootPath && childrenByPath[path] == nil {
                if let kids = try? await dataSource.listDirectory(path) {
                    rawChildrenByPath[path] = kids
                    childrenByPath[path] = filtered(kids)
                }
            }
            persistTree()
            await refreshGitStatus()
        } catch {
            if rootChildren.isEmpty { loadError = mapError(error) }
        }
    }

    private func applySnapshot(_ snap: DirectoryTreeSnapshot) {
        for (path, kids) in snap.childrenByPath {
            rawChildrenByPath[path] = kids
            childrenByPath[path] = filtered(kids)
        }
        truncatedDirs = Set(snap.truncatedDirs)
        rootChildren = childrenByPath[rootPath] ?? []
    }

    /// Applies a fresh bulk fetch, only re-binding directories whose contents
    /// actually changed (cheap `Equatable` compare) so SwiftUI churn stays low.
    /// `expandedDirs` is left untouched, so the tree keeps its open state.
    private func applyFetch(_ fetch: DirectoryTreeFetch) {
        for (path, kids) in fetch.childrenByPath where rawChildrenByPath[path] != kids {
            rawChildrenByPath[path] = kids
            childrenByPath[path] = filtered(kids)
        }
        truncatedDirs = fetch.truncatedDirs
        rootChildren = childrenByPath[rootPath] ?? []
    }

    private func persistTree() {
        guard let identity = dataSource.treeCacheIdentity else { return }
        let snap = DirectoryTreeSnapshot(
            rootPath: rootPath,
            childrenByPath: rawChildrenByPath,
            truncatedDirs: Array(truncatedDirs),
            fetchedAt: Date()
        )
        try? treeCache.save(snap, identity: identity)
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild ... test -only-testing:TreemuxTests/FileBrowserTreeAccelerationTests`
Expected: PASS (both tests).

Also re-run the existing controller suite to confirm no regression (the BFS-backed `loadRoot` must still satisfy the old tests):

Run: `xcodebuild ... test -only-testing:TreemuxTests/FileBrowserTabControllerTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift TreemuxTests/
git commit -m "feat(p3): cache-first loadRoot + bulk refresh + persist in controller"
```

---

## Task 9: Controller — prefetch grandchildren on expand

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift:189-208` (`toggleExpand`)
- Test: `TreemuxTests/FileBrowserTreeAccelerationTests.swift` (extend)

- [ ] **Step 1: Write the failing test**

Append to `FileBrowserTreeAccelerationTests`:

```swift
    func test_prefetchChildren_populatesGrandchildren() async {
        let mock = MockFileBrowserDataSource()
        mock.directoryListings["/r"] = [
            FileNode(id: "/r/sub", name: "sub", path: "/r/sub", kind: .directory, sizeBytes: nil, modifiedAt: nil)
        ]
        mock.directoryListings["/r/sub"] = [
            FileNode(id: "/r/sub/inner", name: "inner", path: "/r/sub/inner", kind: .directory, sizeBytes: nil, modifiedAt: nil)
        ]
        mock.directoryListings["/r/sub/inner"] = [
            FileNode(id: "/r/sub/inner/leaf.txt", name: "leaf.txt", path: "/r/sub/inner/leaf.txt", kind: .file, sizeBytes: 1, modifiedAt: nil)
        ]
        let ctrl = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/r", rootKind: .project),
            dataSource: mock)
        await ctrl.loadRoot()

        // Expanding /r/sub should prefetch /r/sub/inner's children (grandchildren).
        await ctrl.toggleExpand("/r/sub")
        await ctrl.prefetchChildren(of: "/r/sub")
        XCTAssertEqual(ctrl.childrenByPath["/r/sub/inner"]?.map(\.name), ["leaf.txt"])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild ... test -only-testing:TreemuxTests/FileBrowserTreeAccelerationTests`
Expected: COMPILE FAILURE — `prefetchChildren(of:)` undefined.

- [ ] **Step 3: Implement prefetch + hook into `toggleExpand`**

Add to `FileBrowserTabController`:

```swift
    /// Background-prefetch a directory's grandchildren so expanding its children
    /// is instant. Internal (not private) so it is unit-testable directly.
    func prefetchChildren(of path: String) async {
        guard let fetch = try? await dataSource.listTree(
            path, maxDepth: Self.treeFetchDepth, entryCap: Self.treeEntryCap) else { return }
        for (p, kids) in fetch.childrenByPath where rawChildrenByPath[p] != kids {
            rawChildrenByPath[p] = kids
            childrenByPath[p] = filtered(kids)
        }
        truncatedDirs.formUnion(fetch.truncatedDirs)
    }
```

In `toggleExpand`, after `expandedDirs.insert(path)` in the success branch, add a fire-and-forget prefetch:

```swift
                expandedDirs.insert(path)
                Task { [weak self] in await self?.prefetchChildren(of: path) }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild ... test -only-testing:TreemuxTests/FileBrowserTreeAccelerationTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift TreemuxTests/FileBrowserTreeAccelerationTests.swift
git commit -m "feat(p3): prefetch grandchildren on folder expand"
```

---

## Task 10: Controller — `loadMore` for truncated directories

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift`
- Test: `TreemuxTests/FileBrowserTreeAccelerationTests.swift` (extend)

- [ ] **Step 1: Write the failing test**

Append to `FileBrowserTreeAccelerationTests`:

```swift
    func test_loadMore_fetchesFullListingAndClearsTruncation() async {
        let mock = MockFileBrowserDataSource()
        // 3 entries at root; cap is 500 normally, but simulate a pre-truncated
        // state by seeding the controller through a small-cap snapshot path.
        mock.directoryListings["/r"] = (0..<3).map {
            FileNode(id: "/r/f\($0)", name: "f\($0)", path: "/r/f\($0)", kind: .file, sizeBytes: 1, modifiedAt: nil)
        }
        let ctrl = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/r", rootKind: .project),
            dataSource: mock)
        await ctrl.loadRoot()
        // Force a truncated marker, then verify loadMore clears it and lists fully.
        ctrl.markTruncatedForTesting("/r")
        XCTAssertTrue(ctrl.truncatedDirs.contains("/r"))

        await ctrl.loadMore("/r")
        XCTAssertFalse(ctrl.truncatedDirs.contains("/r"))
        XCTAssertEqual(ctrl.childrenByPath["/r"]?.count, 3)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild ... test -only-testing:TreemuxTests/FileBrowserTreeAccelerationTests`
Expected: COMPILE FAILURE — `markTruncatedForTesting` / `loadMore` undefined.

- [ ] **Step 3: Implement `loadMore` (+ a tiny test seam)**

Add to `FileBrowserTabController`:

```swift
    /// Re-fetches a truncated directory's **full** (uncapped) listing via the
    /// normal per-directory call and clears its truncation marker. Backs the
    /// file-tree "Load more" row.
    func loadMore(_ path: String) async {
        do {
            let kids = try await dataSource.listDirectory(path)
            rawChildrenByPath[path] = kids
            childrenByPath[path] = filtered(kids)
            truncatedDirs.remove(path)
            if path == rootPath { rootChildren = childrenByPath[path] ?? [] }
        } catch {
            loadError = mapError(error)
        }
    }

    #if DEBUG
    /// Test seam: lets unit tests drive the truncated-directory UI path without
    /// constructing a 500+ entry directory.
    func markTruncatedForTesting(_ path: String) { truncatedDirs.insert(path) }
    #endif
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild ... test -only-testing:TreemuxTests/FileBrowserTreeAccelerationTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift TreemuxTests/FileBrowserTreeAccelerationTests.swift
git commit -m "feat(p3): add loadMore for truncated directories"
```

---

## Task 11: UI — "Load more" row in the file tree

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileTreePanelView.swift` (the `NodeRow` children block, ~lines 130-145, and the root list)
- Test: build + manual (SwiftUI views are not unit-tested in this project).

- [ ] **Step 1: Add a load-more row under truncated, expanded directories**

In `NodeRow.body`, the children block currently reads:

```swift
            if isExpanded, let kids = children {
                ForEach(kids, id: \.id) { child in
                    NodeRow(node: child, depth: depth + 1, density: density, controller: controller)
                }
            }
```

Replace it with:

```swift
            if isExpanded, let kids = children {
                ForEach(kids, id: \.id) { child in
                    NodeRow(node: child, depth: depth + 1, density: density, controller: controller)
                }
                if controller.truncatedDirs.contains(node.path) {
                    LoadMoreRow(path: node.path, depth: depth + 1, controller: controller)
                }
            }
```

Add the `LoadMoreRow` view at file scope (next to `NodeRow`):

```swift
private struct LoadMoreRow: View {
    let path: String
    let depth: Int
    @ObservedObject var controller: FileBrowserTabController

    var body: some View {
        Button {
            Task { await controller.loadMore(path) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis.circle")
                Text(LocalizedStringKey("Load more"))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.leading, CGFloat(depth) * 14 + 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}
```

(Use whatever per-depth indent constant the surrounding `NodeRow` already uses; `14` is a placeholder — match the existing indent math in `FileTreePanelView`. Confirm the constant when editing.)

- [ ] **Step 2: Point the manual refresh button at the bulk path**

The toolbar refresh (in `FileTreeToolbar`, ~`FileTreePanelView.swift:39`) currently runs the single-directory `refresh` + a separate git refresh:

```swift
            Button {
                Task {
                    await controller.refresh(controller.rootPath)
                    await controller.refreshGitStatus()
                }
            } label: {
```

Change it to force a full bulk re-fetch + cache update (spec §4.5). `refreshTree()` already calls `refreshGitStatus()` internally:

```swift
            Button {
                Task { await controller.refreshTree() }
            } label: {
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild ... build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Treemux/UI/FileBrowser/FileTreePanelView.swift
git commit -m "feat(p3): Load more row + route manual refresh through bulk fetch"
```

---

## Task 12: i18n — `"Load more"` zh-Hans entry

**Files:**
- Modify: `Treemux/Localizable.xcstrings`

- [ ] **Step 1: Add the string entry**

Add a `"Load more"` key to `Treemux/Localizable.xcstrings` with a `zh-Hans` translation. The JSON shape for one entry (insert into the top-level `"strings"` object, keeping keys sorted as Xcode does):

```json
    "Load more" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "加载更多"
          }
        }
      }
    },
```

Preferred: open the project in Xcode, select `Localizable.xcstrings`, find the auto-extracted `"Load more"` key, and type `加载更多` in the zh-Hans column. Either approach is fine as long as the build sees the entry.

- [ ] **Step 2: Build to verify the catalog still parses**

Run: `xcodebuild ... build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED (no xcstrings parse error).

- [ ] **Step 3: Commit**

```bash
git add Treemux/Localizable.xcstrings
git commit -m "i18n(p3): add zh-Hans translation for Load more"
```

---

## Task 13: Full suite + manual validation

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

Run:
```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux \
  -destination 'platform=macOS' -skipPackagePluginValidation test 2>&1 | tail -40
```
Expected: all tests pass (previous count + the new P3 tests). Record the pass count.

- [ ] **Step 2: Build the Debug app and report the run command**

Run:
```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux \
  -destination 'platform=macOS' -skipPackagePluginValidation build 2>&1 | tail -20
```
Then determine the exact DerivedData id and tell 卡皮巴拉 to run:
```bash
rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<id>/Build/Products/Debug/Treemux.app
```

- [ ] **Step 3: Manual validation checklist (卡皮巴拉)**

Against a real remote (system-SSH) project:
1. First open: tree appears (may take one round-trip); reopen the same project → tree renders **instantly** from cache, then updates.
2. Expand a folder → its children appear instantly if within depth/prefetch; deeper folders still load on demand.
3. Create/delete a file remotely, then trigger the manual Refresh (or reopen) → the change appears without collapsing other expanded folders.
4. A directory with >500 entries shows a **Load more** row; tapping it lists the rest.
5. Citadel (password-auth) project still lists correctly (sequential BFS fallback).

- [ ] **Step 4: Final commit (if any cleanup) and prepare FF-merge**

The branch is ready to fast-forward merge back into `docs/file-browser-overhaul` once manual validation passes.

---

## Notes / landmines carried from the spec

- **Portable bulk command**: no GNU-only `find -printf`. `find … -exec ls -ldn {} +` is POSIX; only the time-format flag differs (GNU `--time-style=+%s` vs BSD `-ldnT`), handled by the `||` fallback. `-n` keeps owner/group numeric so filenames-with-spaces tokenize correctly.
- **Symlink loops / permission-denied subtrees**: `find -maxdepth 2` bounds depth (no infinite symlink recursion at this depth), and `2>/dev/null` drops permission-denied stderr noise; denied subtrees simply yield no children (lazy expand still attempts them later).
- **Citadel path**: no arbitrary exec → sequential BFS. Parallel-per-dir was considered and deferred (single SFTP channel serializes; avoids channel-concurrency hazards). Cache + prefetch still benefit this path.
- **Stale cache after external change**: no remote FSEvents; the unconditional background refresh after every cache render covers it.
- **No TTL**: cache is always rendered then refreshed (per 卡皮巴拉's decision).
```