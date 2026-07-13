# Feature 8 — New Folder / New File Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user create a new folder or empty file in place in the file tree — via a directory's right-click menu or a toolbar button — naming it with an inline (VSCode/Finder-style) editor row, on both local and remote workspaces.

**Architecture:** Add `createDirectory` / `createFile` to `FileBrowserDataSource` (with throwing protocol-extension defaults so existing test doubles keep compiling), implemented for local (`FileManager`) and remote (`SFTPService` mkdir / exclusive-create). The controller holds a single `NewEntryDraft` (target directory + folder/file intent + error), and `visibleRows()` injects an `.editor` row under the target directory. A focused `TextField` view commits (create → refresh) or cancels. New files are not auto-opened.

**Tech Stack:** Swift, SwiftUI, XCTest, Xcode (`Treemux.xcodeproj`), macOS, Citadel (SFTP fallback).

## Global Constraints

- **Worktree rule:** All code changes happen in a git worktree. Create it at execution start: `git worktree add -b feat/feature-8-new-file-folder .worktrees/feat+feature-8-new-file-folder main`. Main checkout stays on `main`. (If Feature 10 is being merged first, branch from the merged `main`.)
- **i18n:** every new user-visible string uses `LocalizedStringKey` (or `String(localized:)`) and gets a `zh-Hans` entry in `Treemux/Localizable.xcstrings`. New strings in this plan: `New Folder`, `New File`, `Name cannot be empty`, `Name cannot contain a slash`, `An item named "%@" already exists`.
- **No hardcoded colors** — the editor row uses existing theme tokens (`theme.textPrimary`, `theme.dividerColor`, etc.), matching `FileTreeRow`.
- **Unit test command:** `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/<Class>/<method> test 2>&1 | tail -40`
- **Full test run:** `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation test 2>&1 | tail -40`
- **Build:** `xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug -skipPackagePluginValidation build 2>&1 | tail -20`
- Commit after each task.

## File Structure

- `Treemux/Services/FileBrowser/FileBrowserDataSource.swift` — protocol methods + throwing defaults.
- `Treemux/Services/FileBrowser/LocalFileBrowserDataSource.swift` — local create.
- `Treemux/Services/SFTP/SFTPService.swift` — `createDirectory(at:)`, `createFile(at:)` (SSH + Citadel).
- `Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift` — remote create.
- `Treemux/UI/FileBrowser/FileTreeRowModel.swift` — `NewEntryIntent` + `Kind.editor`.
- `Treemux/UI/FileBrowser/FileBrowserTabController.swift` — `NewEntryDraft`, begin/validate/commit/cancel, `visibleRows()` injection, `targetDirectory(for:)`.
- `Treemux/UI/FileBrowser/FileTreePanelView.swift` — editor row view, context-menu items, toolbar buttons.
- `Treemux/Localizable.xcstrings` — zh-Hans entries.
- Tests: `TreemuxTests/FileBrowserCreateEntryTests.swift` (new), `LocalFileBrowserDataSourceTests.swift`, `MockFileBrowserDataSource` extension in `FileBrowserTabControllerTests.swift`.

---

### Task 1: Protocol methods + defaults + local implementation

**Files:**
- Modify: `Treemux/Services/FileBrowser/FileBrowserDataSource.swift`
- Modify: `Treemux/Services/FileBrowser/LocalFileBrowserDataSource.swift`
- Test: `TreemuxTests/LocalFileBrowserDataSourceTests.swift`

**Interfaces:**
- Produces: `func createDirectory(_ path: String) async throws` and `func createFile(_ path: String) async throws` on `FileBrowserDataSource`. Protocol-extension defaults throw `FileBrowserError.notWritable(path)`. Local implementations create non-recursively and throw `FileBrowserError.notWritable(path)` if the path already exists.

- [ ] **Step 1: Write the failing test**

Add to `TreemuxTests/LocalFileBrowserDataSourceTests.swift`:

```swift
func testCreateDirectoryAndFile() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    let source = LocalFileBrowserDataSource()
    let dirPath = root.appendingPathComponent("newdir").path
    let filePath = root.appendingPathComponent("new.txt").path

    try await source.createDirectory(dirPath)
    try await source.createFile(filePath)

    var isDir: ObjCBool = false
    XCTAssertTrue(fm.fileExists(atPath: dirPath, isDirectory: &isDir))
    XCTAssertTrue(isDir.boolValue)
    XCTAssertTrue(fm.fileExists(atPath: filePath, isDirectory: &isDir))
    XCTAssertFalse(isDir.boolValue)
}

func testCreateDirectoryRejectsExisting() async {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let source = LocalFileBrowserDataSource()
    let p = root.appendingPathComponent("dup").path
    try? await source.createDirectory(p)
    do {
        try await source.createDirectory(p)
        XCTFail("expected an error for existing path")
    } catch {
        // expected
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/LocalFileBrowserDataSourceTests/testCreateDirectoryAndFile test 2>&1 | tail -40`
Expected: FAIL to compile (`createDirectory` / `createFile` not in protocol).

- [ ] **Step 3a: Add protocol methods + defaults**

In `FileBrowserDataSource.swift`, add to the protocol (after `writeFile`):

```swift
    /// Creates a new empty directory at `path` (non-recursive — parent must
    /// exist). Throws if the path already exists or the source is read-only.
    func createDirectory(_ path: String) async throws

    /// Creates a new empty file at `path`. Throws if the path already exists or
    /// the source is read-only.
    func createFile(_ path: String) async throws
```

And in the `extension FileBrowserDataSource` block, add throwing defaults so unrelated conformers (test doubles) keep compiling:

```swift
    func createDirectory(_ path: String) async throws {
        throw FileBrowserError.notWritable(path)
    }
    func createFile(_ path: String) async throws {
        throw FileBrowserError.notWritable(path)
    }
```

- [ ] **Step 3b: Implement locally**

In `LocalFileBrowserDataSource.swift`, add (near `writeFile`):

```swift
    func createDirectory(_ path: String) async throws {
        try await runOnQueue {
            if FileManager.default.fileExists(atPath: path) {
                throw FileBrowserError.notWritable(path)
            }
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: false)
        }
    }

    func createFile(_ path: String) async throws {
        try await runOnQueue {
            if FileManager.default.fileExists(atPath: path) {
                throw FileBrowserError.notWritable(path)
            }
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw FileBrowserError.notWritable(path)
            }
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/LocalFileBrowserDataSourceTests test 2>&1 | tail -40`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Treemux/Services/FileBrowser/FileBrowserDataSource.swift Treemux/Services/FileBrowser/LocalFileBrowserDataSource.swift TreemuxTests/LocalFileBrowserDataSourceTests.swift
git commit -m "feat(file-tree): createDirectory/createFile on data source + local impl"
```

---

### Task 2: Remote implementation (SFTPService + RemoteFileBrowserDataSource)

**Files:**
- Modify: `Treemux/Services/SFTP/SFTPService.swift`
- Modify: `Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift`
- Test: `TreemuxTests/SFTPServiceTests.swift` (command-string unit test only — no live server)

**Interfaces:**
- Consumes: protocol methods from Task 1.
- Produces: `SFTPService.createDirectory(at:)`, `SFTPService.createFile(at:)`, dispatching on `mode` exactly like `writeFile(at:data:)`. `SFTPService.mkdirCommand(path:)` / `touchNoclobberCommand(path:)` static helpers (pure, unit-testable). `RemoteFileBrowserDataSource` forwards after `ensureConnected()`.

- [ ] **Step 1: Write the failing test**

Add to `TreemuxTests/SFTPServiceTests.swift`:

```swift
func testMkdirCommandQuotesPath() {
    XCTAssertEqual(SFTPService.mkdirCommand(path: "/home/u/new dir"),
                   "mkdir -- '/home/u/new dir'")
}

func testTouchNoclobberCommandQuotesPath() {
    // noclobber (`set -C`) makes `>` fail if the file already exists.
    XCTAssertEqual(SFTPService.touchNoclobberCommand(path: "/home/u/a.txt"),
                   "set -C; : > '/home/u/a.txt'")
}
```

(Confirm the exact quoting `shellEscape` produces by reading `shellEscape(_:)` first; adjust the expected string to match its real output — single-quote wrapping.)

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/SFTPServiceTests/testMkdirCommandQuotesPath test 2>&1 | tail -40`
Expected: FAIL to compile (`mkdirCommand` undefined).

- [ ] **Step 3a: Add SFTPService create methods + command helpers**

In `SFTPService.swift`, add the static command helpers (near `bulkListCommand`):

```swift
    static func mkdirCommand(path: String) -> String {
        "mkdir -- \(shellEscapeStatic(path))"
    }

    static func touchNoclobberCommand(path: String) -> String {
        "set -C; : > \(shellEscapeStatic(path))"
    }
```

`shellEscape` is currently an instance method; add a static mirror it can share (or make `shellEscape` static if it has no instance state — read it first). If `shellEscape` is pure, rename its callers to a `static func shellEscapeStatic(_:)` or make the existing one `static`. Keep one implementation (DRY).

Add the create methods (near `writeFile(at:data:)`), mirroring its `mode` dispatch:

```swift
    func createDirectory(at path: String) async throws {
        guard let mode else { throw SFTPServiceError.notConnected }
        switch mode {
        case .ssh(let target):
            let result = try await runSSH(target: target, command: Self.mkdirCommand(path: path))
            guard result.exitCode == 0 else {
                throw SFTPServiceError.commandFailed("mkdir failed at \(path)")
            }
        case .citadel(_, let sftp):
            try await sftp.createDirectory(atPath: path)
        }
    }

    func createFile(at path: String) async throws {
        guard let mode else { throw SFTPServiceError.notConnected }
        switch mode {
        case .ssh(let target):
            let result = try await runSSH(target: target, command: Self.touchNoclobberCommand(path: path))
            guard result.exitCode == 0 else {
                throw SFTPServiceError.commandFailed("create file failed at \(path)")
            }
        case .citadel(_, let sftp):
            // Reject an existing path (mirror noclobber). statViaSFTP throws when
            // the path is absent, which is the success case for creation.
            if (try? await statViaSFTP(sftp: sftp, path: path)) != nil {
                throw SFTPServiceError.commandFailed("already exists: \(path)")
            }
            let file = try await sftp.openFile(filePath: path, flags: [.write, .create, .truncate])
            try await file.close()
        }
    }
```

- [ ] **Step 3b: Forward from RemoteFileBrowserDataSource**

In `RemoteFileBrowserDataSource.swift`, add (near `writeFile`):

```swift
    func createDirectory(_ path: String) async throws {
        try await ensureConnected()
        try await service.createDirectory(at: path)
    }

    func createFile(_ path: String) async throws {
        try await ensureConnected()
        try await service.createFile(at: path)
    }
```

- [ ] **Step 4: Run tests to verify they pass + build**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/SFTPServiceTests test 2>&1 | tail -40`
Expected: PASS. Then full build to confirm Citadel API names resolve:
`xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug -skipPackagePluginValidation build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED. (If `sftp.createDirectory(atPath:)` or the open-file flags don't match the vendored Citadel API, fix to the real signatures — grep `Treemux/Vendor` / existing `openFile` usage for the correct names.)

- [ ] **Step 5: Commit**

```bash
git add Treemux/Services/SFTP/SFTPService.swift Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift TreemuxTests/SFTPServiceTests.swift
git commit -m "feat(sftp): remote createDirectory/createFile (SSH + Citadel)"
```

---

### Task 3: Row model gains the inline-editor kind

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileTreeRowModel.swift`
- Test: `TreemuxTests/FileTreeRowModelTests.swift`

**Interfaces:**
- Produces: `enum NewEntryIntent: Equatable { case folder, file }` and `FileTreeRowModel.Kind.editor(parentPath: String, intent: NewEntryIntent)`.

- [ ] **Step 1: Write the failing test**

Add to `TreemuxTests/FileTreeRowModelTests.swift`:

```swift
func testEditorKindEquatable() {
    let a = FileTreeRowModel(id: "newEntry:/r", kind: .editor(parentPath: "/r", intent: .folder),
                             depth: 0, isSelected: false, isExpanded: false, status: nil)
    let b = FileTreeRowModel(id: "newEntry:/r", kind: .editor(parentPath: "/r", intent: .folder),
                             depth: 0, isSelected: false, isExpanded: false, status: nil)
    XCTAssertEqual(a, b)
    XCTAssertNotEqual(a.kind, .editor(parentPath: "/r", intent: .file))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/FileTreeRowModelTests/testEditorKindEquatable test 2>&1 | tail -40`
Expected: FAIL to compile.

- [ ] **Step 3: Implement in `FileTreeRowModel.swift`**

```swift
/// Which kind of entry an inline-editor row will create.
enum NewEntryIntent: Equatable {
    case folder
    case file
}

struct FileTreeRowModel: Equatable, Identifiable {
    enum Kind: Equatable {
        case node(FileNode)
        case loadMore(parentPath: String)
        case editor(parentPath: String, intent: NewEntryIntent)
    }
    // ... rest unchanged ...
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/FileTreeRowModelTests test 2>&1 | tail -40`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/FileTreeRowModel.swift TreemuxTests/FileTreeRowModelTests.swift
git commit -m "feat(file-tree): add editor row kind + NewEntryIntent"
```

---

### Task 4: Controller — draft state, validation, commit, and row injection

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift`
- Modify: `TreemuxTests/FileBrowserTabControllerTests.swift` (extend `MockFileBrowserDataSource`)
- Test: `TreemuxTests/FileBrowserCreateEntryTests.swift` (create)

**Interfaces:**
- Consumes: `createDirectory`/`createFile` (Tasks 1–2), `Kind.editor` (Task 3), `FileNode.isExpandableDirectory` (Feature 10; if Feature 10 is not merged, use `isDirectory` here and reconcile at merge).
- Produces on `FileBrowserTabController`:
  - `struct NewEntryDraft: Equatable { let parentPath: String; let intent: NewEntryIntent; var errorMessage: String? }`
  - `private(set) var newEntryDraft: NewEntryDraft?`
  - `func targetDirectory(for node: FileNode) -> String`
  - `func beginNewEntry(intent: NewEntryIntent, in directory: String) async`
  - `func validateNewEntryName(_ name: String, in directory: String) -> String?` (nil = valid)
  - `func commitNewEntry(name: String) async`
  - `func cancelNewEntry()`

- [ ] **Step 1a: Extend the mock to record/serve creates**

In `TreemuxTests/FileBrowserTabControllerTests.swift`, add to `MockFileBrowserDataSource`:

```swift
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
```

- [ ] **Step 1b: Write the failing controller tests**

Create `TreemuxTests/FileBrowserCreateEntryTests.swift`:

```swift
import XCTest
@testable import Treemux

@MainActor
final class FileBrowserCreateEntryTests: XCTestCase {
    private func makeController(_ mock: MockFileBrowserDataSource,
                               root: String = "/root") -> FileBrowserTabController {
        FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: root, rootKind: .local),
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/FileBrowserCreateEntryTests test 2>&1 | tail -40`
Expected: FAIL to compile (`beginNewEntry` etc. undefined).

- [ ] **Step 3a: Add the draft state + API to the controller**

In `FileBrowserTabController.swift`, add near the other runtime state (e.g. after `truncatedDirs`):

```swift
    /// Inline "new folder / new file" editor state. Non-nil while the user is
    /// typing a name. Drives an `.editor` row in `visibleRows()`.
    struct NewEntryDraft: Equatable {
        let parentPath: String
        let intent: NewEntryIntent
        var errorMessage: String?
    }
    private(set) var newEntryDraft: NewEntryDraft? {
        didSet { visibleRowsCache = nil }
    }
```

Add the API (e.g. in a new `// MARK: - New entry` section):

```swift
    /// The directory a new entry should be created in, given a right-clicked
    /// node: the node itself when it is a directory, else its parent.
    func targetDirectory(for node: FileNode) -> String {
        node.isExpandableDirectory ? node.path : (node.path as NSString).deletingLastPathComponent
    }

    func beginNewEntry(intent: NewEntryIntent, in directory: String) async {
        // Ensure the target is expanded so the editor row is visible.
        if directory != rootPath && !expandedDirs.contains(directory) {
            await toggleExpand(directory)
        }
        newEntryDraft = NewEntryDraft(parentPath: directory, intent: intent, errorMessage: nil)
    }

    func cancelNewEntry() {
        newEntryDraft = nil
    }

    /// Returns a localized error message for an invalid name, or nil if valid.
    func validateNewEntryName(_ name: String, in directory: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return String(localized: "Name cannot be empty") }
        if trimmed.contains("/") { return String(localized: "Name cannot contain a slash") }
        let siblings = (directory == rootPath) ? rootChildren : (childrenByPath[directory] ?? [])
        if siblings.contains(where: { $0.name == trimmed }) {
            return String.localizedStringWithFormat(
                String(localized: "An item named \"%@\" already exists"), trimmed)
        }
        return nil
    }

    func commitNewEntry(name: String) async {
        guard let draft = newEntryDraft else { return }
        let dir = draft.parentPath
        if let err = validateNewEntryName(name, in: dir) {
            newEntryDraft?.errorMessage = err
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let newPath = (dir == "/" ? "" : dir) + "/" + trimmed
        do {
            switch draft.intent {
            case .folder: try await dataSource.createDirectory(newPath)
            case .file:   try await dataSource.createFile(newPath)
            }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            newEntryDraft?.errorMessage = msg
            return
        }
        newEntryDraft = nil
        // Refresh the parent so the new entry appears. A new folder is expanded
        // (it is empty); a new file is NOT auto-opened — it simply appears.
        await refresh(dir)
        if draft.intent == .folder, !expandedDirs.contains(newPath) {
            expandedDirs.insert(newPath)
            childrenByPath[newPath] = []
            rawChildrenByPath[newPath] = []
        }
        onPersistableStateChanged?()
    }
```

- [ ] **Step 3b: Inject the editor row in `visibleRows()`**

Change the `emit` helper to carry the parent path and inject the editor row at the top of a directory's children. Replace the `emit` closure and its calls:

```swift
        var rows: [FileTreeRowModel] = []
        func emit(_ nodes: [FileNode], depth: Int, parent: String) {
            if let draft = newEntryDraft, draft.parentPath == parent {
                rows.append(FileTreeRowModel(
                    id: "newEntry:" + parent,
                    kind: .editor(parentPath: parent, intent: draft.intent),
                    depth: depth, isSelected: false, isExpanded: false, status: nil))
            }
            for node in nodes {
                let expanded = node.isExpandableDirectory && expandedDirs.contains(node.path)
                rows.append(FileTreeRowModel(
                    id: node.path,
                    kind: .node(node),
                    depth: depth,
                    isSelected: selectedFilePath == node.path,
                    isExpanded: expanded,
                    status: fileStatusByPath[node.path]
                ))
                if expanded, let kids = childrenByPath[node.path] {
                    emit(kids, depth: depth + 1, parent: node.path)
                    if truncatedDirs.contains(node.path) {
                        rows.append(FileTreeRowModel(
                            id: "loadMore:" + node.path,
                            kind: .loadMore(parentPath: node.path),
                            depth: depth + 1,
                            isSelected: false, isExpanded: false, status: nil
                        ))
                    }
                }
            }
        }
        emit(rootChildren, depth: 0, parent: rootPath)
```

Also add `_ = newEntryDraft` to the "touch every input" block at the top of `visibleRows()` (alongside `_ = rootChildren` etc.) so the memoized cache invalidates and SwiftUI re-renders when the draft changes:

```swift
        _ = newEntryDraft
```

(If Feature 10 is not yet merged, `node.isExpandableDirectory` above must be `node.isDirectory` — reconcile when the branches merge.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/FileBrowserCreateEntryTests test 2>&1 | tail -40`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift TreemuxTests/FileBrowserTabControllerTests.swift TreemuxTests/FileBrowserCreateEntryTests.swift
git commit -m "feat(file-tree): new-entry draft state, validation, commit, row injection"
```

---

### Task 5: Inline-editor row view

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileTreePanelView.swift`
- Test: manual (SwiftUI view). Controller logic already covered in Task 4.

**Interfaces:**
- Consumes: `controller.newEntryDraft`, `controller.commitNewEntry(name:)`, `controller.cancelNewEntry()`, `Kind.editor` (Task 3).

- [ ] **Step 1: Render the editor kind in `FileTreeRow.body`**

In the `body` switch of the row view (currently handling `.node` / `.loadMore`), add:

```swift
        case .editor(let parentPath, let intent):
            NewEntryEditorRow(controller: controller, depth: row.depth,
                              parentPath: parentPath, intent: intent)
```

- [ ] **Step 2: Add the `NewEntryEditorRow` view**

Add to `FileTreePanelView.swift`:

```swift
private struct NewEntryEditorRow: View {
    let controller: FileBrowserTabController
    let depth: Int
    let parentPath: String
    let intent: NewEntryIntent
    @Environment(ThemeManager.self) private var theme
    @State private var name: String = ""
    @FocusState private var focused: Bool

    private var iconAsset: String { intent == .folder ? "folder" : "file-document-outline" }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                ForEach(0..<depth, id: \.self) { _ in
                    Rectangle()
                        .fill(theme.dividerColor)
                        .frame(width: 1)
                        .padding(.trailing, 13)
                }
                Spacer().frame(width: 12)                    // disclosure gutter
                Color.clear.frame(width: 4, height: 4)       // git-dot gutter
                Image(iconAsset)
                    .resizable().renderingMode(.template).scaledToFit()
                    .frame(width: 15, height: 15)
                    .foregroundStyle(theme.textSecondary)
                TextField(intent == .folder
                          ? LocalizedStringKey("New Folder")
                          : LocalizedStringKey("New File"), text: $name)
                    .textFieldStyle(.plain)
                    .font(DesignFonts.dataLayer(size: 13))
                    .foregroundStyle(theme.textPrimary)
                    .focused($focused)
                    .onSubmit { Task { await controller.commitNewEntry(name: name) } }
                    .onExitCommand { controller.cancelNewEntry() }   // Esc
            }
            .padding(.horizontal, 8)
            if let err = controller.newEntryDraft?.errorMessage {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .padding(.leading, CGFloat(depth) * 14 + 40)
            }
        }
        .padding(.vertical, 2)
        .onAppear { focused = true }
    }
}
```

Notes: `file-document-outline` and `folder` are existing asset names in `Assets.xcassets`. `onExitCommand` maps to the Escape key. Commit runs async; on validation failure the controller re-populates `errorMessage` and keeps the draft, so the row stays and shows the error.

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug -skipPackagePluginValidation build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Treemux/UI/FileBrowser/FileTreePanelView.swift
git commit -m "feat(file-tree): inline new-entry editor row view"
```

---

### Task 6: Entry points (context menu + toolbar) and i18n

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileTreePanelView.swift` (context menu + toolbar)
- Modify: `Treemux/Localizable.xcstrings`
- Test: manual.

**Interfaces:**
- Consumes: `controller.beginNewEntry(intent:in:)`, `controller.targetDirectory(for:)`.

- [ ] **Step 1: Add context-menu items on the node row**

In the existing `.contextMenu { … }` on the file-tree node row (currently the two Copy-Path buttons), prepend:

```swift
            Button(LocalizedStringKey("New Folder")) {
                Task { await controller.beginNewEntry(intent: .folder,
                                                      in: controller.targetDirectory(for: node)) }
            }
            Button(LocalizedStringKey("New File")) {
                Task { await controller.beginNewEntry(intent: .file,
                                                      in: controller.targetDirectory(for: node)) }
            }
            Divider()
            // ... existing Copy Absolute / Relative Path buttons ...
```

- [ ] **Step 2: Add toolbar buttons in `FileTreeToolbar`**

In `FileTreeToolbar.body`'s `HStack`, before the Refresh button, add two buttons that create under the selected file's directory (or the root when nothing is selected):

```swift
            Button {
                let dir = controller.selectedFilePath.map { path -> String in
                    // Selected path is a file (sub-tab); create in its directory.
                    (path as NSString).deletingLastPathComponent
                } ?? controller.rootPath
                Task { await controller.beginNewEntry(intent: .folder, in: dir) }
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.plain)
            .help(LocalizedStringKey("New Folder"))

            Button {
                let dir = controller.selectedFilePath.map { ($0 as NSString).deletingLastPathComponent }
                    ?? controller.rootPath
                Task { await controller.beginNewEntry(intent: .file, in: dir) }
            } label: {
                Image(systemName: "doc.badge.plus")
            }
            .buttonStyle(.plain)
            .help(LocalizedStringKey("New File"))
```

- [ ] **Step 3: Add zh-Hans entries to `Localizable.xcstrings`**

Add (or verify) these keys with `zh-Hans` translations in `Treemux/Localizable.xcstrings`:

| key | zh-Hans |
|---|---|
| `New Folder` | 新建文件夹 |
| `New File` | 新建文件 |
| `Name cannot be empty` | 名称不能为空 |
| `Name cannot contain a slash` | 名称不能包含斜杠 |
| `An item named "%@" already exists` | 已存在名为“%@”的项目 |

Open `Localizable.xcstrings` in Xcode (or edit the JSON directly, following the existing entry shape) and provide each string's `zh-Hans` localization. After adding, build to confirm the catalog still parses.

- [ ] **Step 4: Build + manual verification**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug -skipPackagePluginValidation build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED. Then build & run the app and verify:
- Right-click a folder → New Folder / New File → inline editor appears under it; type + Enter creates it; Esc cancels.
- Right-click a file → the new entry is created in the file's directory.
- Toolbar buttons create under the selected file's directory (or root).
- Duplicate / empty / slash names show the inline error and keep the editor open.
- Remote (system-SSH) workspace: creating a folder/file works and appears after refresh.
- Interface is fully Chinese under a zh-Hans system locale (no English leak).

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/FileTreePanelView.swift Treemux/Localizable.xcstrings
git commit -m "feat(file-tree): new-entry context menu + toolbar buttons + i18n"
```

---

### Task 7: Full regression

- [ ] **Step 1: Run the whole suite**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation test 2>&1 | tail -40`
Expected: all tests PASS.

- [ ] **Step 2: Commit (if any fixups were needed)**

```bash
git add -A && git commit -m "test(file-tree): green after new-file/folder feature" || echo "nothing to commit"
```

---

## Notes / Design Decisions (carry into review)

- **Selection vs. open.** The tree's "selected" highlight is derived from the active sub-tab's path (`selectedFilePath`); there is no independent tree-selection state. So "select the new node without opening it" is not representable without new machinery (YAGNI). Chosen behavior: after create, the parent directory is refreshed so the new entry appears; a new **folder** is auto-expanded (empty); a new **file** is **not** auto-opened. This honors "don't auto-open unsaved-tab-safe" from the spec. If auto-selecting/opening a new file is later desired, revisit.
- **Protocol defaults.** `createDirectory`/`createFile` ship throwing defaults so the several existing test doubles (`GatedFileBrowserDataSource`, `GatedTreeDataSource`, `ScriptedDataSource`, `GatedWriteFileBrowserDataSource`) keep compiling without change.
- **Exclusive create.** Local uses a pre-existence check; remote SSH uses `mkdir` (fails if exists) and `set -C; : >` (noclobber); Citadel pre-checks via `statViaSFTP`. No silent overwrite.
