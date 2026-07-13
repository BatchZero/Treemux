# Feature 10 — Symlink-Directory Reading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a symlink that points at a directory behave like a directory in the file tree — show a disclosure triangle and expand to list the target's contents — on both local and remote (system-SSH) workspaces.

**Architecture:** Add a derived `symlinkTargetIsDirectory` flag to `FileNode` (and the SFTP entry type). Data sources populate it: local via a target `stat`, remote via a one-round-trip `[ -d ]` probe folded into the existing listing command. The tree UI keys disclosure/expand on a new `isExpandableDirectory` computed property instead of `isDirectory`. Eager prefetch already never follows symlinks, so no cycle machinery is needed.

**Tech Stack:** Swift, SwiftUI, XCTest, Xcode project (`Treemux.xcodeproj`), macOS.

## Global Constraints

- **Worktree rule:** All code changes happen in a git worktree, never on `main` in the main checkout. Create it at execution start: `git worktree add -b feat/feature-10-symlink-dirs .worktrees/feat+feature-10-symlink-dirs main`. The main checkout stays on `main`.
- **Comments in English; UI copy via `LocalizedStringKey` with a synced `zh-Hans` entry in `Treemux/Localizable.xcstrings`.** This feature adds no new user-visible strings (icons/behavior only), so no xcstrings change is expected — verify at the end.
- **No hardcoded colors** — all colors go through theme tokens. Not applicable here (no new colored UI).
- **Unit test command** (single test):
  `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/<Class>/<method> test 2>&1 | tail -40`
- **Full test run:**
  `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation test 2>&1 | tail -40`
- **Build:**
  `xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug -skipPackagePluginValidation build 2>&1 | tail -20`
- Commit after each task.

## File Structure

- `Treemux/Domain/FileNode.swift` — add `symlinkTargetIsDirectory`, `isSymlink`, `isExpandableDirectory`; robust Codable for the new key.
- `Treemux/Services/SFTP/SFTPDirectoryEntry.swift` — add `symlinkTargetIsDirectory` to `SFTPRichEntry`.
- `Treemux/Services/FileBrowser/LocalFileBrowserDataSource.swift` — resolve local symlink target type in `makeNode`.
- `Treemux/Services/SFTP/SFTPService.swift` — parse a symlink-dir set and populate the flag in `parseListing` / `parseRecursiveListing`; append a `[ -d ]` probe to `listAllEntriesViaSSH` and `bulkListCommand`.
- `Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift` — map `symlinkTargetIsDirectory` through `node(from:)`.
- `Treemux/UI/FileBrowser/FileBrowserTabController.swift` — use `isExpandableDirectory` for the `expanded` decision in `visibleRows()`.
- `Treemux/UI/FileBrowser/FileTreePanelView.swift` — use `isExpandableDirectory` for disclosure triangle + click/double-click routing.
- Tests: `TreemuxTests/FileNodeSymlinkTests.swift` (new), plus additions to `LocalFileBrowserDataSourceTests.swift`, `SFTPServiceTests.swift`, `FileBrowserTabControllerTests.swift`.

---

### Task 1: `FileNode` gains the symlink-directory flag

**Files:**
- Modify: `Treemux/Domain/FileNode.swift`
- Test: `TreemuxTests/FileNodeSymlinkTests.swift` (create)

**Interfaces:**
- Produces: `FileNode.symlinkTargetIsDirectory: Bool` (stored, default `false`), `FileNode.isSymlink: Bool`, `FileNode.isExpandableDirectory: Bool`. Memberwise init keeps a default for the new field so existing constructions compile. Codable decodes the new key with `decodeIfPresent` so older cached snapshots still load.

- [ ] **Step 1: Write the failing test**

Create `TreemuxTests/FileNodeSymlinkTests.swift`:

```swift
import XCTest
@testable import Treemux

final class FileNodeSymlinkTests: XCTestCase {
    private func node(_ kind: FileNode.Kind, targetDir: Bool = false) -> FileNode {
        FileNode(id: "/p", name: "p", path: "/p", kind: kind,
                 sizeBytes: nil, modifiedAt: nil, symlinkTargetIsDirectory: targetDir)
    }

    func testRealDirectoryIsExpandable() {
        XCTAssertTrue(node(.directory).isExpandableDirectory)
    }

    func testFileIsNotExpandable() {
        XCTAssertFalse(node(.file).isExpandableDirectory)
    }

    func testSymlinkToDirectoryIsExpandable() {
        XCTAssertTrue(node(.symlink(target: "/t"), targetDir: true).isExpandableDirectory)
    }

    func testSymlinkToFileIsNotExpandable() {
        XCTAssertFalse(node(.symlink(target: "/t"), targetDir: false).isExpandableDirectory)
    }

    func testDefaultFlagIsFalse() {
        let n = FileNode(id: "/p", name: "p", path: "/p", kind: .symlink(target: "/t"),
                         sizeBytes: nil, modifiedAt: nil)
        XCTAssertFalse(n.symlinkTargetIsDirectory)
    }

    func testDecodesLegacyJSONWithoutFlag() throws {
        // A snapshot encoded before the flag existed must still decode.
        let legacy = #"{"id":"/p","name":"p","path":"/p","kind":{"symlink":{"target":"/t"}},"sizeBytes":null,"modifiedAt":null}"#
        let data = Data(legacy.utf8)
        let decoded = try JSONDecoder().decode(FileNode.self, from: data)
        XCTAssertFalse(decoded.symlinkTargetIsDirectory)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/FileNodeSymlinkTests test 2>&1 | tail -40`
Expected: FAIL to compile (`symlinkTargetIsDirectory` / `isExpandableDirectory` not found).

- [ ] **Step 3: Implement in `FileNode.swift`**

Replace the struct body's stored properties and computed accessors. The full struct becomes:

```swift
struct FileNode: Identifiable, Equatable, Codable, Sendable {
    enum Kind: Equatable, Codable, Sendable {
        case directory
        case file
        case symlink(target: String?)
    }

    let id: String       // absolute path doubles as id
    let name: String
    let path: String
    let kind: Kind
    let sizeBytes: Int64?
    let modifiedAt: Date?
    /// Only meaningful when `kind` is `.symlink`: true when the link resolves to
    /// a directory, so the tree can render it as expandable. Defaults to false so
    /// existing constructions and legacy cached snapshots stay valid.
    var symlinkTargetIsDirectory: Bool = false

    var isDirectory: Bool {
        if case .directory = kind { return true }
        return false
    }

    var isSymlink: Bool {
        if case .symlink = kind { return true }
        return false
    }

    /// A real directory, or a symlink whose target is a directory. Drives the
    /// disclosure triangle and expand routing in the file tree.
    var isExpandableDirectory: Bool {
        isDirectory || (isSymlink && symlinkTargetIsDirectory)
    }

    var isHidden: Bool {
        name.hasPrefix(".")
    }

    // Custom decode so snapshots written before `symlinkTargetIsDirectory`
    // existed still load (the synthesized decoder would throw on the missing
    // key). Encoding stays synthesized.
    private enum CodingKeys: String, CodingKey {
        case id, name, path, kind, sizeBytes, modifiedAt, symlinkTargetIsDirectory
    }

    init(id: String, name: String, path: String, kind: Kind,
         sizeBytes: Int64?, modifiedAt: Date?, symlinkTargetIsDirectory: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.symlinkTargetIsDirectory = symlinkTargetIsDirectory
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        kind = try c.decode(Kind.self, forKey: .kind)
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt)
        symlinkTargetIsDirectory = try c.decodeIfPresent(Bool.self, forKey: .symlinkTargetIsDirectory) ?? false
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/FileNodeSymlinkTests test 2>&1 | tail -40`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Treemux/Domain/FileNode.swift TreemuxTests/FileNodeSymlinkTests.swift
git commit -m "feat(file-tree): add symlinkTargetIsDirectory + isExpandableDirectory to FileNode"
```

---

### Task 2: Local data source resolves symlink target type

**Files:**
- Modify: `Treemux/Services/FileBrowser/LocalFileBrowserDataSource.swift:103-123` (`makeNode`)
- Test: `TreemuxTests/LocalFileBrowserDataSourceTests.swift`

**Interfaces:**
- Consumes: `FileNode.init(..., symlinkTargetIsDirectory:)` from Task 1.
- Produces: local `listDirectory` now returns symlink nodes with `symlinkTargetIsDirectory` set correctly.

- [ ] **Step 1: Write the failing test**

Add to `TreemuxTests/LocalFileBrowserDataSourceTests.swift`:

```swift
func testSymlinkToDirectoryMarkedExpandable() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    let realDir = root.appendingPathComponent("real")
    try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
    let realFile = root.appendingPathComponent("file.txt")
    try Data("hi".utf8).write(to: realFile)

    let dirLink = root.appendingPathComponent("dirlink")
    try fm.createSymbolicLink(at: dirLink, withDestinationURL: realDir)
    let fileLink = root.appendingPathComponent("filelink")
    try fm.createSymbolicLink(at: fileLink, withDestinationURL: realFile)

    let source = LocalFileBrowserDataSource()
    let nodes = try await source.listDirectory(root.path)
    let byName = Dictionary(uniqueKeysWithValues: nodes.map { ($0.name, $0) })

    XCTAssertTrue(byName["dirlink"]!.isSymlink)
    XCTAssertTrue(byName["dirlink"]!.isExpandableDirectory)
    XCTAssertTrue(byName["filelink"]!.isSymlink)
    XCTAssertFalse(byName["filelink"]!.isExpandableDirectory)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/LocalFileBrowserDataSourceTests/testSymlinkToDirectoryMarkedExpandable test 2>&1 | tail -40`
Expected: FAIL (`dirlink` not expandable — flag defaults false).

- [ ] **Step 3: Implement in `makeNode`**

Replace the `if values.isSymbolicLink == true { … }` branch (lines ~106-114) so it also records the target type. The updated `makeNode` body:

```swift
private static func makeNode(from url: URL) throws -> FileNode {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
    let kind: FileNode.Kind
    var symlinkTargetIsDirectory = false
    if values.isSymbolicLink == true {
        // Resolve target lazily — readlink not exposed via URLResourceKey.
        let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path))
        kind = .symlink(target: target)
        // Follow the link to classify the target. `isDirectory` on the resolved
        // path follows symlinks; a broken link yields false (not expandable).
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            symlinkTargetIsDirectory = isDir.boolValue
        }
    } else if values.isDirectory == true {
        kind = .directory
    } else {
        kind = .file
    }
    return FileNode(
        id: url.path,
        name: url.lastPathComponent,
        path: url.path,
        kind: kind,
        sizeBytes: values.fileSize.map(Int64.init),
        modifiedAt: values.contentModificationDate,
        symlinkTargetIsDirectory: symlinkTargetIsDirectory
    )
}
```

Note: `FileManager.fileExists(atPath:isDirectory:)` follows symlinks, so it reports the target's type. For a real directory/file it is not called (only the symlink branch sets the flag).

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/LocalFileBrowserDataSourceTests/testSymlinkToDirectoryMarkedExpandable test 2>&1 | tail -40`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Treemux/Services/FileBrowser/LocalFileBrowserDataSource.swift TreemuxTests/LocalFileBrowserDataSourceTests.swift
git commit -m "feat(file-tree): resolve local symlink target type"
```

---

### Task 3: SFTP entry type carries the flag; `parseListing` populates it from a probe set

**Files:**
- Modify: `Treemux/Services/SFTP/SFTPDirectoryEntry.swift` (`SFTPRichEntry`)
- Modify: `Treemux/Services/SFTP/SFTPService.swift` (`parseListing`, `parseRecursiveListing`)
- Test: `TreemuxTests/SFTPServiceTests.swift`

**Interfaces:**
- Produces: `SFTPRichEntry.symlinkTargetIsDirectory: Bool` (stored, default `false`). `SFTPService.parseListing(output:parentPath:symlinkDirPaths:)` and `parseRecursiveListing(output:root:symlinkDirPaths:)` gain a `symlinkDirPaths: Set<String>` parameter (default `[]`) — the set of absolute paths whose symlink target is a directory. When an entry is a symlink and its path is in the set, its flag is set true.

- [ ] **Step 1: Write the failing test**

Add to `TreemuxTests/SFTPServiceTests.swift`:

```swift
func testParseListingMarksSymlinkDirFromProbeSet() {
    // GNU `ls -lA --time-style=+%s` layout: perms links owner group size epoch name
    let output = """
    total 8
    lrwxrwxrwx 1 0 0 5 1700000000 dlink -> realdir
    lrwxrwxrwx 1 0 0 5 1700000000 flink -> real.txt
    """
    let entries = SFTPService.parseListing(
        output: output, parentPath: "/home/u",
        symlinkDirPaths: ["/home/u/dlink"])
    let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
    XCTAssertTrue(byName["dlink"]!.symlinkTargetIsDirectory)
    XCTAssertFalse(byName["flink"]!.symlinkTargetIsDirectory)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/SFTPServiceTests/testParseListingMarksSymlinkDirFromProbeSet test 2>&1 | tail -40`
Expected: FAIL to compile (extra `symlinkDirPaths` argument / property missing).

- [ ] **Step 3a: Add the flag to `SFTPRichEntry`**

In `SFTPDirectoryEntry.swift`, add a stored property to `SFTPRichEntry` (keep `Kind` unchanged so existing `.symlink(target:)` matches stay valid):

```swift
struct SFTPRichEntry: Equatable {
    enum Kind: Equatable {
        case directory
        case file
        case symlink(target: String?)
    }

    let name: String
    let path: String
    let kind: Kind
    let sizeBytes: Int64?
    let modifiedAt: Date?
    /// Only meaningful for `.symlink` — true when the link resolves to a directory.
    var symlinkTargetIsDirectory: Bool = false

    var isDirectory: Bool {
        if case .directory = kind { return true }
        return false
    }
}
```

- [ ] **Step 3b: Thread `symlinkDirPaths` through the parsers**

In `SFTPService.swift`, change `parseListing` and `parseRecursiveListing` signatures and set the flag when appending each entry.

`parseListing` — update the signature and the `entries.append(...)`:

```swift
static func parseListing(output: String, parentPath: String,
                         symlinkDirPaths: Set<String> = []) -> [SFTPRichEntry] {
    // ... unchanged body until the append ...
            entries.append(SFTPRichEntry(
                name: name,
                path: fullPath,
                kind: resolvedKind,
                sizeBytes: size,
                modifiedAt: mtime,
                symlinkTargetIsDirectory: symlinkDirPaths.contains(fullPath)
            ))
    // ... unchanged remainder ...
}
```

`parseRecursiveListing` — update the signature and the append:

```swift
static func parseRecursiveListing(output: String, root: String,
                                  symlinkDirPaths: Set<String> = []) -> [String: [SFTPRichEntry]] {
    // ... unchanged body until the grouped append ...
            grouped[parent, default: []].append(
                SFTPRichEntry(name: name, path: absolutePath, kind: kind,
                              sizeBytes: size, modifiedAt: mtime,
                              symlinkTargetIsDirectory: symlinkDirPaths.contains(absolutePath))
            )
    // ... unchanged remainder ...
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/SFTPServiceTests/testParseListingMarksSymlinkDirFromProbeSet test 2>&1 | tail -40`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Treemux/Services/SFTP/SFTPDirectoryEntry.swift Treemux/Services/SFTP/SFTPService.swift TreemuxTests/SFTPServiceTests.swift
git commit -m "feat(sftp): parse symlink-dir flag from probe set"
```

---

### Task 4: Build the symlink-dir probe and wire it into the SSH listing paths

**Files:**
- Modify: `Treemux/Services/SFTP/SFTPService.swift` (`listAllEntriesViaSSH`, `bulkListCommand` / `listTreeViaCommand`, add a `symlinkDirProbeCommand` helper + `parseSymlinkDirProbe`)
- Test: `TreemuxTests/SFTPServiceTests.swift`

**Interfaces:**
- Consumes: `parseListing(...symlinkDirPaths:)`, `parseRecursiveListing(...symlinkDirPaths:)` from Task 3.
- Produces: `SFTPService.parseSymlinkDirProbe(_ output: String, parentPath: String?) -> Set<String>` — parses the probe section into absolute paths whose symlink target is a directory. The probe emits one path per line (absolute for per-dir, `./rel` for bulk). A `MARKER` string separates the listing section from the probe section in the combined command output.

- [ ] **Step 1: Write the failing test**

Add to `TreemuxTests/SFTPServiceTests.swift`:

```swift
func testParseSymlinkDirProbeAbsolute() {
    let out = "/home/u/dlink\n/home/u/nested/dlink2\n"
    let set = SFTPService.parseSymlinkDirProbe(out, parentPath: nil)
    XCTAssertEqual(set, ["/home/u/dlink", "/home/u/nested/dlink2"])
}

func testParseSymlinkDirProbeRelativeToRoot() {
    // Bulk form: `find .` emits ./-relative paths; resolve against root.
    let out = "./dlink\n./nested/dlink2\n"
    let set = SFTPService.parseSymlinkDirProbe(out, parentPath: "/home/u")
    XCTAssertEqual(set, ["/home/u/dlink", "/home/u/nested/dlink2"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/SFTPServiceTests/testParseSymlinkDirProbeAbsolute test 2>&1 | tail -40`
Expected: FAIL to compile (`parseSymlinkDirProbe` undefined).

- [ ] **Step 3a: Add the probe parser + command helpers**

In `SFTPService.swift`, add near `parseListing`:

```swift
/// Marker separating the listing section from the symlink-dir probe section
/// in the combined command output. Chosen to never collide with a filename.
static let symlinkProbeMarker = "@@TMX_SYMDIRS@@"

/// Parses the probe section: one path per line, each a symlink whose target is
/// a directory. When `parentPath` is non-nil, entries are `./`-relative and are
/// resolved against it (bulk form); otherwise they are already absolute.
static func parseSymlinkDirProbe(_ output: String, parentPath: String?) -> Set<String> {
    let base = parentPath.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
    var set: Set<String> = []
    for raw in output.components(separatedBy: "\n") {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if let base {
            if line.hasPrefix("./") { line.removeFirst(2) }
            if line.isEmpty { continue }
            set.insert(base + "/" + line)
        } else {
            set.insert(line)
        }
    }
    return set
}
```

Add a shell fragment builder. It lists, then prints the marker, then prints each symlink (at the given depth) whose target is a directory. `[ -d "$l/" ]` follows the link portably (POSIX):

```swift
/// Shell fragment that, after the main listing, emits the marker followed by
/// one line per symlink (to `maxdepth`) whose target is a directory. Portable:
/// `[ -d "$l/" ]` dereferences the link on both GNU and BSD userlands.
static func symlinkDirProbeFragment(maxDepth: Int) -> String {
    "echo \(symlinkProbeMarker); "
    + "find . -mindepth 1 -maxdepth \(maxDepth) -type l 2>/dev/null "
    + "| while IFS= read -r l; do [ -d \"$l/\" ] && printf '%s\\n' \"$l\"; done"
}
```

- [ ] **Step 3b: Wire the probe into `listAllEntriesViaSSH`**

The per-directory listing runs at depth 1. Because `find`'s probe emits `./name`, run the whole combined command with `cd` into the path so both sections use the same relative base, then resolve against `path`. Replace `listAllEntriesViaSSH`:

```swift
private func listAllEntriesViaSSH(target: SSHTarget, path: String) async throws -> [SFTPRichEntry] {
    let escapedPath = shellEscape(path)
    let gnuCmd = "ls -lA --time-style=+%s -- \(escapedPath)"
    let bsdCmd = "ls -lAT -- \(escapedPath)"
    let listing = "( \(gnuCmd) 2>/dev/null || \(bsdCmd) )"
    // cd into the dir so the probe's `find .` emits ./-relative names we can
    // resolve against `path`. The listing itself still uses the absolute path.
    let combined = "\(listing); cd \(escapedPath) && \(Self.symlinkDirProbeFragment(maxDepth: 1))"

    let result = try await runSSH(target: target, command: combined, timeout: Self.listingCommandTimeout)
    guard result.exitCode == 0 else {
        throw SFTPServiceError.commandFailed("ls failed at \(path)")
    }

    let sections = result.output.components(separatedBy: Self.symlinkProbeMarker)
    let listingOut = sections.first ?? result.output
    let probeOut = sections.count > 1 ? sections[1] : ""
    let symlinkDirs = Self.parseSymlinkDirProbe(probeOut, parentPath: path)
    return Self.parseListing(output: listingOut, parentPath: path, symlinkDirPaths: symlinkDirs)
}
```

- [ ] **Step 3c: Wire the probe into the bulk path**

In `bulkListCommand`, append the probe after the capped listing. Update it:

```swift
static func bulkListCommand(maxDepth: Int, maxEntries: Int = bulkListMaxEntries) -> String {
    let sel = "\\( -type d -o -type f -o -type l \\)"
    let gnu = "find . -mindepth 1 -maxdepth \(maxDepth) \(sel) -exec ls -ldn --time-style=+%s {} +"
    let bsd = "find . -mindepth 1 -maxdepth \(maxDepth) \(sel) -exec ls -ldnT {} +"
    let listing = "( \(gnu) 2>/dev/null || \(bsd) ) | head -n \(maxEntries)"
    return "\(listing); \(symlinkDirProbeFragment(maxDepth: maxDepth))"
}
```

Then in `listTreeViaCommand` (around line 279), split the output on the marker and pass the set to `parseRecursiveListing`. Find the existing call and update it:

```swift
func listTreeViaCommand(root: String, maxDepth: Int, entryCap: Int)
    async throws -> ([String: [SFTPRichEntry]], Set<String>) {
    let output = try await runCommand(
        Self.bulkListCommand(maxDepth: maxDepth), in: root, timeout: Self.listingCommandTimeout)
    let sections = output.components(separatedBy: Self.symlinkProbeMarker)
    let listingOut = sections.first ?? output
    let probeOut = sections.count > 1 ? sections[1] : ""
    // `runCommand(_:in:)` supplies the leading `cd <root>`, so the probe's
    // `find .` names are ./-relative to `root`.
    let symlinkDirs = Self.parseSymlinkDirProbe(probeOut, parentPath: root)
    let grouped = Self.parseRecursiveListing(output: listingOut, root: root, symlinkDirPaths: symlinkDirs)
    // ... keep the existing truncation/entryCap logic that builds the returned tuple,
    //     operating on `grouped` instead of the previous inline parse result ...
}
```

Note: if `listTreeViaCommand` currently parses inline, replace only the parse call with the marker-split version above; keep its existing per-directory `entryCap` truncation and return shape unchanged. Read lines 276-296 of `SFTPService.swift` before editing to preserve the truncation logic.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/SFTPServiceTests test 2>&1 | tail -40`
Expected: PASS (probe parser tests + existing SFTP tests still green).

- [ ] **Step 5: Commit**

```bash
git add Treemux/Services/SFTP/SFTPService.swift TreemuxTests/SFTPServiceTests.swift
git commit -m "feat(sftp): one-round-trip symlink-dir probe on listing + bulk paths"
```

---

### Task 5: Remote data source maps the flag through `node(from:)`

**Files:**
- Modify: `Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift:35-44` (`node(from:)`)
- Test: `TreemuxTests/SFTPRecursiveListingTests.swift`

**Interfaces:**
- Consumes: `SFTPRichEntry.symlinkTargetIsDirectory` (Task 3), `FileNode.init(..., symlinkTargetIsDirectory:)` (Task 1).
- Produces: `RemoteFileBrowserDataSource.node(from:)` copies the flag onto the `FileNode`.

- [ ] **Step 1: Write the failing test**

Add to `TreemuxTests/SFTPRecursiveListingTests.swift`:

```swift
func testNodeFromEntryCarriesSymlinkDirFlag() {
    let entry = SFTPRichEntry(name: "dlink", path: "/r/dlink",
                              kind: .symlink(target: "/r/real"),
                              sizeBytes: 5, modifiedAt: nil,
                              symlinkTargetIsDirectory: true)
    let node = RemoteFileBrowserDataSource.node(from: entry)
    XCTAssertTrue(node.isSymlink)
    XCTAssertTrue(node.isExpandableDirectory)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/SFTPRecursiveListingTests/testNodeFromEntryCarriesSymlinkDirFlag test 2>&1 | tail -40`
Expected: FAIL (`isExpandableDirectory` false — flag not mapped).

- [ ] **Step 3: Implement in `node(from:)`**

```swift
static func node(from entry: SFTPRichEntry) -> FileNode {
    let kind: FileNode.Kind
    switch entry.kind {
    case .directory: kind = .directory
    case .file: kind = .file
    case .symlink(let target): kind = .symlink(target: target)
    }
    return FileNode(id: entry.path, name: entry.name, path: entry.path,
                    kind: kind, sizeBytes: entry.sizeBytes, modifiedAt: entry.modifiedAt,
                    symlinkTargetIsDirectory: entry.symlinkTargetIsDirectory)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/SFTPRecursiveListingTests/testNodeFromEntryCarriesSymlinkDirFlag test 2>&1 | tail -40`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift TreemuxTests/SFTPRecursiveListingTests.swift
git commit -m "feat(sftp): map symlink-dir flag from entry to FileNode"
```

---

### Task 6: Controller expands symlink-directories

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift:467` (`visibleRows()` `expanded` computation)
- Test: `TreemuxTests/FileBrowserTabControllerTests.swift`

**Interfaces:**
- Consumes: `FileNode.isExpandableDirectory` (Task 1), the existing `toggleExpand(_:)`, `MockFileBrowserDataSource` (extends its `directoryListings`).
- Produces: a symlink-dir node, when in `expandedDirs`, emits its children rows; `toggleExpand` on a symlink-dir path lists and shows them.

- [ ] **Step 1: Write the failing test**

Add to `TreemuxTests/FileBrowserTabControllerTests.swift`:

```swift
@MainActor
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
        initial: FileBrowserTabState(rootPath: "/root", rootKind: .local,
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
```

(If `FileBrowserTabState`'s initializer signature differs, mirror the exact form used by neighboring tests in this file — read one existing test's constructor first.)

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/FileBrowserTabControllerTests/testExpandSymlinkDirectoryShowsChildren test 2>&1 | tail -40`
Expected: FAIL — `visibleRows()` gates children on `node.isDirectory`, which is false for the symlink, so `inner.txt` never renders.

- [ ] **Step 3: Implement — use `isExpandableDirectory` in `visibleRows()`**

In `FileBrowserTabController.swift`, in the `emit` closure of `visibleRows()` (line ~467), change:

```swift
let expanded = node.isExpandableDirectory && expandedDirs.contains(node.path)
```

(`toggleExpand` needs no change — it already calls `dataSource.listDirectory(path)`, which follows the link. `refreshTree`'s reload of already-expanded dirs (line 274) also already works for any path in `expandedDirs`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/FileBrowserTabControllerTests/testExpandSymlinkDirectoryShowsChildren test 2>&1 | tail -40`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift TreemuxTests/FileBrowserTabControllerTests.swift
git commit -m "feat(file-tree): expand symlink-directories in visibleRows"
```

---

### Task 7: Tree UI shows disclosure + routes clicks for symlink-directories

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileTreePanelView.swift:244,289,296`
- Test: manual (SwiftUI view — no unit harness); covered functionally by Task 6 at the controller level.

**Interfaces:**
- Consumes: `FileNode.isExpandableDirectory` (Task 1).

- [ ] **Step 1: Change the three routing sites**

In `FileTreePanelView.swift`:

Line ~244 (disclosure triangle):
```swift
if node.isExpandableDirectory {
    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
```

Line ~289 (double-click → pin only real files; a symlink-dir should not pin):
```swift
TapGesture(count: 2).onEnded {
    if !node.isExpandableDirectory {
        Task { await controller.pinFile(node.path) }
    }
}
```

Line ~296 (single-click → expand vs open):
```swift
TapGesture(count: 1).onEnded {
    if node.isExpandableDirectory {
        Task { await controller.toggleExpand(node.path) }
    } else {
        Task { await controller.openInTree(node.path) }
    }
}
```

The icon stays the symlink variant — `FileIconCatalog.icon(for:)` matches `case .symlink` regardless of the flag, so a symlink-dir still shows the link icon (user can tell it is a link) while being expandable. No change to `FileIconCatalog`.

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug -skipPackagePluginValidation build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual verification**

Build and run per the project run command. Verify:
- A local symlinked directory shows a disclosure triangle and expands to its target's contents; a symlinked file does not.
- On a remote (system-SSH key-auth) workspace, a symlinked directory at the root expands.

- [ ] **Step 4: Commit**

```bash
git add Treemux/UI/FileBrowser/FileTreePanelView.swift
git commit -m "feat(file-tree): disclosure + click routing for symlink-directories"
```

---

### Task 8: Full regression + Citadel limitation note

**Files:**
- Modify: `Treemux/Services/SFTP/SFTPService.swift` (`listAllEntriesViaSFTP` — add a comment documenting the limitation)

- [ ] **Step 1: Document the Citadel fallback limitation**

The Citadel (password-auth) SFTP path (`listAllEntriesViaSFTP`) has no arbitrary command exec, so it cannot run the `[ -d ]` probe. Symlink-directories over Citadel stay non-expandable (`symlinkTargetIsDirectory` defaults false). Add a comment above `listAllEntriesViaSFTP`:

```swift
// NOTE: symlink target-type resolution needs the `[ -d ]` probe, which requires
// arbitrary command exec — unavailable on the Citadel password-auth path. Over
// Citadel, symlink-directories therefore render as plain (non-expandable) links.
// The common key-auth system-SSH path (listAllEntriesViaSSH) is fully supported.
```

- [ ] **Step 2: Run the full test suite**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation test 2>&1 | tail -40`
Expected: all tests PASS (no regressions in `DirectoryTreeCacheTests`, `SFTPServiceTests`, `SFTPRecursiveListingTests`, `FileBrowserTabControllerTests`, `LocalFileBrowserDataSourceTests`).

- [ ] **Step 3: Commit**

```bash
git add Treemux/Services/SFTP/SFTPService.swift
git commit -m "docs(sftp): note Citadel symlink-dir limitation"
```

---

## Notes / Design Decisions (carry into review)

- **No cycle machinery.** The eager tree fetch never follows symlinks: `BFSTreeLister` recurses `where child.isDirectory` (symlink-dirs are `isDirectory == false`), and the remote bulk `find` runs without `-L`. Automated recursion into a symlinked directory is therefore impossible; only user-driven, finite, one-level-per-click expansion follows a link. So the spec's visited-set cycle guard is intentionally omitted as YAGNI. If a future change makes prefetch follow symlinks, revisit this.
- **Flag, not enum change.** `symlinkTargetIsDirectory` is a derived `Bool` on `FileNode`/`SFTPRichEntry`, not a new associated value on `Kind.symlink`, to avoid breaking every `.symlink(target:)` pattern match (`FileIconCatalog`, existing tests) and to keep Codable stable (with `decodeIfPresent` for legacy snapshots).
- **One remote round-trip.** The `[ -d ]` probe is appended to the existing listing/bulk command, so target-type resolution adds no per-symlink round-trips.
