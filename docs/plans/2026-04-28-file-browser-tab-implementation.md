# File Browser Tab Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a VSCode-like file browser as a first-class tab kind alongside terminal tabs. Entry from sidebar buttons (Project + Worktree rows) and `Cmd+Shift+T`. Inside the tab: left file tree + right viewer (text editor with Cmd+S save, image preview, Quick Look fallback, binary metadata view). Works for local and remote (SSH/SFTP) workspaces.

**Architecture:** Extend `WorkspaceTabStateRecord` with `kind: WorkspaceTabKind` and a sibling `fileBrowserState: FileBrowserTabState?` payload (mutually exclusive with the existing `panes/layout/...` fields). A new `FileBrowserTabController` mirrors the existing `WorkspaceSessionController` shape. `FileBrowserDataSource` protocol abstracts local (`FileManager`) vs remote (extended `SFTPService`). `WorkspaceDetailView` dispatches by `tab.kind`; tab bar visually differentiates kinds. The Runestone editor is added via SwiftPM through `project.yml`.

**Tech Stack:** Swift / SwiftUI / AppKit, Runestone (`https://github.com/simonbs/Runestone`) for the code editor, existing Citadel-based `SFTPService` extended for `readFile`/`writeFile`, XCTest in `TreemuxTests/`.

---

## Reference: design document

Design lives at `docs/plans/2026-04-28-file-browser-tab-design.md` — re-read it before starting.

## Reference: project rules (must follow)

- Communicate in Chinese with the user; **English in code/comments**.
- Address the user as "卡皮巴拉".
- After the final build succeeds, surface this command for the user to run:
  `rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<id>/Build/Products/Debug/Treemux.app`
  (Substitute `<id>` based on the actual `DerivedData` path.)
- All work happens in the `.worktrees/feat+file-browser-tab/` worktree on branch `feat/file-browser-tab`.
- Every user-visible string MUST use `LocalizedStringKey`, with a `zh-Hans` translation added to `Treemux/Localizable.xcstrings`.
- Run `xcodegen generate` after editing `project.yml` (it regenerates `Treemux.xcodeproj`).

## Build & test commands (used throughout)

- Regenerate xcodeproj: `xcodegen generate`
- Build (worktree-aware): `xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build`
- Run tests: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' test`
- Run a single test: append `-only-testing:TreemuxTests/<TestClassName>/<testMethodName>`

When a test step says "Run it to make sure it fails," that uses the per-test command.

---

# Phase 0 — Setup

## Task 0.1: Add Runestone via SwiftPM

**Files:**
- Modify: `project.yml`

**Step 1: Edit `project.yml` to add the Runestone package**

Under `packages:`, append:

```yaml
  Runestone:
    url: https://github.com/simonbs/Runestone
    from: "0.4.0"
```

Under `targets.Treemux.dependencies:`, append:

```yaml
      - package: Runestone
        product: Runestone
```

**Step 2: Regenerate the Xcode project**

Run: `xcodegen generate`
Expected: `Updated project at Treemux.xcodeproj` and no errors.

**Step 3: Build to confirm Runestone resolves**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build`
Expected: BUILD SUCCEEDED. (First run will fetch the package; this may take a minute.)

**Step 4: Commit**

```bash
git add project.yml Treemux.xcodeproj
git commit -m "chore: add Runestone package for file browser editor"
```

> If Runestone fails to integrate, fall back to `https://github.com/ZeeZide/CodeEditor` and update later phase tasks accordingly.

---

# Phase 1 — Data model (tab kind + file browser state)

## Task 1.1: Add `WorkspaceTabKind` enum

**Files:**
- Create: `Treemux/Domain/WorkspaceTabKind.swift`
- Test: `TreemuxTests/WorkspaceTabKindCodingTests.swift`

**Step 1: Write the failing test**

```swift
// TreemuxTests/WorkspaceTabKindCodingTests.swift
import XCTest
@testable import Treemux

final class WorkspaceTabKindCodingTests: XCTestCase {
    func testRoundTripTerminal() throws {
        let data = try JSONEncoder().encode(WorkspaceTabKind.terminal)
        let decoded = try JSONDecoder().decode(WorkspaceTabKind.self, from: data)
        XCTAssertEqual(decoded, .terminal)
    }

    func testRoundTripFileBrowser() throws {
        let data = try JSONEncoder().encode(WorkspaceTabKind.fileBrowser)
        let decoded = try JSONDecoder().decode(WorkspaceTabKind.self, from: data)
        XCTAssertEqual(decoded, .fileBrowser)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' test -only-testing:TreemuxTests/WorkspaceTabKindCodingTests`
Expected: compile error — `WorkspaceTabKind` undefined.

**Step 3: Implement minimal type**

```swift
// Treemux/Domain/WorkspaceTabKind.swift
import Foundation

/// Discriminator for tab content. New kinds (e.g. logs, diffs) can be added
/// without breaking existing terminal-tab persistence.
enum WorkspaceTabKind: String, Codable {
    case terminal
    case fileBrowser
}
```

**Step 4: Regenerate project & run test**

```bash
xcodegen generate
xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' test -only-testing:TreemuxTests/WorkspaceTabKindCodingTests
```
Expected: PASS.

**Step 5: Commit**

```bash
git add Treemux/Domain/WorkspaceTabKind.swift TreemuxTests/WorkspaceTabKindCodingTests.swift Treemux.xcodeproj
git commit -m "feat(domain): add WorkspaceTabKind enum"
```

## Task 1.2: Add `FileBrowserTabState` model

**Files:**
- Create: `Treemux/Domain/FileBrowserTabState.swift`
- Test: `TreemuxTests/FileBrowserTabStateCodingTests.swift`

**Step 1: Write the failing test**

```swift
// TreemuxTests/FileBrowserTabStateCodingTests.swift
import XCTest
@testable import Treemux

final class FileBrowserTabStateCodingTests: XCTestCase {
    func testRoundTripWithDefaults() throws {
        let state = FileBrowserTabState(
            rootPath: "/tmp/foo",
            rootKind: .worktree,
            selectedFilePath: "/tmp/foo/bar.txt",
            splitRatio: 0.3,
            expandedDirs: ["/tmp/foo", "/tmp/foo/sub"],
            showsHiddenFiles: true
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(FileBrowserTabState.self, from: data)
        XCTAssertEqual(decoded.rootPath, "/tmp/foo")
        XCTAssertEqual(decoded.rootKind, .worktree)
        XCTAssertEqual(decoded.selectedFilePath, "/tmp/foo/bar.txt")
        XCTAssertEqual(decoded.splitRatio, 0.3, accuracy: 0.0001)
        XCTAssertEqual(decoded.expandedDirs, ["/tmp/foo", "/tmp/foo/sub"])
        XCTAssertTrue(decoded.showsHiddenFiles)
    }

    func testDecodeMissingOptionalFields() throws {
        // Minimal payload — defaults should fill in.
        let json = """
        {"rootPath": "/x", "rootKind": "project"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FileBrowserTabState.self, from: json)
        XCTAssertEqual(decoded.rootPath, "/x")
        XCTAssertEqual(decoded.rootKind, .project)
        XCTAssertNil(decoded.selectedFilePath)
        XCTAssertEqual(decoded.splitRatio, 0.28, accuracy: 0.0001)
        XCTAssertEqual(decoded.expandedDirs, [])
        XCTAssertFalse(decoded.showsHiddenFiles)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `... -only-testing:TreemuxTests/FileBrowserTabStateCodingTests`
Expected: compile error — type undefined.

**Step 3: Implement**

```swift
// Treemux/Domain/FileBrowserTabState.swift
import Foundation

enum FileBrowserRootKind: String, Codable {
    case project
    case worktree
}

/// Persistent state for a file browser tab. Edited buffers (dirty content)
/// are intentionally NOT persisted — they're discarded on restart after a
/// dirty-prompt confirmation; this prevents stale buffers from overwriting
/// files that were modified externally (in terminal, by `git pull`, etc.).
struct FileBrowserTabState: Codable, Equatable {
    var rootPath: String
    var rootKind: FileBrowserRootKind
    var selectedFilePath: String?
    var splitRatio: Double
    var expandedDirs: [String]
    var showsHiddenFiles: Bool

    init(
        rootPath: String,
        rootKind: FileBrowserRootKind,
        selectedFilePath: String? = nil,
        splitRatio: Double = 0.28,
        expandedDirs: [String] = [],
        showsHiddenFiles: Bool = false
    ) {
        self.rootPath = rootPath
        self.rootKind = rootKind
        self.selectedFilePath = selectedFilePath
        self.splitRatio = splitRatio
        self.expandedDirs = expandedDirs
        self.showsHiddenFiles = showsHiddenFiles
    }

    enum CodingKeys: String, CodingKey {
        case rootPath, rootKind, selectedFilePath, splitRatio, expandedDirs, showsHiddenFiles
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rootPath = try c.decode(String.self, forKey: .rootPath)
        rootKind = try c.decode(FileBrowserRootKind.self, forKey: .rootKind)
        selectedFilePath = try c.decodeIfPresent(String.self, forKey: .selectedFilePath)
        splitRatio = try c.decodeIfPresent(Double.self, forKey: .splitRatio) ?? 0.28
        expandedDirs = try c.decodeIfPresent([String].self, forKey: .expandedDirs) ?? []
        showsHiddenFiles = try c.decodeIfPresent(Bool.self, forKey: .showsHiddenFiles) ?? false
    }
}
```

**Step 4: Regenerate & run test**

```bash
xcodegen generate
xcodebuild ... test -only-testing:TreemuxTests/FileBrowserTabStateCodingTests
```
Expected: PASS.

**Step 5: Commit**

```bash
git add Treemux/Domain/FileBrowserTabState.swift TreemuxTests/FileBrowserTabStateCodingTests.swift Treemux.xcodeproj
git commit -m "feat(domain): add FileBrowserTabState"
```

## Task 1.3: Extend `WorkspaceTabStateRecord` with `kind` + `fileBrowserState`

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift` (the `WorkspaceTabStateRecord` struct, lines 57-115)
- Test: `TreemuxTests/WorkspaceTabRecordMigrationTests.swift`

**Step 1: Write the failing test**

```swift
// TreemuxTests/WorkspaceTabRecordMigrationTests.swift
import XCTest
@testable import Treemux

final class WorkspaceTabRecordMigrationTests: XCTestCase {
    func testLegacyDecodeWithoutKindDefaultsToTerminal() throws {
        // Legacy payload: pre-migration tabs serialized without `kind`.
        let legacyJSON = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "title": "Tab 1",
            "isManuallyNamed": false,
            "panes": [],
            "focusedPaneID": null,
            "zoomedPaneID": null
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(WorkspaceTabStateRecord.self, from: legacyJSON)
        XCTAssertEqual(decoded.kind, .terminal)
        XCTAssertNil(decoded.fileBrowserState)
        XCTAssertEqual(decoded.title, "Tab 1")
    }

    func testFileBrowserKindRoundTrip() throws {
        let state = FileBrowserTabState(rootPath: "/tmp/x", rootKind: .worktree)
        let record = WorkspaceTabStateRecord(
            title: "Files",
            kind: .fileBrowser,
            fileBrowserState: state
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(WorkspaceTabStateRecord.self, from: data)
        XCTAssertEqual(decoded.kind, .fileBrowser)
        XCTAssertEqual(decoded.fileBrowserState?.rootPath, "/tmp/x")
        XCTAssertNil(decoded.layout)
        XCTAssertEqual(decoded.panes.count, 0)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `... -only-testing:TreemuxTests/WorkspaceTabRecordMigrationTests`
Expected: compile error — `WorkspaceTabStateRecord` has no `kind` / `fileBrowserState` initializer.

**Step 3: Modify `WorkspaceTabStateRecord`**

In `Treemux/Domain/WorkspaceModels.swift`, replace lines 57-115 with:

```swift
struct WorkspaceTabStateRecord: Codable, Identifiable {
    let id: UUID
    var title: String
    var isManuallyNamed: Bool
    var kind: WorkspaceTabKind

    // Terminal-tab fields (nil when kind == .fileBrowser)
    let layout: SessionLayoutNode?
    let panes: [PaneSnapshot]
    let focusedPaneID: UUID?
    let zoomedPaneID: UUID?

    // File-browser-tab field (nil when kind == .terminal)
    var fileBrowserState: FileBrowserTabState?

    init(
        id: UUID = UUID(),
        title: String,
        isManuallyNamed: Bool = false,
        kind: WorkspaceTabKind = .terminal,
        layout: SessionLayoutNode? = nil,
        panes: [PaneSnapshot] = [],
        focusedPaneID: UUID? = nil,
        zoomedPaneID: UUID? = nil,
        fileBrowserState: FileBrowserTabState? = nil
    ) {
        self.id = id
        self.title = title
        self.isManuallyNamed = isManuallyNamed
        self.kind = kind
        self.layout = layout
        self.panes = panes
        self.focusedPaneID = focusedPaneID
        self.zoomedPaneID = zoomedPaneID
        self.fileBrowserState = fileBrowserState
    }

    /// Creates a default single-pane terminal tab for the given working directory.
    static func makeDefault(workingDirectory: String, sshTarget: SSHTarget? = nil, title: String = "Tab 1") -> WorkspaceTabStateRecord {
        let paneID = UUID()
        let pane = PaneSnapshot(
            id: paneID,
            backend: .defaultBackend(for: sshTarget),
            workingDirectory: workingDirectory
        )
        return WorkspaceTabStateRecord(
            title: title,
            kind: .terminal,
            layout: .pane(PaneLeaf(paneID: paneID)),
            panes: [pane],
            focusedPaneID: paneID
        )
    }

    /// Creates a default file browser tab rooted at `rootPath`.
    static func makeFileBrowser(rootPath: String, rootKind: FileBrowserRootKind, title: String) -> WorkspaceTabStateRecord {
        WorkspaceTabStateRecord(
            title: title,
            kind: .fileBrowser,
            fileBrowserState: FileBrowserTabState(rootPath: rootPath, rootKind: rootKind)
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, title, isManuallyNamed, kind, layout, panes, focusedPaneID, zoomedPaneID, fileBrowserState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        isManuallyNamed = try container.decodeIfPresent(Bool.self, forKey: .isManuallyNamed) ?? false
        // Legacy data: missing `kind` → terminal.
        kind = try container.decodeIfPresent(WorkspaceTabKind.self, forKey: .kind) ?? .terminal
        layout = try container.decodeIfPresent(SessionLayoutNode.self, forKey: .layout)
        panes = try container.decodeIfPresent([PaneSnapshot].self, forKey: .panes) ?? []
        focusedPaneID = try container.decodeIfPresent(UUID.self, forKey: .focusedPaneID)
        zoomedPaneID = try container.decodeIfPresent(UUID.self, forKey: .zoomedPaneID)
        fileBrowserState = try container.decodeIfPresent(FileBrowserTabState.self, forKey: .fileBrowserState)
    }
}
```

**Step 4: Run test**

Run: `... -only-testing:TreemuxTests/WorkspaceTabRecordMigrationTests`
Expected: PASS.

**Step 5: Run full test suite to ensure no regression**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' test`
Expected: All tests pass.

**Step 6: Commit**

```bash
git add Treemux/Domain/WorkspaceModels.swift TreemuxTests/WorkspaceTabRecordMigrationTests.swift
git commit -m "feat(domain): extend WorkspaceTabStateRecord with kind + fileBrowserState"
```

---

# Phase 2 — File browser data model & local data source

## Task 2.1: Define `FileNode` and `FileMetadata`

**Files:**
- Create: `Treemux/Domain/FileNode.swift`
- Test: (no separate test — covered by data source tests)

**Step 1: Implement**

```swift
// Treemux/Domain/FileNode.swift
import Foundation

/// One entry in a file browser directory listing. Trees are loaded lazily —
/// `children` is nil for unexpanded directories, and `[]` for empty / loaded.
struct FileNode: Identifiable, Equatable {
    enum Kind: Equatable {
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

    var isDirectory: Bool {
        if case .directory = kind { return true }
        return false
    }

    var isHidden: Bool {
        name.hasPrefix(".")
    }
}

/// Metadata fetched before deciding how to render a file (size guard, type).
struct FileMetadata: Equatable {
    let path: String
    let sizeBytes: Int64
    let modifiedAt: Date?
    let isDirectory: Bool
    let isSymbolicLink: Bool
}
```

**Step 2: Regenerate & build**

```bash
xcodegen generate
xcodebuild ... build
```
Expected: BUILD SUCCEEDED.

**Step 3: Commit**

```bash
git add Treemux/Domain/FileNode.swift Treemux.xcodeproj
git commit -m "feat(domain): add FileNode and FileMetadata"
```

## Task 2.2: Define `FileBrowserDataSource` protocol

**Files:**
- Create: `Treemux/Services/FileBrowser/FileBrowserDataSource.swift`

**Step 1: Implement**

```swift
// Treemux/Services/FileBrowser/FileBrowserDataSource.swift
import Foundation

enum FileBrowserError: LocalizedError {
    case notFound(String)
    case notReadable(String)
    case notWritable(String)
    case fileTooLarge(path: String, sizeBytes: Int64, limit: Int64)
    case decodingFailed(String)
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .notFound(let p): return "File not found: \(p)"
        case .notReadable(let p): return "Cannot read file: \(p)"
        case .notWritable(let p): return "Cannot write file: \(p)"
        case .fileTooLarge(let p, let size, let limit):
            return "File too large (\(size) bytes, limit \(limit)): \(p)"
        case .decodingFailed(let p): return "Cannot decode text: \(p)"
        case .underlying(let e): return e.localizedDescription
        }
    }
}

/// Abstracts file system access so the same UI works for local and remote
/// (SFTP) workspaces. All methods are async and may throw FileBrowserError.
protocol FileBrowserDataSource: AnyObject {
    var supportsWrite: Bool { get }

    func listDirectory(_ path: String) async throws -> [FileNode]
    func fileMetadata(_ path: String) async throws -> FileMetadata

    /// Reads up to `maxBytes` from the file. Throws `.fileTooLarge` if the file
    /// exceeds `maxBytes`; the caller is expected to check size first via
    /// `fileMetadata` for files larger than the comfort threshold.
    func readFile(_ path: String, maxBytes: Int) async throws -> Data

    /// Writes data atomically when possible. Local: temp file + rename; remote:
    /// SFTP write to temp, rename. Caller decides whether to confirm overwrites.
    func writeFile(_ path: String, data: Data) async throws

    /// Returns a URL to a local file usable by Quick Look. For local sources
    /// this is the original path; for remote, downloads to NSTemporaryDirectory.
    func downloadForQuickLook(_ path: String, progress: @escaping (Double) -> Void) async throws -> URL
}
```

**Step 2: Regenerate & build**

```bash
xcodegen generate
xcodebuild ... build
```
Expected: BUILD SUCCEEDED.

**Step 3: Commit**

```bash
git add Treemux/Services/FileBrowser/FileBrowserDataSource.swift Treemux.xcodeproj
git commit -m "feat(services): add FileBrowserDataSource protocol"
```

## Task 2.3: Implement `LocalFileBrowserDataSource` (list + metadata)

**Files:**
- Create: `Treemux/Services/FileBrowser/LocalFileBrowserDataSource.swift`
- Test: `TreemuxTests/LocalFileBrowserDataSourceTests.swift`

**Step 1: Write the failing test**

```swift
// TreemuxTests/LocalFileBrowserDataSourceTests.swift
import XCTest
@testable import Treemux

final class LocalFileBrowserDataSourceTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("treemux-fb-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testListDirectoryReturnsFilesAndSubdirs() async throws {
        let sub = tmpDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = tmpDir.appendingPathComponent("hello.txt")
        try "hi".write(to: file, atomically: true, encoding: .utf8)

        let ds = LocalFileBrowserDataSource()
        let nodes = try await ds.listDirectory(tmpDir.path)
        let names = Set(nodes.map(\.name))
        XCTAssertTrue(names.contains("sub"))
        XCTAssertTrue(names.contains("hello.txt"))

        let dirNode = nodes.first { $0.name == "sub" }
        XCTAssertEqual(dirNode?.kind, .directory)
        let fileNode = nodes.first { $0.name == "hello.txt" }
        XCTAssertEqual(fileNode?.kind, .file)
        XCTAssertEqual(fileNode?.sizeBytes, 2)
    }

    func testFileMetadata() async throws {
        let file = tmpDir.appendingPathComponent("a.bin")
        try Data(repeating: 0, count: 1024).write(to: file)
        let ds = LocalFileBrowserDataSource()
        let meta = try await ds.fileMetadata(file.path)
        XCTAssertEqual(meta.sizeBytes, 1024)
        XCTAssertFalse(meta.isDirectory)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `... -only-testing:TreemuxTests/LocalFileBrowserDataSourceTests`
Expected: compile error — `LocalFileBrowserDataSource` undefined.

**Step 3: Implement (list + metadata only — read/write/quicklook in next task)**

```swift
// Treemux/Services/FileBrowser/LocalFileBrowserDataSource.swift
import Foundation

final class LocalFileBrowserDataSource: FileBrowserDataSource {
    let supportsWrite = true
    private let queue = DispatchQueue(label: "treemux.localfs", qos: .userInitiated)

    func listDirectory(_ path: String) async throws -> [FileNode] {
        try await runOnQueue {
            let url = URL(fileURLWithPath: path)
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            let contents = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
            return try contents.map { try Self.makeNode(from: $0) }
                .sorted(by: Self.naturalOrder)
        }
    }

    func fileMetadata(_ path: String) async throws -> FileMetadata {
        try await runOnQueue {
            let url = URL(fileURLWithPath: path)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            return FileMetadata(
                path: path,
                sizeBytes: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate,
                isDirectory: values.isDirectory ?? false,
                isSymbolicLink: values.isSymbolicLink ?? false
            )
        }
    }

    func readFile(_ path: String, maxBytes: Int) async throws -> Data {
        // Implemented in next task.
        fatalError("not yet implemented")
    }

    func writeFile(_ path: String, data: Data) async throws {
        // Implemented in next task.
        fatalError("not yet implemented")
    }

    func downloadForQuickLook(_ path: String, progress: @escaping (Double) -> Void) async throws -> URL {
        // Local: just return the path itself.
        URL(fileURLWithPath: path)
    }

    // MARK: - helpers

    private static func makeNode(from url: URL) throws -> FileNode {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        let kind: FileNode.Kind
        if values.isSymbolicLink == true {
            // Resolve target lazily — readlink not exposed via URLResourceKey.
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path))
            kind = .symlink(target: target)
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
            modifiedAt: values.contentModificationDate
        )
    }

    /// Natural ordering: directories first, then case-insensitive alpha.
    private static func naturalOrder(_ a: FileNode, _ b: FileNode) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    private func runOnQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try body()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }
}
```

**Step 4: Regenerate & run test**

```bash
xcodegen generate
xcodebuild ... test -only-testing:TreemuxTests/LocalFileBrowserDataSourceTests
```
Expected: PASS.

**Step 5: Commit**

```bash
git add Treemux/Services/FileBrowser/LocalFileBrowserDataSource.swift TreemuxTests/LocalFileBrowserDataSourceTests.swift Treemux.xcodeproj
git commit -m "feat(services): LocalFileBrowserDataSource list + metadata"
```

## Task 2.4: Implement `LocalFileBrowserDataSource.readFile / writeFile`

**Files:**
- Modify: `Treemux/Services/FileBrowser/LocalFileBrowserDataSource.swift`
- Modify: `TreemuxTests/LocalFileBrowserDataSourceTests.swift` (add tests)

**Step 1: Add failing tests**

Append to `LocalFileBrowserDataSourceTests`:

```swift
    func testReadFileSmall() async throws {
        let file = tmpDir.appendingPathComponent("hello.txt")
        try "hello world".write(to: file, atomically: true, encoding: .utf8)
        let ds = LocalFileBrowserDataSource()
        let data = try await ds.readFile(file.path, maxBytes: 1024)
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello world")
    }

    func testReadFileTooLargeThrows() async throws {
        let file = tmpDir.appendingPathComponent("big.bin")
        try Data(repeating: 1, count: 5000).write(to: file)
        let ds = LocalFileBrowserDataSource()
        do {
            _ = try await ds.readFile(file.path, maxBytes: 1024)
            XCTFail("expected fileTooLarge")
        } catch FileBrowserError.fileTooLarge {
            // expected
        }
    }

    func testWriteFileAtomic() async throws {
        let file = tmpDir.appendingPathComponent("out.txt")
        let ds = LocalFileBrowserDataSource()
        try await ds.writeFile(file.path, data: "alpha".data(using: .utf8)!)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "alpha")
        // Overwrite
        try await ds.writeFile(file.path, data: "beta".data(using: .utf8)!)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "beta")
    }
```

**Step 2: Run tests to verify they fail**

Run: `... -only-testing:TreemuxTests/LocalFileBrowserDataSourceTests`
Expected: tests crash with "not yet implemented" or fail.

**Step 3: Replace stub implementations**

In `LocalFileBrowserDataSource.swift`, replace `readFile` and `writeFile`:

```swift
    func readFile(_ path: String, maxBytes: Int) async throws -> Data {
        try await runOnQueue {
            let url = URL(fileURLWithPath: path)
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs[.size] as? Int64) ?? 0
            if size > Int64(maxBytes) {
                throw FileBrowserError.fileTooLarge(path: path, sizeBytes: size, limit: Int64(maxBytes))
            }
            return try Data(contentsOf: url)
        }
    }

    func writeFile(_ path: String, data: Data) async throws {
        try await runOnQueue {
            let url = URL(fileURLWithPath: path)
            try data.write(to: url, options: .atomic)
        }
    }
```

**Step 4: Run tests**

Run: `... -only-testing:TreemuxTests/LocalFileBrowserDataSourceTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add Treemux/Services/FileBrowser/LocalFileBrowserDataSource.swift TreemuxTests/LocalFileBrowserDataSourceTests.swift
git commit -m "feat(services): LocalFileBrowserDataSource read/write"
```

---

# Phase 3 — File classification

## Task 3.1: `FileTypeClassifier` for view dispatch

**Files:**
- Create: `Treemux/Services/FileBrowser/FileTypeClassifier.swift`
- Test: `TreemuxTests/FileTypeClassifierTests.swift`

**Step 1: Write the failing test**

```swift
// TreemuxTests/FileTypeClassifierTests.swift
import XCTest
@testable import Treemux

final class FileTypeClassifierTests: XCTestCase {
    func testTextByExtension() {
        XCTAssertEqual(FileTypeClassifier.classifyByName("README.md"), .text)
        XCTAssertEqual(FileTypeClassifier.classifyByName("foo.swift"), .text)
        XCTAssertEqual(FileTypeClassifier.classifyByName("data.json"), .text)
        XCTAssertEqual(FileTypeClassifier.classifyByName("a.txt"), .text)
        XCTAssertEqual(FileTypeClassifier.classifyByName("a.YML"), .text)
    }

    func testImageByExtension() {
        XCTAssertEqual(FileTypeClassifier.classifyByName("a.png"), .image)
        XCTAssertEqual(FileTypeClassifier.classifyByName("foo.JPG"), .image)
        XCTAssertEqual(FileTypeClassifier.classifyByName("anim.gif"), .image)
        XCTAssertEqual(FileTypeClassifier.classifyByName("photo.heic"), .image)
        XCTAssertEqual(FileTypeClassifier.classifyByName("vector.svg"), .image)
    }

    func testQuickLookByExtension() {
        XCTAssertEqual(FileTypeClassifier.classifyByName("doc.pdf"), .quickLook)
        XCTAssertEqual(FileTypeClassifier.classifyByName("clip.mp4"), .quickLook)
        XCTAssertEqual(FileTypeClassifier.classifyByName("song.mp3"), .quickLook)
        XCTAssertEqual(FileTypeClassifier.classifyByName("doc.docx"), .quickLook)
    }

    func testUnknownByExtension() {
        XCTAssertEqual(FileTypeClassifier.classifyByName("a.exe"), .binary)
        XCTAssertEqual(FileTypeClassifier.classifyByName("noext"), .unknown)
    }

    func testTextSniffOnUtf8Bytes() {
        let utf8 = "Hello 你好\nworld".data(using: .utf8)!
        XCTAssertEqual(FileTypeClassifier.classifyByContent(utf8), .text)
    }

    func testBinarySniffOnNullBytes() {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(FileTypeClassifier.classifyByContent(bytes), .binary)
    }
}
```

**Step 2: Run to confirm failure**

Run: `... -only-testing:TreemuxTests/FileTypeClassifierTests`
Expected: compile error.

**Step 3: Implement**

```swift
// Treemux/Services/FileBrowser/FileTypeClassifier.swift
import Foundation

enum FileViewKind: Equatable {
    case text
    case image
    case quickLook
    case binary
    case unknown
}

enum FileTypeClassifier {
    private static let textExts: Set<String> = [
        "txt", "md", "markdown", "rst", "log",
        "swift", "h", "m", "mm", "c", "cc", "cpp", "hpp", "rs", "go", "java", "kt", "py", "rb", "js", "jsx", "ts", "tsx", "css", "scss", "html", "xml", "json", "yaml", "yml", "toml", "ini", "conf", "sh", "zsh", "bash", "fish", "lua", "vim",
        "gitignore", "gitattributes", "env", "dockerfile", "makefile",
        "plist", "xcconfig", "pbxproj", "podspec",
        "csv", "tsv", "sql"
    ]

    private static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "svg", "ico"
    ]

    private static let quickLookExts: Set<String> = [
        "pdf",
        "mp4", "mov", "m4v", "avi", "mkv",
        "mp3", "wav", "aiff", "m4a", "flac",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key",
        "rtf", "rtfd"
    ]

    static func classifyByName(_ filename: String) -> FileViewKind {
        let lower = filename.lowercased()
        // Special filenames without extensions.
        let basename = (lower as NSString).lastPathComponent
        if ["dockerfile", "makefile", "rakefile", "gemfile", "podfile", "license", "readme", "changelog", "authors", "contributors"].contains(basename) {
            return .text
        }
        let ext = (lower as NSString).pathExtension
        if ext.isEmpty { return .unknown }
        if textExts.contains(ext) { return .text }
        if imageExts.contains(ext) { return .image }
        if quickLookExts.contains(ext) { return .quickLook }
        // Anything else with a known extension is treated as binary by default.
        return .binary
    }

    /// Sniff up to 8 KB to decide text vs. binary (null bytes => binary).
    static func classifyByContent(_ data: Data) -> FileViewKind {
        let sample = data.prefix(8192)
        if sample.contains(0) { return .binary }
        if String(data: sample, encoding: .utf8) != nil { return .text }
        return .binary
    }
}
```

**Step 4: Regenerate & run test**

Run: `... test -only-testing:TreemuxTests/FileTypeClassifierTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add Treemux/Services/FileBrowser/FileTypeClassifier.swift TreemuxTests/FileTypeClassifierTests.swift Treemux.xcodeproj
git commit -m "feat(services): FileTypeClassifier"
```

---

# Phase 4 — File browser tab controller

## Task 4.1: `OpenFileState` enum + scaffold `FileBrowserTabController`

**Files:**
- Create: `Treemux/UI/FileBrowser/OpenFileState.swift`
- Create: `Treemux/UI/FileBrowser/FileBrowserTabController.swift`

**Step 1: Implement `OpenFileState`**

```swift
// Treemux/UI/FileBrowser/OpenFileState.swift
import AppKit
import Foundation

enum OpenFileState: Equatable {
    case empty
    case loadingMeta(path: String)
    case loadingContent(path: String)
    case confirmingLargeFile(path: String, sizeBytes: Int64)
    case text(path: String, content: String, encoding: String.Encoding, dirty: Bool)
    case image(path: String, image: NSImage)
    case quickLook(path: String, localFileURL: URL)
    case binary(path: String, metadata: FileMetadata)
    case error(path: String, message: String)

    static func == (lhs: OpenFileState, rhs: OpenFileState) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .empty): return true
        case (.loadingMeta(let a), .loadingMeta(let b)): return a == b
        case (.loadingContent(let a), .loadingContent(let b)): return a == b
        case (.confirmingLargeFile(let a, let s1), .confirmingLargeFile(let b, let s2)):
            return a == b && s1 == s2
        case (.text(let a1, let c1, let e1, let d1), .text(let a2, let c2, let e2, let d2)):
            return a1 == a2 && c1 == c2 && e1 == e2 && d1 == d2
        case (.image(let a, _), .image(let b, _)): return a == b
        case (.quickLook(let a, _), .quickLook(let b, _)): return a == b
        case (.binary(let a, let m1), .binary(let b, let m2)): return a == b && m1 == m2
        case (.error(let a, let m1), .error(let b, let m2)): return a == b && m1 == m2
        default: return false
        }
    }
}
```

**Step 2: Implement controller scaffold**

```swift
// Treemux/UI/FileBrowser/FileBrowserTabController.swift
import AppKit
import Combine
import Foundation

@MainActor
final class FileBrowserTabController: ObservableObject {
    // Persistent state mirrors / writes back to FileBrowserTabState.
    @Published var rootPath: String
    @Published private(set) var rootKind: FileBrowserRootKind
    @Published var splitRatio: Double
    @Published var expandedDirs: Set<String>
    @Published var showsHiddenFiles: Bool

    // Runtime state.
    @Published private(set) var rootChildren: [FileNode] = []
    @Published private(set) var childrenByPath: [String: [FileNode]] = [:]
    @Published private(set) var selectedFilePath: String?
    @Published private(set) var openFile: OpenFileState = .empty
    @Published private(set) var loadingPaths: Set<String> = []

    // Configuration.
    static let textReadLimit: Int = 5 * 1024 * 1024       // 5 MB
    static let largeFileThreshold: Int64 = 5 * 1024 * 1024 // 5 MB
    static let quickLookOnlyThreshold: Int64 = 100 * 1024 * 1024 // 100 MB

    let dataSource: any FileBrowserDataSource

    /// Called when the persistent state should be written back into
    /// `WorkspaceTabStateRecord.fileBrowserState` (debounced by caller).
    var onPersistableStateChanged: (() -> Void)?

    init(initial state: FileBrowserTabState, dataSource: any FileBrowserDataSource) {
        self.rootPath = state.rootPath
        self.rootKind = state.rootKind
        self.splitRatio = state.splitRatio
        self.expandedDirs = Set(state.expandedDirs)
        self.showsHiddenFiles = state.showsHiddenFiles
        self.selectedFilePath = state.selectedFilePath
        self.dataSource = dataSource
    }

    func snapshot() -> FileBrowserTabState {
        FileBrowserTabState(
            rootPath: rootPath,
            rootKind: rootKind,
            selectedFilePath: selectedFilePath,
            splitRatio: splitRatio,
            expandedDirs: Array(expandedDirs),
            showsHiddenFiles: showsHiddenFiles
        )
    }
}
```

**Step 3: Build**

```bash
xcodegen generate
xcodebuild ... build
```
Expected: BUILD SUCCEEDED.

**Step 4: Commit**

```bash
git add Treemux/UI/FileBrowser/ Treemux.xcodeproj
git commit -m "feat(ui): scaffold FileBrowserTabController + OpenFileState"
```

## Task 4.2: Tree loading (`loadRoot`, `toggleExpand`)

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift`
- Test: `TreemuxTests/FileBrowserTabControllerTests.swift`

**Step 1: Write the failing test (with mock data source)**

```swift
// TreemuxTests/FileBrowserTabControllerTests.swift
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
```

**Step 2: Run to confirm failure**

Run: `... -only-testing:TreemuxTests/FileBrowserTabControllerTests`
Expected: compile error — `loadRoot` / `toggleExpand` undefined.

**Step 3: Implement methods**

Append to `FileBrowserTabController`:

```swift
    // MARK: - Tree loading

    func loadRoot() async {
        do {
            let children = try await dataSource.listDirectory(rootPath)
            self.rootChildren = filtered(children)
            self.childrenByPath[rootPath] = self.rootChildren
            // Restore previously-expanded dirs (best effort; missing dirs are silently skipped).
            for path in expandedDirs where path != rootPath {
                if (try? await dataSource.listDirectory(path)) != nil {
                    let kids = try await dataSource.listDirectory(path)
                    self.childrenByPath[path] = filtered(kids)
                }
            }
        } catch {
            self.rootChildren = []
        }
    }

    func toggleExpand(_ path: String) async {
        if expandedDirs.contains(path) {
            expandedDirs.remove(path)
            childrenByPath[path] = nil
        } else {
            loadingPaths.insert(path)
            defer { loadingPaths.remove(path) }
            do {
                let kids = try await dataSource.listDirectory(path)
                childrenByPath[path] = filtered(kids)
                expandedDirs.insert(path)
            } catch {
                // Leave collapsed on error; caller may surface a toast.
            }
        }
        onPersistableStateChanged?()
    }

    func setShowsHiddenFiles(_ show: Bool) {
        guard showsHiddenFiles != show else { return }
        showsHiddenFiles = show
        // Re-filter cached listings without re-fetching.
        for (key, value) in childrenByPath {
            childrenByPath[key] = filtered(value)
        }
        rootChildren = childrenByPath[rootPath] ?? []
        onPersistableStateChanged?()
    }

    func refresh(_ path: String) async {
        do {
            let kids = try await dataSource.listDirectory(path)
            childrenByPath[path] = filtered(kids)
            if path == rootPath { rootChildren = childrenByPath[path] ?? [] }
        } catch {
            // Silent on error; caller can surface UI.
        }
    }

    private func filtered(_ nodes: [FileNode]) -> [FileNode] {
        showsHiddenFiles ? nodes : nodes.filter { !$0.isHidden }
    }
```

**Step 4: Run tests**

Run: `... -only-testing:TreemuxTests/FileBrowserTabControllerTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift TreemuxTests/FileBrowserTabControllerTests.swift
git commit -m "feat(ui): file browser tree loading + expand/collapse"
```

## Task 4.3: `selectFile` state machine

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift`
- Modify: `TreemuxTests/FileBrowserTabControllerTests.swift`

**Step 1: Add failing tests**

Append to `FileBrowserTabControllerTests`:

```swift
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
```

**Step 2: Run to confirm failure**

Expected: compile error — `selectFile` undefined.

**Step 3: Implement**

```swift
    // MARK: - File selection

    func selectFile(_ path: String) async {
        // Dirty guard handled by the UI sheet before calling selectFile.
        selectedFilePath = path
        openFile = .loadingMeta(path: path)
        onPersistableStateChanged?()

        let meta: FileMetadata
        do {
            meta = try await dataSource.fileMetadata(path)
        } catch {
            openFile = .error(path: path, message: error.localizedDescription)
            return
        }

        // Force Quick Look for files larger than the absolute editor cap.
        if meta.sizeBytes > Self.quickLookOnlyThreshold {
            await loadQuickLook(path: path)
            return
        }
        // Prompt for files between large threshold and quickLookOnly threshold.
        if meta.sizeBytes > Self.largeFileThreshold {
            openFile = .confirmingLargeFile(path: path, sizeBytes: meta.sizeBytes)
            return
        }

        await dispatchByType(path: path, meta: meta)
    }

    /// Called from UI when user confirms the large-file prompt.
    func confirmLargeFileLoad() async {
        guard case .confirmingLargeFile(let path, _) = openFile else { return }
        do {
            let meta = try await dataSource.fileMetadata(path)
            await dispatchByType(path: path, meta: meta)
        } catch {
            openFile = .error(path: path, message: error.localizedDescription)
        }
    }

    /// Called from UI when user cancels the large-file prompt.
    func cancelLargeFileLoad() {
        openFile = .empty
        selectedFilePath = nil
    }

    private func dispatchByType(path: String, meta: FileMetadata) async {
        let kind = FileTypeClassifier.classifyByName(path)
        switch kind {
        case .text:
            await loadText(path: path)
        case .image:
            await loadImage(path: path)
        case .quickLook:
            await loadQuickLook(path: path)
        case .binary:
            openFile = .binary(path: path, metadata: meta)
        case .unknown:
            // Try a content sniff to upgrade unknowns into text where possible.
            await loadUnknown(path: path, meta: meta)
        }
    }

    private func loadText(path: String) async {
        openFile = .loadingContent(path: path)
        do {
            let data = try await dataSource.readFile(path, maxBytes: Self.textReadLimit)
            let (content, encoding) = decode(data)
            openFile = .text(path: path, content: content, encoding: encoding, dirty: false)
        } catch FileBrowserError.fileTooLarge(_, let size, _) {
            openFile = .confirmingLargeFile(path: path, sizeBytes: size)
        } catch {
            openFile = .error(path: path, message: error.localizedDescription)
        }
    }

    private func loadImage(path: String) async {
        openFile = .loadingContent(path: path)
        do {
            let data = try await dataSource.readFile(path, maxBytes: Int(Self.quickLookOnlyThreshold))
            if let img = NSImage(data: data) {
                openFile = .image(path: path, image: img)
            } else {
                openFile = .error(path: path, message: "Cannot decode image")
            }
        } catch {
            openFile = .error(path: path, message: error.localizedDescription)
        }
    }

    private func loadQuickLook(path: String) async {
        openFile = .loadingContent(path: path)
        do {
            let url = try await dataSource.downloadForQuickLook(path) { _ in }
            openFile = .quickLook(path: path, localFileURL: url)
        } catch {
            openFile = .error(path: path, message: error.localizedDescription)
        }
    }

    private func loadUnknown(path: String, meta: FileMetadata) async {
        do {
            let preview = try await dataSource.readFile(path, maxBytes: 8192)
            switch FileTypeClassifier.classifyByContent(preview) {
            case .text:
                await loadText(path: path)
            default:
                openFile = .binary(path: path, metadata: meta)
            }
        } catch {
            openFile = .binary(path: path, metadata: meta)
        }
    }

    /// Tries UTF-8 → GBK → Latin-1.
    private func decode(_ data: Data) -> (String, String.Encoding) {
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8) }
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: data, encoding: gbk) { return (s, gbk) }
        return (String(data: data, encoding: .isoLatin1) ?? "", .isoLatin1)
    }
```

**Step 4: Run tests**

Run: `... -only-testing:TreemuxTests/FileBrowserTabControllerTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift TreemuxTests/FileBrowserTabControllerTests.swift
git commit -m "feat(ui): file browser select+dispatch state machine"
```

## Task 4.4: Edit / save / dirty tracking

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift`
- Modify: `TreemuxTests/FileBrowserTabControllerTests.swift`

**Step 1: Add failing tests**

Append:

```swift
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
```

**Step 2: Run to confirm failure**

Expected: compile errors.

**Step 3: Implement**

Append to `FileBrowserTabController`:

```swift
    // MARK: - Edit / save

    var isDirty: Bool {
        if case .text(_, _, _, let dirty) = openFile { return dirty }
        return false
    }

    /// Updates the in-memory buffer for the currently open text file.
    func updateBuffer(content: String) {
        guard case .text(let path, _, let encoding, _) = openFile else { return }
        openFile = .text(path: path, content: content, encoding: encoding, dirty: true)
    }

    /// Saves the current buffer back to disk via the data source.
    func saveCurrentFile() async throws {
        guard case .text(let path, let content, let encoding, _) = openFile else {
            return
        }
        let data = content.data(using: encoding) ?? Data()
        try await dataSource.writeFile(path, data: data)
        openFile = .text(path: path, content: content, encoding: encoding, dirty: false)
    }
```

**Step 4: Run tests**

Run: `... -only-testing:TreemuxTests/FileBrowserTabControllerTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift TreemuxTests/FileBrowserTabControllerTests.swift
git commit -m "feat(ui): file browser edit + save"
```

---

# Phase 5 — WorkspaceModel integration

## Task 5.1: Add `createFileBrowserTab` + `fileBrowserController(forTabID:)`

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift`
- Test: `TreemuxTests/WorkspaceModelTabKindTests.swift`

**Step 1: Write failing test**

```swift
// TreemuxTests/WorkspaceModelTabKindTests.swift
import XCTest
@testable import Treemux

@MainActor
final class WorkspaceModelTabKindTests: XCTestCase {
    func testCreateFileBrowserTabAppendsAndActivates() {
        let model = WorkspaceModel(
            name: "tmp",
            kind: .repository,
            repositoryRoot: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        let initialCount = model.tabs.count
        model.createFileBrowserTab(rootPath: NSTemporaryDirectory(), rootKind: .worktree, title: "Files")
        XCTAssertEqual(model.tabs.count, initialCount + 1)
        let last = model.tabs.last!
        XCTAssertEqual(last.kind, .fileBrowser)
        XCTAssertNotNil(last.fileBrowserState)
        XCTAssertEqual(model.activeTabID, last.id)
    }

    func testFileBrowserTabRoundTripsThroughRecord() {
        let model = WorkspaceModel(
            name: "tmp",
            kind: .repository,
            repositoryRoot: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        model.createFileBrowserTab(rootPath: "/x", rootKind: .project, title: "Files")
        let record = model.toRecord()
        let restored = WorkspaceModel(from: record)
        let fbTab = restored.tabs.first { $0.kind == .fileBrowser }
        XCTAssertNotNil(fbTab)
        XCTAssertEqual(fbTab?.fileBrowserState?.rootPath, "/x")
    }
}
```

**Step 2: Run to confirm failure**

Expected: compile error — `createFileBrowserTab` undefined.

**Step 3: Modify `WorkspaceModel`**

In `Treemux/Domain/WorkspaceModels.swift`, add field for file browser controllers and a creation method.

Add a property near `private var tabControllers` (around line 198):

```swift
    /// File browser controllers keyed by worktree path → tab ID.
    private var fileBrowserControllers: [String: [UUID: FileBrowserTabController]] = [:]
```

Add method (place after `createTab()`, around line 294):

```swift
    /// Creates a new file-browser tab and makes it active.
    func createFileBrowserTab(rootPath: String, rootKind: FileBrowserRootKind, title: String) {
        saveActiveTabState()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty ? URL(fileURLWithPath: rootPath).lastPathComponent : trimmed
        let newTab = WorkspaceTabStateRecord.makeFileBrowser(rootPath: rootPath, rootKind: rootKind, title: label)
        tabs.append(newTab)
        activeTabID = newTab.id
    }

    /// Returns or creates a file browser controller for the given tab.
    func fileBrowserController(forTabID tabID: UUID) -> FileBrowserTabController? {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              tab.kind == .fileBrowser,
              let state = tab.fileBrowserState else { return nil }
        let path = activeWorktreePath
        if let existing = fileBrowserControllers[path]?[tabID] { return existing }

        let dataSource: any FileBrowserDataSource = makeDataSource()
        let ctrl = FileBrowserTabController(initial: state, dataSource: dataSource)
        ctrl.onPersistableStateChanged = { [weak self] in
            self?.persistFileBrowserState(tabID: tabID)
        }
        if fileBrowserControllers[path] == nil { fileBrowserControllers[path] = [:] }
        fileBrowserControllers[path]?[tabID] = ctrl
        return ctrl
    }

    private func makeDataSource() -> any FileBrowserDataSource {
        if let target = sshTarget {
            return RemoteFileBrowserDataSource(sshTarget: target)
        }
        return LocalFileBrowserDataSource()
    }

    private func persistFileBrowserState(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              let ctrl = fileBrowserControllers[activeWorktreePath]?[tabID] else { return }
        var record = tabs[index]
        record.fileBrowserState = ctrl.snapshot()
        tabs[index] = record
    }
```

Update `closeTab` (around line 305) to also clean up the file browser controller:

```swift
    func closeTab(_ tabID: UUID) {
        saveActiveTabState()
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        let path = activeWorktreePath
        if let ctrl = tabControllers[path]?[tabID] {
            ctrl.terminateAll()
            tabControllers[path]?.removeValue(forKey: tabID)
        }
        // File browser controllers don't have terminal sessions to terminate;
        // just drop the reference so the next open re-creates fresh state.
        fileBrowserControllers[path]?.removeValue(forKey: tabID)

        tabs.remove(at: index)

        if tabs.isEmpty {
            activeTabID = nil
        } else if activeTabID == tabID {
            let newIndex = min(index, tabs.count - 1)
            activeTabID = tabs[newIndex].id
        }
    }
```

> Note: `RemoteFileBrowserDataSource` doesn't exist yet — Phase 6 adds it. The placeholder reference will fail to compile if you skip ahead. Add a temporary stub (next sub-step) to keep the build green.

**Step 4: Add a stub `RemoteFileBrowserDataSource`**

Create `Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift`:

```swift
// Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift
import Foundation

/// Stub implementation. Filled in during Phase 6.
final class RemoteFileBrowserDataSource: FileBrowserDataSource {
    let supportsWrite = true
    let sshTarget: SSHTarget

    init(sshTarget: SSHTarget) {
        self.sshTarget = sshTarget
    }

    func listDirectory(_ path: String) async throws -> [FileNode] { [] }
    func fileMetadata(_ path: String) async throws -> FileMetadata {
        FileMetadata(path: path, sizeBytes: 0, modifiedAt: nil, isDirectory: false, isSymbolicLink: false)
    }
    func readFile(_ path: String, maxBytes: Int) async throws -> Data { Data() }
    func writeFile(_ path: String, data: Data) async throws { }
    func downloadForQuickLook(_ path: String, progress: @escaping (Double) -> Void) async throws -> URL {
        URL(fileURLWithPath: path)
    }
}
```

**Step 5: Regenerate, build, and run all tests**

```bash
xcodegen generate
xcodebuild ... test
```
Expected: all tests pass.

**Step 6: Commit**

```bash
git add Treemux/Domain/WorkspaceModels.swift Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift TreemuxTests/WorkspaceModelTabKindTests.swift Treemux.xcodeproj
git commit -m "feat(domain): WorkspaceModel.createFileBrowserTab + controller wiring"
```

---

# Phase 6 — Remote (SFTP) data source

## Task 6.1: Extend `SFTPService` with file read/write & detailed listings

**Files:**
- Modify: `Treemux/Services/SFTP/SFTPService.swift`
- Modify: `Treemux/Services/SFTP/SFTPDirectoryEntry.swift`

**Step 1: Read current files**

Re-read `SFTPService.swift` and `SFTPDirectoryEntry.swift`. Existing methods only list directories — extend them to:
- list **all** entries (files + dirs + symlinks) with size & mtime
- read full file contents (Citadel: `sftp.openFile + readAll`; SSH path: `cat -- <esc>` falling back to `scp` for binary safety)
- write full file contents (Citadel: `sftp.openFile(write).write`; SSH path: write to temp via `tee`)
- stat a single path

**Step 2: Implement (high level — copy structure of existing list methods)**

Add to `SFTPDirectoryEntry.swift`:

```swift
struct SFTPRichEntry: Equatable {
    enum Kind: Equatable { case directory, file, symlink(target: String?) }
    let name: String
    let path: String
    let kind: Kind
    let sizeBytes: Int64?
    let modifiedAt: Date?
}

struct SFTPRichStat: Equatable {
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let sizeBytes: Int64
    let modifiedAt: Date?
}
```

Add to `SFTPService` (within the actor):

```swift
    /// List all entries (files + dirs + symlinks) at `path`.
    func listAllEntries(at path: String) async throws -> [SFTPRichEntry] {
        guard let mode else { throw SFTPServiceError.notConnected }
        switch mode {
        case .ssh(let target):
            return try await listAllEntriesViaSSH(target: target, path: path)
        case .citadel(_, let sftp):
            return try await listAllEntriesViaSFTP(sftp: sftp, path: path)
        }
    }

    func stat(_ path: String) async throws -> SFTPRichStat {
        guard let mode else { throw SFTPServiceError.notConnected }
        switch mode {
        case .ssh(let target):
            return try await statViaSSH(target: target, path: path)
        case .citadel(_, let sftp):
            return try await statViaSFTP(sftp: sftp, path: path)
        }
    }

    func readFile(at path: String, maxBytes: Int) async throws -> Data {
        guard let mode else { throw SFTPServiceError.notConnected }
        switch mode {
        case .ssh(let target):
            return try await readFileViaSSH(target: target, path: path, maxBytes: maxBytes)
        case .citadel(_, let sftp):
            return try await readFileViaSFTP(sftp: sftp, path: path, maxBytes: maxBytes)
        }
    }

    func writeFile(at path: String, data: Data) async throws {
        guard let mode else { throw SFTPServiceError.notConnected }
        switch mode {
        case .ssh(let target):
            try await writeFileViaSSH(target: target, path: path, data: data)
        case .citadel(_, let sftp):
            try await writeFileViaSFTP(sftp: sftp, path: path, data: data)
        }
    }
```

For each `via*` method use the same patterns established in this file:

- **Citadel paths** — use `sftp.openFile(...)`, `readAll`, `write` per Citadel API.
- **SSH paths** — use the existing `runSSH`/`runSSHRaw` helpers (or extend them) for `stat -c`/`stat -f`, `cat`, and `tee`.

> Implementation detail: For the SSH path, prefer `base64`-wrapped reads and `tee` writes so binary files survive newline mangling. Use the same shell-escape helper already in the file. For very large files (>10 MB), throw `fileTooLarge` before reading to avoid blowing memory.

**Step 3: Smoke test**

Build and run any existing SFTP-using flows manually (open a remote workspace) — listing should still work.

```bash
xcodebuild ... build
```
Expected: BUILD SUCCEEDED.

**Step 4: Commit**

```bash
git add Treemux/Services/SFTP/
git commit -m "feat(sftp): rich listing + read/write/stat"
```

> Caveat: There is no automated unit test for the remote path; coverage relies on manual smoke testing in Phase 11.

## Task 6.2: Replace `RemoteFileBrowserDataSource` stub with real impl

**Files:**
- Modify: `Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift`

**Step 1: Implement**

```swift
// Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift
import Foundation

final class RemoteFileBrowserDataSource: FileBrowserDataSource {
    let supportsWrite = true
    let sshTarget: SSHTarget
    private let service: SFTPService
    private var didConnect = false

    init(sshTarget: SSHTarget, service: SFTPService = SFTPService()) {
        self.sshTarget = sshTarget
        self.service = service
    }

    private func ensureConnected() async throws {
        if didConnect { return }
        try await service.connect(target: sshTarget)
        didConnect = true
    }

    func listDirectory(_ path: String) async throws -> [FileNode] {
        try await ensureConnected()
        let rich = try await service.listAllEntries(at: path)
        return rich.map { entry in
            let kind: FileNode.Kind = {
                switch entry.kind {
                case .directory: return .directory
                case .file: return .file
                case .symlink(let t): return .symlink(target: t)
                }
            }()
            return FileNode(id: entry.path, name: entry.name, path: entry.path,
                            kind: kind, sizeBytes: entry.sizeBytes, modifiedAt: entry.modifiedAt)
        }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func fileMetadata(_ path: String) async throws -> FileMetadata {
        try await ensureConnected()
        let s = try await service.stat(path)
        return FileMetadata(path: path, sizeBytes: s.sizeBytes, modifiedAt: s.modifiedAt,
                            isDirectory: s.isDirectory, isSymbolicLink: s.isSymlink)
    }

    func readFile(_ path: String, maxBytes: Int) async throws -> Data {
        try await ensureConnected()
        return try await service.readFile(at: path, maxBytes: maxBytes)
    }

    func writeFile(_ path: String, data: Data) async throws {
        try await ensureConnected()
        try await service.writeFile(at: path, data: data)
    }

    func downloadForQuickLook(_ path: String, progress: @escaping (Double) -> Void) async throws -> URL {
        try await ensureConnected()
        let data = try await service.readFile(at: path, maxBytes: 200 * 1024 * 1024)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        try data.write(to: url, options: .atomic)
        return url
    }
}
```

**Step 2: Build**

```bash
xcodebuild ... build
```
Expected: BUILD SUCCEEDED.

**Step 3: Commit**

```bash
git add Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift
git commit -m "feat(services): RemoteFileBrowserDataSource on SFTPService"
```

---

# Phase 7 — File browser UI views

## Task 7.1: `FileBrowserTabContentView` (HSplitView shell)

**Files:**
- Create: `Treemux/UI/FileBrowser/FileBrowserTabContentView.swift`

**Step 1: Implement**

```swift
// Treemux/UI/FileBrowser/FileBrowserTabContentView.swift
import SwiftUI

struct FileBrowserTabContentView: View {
    @ObservedObject var controller: FileBrowserTabController

    var body: some View {
        HSplitView {
            FileTreePanelView(controller: controller)
                .frame(minWidth: 180, idealWidth: 240, maxWidth: 480)
            FileViewerPanelView(controller: controller)
                .frame(minWidth: 200)
        }
        .task {
            await controller.loadRoot()
        }
    }
}
```

**Step 2: Build (will require placeholder views)**

```bash
xcodegen generate
xcodebuild ... build
```
Expected: build fails — referenced views don't exist yet.

**Step 3: Add stub views to keep build green**

Create `Treemux/UI/FileBrowser/FileTreePanelView.swift`:

```swift
import SwiftUI

struct FileTreePanelView: View {
    @ObservedObject var controller: FileBrowserTabController
    var body: some View {
        Text("File tree placeholder")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

Create `Treemux/UI/FileBrowser/FileViewerPanelView.swift`:

```swift
import SwiftUI

struct FileViewerPanelView: View {
    @ObservedObject var controller: FileBrowserTabController
    var body: some View {
        Text("File viewer placeholder")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

**Step 4: Build**

```bash
xcodegen generate
xcodebuild ... build
```
Expected: BUILD SUCCEEDED.

**Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/ Treemux.xcodeproj
git commit -m "feat(ui): file browser tab content shell + placeholder panels"
```

## Task 7.2: Wire `WorkspaceDetailView` to dispatch by tab kind

**Files:**
- Modify: `Treemux/UI/Workspace/WorkspaceDetailView.swift`

**Step 1: Read current dispatch (lines 22-44) and replace**

```swift
private struct WorkspaceTabContainerView: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            if workspace.tabs.count > 1 {
                WorkspaceTabBarView(workspace: workspace)
            }

            if let tabID = workspace.activeTabID,
               let tab = workspace.tabs.first(where: { $0.id == tabID }) {
                Group {
                    switch tab.kind {
                    case .terminal:
                        if let controller = workspace.sessionController {
                            WorkspaceSessionDetailView(
                                controller: controller,
                                onCloseTab: { workspace.closeTab(tabID) }
                            )
                        }
                    case .fileBrowser:
                        if let controller = workspace.fileBrowserController(forTabID: tabID) {
                            FileBrowserTabContentView(controller: controller)
                        }
                    }
                }
                .id(tabID)
            } else {
                EmptyTabStateView { workspace.createTab() }
            }
        }
    }
}
```

**Step 2: Build**

```bash
xcodebuild ... build
```
Expected: BUILD SUCCEEDED.

**Step 3: Commit**

```bash
git add Treemux/UI/Workspace/WorkspaceDetailView.swift
git commit -m "feat(ui): dispatch tab content by WorkspaceTabKind"
```

## Task 7.3: `FileTreePanelView` — outline rendering with expand/collapse

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileTreePanelView.swift`

**Step 1: Implement**

Replace the placeholder with a SwiftUI `List`-based hierarchical tree (DisclosureGroup is not great for huge trees; we'll start with `OutlineGroup` since it's adequate at this scale and integrates cleanly).

```swift
import SwiftUI

struct FileTreePanelView: View {
    @ObservedObject var controller: FileBrowserTabController

    var body: some View {
        VStack(spacing: 0) {
            FileTreeToolbar(controller: controller)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.rootChildren, id: \.id) { node in
                        NodeRow(node: node, depth: 0, controller: controller)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct FileTreeToolbar: View {
    @ObservedObject var controller: FileBrowserTabController

    var body: some View {
        HStack(spacing: 8) {
            Text(URL(fileURLWithPath: controller.rootPath).lastPathComponent)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                Task { await controller.refresh(controller.rootPath) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help(LocalizedStringKey("Refresh"))

            Button {
                controller.setShowsHiddenFiles(!controller.showsHiddenFiles)
            } label: {
                Image(systemName: controller.showsHiddenFiles ? "eye" : "eye.slash")
            }
            .buttonStyle(.plain)
            .help(LocalizedStringKey("Toggle Hidden Files"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

private struct NodeRow: View {
    let node: FileNode
    let depth: Int
    @ObservedObject var controller: FileBrowserTabController
    @State private var isHovered = false

    private var isSelected: Bool { controller.selectedFilePath == node.path }
    private var isExpanded: Bool { controller.expandedDirs.contains(node.path) }
    private var children: [FileNode]? { controller.childrenByPath[node.path] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if isExpanded, let kids = children {
                ForEach(kids, id: \.id) { child in
                    NodeRow(node: child, depth: depth + 1, controller: controller)
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 4) {
            Spacer().frame(width: CGFloat(depth) * 14)
            if node.isDirectory {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 12)
            } else {
                Spacer().frame(width: 12)
            }
            Image(systemName: iconName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(node.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.25)
                      : isHovered ? Color.primary.opacity(0.06)
                      : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            if node.isDirectory {
                Task { await controller.toggleExpand(node.path) }
            } else {
                Task { await controller.selectFile(node.path) }
            }
        }
    }

    private var iconName: String {
        switch node.kind {
        case .directory: return isExpanded ? "folder.fill" : "folder"
        case .symlink: return "arrow.up.right.square"
        case .file:
            switch FileTypeClassifier.classifyByName(node.name) {
            case .text: return "doc.text"
            case .image: return "photo"
            case .quickLook: return "doc.richtext"
            case .binary: return "doc"
            case .unknown: return "doc"
            }
        }
    }
}
```

**Step 2: Build**

```bash
xcodebuild ... build
```
Expected: BUILD SUCCEEDED.

**Step 3: Commit**

```bash
git add Treemux/UI/FileBrowser/FileTreePanelView.swift
git commit -m "feat(ui): file tree panel with expand/collapse"
```

## Task 7.4: `FileViewerPanelView` — dispatching shell with welcome state

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileViewerPanelView.swift`

**Step 1: Implement**

```swift
import SwiftUI

struct FileViewerPanelView: View {
    @ObservedObject var controller: FileBrowserTabController

    var body: some View {
        Group {
            switch controller.openFile {
            case .empty:
                EmptyViewerState(rootPath: controller.rootPath)
            case .loadingMeta(let p), .loadingContent(let p):
                LoadingViewerState(path: p)
            case .confirmingLargeFile(let path, let size):
                LargeFileConfirmView(path: path, sizeBytes: size,
                                     onConfirm: { Task { await controller.confirmLargeFileLoad() } },
                                     onCancel: { controller.cancelLargeFileLoad() })
            case .text(let path, let content, let encoding, let dirty):
                TextEditorView(path: path, content: content, encoding: encoding, dirty: dirty, controller: controller)
            case .image(let path, let img):
                ImagePreviewView(path: path, image: img)
            case .quickLook(let path, let url):
                QuickLookViewerView(path: path, url: url)
            case .binary(let path, let meta):
                BinaryInfoView(path: path, metadata: meta)
            case .error(let path, let msg):
                ErrorViewerState(path: path, message: msg)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct EmptyViewerState: View {
    let rootPath: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 36))
            Text(LocalizedStringKey("Select a file from the tree"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LoadingViewerState: View {
    let path: String
    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ErrorViewerState: View {
    let path: String
    let message: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            Text(message).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

**Step 2: Build (will fail — sub-views missing)**

Create stubs to compile:

`Treemux/UI/FileBrowser/TextEditorView.swift`:
```swift
import SwiftUI

struct TextEditorView: View {
    let path: String
    let content: String
    let encoding: String.Encoding
    let dirty: Bool
    @ObservedObject var controller: FileBrowserTabController
    var body: some View {
        Text("Text editor placeholder for \(path)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

`Treemux/UI/FileBrowser/ImagePreviewView.swift`:
```swift
import SwiftUI

struct ImagePreviewView: View {
    let path: String
    let image: NSImage
    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.05))
    }
}
```

`Treemux/UI/FileBrowser/QuickLookViewerView.swift`:
```swift
import SwiftUI
import Quartz

struct QuickLookViewerView: NSViewRepresentable {
    let path: String
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        v.previewItem = url as QLPreviewItem
        v.autostarts = true
        return v
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        if (nsView.previewItem as? URL) != url {
            nsView.previewItem = url as QLPreviewItem
        }
    }
}
```

`Treemux/UI/FileBrowser/BinaryInfoView.swift`:
```swift
import SwiftUI

struct BinaryInfoView: View {
    let path: String
    let metadata: FileMetadata
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey("Binary file"))
                .font(.title3.bold())
            HStack { Text(LocalizedStringKey("Path:")); Text(path).foregroundStyle(.secondary) }
            HStack { Text(LocalizedStringKey("Size:")); Text("\(metadata.sizeBytes) bytes").foregroundStyle(.secondary) }
            if let m = metadata.modifiedAt {
                HStack { Text(LocalizedStringKey("Modified:")); Text(m.formatted()).foregroundStyle(.secondary) }
            }
            if let url = URL(string: "file://\(path)") {
                Button(LocalizedStringKey("Reveal in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
```

`Treemux/UI/FileBrowser/LargeFileConfirmView.swift`:
```swift
import SwiftUI

struct LargeFileConfirmView: View {
    let path: String
    let sizeBytes: Int64
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var sizeMB: String {
        String(format: "%.1f", Double(sizeBytes) / (1024 * 1024))
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text(LocalizedStringKey("Large File"))
                .font(.headline)
            Text("\(URL(fileURLWithPath: path).lastPathComponent) — \(sizeMB) MB")
                .foregroundStyle(.secondary)
            HStack {
                Button(LocalizedStringKey("Cancel"), action: onCancel)
                Button(LocalizedStringKey("Open Anyway"), action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }
}
```

**Step 3: Build**

```bash
xcodegen generate
xcodebuild ... build
```
Expected: BUILD SUCCEEDED.

**Step 4: Commit**

```bash
git add Treemux/UI/FileBrowser/ Treemux.xcodeproj
git commit -m "feat(ui): file viewer panel + state-specific stubs"
```

## Task 7.5: Real `TextEditorView` with Runestone

**Files:**
- Modify: `Treemux/UI/FileBrowser/TextEditorView.swift`

**Step 1: Implement**

```swift
import SwiftUI
import Runestone

struct TextEditorView: View {
    let path: String
    let content: String
    let encoding: String.Encoding
    let dirty: Bool
    @ObservedObject var controller: FileBrowserTabController

    var body: some View {
        VStack(spacing: 0) {
            RunestoneEditor(text: content,
                            languageName: TextEditorView.languageHint(for: path),
                            onChange: { controller.updateBuffer(content: $0) },
                            onSave: { Task { try? await controller.saveCurrentFile() } })
            Divider()
            statusBar
        }
    }

    private var statusBar: some View {
        HStack {
            Text(URL(fileURLWithPath: path).lastPathComponent)
            if dirty {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            }
            Spacer()
            Text(encodingDisplay).foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.thinMaterial)
    }

    private var encodingDisplay: String {
        switch encoding {
        case .utf8: return "UTF-8"
        case .isoLatin1: return "Latin-1"
        default: return "Encoding"
        }
    }

    static func languageHint(for path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }
}

/// AppKit bridge for Runestone's TextView.
struct RunestoneEditor: NSViewRepresentable {
    let text: String
    let languageName: String?
    let onChange: (String) -> Void
    let onSave: () -> Void

    func makeNSView(context: Context) -> TextView {
        let tv = TextView()
        tv.text = text
        tv.showLineNumbers = true
        tv.editorDelegate = context.coordinator
        return tv
    }

    func updateNSView(_ nsView: TextView, context: Context) {
        if nsView.text != text {
            nsView.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, TextViewDelegate {
        let parent: RunestoneEditor
        init(parent: RunestoneEditor) { self.parent = parent }

        func textViewDidChange(_ textView: TextView) {
            parent.onChange(textView.text)
        }

        func textView(_ textView: TextView, doCommandBy selector: Selector) -> Bool {
            // Cmd+S → save
            if selector == #selector(NSResponder.insertNewline(_:)) { return false }
            return false
        }
    }
}
```

> Real Cmd+S routing: handle via menu command in Phase 8 / SwiftUI focused values, not inside Runestone's selector.

**Step 2: Build**

```bash
xcodebuild ... build
```
Expected: BUILD SUCCEEDED. (If Runestone API has shifted, adjust the `TextView`/`TextViewDelegate` calls per their README — keep the public surface of `RunestoneEditor` stable.)

**Step 3: Commit**

```bash
git add Treemux/UI/FileBrowser/TextEditorView.swift
git commit -m "feat(ui): Runestone-based text editor"
```

---

# Phase 8 — Save shortcut + dirty close prompt

## Task 8.1: Cmd+S binding via SwiftUI focused command

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabContentView.swift`
- Modify: `Treemux/AppDelegate.swift` (Edit menu — add Save item)

**Step 1: Add a focused-state-driven Save menu item**

In `AppDelegate.swift`, find the Edit menu construction (around lines 100-110) and add at the end of the Edit menu:

```swift
        editMenu.addItem(.separator())
        let saveFileItem = NSMenuItem(title: "Save", action: #selector(saveCurrentFile), keyEquivalent: "s")
        saveFileItem.keyEquivalentModifierMask = [.command]
        saveFileItem.target = self
        editMenu.addItem(saveFileItem)
```

Add the action method (somewhere near the other `@objc` methods):

```swift
    @objc private func saveCurrentFile() {
        NotificationCenter.default.post(name: .treemuxSaveCurrentFile, object: nil)
    }
```

**Step 2: Add the notification name**

Create or extend `Treemux/Support/Notifications.swift` (if it exists; otherwise add to a sensible Support file). If creating a new file:

```swift
import Foundation

extension Notification.Name {
    static let treemuxSaveCurrentFile = Notification.Name("treemux.saveCurrentFile")
}
```

**Step 3: Listen in `FileBrowserTabContentView`**

Add the `.onReceive` handler:

```swift
        .onReceive(NotificationCenter.default.publisher(for: .treemuxSaveCurrentFile)) { _ in
            Task { try? await controller.saveCurrentFile() }
        }
```

**Step 4: Build**

```bash
xcodegen generate
xcodebuild ... build
```
Expected: BUILD SUCCEEDED.

**Step 5: Commit**

```bash
git add Treemux/AppDelegate.swift Treemux/Support/Notifications.swift Treemux/UI/FileBrowser/FileBrowserTabContentView.swift Treemux.xcodeproj
git commit -m "feat(ui): Cmd+S triggers file browser save"
```

> Note: The Save menu item is global; it fires regardless of focus. The notification handler in `FileBrowserTabContentView` only acts when a file browser tab is active — if no file is open, `saveCurrentFile()` becomes a no-op. This is acceptable because terminals don't claim Cmd+S, and an inactive file browser tab won't observe the notification (the view is unmounted by the kind dispatch).

## Task 8.2: Dirty-close confirmation sheet

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabContentView.swift`
- Modify: `Treemux/UI/Workspace/WorkspaceTabBarView.swift`

**Step 1: Add a confirm flow on the controller**

Append to `FileBrowserTabController`:

```swift
    @Published var pendingClose: PendingCloseAction?

    enum PendingCloseAction: Equatable {
        case closeTab(UUID)
        case switchFile(String)
    }

    /// Returns true if the action can proceed immediately; false if the UI
    /// should display a "save / discard / cancel" sheet (set as `pendingClose`).
    func requestClose(_ action: PendingCloseAction) -> Bool {
        if !isDirty { return true }
        pendingClose = action
        return false
    }

    func resolvePendingClose(_ choice: CloseChoice) async -> PendingCloseAction? {
        guard let action = pendingClose else { return nil }
        pendingClose = nil
        switch choice {
        case .save:
            do { try await saveCurrentFile() } catch { return nil }
        case .discard:
            // Reset dirty state by reverting buffer.
            if case .text(let p, _, let e, _) = openFile {
                openFile = .text(path: p, content: contentBackup ?? "", encoding: e, dirty: false)
            }
        case .cancel:
            return nil
        }
        return action
    }

    enum CloseChoice { case save, discard, cancel }

    private var contentBackup: String?
```

**Step 2: Capture buffer backup on selectFile**

Update `loadText` to record `contentBackup`:

```swift
    private func loadText(path: String) async {
        openFile = .loadingContent(path: path)
        do {
            let data = try await dataSource.readFile(path, maxBytes: Self.textReadLimit)
            let (content, encoding) = decode(data)
            contentBackup = content
            openFile = .text(path: path, content: content, encoding: encoding, dirty: false)
        } catch FileBrowserError.fileTooLarge(_, let size, _) {
            openFile = .confirmingLargeFile(path: path, sizeBytes: size)
        } catch {
            openFile = .error(path: path, message: error.localizedDescription)
        }
    }
```

**Step 3: Hook `WorkspaceTabBarView`'s tab close to consult the controller**

This is the trickiest integration. In `WorkspaceTabBarView.swift`, change the `onClose:` callback for tab buttons (lines 38-44) to consult the model first:

```swift
                                onClose: {
                                    workspace.requestCloseTab(tab.id)
                                },
```

In `WorkspaceModel`, add:

```swift
    /// Tries to close the tab. If the file browser controller for that tab is
    /// dirty, sets a pending action and posts a notification; the UI shows a
    /// sheet that calls `resolvePendingTabClose(...)`.
    func requestCloseTab(_ tabID: UUID) {
        if let tab = tabs.first(where: { $0.id == tabID }), tab.kind == .fileBrowser,
           let ctrl = fileBrowserControllers[activeWorktreePath]?[tabID],
           !ctrl.requestClose(.closeTab(tabID)) {
            // Sheet is now pending; UI will route the user's choice back via
            // resolvePendingTabClose.
            return
        }
        closeTab(tabID)
    }

    func resolvePendingTabClose(_ tabID: UUID, choice: FileBrowserTabController.CloseChoice) async {
        guard let ctrl = fileBrowserControllers[activeWorktreePath]?[tabID] else { return }
        if let action = await ctrl.resolvePendingClose(choice),
           case .closeTab(let id) = action {
            closeTab(id)
        }
    }
```

Render the sheet in `FileBrowserTabContentView`:

```swift
        .sheet(item: pendingCloseBinding) { action in
            DirtyCloseSheet(
                onSave: { Task { await resolveCurrentTab(.save, action: action) } },
                onDiscard: { Task { await resolveCurrentTab(.discard, action: action) } },
                onCancel: { Task { await resolveCurrentTab(.cancel, action: action) } }
            )
        }
```

(Add the binding helpers and `DirtyCloseSheet` struct in the same file — model after existing `Sheets/` patterns.)

**Step 4: Build & smoke test compile**

```bash
xcodebuild ... build
```
Expected: BUILD SUCCEEDED.

**Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/ Treemux/UI/Workspace/WorkspaceTabBarView.swift Treemux/Domain/WorkspaceModels.swift
git commit -m "feat(ui): dirty close prompt for file browser tabs"
```

---

# Phase 9 — Sidebar buttons + Cmd+Shift+T

## Task 9.1: Add hover-revealed file browser button to sidebar rows

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarNodeRow.swift`

**Step 1: Implement**

Add to `WorkspaceRowContent`'s `HStack` (after the `Spacer()` at line 87) **before** the closing brace, the trailing button:

```swift
            if isHovered {
                Button {
                    let root = workspace.repositoryRoot?.path ?? workspace.activeWorktreePath
                    workspace.createFileBrowserTab(rootPath: root, rootKind: .project,
                                                  title: workspace.name)
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(LocalizedStringKey("Open File Browser"))
                .padding(.trailing, 2)
            }
```

Mirror the same in `WorktreeRowContent` (after its `Spacer()` at line 138):

```swift
            if isHovered {
                Button {
                    workspace.createFileBrowserTab(rootPath: worktree.path.path, rootKind: .worktree,
                                                  title: worktree.path.lastPathComponent)
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(LocalizedStringKey("Open File Browser"))
                .padding(.trailing, 2)
            }
```

**Step 2: Build**

```bash
xcodebuild ... build
```
Expected: BUILD SUCCEEDED.

**Step 3: Commit**

```bash
git add Treemux/UI/Sidebar/SidebarNodeRow.swift
git commit -m "feat(sidebar): hover-revealed file browser button"
```

## Task 9.2: Add `ShortcutAction.newFileBrowserTab`

**Files:**
- Modify: `Treemux/Domain/ShortcutAction.swift`
- Modify: `Treemux/AppDelegate.swift`

**Step 1: Extend `ShortcutAction`**

In `Treemux/Domain/ShortcutAction.swift`, add `newFileBrowserTab` to the enum (around line 35), category mapping (around line 52), title (around line 66), subtitle (around line 85), and default shortcut (around line 108):

```swift
    case newFileBrowserTab
```

```swift
        case .newTab, .newFileBrowserTab, .closeTab, .nextTab, .previousTab:
            return .tabs
```

```swift
        case .newFileBrowserTab: return "New File Browser Tab"
```

```swift
        case .newFileBrowserTab: return "Create a new file browser tab for the selected worktree."
```

```swift
        case .newFileBrowserTab:
            return StoredShortcut(key: "t", command: true, shift: true, option: false, control: false)
```

**Step 2: Wire in main menu**

In `AppDelegate.swift`, after `newTabItem` registration (around line 161), add:

```swift
        let newFBTabItem = NSMenuItem(title: "New File Browser Tab", action: #selector(newFileBrowserTab), keyEquivalent: "")
        newFBTabItem.target = self
        applyShortcut(.newFileBrowserTab, to: newFBTabItem)
        tabMenu.addItem(newFBTabItem)
```

Add the action method:

```swift
    @objc private func newFileBrowserTab() {
        guard let workspace = store?.selectedWorkspace else { return }
        let root: String
        let kind: FileBrowserRootKind
        if !workspace.activeWorktreePath.isEmpty {
            root = workspace.activeWorktreePath
            kind = .worktree
        } else if let r = workspace.repositoryRoot?.path {
            root = r
            kind = .project
        } else {
            return
        }
        let title = URL(fileURLWithPath: root).lastPathComponent
        workspace.createFileBrowserTab(rootPath: root, rootKind: kind, title: title)
    }
```

**Step 3: Build**

```bash
xcodebuild ... build
```
Expected: BUILD SUCCEEDED. The default shortcut is now Cmd+Shift+T.

**Step 4: Commit**

```bash
git add Treemux/Domain/ShortcutAction.swift Treemux/AppDelegate.swift
git commit -m "feat(shortcut): Cmd+Shift+T opens file browser tab"
```

## Task 9.3: Optional — register in command palette

**Files:**
- Modify: `Treemux/UI/Components/CommandPaletteView.swift`

**Step 1: Add a palette entry**

Look at the existing entries (the file shows a `createTab()` invocation around line 126). Mirror that pattern with a new entry:

```swift
                CommandPaletteCommand(
                    title: String(localized: "New File Browser Tab"),
                    subtitle: String(localized: "Open the active worktree as a file browser"),
                    shortcut: TreemuxKeyboardShortcuts.displayString(for: .newFileBrowserTab, in: settings),
                    action: {
                        guard let ws = store.selectedWorkspace else { return }
                        let root = ws.activeWorktreePath.isEmpty
                            ? (ws.repositoryRoot?.path ?? "")
                            : ws.activeWorktreePath
                        let kind: FileBrowserRootKind = ws.activeWorktreePath.isEmpty ? .project : .worktree
                        if !root.isEmpty {
                            ws.createFileBrowserTab(rootPath: root, rootKind: kind, title: URL(fileURLWithPath: root).lastPathComponent)
                        }
                    }
                ),
```

**Step 2: Build**

```bash
xcodebuild ... build
```
Expected: BUILD SUCCEEDED.

**Step 3: Commit**

```bash
git add Treemux/UI/Components/CommandPaletteView.swift
git commit -m "feat(palette): expose New File Browser Tab"
```

---

# Phase 10 — Tab bar visual differentiation

## Task 10.1: Show kind-specific icon and dirty dot in tab bar

**Files:**
- Modify: `Treemux/UI/Workspace/WorkspaceTabBarView.swift`

**Step 1: Add icon + dirty dot**

Inside `TabButton`'s body `HStack`, before `Text(tab.title)` (around line 105), insert:

```swift
                Image(systemName: tab.kind == .fileBrowser ? "folder" : "terminal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .tertiary)
```

For dirty dot, the tab record alone doesn't know dirty state; pass workspace down so the row can ask `workspace.fileBrowserController(forTabID: tab.id)?.isDirty`. Refactor:

- Change `TabButton` to receive `let isDirty: Bool` from its parent.
- In the parent `ForEach`, compute:

```swift
                let isDirty: Bool = {
                    guard tab.kind == .fileBrowser else { return false }
                    return workspace.fileBrowserController(forTabID: tab.id)?.isDirty ?? false
                }()
```

Inside the button body, after the icon:

```swift
                if isDirty {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                }
```

**Step 2: Build**

```bash
xcodebuild ... build
```
Expected: BUILD SUCCEEDED.

**Step 3: Commit**

```bash
git add Treemux/UI/Workspace/WorkspaceTabBarView.swift
git commit -m "feat(tabbar): kind icon + dirty dot for file browser tabs"
```

---

# Phase 11 — Localization

## Task 11.1: Add zh-Hans translations for new strings

**Files:**
- Modify: `Treemux/Localizable.xcstrings`

**Step 1: Audit new strings**

Run `grep -rn "LocalizedStringKey\|String(localized:" Treemux/UI/FileBrowser/ Treemux/UI/Sidebar/SidebarNodeRow.swift Treemux/UI/Components/CommandPaletteView.swift Treemux/AppDelegate.swift` and list every user-visible string that touched in Phases 7–10. The expected set:

- "Refresh"
- "Toggle Hidden Files"
- "Select a file from the tree"
- "Binary file"
- "Path:"
- "Size:"
- "Modified:"
- "Reveal in Finder"
- "Large File"
- "Cancel"
- "Open Anyway"
- "Open File Browser"
- "New File Browser Tab"
- "Open the active worktree as a file browser"
- "Save"

Plus shortcut titles registered in `ShortcutAction.swift`:
- "New File Browser Tab" (already counted above)
- "Create a new file browser tab for the selected worktree."

**Step 2: Open `Localizable.xcstrings` and add a `zh-Hans` translation for each string**

Suggested translations:

| Source | zh-Hans |
|---|---|
| Refresh | 刷新 |
| Toggle Hidden Files | 显示/隐藏隐藏文件 |
| Select a file from the tree | 从左侧选择一个文件 |
| Binary file | 二进制文件 |
| Path: | 路径： |
| Size: | 大小： |
| Modified: | 修改时间： |
| Reveal in Finder | 在 Finder 中显示 |
| Large File | 大文件 |
| Cancel | 取消 |
| Open Anyway | 仍然打开 |
| Open File Browser | 打开文件浏览器 |
| New File Browser Tab | 新建文件浏览器标签页 |
| Open the active worktree as a file browser | 把当前 worktree 作为文件浏览器打开 |
| Save | 保存 |
| Create a new file browser tab for the selected worktree. | 为选中的 worktree 创建一个新的文件浏览器标签页。 |

Apply by editing `Localizable.xcstrings` JSON or via Xcode's String Catalog editor.

**Step 3: Build (verify no missing translations diagnostic)**

```bash
xcodebuild ... build
```
Expected: BUILD SUCCEEDED, no String Catalog warnings.

**Step 4: Commit**

```bash
git add Treemux/Localizable.xcstrings
git commit -m "i18n: zh-Hans translations for file browser"
```

---

# Phase 12 — Manual smoke test

## Task 12.1: Build, run, and verify behaviour end to end

**Step 1: Clean build**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug clean build
```
Expected: BUILD SUCCEEDED.

**Step 2: Identify the DerivedData path**

```bash
ls -d ~/Library/Developer/Xcode/DerivedData/Treemux-* | head -1
```

Capture the suffix after `Treemux-` (e.g. `abcdef123`).

**Step 3: Tell the user the run command**

Surface this to 卡皮巴拉:

```
rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<id>/Build/Products/Debug/Treemux.app
```

Substitute `<id>` with the value from Step 2.

**Step 4: Manual checklist (the user should run through these — agent only verifies the build)**

- [ ] Open a local repository → hover Project row → file browser button appears → click → tab opens with tree
- [ ] Hover a Worktree row → button appears → click → tab opens at that worktree
- [ ] `Cmd+Shift+T` opens a file browser tab for the current worktree
- [ ] Click a small text file → editor loads, Cmd+S saves, file on disk reflects edit
- [ ] Edit a file but don't save → tab title shows dirty dot
- [ ] Try to close the tab while dirty → confirmation sheet (Save/Discard/Cancel)
- [ ] Click an image → preview shows
- [ ] Click a PDF → Quick Look renders inline
- [ ] Click a binary (e.g. an executable) → metadata view + Reveal in Finder
- [ ] Click a >5 MB file → confirmation prompt
- [ ] Click a >100 MB file → forced Quick Look (no confirm prompt)
- [ ] Connect a remote (SSH) workspace, repeat the above on remote files
- [ ] Quit and relaunch → file browser tab restored with same root and selected file
- [ ] Mix terminal tabs and file browser tabs in the same workspace; drag-reorder works; close from middle works

**Step 5: Final commit (if there are uncommitted polish fixes)**

```bash
git status
# if needed
git commit -am "chore: post-smoke-test polish"
```

---

# Done

Final deliverable:
- Branch `feat/file-browser-tab` in `.worktrees/feat+file-browser-tab/`
- All Phase 0-12 commits landed
- All XCTest tests passing
- Manual checklist verified
- 卡皮巴拉 informed of the run command

Hand-off to user for review and PR creation.
