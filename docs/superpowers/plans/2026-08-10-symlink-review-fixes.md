# Symlink Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix root-path cycle detection, controller-owned expansion cancellation, and lossless system-SSH canonical identities found during review.

**Architecture:** Keep canonical ancestry checks in `FileBrowserTabController`, but normalize path containment and let the controller own cancellable expansion tasks. Keep transport-specific identity encoding in `SFTPService`, using a sentinel-protected shell value and hexadecimal framing so valid path characters are never trimmed.

**Tech Stack:** Swift 6, Swift Concurrency, Foundation, Citadel SFTP, POSIX shell tools, XCTest, Xcode 26.

## Global Constraints

- Communicate with the user in Chinese and use English code comments.
- Work only in `codex/feat/symlink-directory-support` under `.worktrees/codex+feat+symlink-directory-support`; the main checkout remains on `main`.
- All user-visible strings use localization; these fixes add no user-visible copy.
- Do not change the existing Citadel maximum of four concurrent metadata requests.
- Every production change must follow a witnessed red-green test cycle.

---

### Task 1: Normalize ancestry traversal for root paths

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift:554-563`
- Test: `TreemuxTests/FileBrowserTabControllerTests.swift`

**Interfaces:**
- Consumes: `rootPath: String`, displayed node paths, and `canonicalDirectoryIdentity(_:)`.
- Produces: `ancestorPaths(of:) -> [String]` that handles `/`, trailing separators, and path-component boundaries.

- [ ] **Step 1: Add the failing root-cycle test**

Add a test that browses `/`, expands `/a`, and attempts to expand a symlink at `/a/back-to-a` whose canonical target is `/canonical/a`:

```swift
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
    let callsBeforeCycle = mock.listDirectoryCalls.count

    await controller.toggleExpand("/a/back-to-a")

    XCTAssertFalse(controller.expandedDirs.contains("/a/back-to-a"))
    XCTAssertEqual(mock.listDirectoryCalls.count, callsBeforeCycle)
    let row = try XCTUnwrap(controller.visibleRows().first { $0.id == "/a/back-to-a" })
    XCTAssertNotNil(row.symlinkError)
}
```

- [ ] **Step 2: Run the focused test and witness the expected failure**

Run:

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -derivedDataPath /tmp/treemux-symlink-review-dd -skipPackagePluginValidation -only-testing:TreemuxTests/FileBrowserTabControllerTests/testNestedSymlinkCycleStopsWhenBrowserRootIsSlash
```

Expected: FAIL because `/a` is excluded from the ancestry and the mock records a listing call for `/a/back-to-a`.

- [ ] **Step 3: Implement normalized component-boundary containment**

Normalize paths with `NSString.standardizingPath`, remove redundant trailing separators except for `/`, and walk parents until the normalized root is reached. Use an explicit root case rather than constructing `root + "/"` when root is `/`:

```swift
private func ancestorPaths(of path: String) -> [String] {
    let root = (rootPath as NSString).standardizingPath
    var current = ((path as NSString).standardizingPath as NSString)
        .deletingLastPathComponent
    var paths: [String] = []

    while current == root || (root == "/" ? current.hasPrefix("/") : current.hasPrefix(root + "/")) {
        paths.append(current)
        if current == root { break }
        let parent = (current as NSString).deletingLastPathComponent
        guard parent != current else { break }
        current = parent
    }
    return paths.reversed()
}
```

- [ ] **Step 4: Run the focused controller test and the controller suite**

Run the focused command from Step 2, then:

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -derivedDataPath /tmp/treemux-symlink-review-dd -skipPackagePluginValidation -only-testing:TreemuxTests/FileBrowserTabControllerTests
```

Expected: PASS.

- [ ] **Step 5: Commit the root-cycle fix**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift TreemuxTests/FileBrowserTabControllerTests.swift
git commit -m 'fix: detect symlink cycles under filesystem root'
```

---

### Task 2: Cancel controller-owned expansion work

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift:75-80,316-322,396-446`
- Test: `TreemuxTests/FileBrowserTabControllerTests.swift`

**Interfaces:**
- Consumes: `toggleExpand(_:) async`, the existing per-path UUID token, and cancellable data-source calls.
- Produces: a private `ExpansionOperation` containing `token: UUID` and `task: Task<Void, Never>`, stored in `expansionOperationsByPath`.

- [ ] **Step 1: Add a cancellation-aware test data source seam**

Extend the test mock with an opt-in cancellable delay for one path. Signal entry through `AsyncStream`, sleep until cancelled, then signal cancellation before throwing `CancellationError`:

```swift
var cancellableListDirectoryPath: String?
private var cancellableListEnteredContinuation: AsyncStream<Void>.Continuation?
private var cancellableListCancelledContinuation: AsyncStream<Void>.Continuation?

func armCancellableListDirectory(path: String) -> (entered: AsyncStream<Void>, cancelled: AsyncStream<Void>) {
    let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
    let (cancelled, cancelledContinuation) = AsyncStream<Void>.makeStream()
    cancellableListDirectoryPath = path
    cancellableListEnteredContinuation = enteredContinuation
    cancellableListCancelledContinuation = cancelledContinuation
    return (entered, cancelled)
}
```

Inside `listDirectory`, when the path matches, yield `entered`, then call `try await Task.sleep(for: .seconds(30))`; in the cancellation catch, yield and finish `cancelled`, then rethrow.

- [ ] **Step 2: Add the failing controller cancellation test**

```swift
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
}
```

- [ ] **Step 3: Run the focused test and witness the expected failure**

Run:

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -derivedDataPath /tmp/treemux-symlink-review-dd -skipPackagePluginValidation -only-testing:TreemuxTests/FileBrowserTabControllerTests/testSecondToggleCancelsInFlightExpansionTask
```

Expected: the test times out or fails because clearing `expansionTokens[path]` does not cancel the first task.

- [ ] **Step 4: Move expansion work into controller-owned tasks**

Add:

```swift
private struct ExpansionOperation {
    let token: UUID
    let task: Task<Void, Never>
}

@ObservationIgnored private var expansionOperationsByPath: [String: ExpansionOperation] = [:]
```

Refactor `toggleExpand(_:)` so it:

1. cancels and removes an existing operation on a second toggle;
2. keeps the existing synchronous collapse branch;
3. creates a token and `Task { [weak self] in await self?.performExpansion(...) }` for a new expansion;
4. stores the operation before awaiting `task.value`;
5. removes it after completion only when its token still matches.

Move the current validation/list/apply body into:

```swift
private func performExpansion(_ path: String, generation: Int, token: UUID) async
```

Check `Task.checkCancellation()` before validation, before `listDirectory`, and immediately after each await. Treat `CancellationError` as silent; map other errors only when the token and generation are still current.

At the start of `refreshTree()`, call `cancelAllExpansionOperations()` before clearing tokens. That helper cancels every stored task, clears the dictionary, and then clears loading/token state.

- [ ] **Step 5: Run the focused test and controller suites**

Run the focused command from Step 3, then:

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -derivedDataPath /tmp/treemux-symlink-review-dd -skipPackagePluginValidation -only-testing:TreemuxTests/FileBrowserTabControllerTests -only-testing:TreemuxTests/FileBrowserTabControllerStaleLoadTests
```

Expected: PASS, including existing stale-result tests.

- [ ] **Step 6: Commit the cancellation fix**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift TreemuxTests/FileBrowserTabControllerTests.swift
git commit -m 'fix: cancel in-flight file tree expansions'
```

---

### Task 3: Preserve exact system-SSH canonical identities

**Files:**
- Modify: `Treemux/Services/SFTP/SFTPService.swift:206-220,762-809`
- Test: `TreemuxTests/SFTPServiceTests.swift`

**Interfaces:**
- Consumes: `shellQuote(_:)`, `shellEscape(_:)`, and `decodeHexString(_:)`.
- Produces: `canonicalDirectoryIdentityCommand(path:) -> String` and `parseCanonicalDirectoryIdentityOutput(_:) -> String?`.

- [ ] **Step 1: Add the failing shell round-trip test**

Create a temporary directory with a name containing leading/trailing spaces, a tab, and a newline. Execute the new command helper locally through `/bin/sh`, parse its output, and compare it with Foundation's resolved path:

```swift
func testCanonicalIdentityCommandPreservesWhitespaceAndNewlines() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("treemux-canonical-\(UUID().uuidString)")
    let directory = root.appendingPathComponent(" leading\tline\ntrailing ")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", SFTPService.canonicalDirectoryIdentityCommand(path: directory.path)]
    let result = try await SFTPService.runProcessAndCaptureOutput(process)

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(
        SFTPService.parseCanonicalDirectoryIdentityOutput(result.output),
        directory.resolvingSymlinksInPath().standardizedFileURL.path
    )
}
```

- [ ] **Step 2: Run the focused test and witness the expected failure**

Run:

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -derivedDataPath /tmp/treemux-symlink-review-dd -skipPackagePluginValidation -only-testing:TreemuxTests/SFTPServiceTests/testCanonicalIdentityCommandPreservesWhitespaceAndNewlines
```

Expected: FAIL because the command/parser helpers do not exist.

- [ ] **Step 3: Add a sentinel-protected hex command and parser**

Build a portable shell script that:

1. resolves the path with `realpath --` or `cd -P` plus `pwd -P`;
2. appends `\001` before command substitution strips trailing newlines;
3. removes the sentinel and exactly one command-produced newline;
4. emits `H` followed by the exact UTF-8 bytes encoded with `od -An -v -tx1`.

Expose the command as `canonicalDirectoryIdentityCommand(path:)`. Implement `parseCanonicalDirectoryIdentityOutput(_:)` by removing only the record's terminating newline, requiring the `H` prefix, and decoding the remaining hex through `decodeHexString`.

Update `canonicalDirectoryIdentity(_:)` to run the helper and accept only a zero exit code plus a non-empty decoded identity. Do not use `trimmingCharacters(in:)` on the identity.

- [ ] **Step 4: Run the focused SFTP tests**

Run the focused command from Step 2, then:

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -derivedDataPath /tmp/treemux-symlink-review-dd -skipPackagePluginValidation -only-testing:TreemuxTests/SFTPServiceTests -only-testing:TreemuxTests/SFTPRecursiveListingTests
```

Expected: PASS.

- [ ] **Step 5: Commit the SSH identity fix**

```bash
git add Treemux/Services/SFTP/SFTPService.swift TreemuxTests/SFTPServiceTests.swift
git commit -m 'fix: preserve ssh canonical directory identities'
```

---

### Task 4: Verify and review the completed corrections

**Files:**
- Review: all changes from `main...HEAD`
- Verify: `Treemux/Localizable.xcstrings`

**Interfaces:**
- Consumes: the three independently committed fixes.
- Produces: a clean, buildable branch ready for integration choice.

- [ ] **Step 1: Run all symlink-focused suites**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -derivedDataPath /tmp/treemux-symlink-review-dd -skipPackagePluginValidation \
  -only-testing:TreemuxTests/FileNodeSymlinkTests \
  -only-testing:TreemuxTests/LocalFileBrowserDataSourceTests \
  -only-testing:TreemuxTests/SFTPServiceTests \
  -only-testing:TreemuxTests/SFTPRecursiveListingTests \
  -only-testing:TreemuxTests/FileBrowserTabControllerTests \
  -only-testing:TreemuxTests/FileBrowserTabControllerStaleLoadTests \
  -only-testing:TreemuxTests/FileTreeRowModelTests
```

Expected: PASS.

- [ ] **Step 2: Run the complete test suite**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -derivedDataPath /tmp/treemux-symlink-review-dd -skipPackagePluginValidation
```

Expected: all tests pass with zero failures.

- [ ] **Step 3: Run a standard Debug build**

```bash
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -configuration Debug -destination 'platform=macOS' -skipPackagePluginValidation
```

Expected: exit code 0 and a Debug app under the worktree-specific DerivedData directory.

- [ ] **Step 4: Check formatting, localization, and branch cleanliness**

```bash
git diff --check main...HEAD
jq empty Treemux/Localizable.xcstrings
git status --short
```

Expected: no diff errors, valid localization JSON, and a clean worktree.

- [ ] **Step 5: Perform a read-only defect-first review**

Review the complete `main...HEAD` merge diff, with particular attention to cancellation races, root containment, shell portability, malformed identity records, and the new regression tests. Fix any qualifying findings through another red-green cycle before declaring completion.
