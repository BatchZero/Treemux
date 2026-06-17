# P2 — Editor Smoothness (Targeted Fixes) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the three confirmed main-thread hot spots that make the file editor janky during open/typing/save, without swapping the `CodeEditSourceEditor` engine.

**Architecture:** Three independent, profile-driven fixes against the existing `CodeEditSourceEditor` 0.15.2 + BatchZero `CodeEditTextView` fork stack:
1. Kill the per-render `FileManager.attributesOfItem` syscall in `TextEditorView` (replace with an in-memory byte count via a pure, testable policy function).
2. Make cursor-move completion fully synchronous-but-non-blocking by reading a lock-protected `WordIndexSnapshotStore` instead of bridging the `BufferWordIndex` actor with a 50 ms `DispatchSemaphore` on the main thread.
3. Return from `saveCurrentFile()` immediately and run the git-status / diff refresh off the save path (mirroring the existing fire-and-forget `Task { … }` pattern already used at `FileBrowserTabController.swift:331`).

**Tech Stack:** Swift 5, SwiftUI, AppKit, Swift Concurrency (actors), XCTest. macOS app built with `xcodebuild` (XcodeGen-generated project).

**Out of scope / already done:** The spec's fourth symptom ("switching files/sub-tabs janky — full SourceEditor re-init on every switch") is **already solved** on this branch — `FileViewerPanelView.content` keeps every sub-tab's editor alive in a `ZStack` and toggles visibility via `.opacity`/`.allowsHitTesting` instead of `.id`-based rebuilds (see the comment at `FileViewerPanelView.swift:26-33`). Task 4 verifies this and the two secondary knobs (300 ms index debounce, 2 MB highlight limit) rather than re-implementing them.

---

## Build & Test Commands (read once)

All commands run from the worktree root:
`/Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+filebrowser-p2-editor-smoothness`

- **Full test suite:**
  ```bash
  xcodebuild test -project Treemux.xcodeproj -scheme Treemux \
    -destination 'platform=macOS' -skipPackagePluginValidation 2>&1 | xcbeautify || true
  ```
  (`-skipPackagePluginValidation` is required for non-interactive runs because of the SwiftLint build plugin. If `xcbeautify` is not installed, drop the `| xcbeautify` pipe.)

- **Single test class (fast TDD loop):** append `-only-testing:TreemuxTests/<ClassName>` to the command above, e.g. `-only-testing:TreemuxTests/EditorHighlightPolicyTests`.

- **Baseline:** the suite is green at 273+ tests on this branch. Every task must keep it green.

---

## File Structure

**New files:**
- `Treemux/UI/FileBrowser/EditorHighlightPolicy.swift` — pure decision: should a file of a given byte count + path be tree-sitter highlighted? (Task 1)
- `Treemux/Services/Editor/WordIndexSnapshotStore.swift` — lock-protected, synchronously-readable frequency snapshot + shared ranking function. (Task 2)
- `TreemuxTests/EditorHighlightPolicyTests.swift` — unit tests for the policy. (Task 1)
- `TreemuxTests/WordIndexSnapshotStoreTests.swift` — unit tests for the snapshot store. (Task 2)

**Modified files:**
- `Treemux/UI/FileBrowser/TextEditorView.swift` — use the policy + in-memory byte count instead of `attributesOfItem`. (Task 1)
- `Treemux/Services/Editor/BufferWordIndex.swift` — own a `WordIndexSnapshotStore`, publish on every mutation, delegate ranking to the shared function. (Task 2)
- `Treemux/UI/FileBrowser/CompletionPopover.swift` — read the snapshot synchronously in `completionOnCursorMove`; delete `blockingSuggestions` + `ResultBox`. (Task 2)
- `Treemux/UI/FileBrowser/FileBrowserTabController.swift` — non-blocking `saveCurrentFile()`. (Task 3)
- `TreemuxTests/FileBrowserTabControllerTests.swift` (or a new focused test file) — save-returns-immediately test. (Task 3)
- `TreemuxTests/BufferWordIndexTests.swift` — snapshot-stays-in-sync test. (Task 2)

---

## Task 1: Eliminate the per-render filesystem stat

**Why:** `CodeEditorRepresentable.fileSizeBytes` (`TextEditorView.swift:156-159`) calls `FileManager.default.attributesOfItem(atPath:)` — a synchronous filesystem syscall. It is read by `shouldHighlight` → `language`, both evaluated **on every SwiftUI body eval**. Because P1's `ZStack` keeps *every* open sub-tab's editor alive, a single `@Published` change on the controller re-evals **all** of their bodies, multiplying the syscall count. We replace the syscall with the already-in-memory `content.utf8.count` (which also more accurately reflects what is actually loaded into the editor than the on-disk size), routed through a pure, unit-testable policy function.

**Files:**
- Create: `Treemux/UI/FileBrowser/EditorHighlightPolicy.swift`
- Create: `TreemuxTests/EditorHighlightPolicyTests.swift`
- Modify: `Treemux/UI/FileBrowser/TextEditorView.swift:153-185`

- [ ] **Step 1: Write the failing test**

Create `TreemuxTests/EditorHighlightPolicyTests.swift`:

```swift
//
//  EditorHighlightPolicyTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

final class EditorHighlightPolicyTests: XCTestCase {
    func test_smallKnownLanguageFile_isHighlighted() {
        XCTAssertTrue(EditorHighlightPolicy.shouldHighlight(path: "/r/a.swift", byteCount: 1_000))
    }

    func test_fileAtLimit_isHighlighted() {
        XCTAssertTrue(
            EditorHighlightPolicy.shouldHighlight(path: "/r/a.swift",
                                                  byteCount: EditorHighlightPolicy.highlightSizeLimit))
    }

    func test_fileOverLimit_isNotHighlighted() {
        XCTAssertFalse(
            EditorHighlightPolicy.shouldHighlight(path: "/r/a.swift",
                                                  byteCount: EditorHighlightPolicy.highlightSizeLimit + 1))
    }

    func test_unknownLanguage_isNotHighlighted() {
        // No FileTypeClassifier language mapping → never highlight, regardless of size.
        XCTAssertFalse(EditorHighlightPolicy.shouldHighlight(path: "/r/notes.unknownext", byteCount: 10))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -skipPackagePluginValidation -only-testing:TreemuxTests/EditorHighlightPolicyTests 2>&1 | xcbeautify || true
```
Expected: FAIL — `cannot find 'EditorHighlightPolicy' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Treemux/UI/FileBrowser/EditorHighlightPolicy.swift`:

```swift
//
//  EditorHighlightPolicy.swift
//  Treemux
//
//  Pure decision for whether the editor should run tree-sitter highlighting on
//  a buffer. Extracted from the view so the size/language gate is unit-testable
//  and so the render path never performs a filesystem stat.
//

import Foundation

enum EditorHighlightPolicy {
    /// Files larger than this open without tree-sitter highlighting. Kept in
    /// bytes; callers pass the in-memory buffer size (`content.utf8.count`),
    /// never an on-disk `stat`.
    static let highlightSizeLimit: Int = 2 * 1024 * 1024

    /// Highlight only when the path maps to a known language AND the in-memory
    /// buffer is within the size limit.
    static func shouldHighlight(path: String, byteCount: Int) -> Bool {
        guard FileTypeClassifier.language(forPath: path) != nil else { return false }
        return byteCount <= highlightSizeLimit
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command. Expected: PASS (4 tests).

- [ ] **Step 5: Rewire the view to use the policy (no syscall)**

In `Treemux/UI/FileBrowser/TextEditorView.swift`, delete `highlightSizeLimit`, `fileSizeBytes`, and `shouldHighlight` (lines 153-164) and replace the size/language block. The new `language` reads `EditorHighlightPolicy` with the in-memory `content` byte count:

```swift
    // MARK: - Language / size guard

    private var language: CodeLanguage {
        // Use the in-memory buffer size — never stat the file on the render
        // path. `content` is the text actually loaded into the editor.
        guard EditorHighlightPolicy.shouldHighlight(path: path, byteCount: content.utf8.count),
              let lang = FileTypeClassifier.language(forPath: path) else {
            return .default
        }
        switch lang {
        case .swift: return .swift
        case .javascript: return .javascript
        case .typescript: return .typescript
        case .tsx: return .tsx
        case .python: return .python
        case .go: return .go
        case .rust: return .rust
        case .json: return .json
        case .yaml: return .yaml
        case .markdown: return .markdown
        case .html: return .html
        case .css: return .css
        case .bash: return .bash
        }
    }
```

Confirm no other reference to the deleted members remains:
```bash
grep -n "fileSizeBytes\|shouldHighlight\|attributesOfItem\|highlightSizeLimit" Treemux/UI/FileBrowser/TextEditorView.swift
```
Expected: no output.

- [ ] **Step 6: Run the full suite to verify nothing regressed**

Run the full-suite command. Expected: PASS (all prior tests + 4 new).

- [ ] **Step 7: Commit**

```bash
git add Treemux/UI/FileBrowser/EditorHighlightPolicy.swift \
        TreemuxTests/EditorHighlightPolicyTests.swift \
        Treemux/UI/FileBrowser/TextEditorView.swift
git commit -m "perf(editor): drop per-render attributesOfItem stat; gate highlight on in-memory size"
```

---

## Task 2: Synchronous, non-blocking cursor-move completion

**Why:** `WordCompletionDelegate.completionOnCursorMove` (`CompletionPopover.swift:106-125`) must return synchronously (upstream protocol). Today it bridges the `BufferWordIndex` **actor** by spawning a detached `Task` and waiting on a `DispatchSemaphore` for up to 50 ms **on the main thread** (`blockingSuggestions`, lines 213-227). Under contention (e.g. the actor is re-tokenizing a large/CJK buffer) that wait can block the main thread for up to 50 ms ≈ 3 dropped frames. Fix: maintain a lock-protected, immutable frequency snapshot that the main thread can read with zero blocking, and delete the semaphore path entirely.

**Files:**
- Create: `Treemux/Services/Editor/WordIndexSnapshotStore.swift`
- Create: `TreemuxTests/WordIndexSnapshotStoreTests.swift`
- Modify: `Treemux/Services/Editor/BufferWordIndex.swift`
- Modify: `Treemux/UI/FileBrowser/CompletionPopover.swift:106-235`
- Modify: `TreemuxTests/BufferWordIndexTests.swift`

- [ ] **Step 1: Write the failing test for the snapshot store**

Create `TreemuxTests/WordIndexSnapshotStoreTests.swift`:

```swift
//
//  WordIndexSnapshotStoreTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

final class WordIndexSnapshotStoreTests: XCTestCase {
    func test_suggestions_rankByFrequencyThenAlpha() {
        let store = WordIndexSnapshotStore()
        store.replace(["alpha": 3, "alacrity": 1, "able": 1])
        // All share prefix "al"/"a"; "alpha" highest freq first, then alpha order.
        XCTAssertEqual(store.suggestions(prefix: "al", limit: 10), ["alpha", "alacrity"])
    }

    func test_suggestions_excludesExactPrefixMatch() {
        let store = WordIndexSnapshotStore()
        store.replace(["count": 2, "counter": 1])
        XCTAssertEqual(store.suggestions(prefix: "count", limit: 10), ["counter"])
    }

    func test_suggestions_caseInsensitivePrefix() {
        let store = WordIndexSnapshotStore()
        store.replace(["Buffer": 1])
        XCTAssertEqual(store.suggestions(prefix: "buf", limit: 10), ["Buffer"])
    }

    func test_emptyPrefix_returnsNothing() {
        let store = WordIndexSnapshotStore()
        store.replace(["alpha": 1])
        XCTAssertEqual(store.suggestions(prefix: "", limit: 10), [])
    }

    func test_replace_overwritesPreviousSnapshot() {
        let store = WordIndexSnapshotStore()
        store.replace(["alpha": 1])
        store.replace(["beta": 1])
        XCTAssertEqual(store.suggestions(prefix: "al", limit: 10), [])
        XCTAssertEqual(store.suggestions(prefix: "be", limit: 10), ["beta"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -skipPackagePluginValidation -only-testing:TreemuxTests/WordIndexSnapshotStoreTests 2>&1 | xcbeautify || true
```
Expected: FAIL — `cannot find 'WordIndexSnapshotStore' in scope`.

- [ ] **Step 3: Write the snapshot store + shared ranking function**

Create `Treemux/Services/Editor/WordIndexSnapshotStore.swift`:

```swift
//
//  WordIndexSnapshotStore.swift
//  Treemux
//
//  Synchronously-readable mirror of `BufferWordIndex`'s frequency map. The
//  cursor-move completion hook is a synchronous upstream protocol method, so it
//  cannot `await` the actor. Instead the actor publishes an immutable frequency
//  snapshot here after every mutation, and the main thread reads it under a
//  short-held lock — no `DispatchSemaphore`, no main-thread blocking.
//

import Foundation

/// Pure, allocation-free ranking shared by the actor and the snapshot store so
/// both produce identical results. Ranks by descending frequency, then ascending
/// lexicographic order; excludes any exact match for `prefix`; case-insensitive.
func rankedWordSuggestions(from freq: [String: Int], prefix: String, limit: Int) -> [String] {
    guard !prefix.isEmpty else { return [] }
    let lower = prefix.lowercased()
    return freq.keys
        .filter { $0.lowercased().hasPrefix(lower) && $0 != prefix }
        .sorted { lhs, rhs in
            let lf = freq[lhs] ?? 0
            let rf = freq[rhs] ?? 0
            if lf != rf { return lf > rf }
            return lhs < rhs
        }
        .prefix(limit)
        .map { $0 }
}

/// Thread-safe holder for the latest frequency snapshot. `@unchecked Sendable`
/// because all access to `freq` is guarded by `lock`.
final class WordIndexSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var freq: [String: Int] = [:]

    /// Atomically replaces the published snapshot.
    func replace(_ newFreq: [String: Int]) {
        lock.lock()
        freq = newFreq
        lock.unlock()
    }

    /// Synchronously returns up to `limit` ranked suggestions for `prefix`.
    /// Copies the dictionary under the lock, then ranks outside it so the lock
    /// is held only for the O(1) reference copy.
    func suggestions(prefix: String, limit: Int = 20) -> [String] {
        lock.lock()
        let snapshot = freq
        lock.unlock()
        return rankedWordSuggestions(from: snapshot, prefix: prefix, limit: limit)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command. Expected: PASS (5 tests).

- [ ] **Step 5: Make `BufferWordIndex` own and publish the snapshot**

In `Treemux/Services/Editor/BufferWordIndex.swift`:

(a) Add a nonisolated immutable snapshot property right after the actor's stored vars (after `private var freq: [String: Int] = [:]`):

```swift
    /// Synchronously-readable mirror of `freq`, published after every mutation.
    /// A `let` of a `Sendable` type is nonisolated, so the main-thread cursor
    /// hook can read it without awaiting the actor.
    let snapshot = WordIndexSnapshotStore()
```

(b) At the **end** of `update(bufferID:contents:)` (after the frequency-bump loop), publish:

```swift
        snapshot.replace(freq)
```

(c) At the **end** of `remove(bufferID:)` (after the decrement loop), publish:

```swift
        snapshot.replace(freq)
```

(d) Replace the body of `suggestions(prefix:limit:)` to delegate to the shared ranking function (DRY — single source of ranking truth):

```swift
    func suggestions(prefix: String, limit: Int = 20) -> [String] {
        rankedWordSuggestions(from: freq, prefix: prefix, limit: limit)
    }
```

- [ ] **Step 6: Write the failing test that the snapshot tracks the actor**

Append to `TreemuxTests/BufferWordIndexTests.swift` (inside the existing test class):

```swift
    func test_snapshotMatchesActorAfterUpdate() async {
        let index = BufferWordIndex()
        let id = UUID()
        await index.update(bufferID: id, contents: "counter counting countdown")
        let viaActor = await index.suggestions(prefix: "count", limit: 10)
        let viaSnapshot = index.snapshot.suggestions(prefix: "count", limit: 10)
        XCTAssertEqual(viaSnapshot, viaActor)
        XCTAssertFalse(viaSnapshot.isEmpty)
    }

    func test_snapshotClearsAfterRemove() async {
        let index = BufferWordIndex()
        let id = UUID()
        await index.update(bufferID: id, contents: "counter counting")
        await index.remove(bufferID: id)
        XCTAssertEqual(index.snapshot.suggestions(prefix: "count", limit: 10), [])
    }
```

- [ ] **Step 7: Run BufferWordIndex tests**

Run:
```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -skipPackagePluginValidation -only-testing:TreemuxTests/BufferWordIndexTests 2>&1 | xcbeautify || true
```
Expected: PASS (existing tests + 2 new).

- [ ] **Step 8: Rewire the cursor-move hook; delete the semaphore**

In `Treemux/UI/FileBrowser/CompletionPopover.swift`:

(a) Replace the body of `completionOnCursorMove` (lines 106-125) so it reads the snapshot synchronously:

```swift
    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        guard isEnabled() else { return nil }
        guard let prefixInfo = synchronousPrefixInfo(in: textView, at: cursorPosition) else {
            return nil
        }
        guard prefixInfo.prefix.count >= Self.minPrefixLength else { return nil }

        // Read the published snapshot directly on the main thread — O(N) over an
        // in-memory dictionary, no actor await, no semaphore, no blocking wait.
        let words = wordIndex.snapshot.suggestions(prefix: prefixInfo.prefix,
                                                   limit: Self.suggestionLimit)
        guard !words.isEmpty else { return nil }

        return words.map { WordCompletionEntry(label: $0, prefixRange: prefixInfo.range) }
    }
```

(b) Delete `blockingSuggestions(prefix:)` (lines 212-227) and the `ResultBox` class (lines 229-234) entirely.

(c) Confirm both are gone and nothing else references them:

```bash
grep -n "blockingSuggestions\|ResultBox\|DispatchSemaphore" Treemux/UI/FileBrowser/CompletionPopover.swift
```
Expected: no output.

- [ ] **Step 9: Run the full suite**

Run the full-suite command. Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add Treemux/Services/Editor/WordIndexSnapshotStore.swift \
        TreemuxTests/WordIndexSnapshotStoreTests.swift \
        Treemux/Services/Editor/BufferWordIndex.swift \
        Treemux/UI/FileBrowser/CompletionPopover.swift \
        TreemuxTests/BufferWordIndexTests.swift
git commit -m "perf(editor): drop main-thread completion semaphore; read lock-free word snapshot"
```

---

## Task 3: Non-blocking file save

**Why:** `FileBrowserTabController.saveCurrentFile()` (`FileBrowserTabController.swift:581-590`) awaits `refreshDiffForActive()` and `refreshGitStatus()` **serially after** the disk write before returning. Each is a `git` subprocess round-trip on `MainActor`; the caller (⌘S) stays blocked until both finish, stuttering the UI. Fix: flip `dirty` to false immediately after the write, then fire-and-forget the refresh in a detached `Task` — the same pattern already used at line 331 (`Task { await self.refreshDiffForActive() }`).

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift:580-590`
- Modify: `TreemuxTests/FileBrowserTabControllerTests.swift`

- [ ] **Step 1: Inspect the test mock's git hooks**

Run, to confirm what the mock exposes (the test in Step 2 must drive `gitDiffService` / git status through whatever the mock supports):
```bash
grep -n "gitDiffService\|repoRoot\|GitDiffService\|writeFile\|class MockFileBrowserDataSource" \
  TreemuxTests/*.swift Treemux/UI/FileBrowser/FileBrowserTabController.swift | head -40
```
Note the results before writing the test — if `gitDiffService`/`repoRoot` are nil in the default test setup, `refreshDiffForActive()`/`refreshGitStatus()` early-return (see `FileBrowserTabController.swift:246` and `:261`), which is fine: the test then only needs to assert the write happened and `dirty` is cleared synchronously on return.

- [ ] **Step 2: Write the failing test**

Add to `TreemuxTests/FileBrowserTabControllerTests.swift`. This test asserts that `saveCurrentFile()` writes the buffer and clears `dirty` by the time it returns (the refresh is now detached and not part of the awaited path):

```swift
    func test_saveCurrentFile_writesAndClearsDirtyOnReturn() async throws {
        let mock = MockFileBrowserDataSource()
        mock.fileMetas["/r/a.txt"] = FileMetadata(path: "/r/a.txt", sizeBytes: 5, modifiedAt: nil,
                                                  isDirectory: false, isSymbolicLink: false)
        mock.fileContents["/r/a.txt"] = "hello".data(using: .utf8)!
        let ctrl = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/r", rootKind: .worktree), dataSource: mock)
        await ctrl.openInTree("/r/a.txt")
        ctrl.updateActiveBuffer(content: "hello world")   // marks dirty

        try await ctrl.saveCurrentFile()

        // On return: disk write happened and dirty is already cleared.
        XCTAssertEqual(mock.writtenFiles["/r/a.txt"].flatMap { String(data: $0, encoding: .utf8) },
                       "hello world")
        if case .text(_, let content, _, let dirty) = ctrl.openFile {
            XCTAssertEqual(content, "hello world")
            XCTAssertFalse(dirty, "dirty must be cleared synchronously on save return")
        } else {
            XCTFail("expected .text")
        }
    }
```

> **Adapt to the mock:** verify the exact names in Step 1. `updateActiveBuffer(content:)` is the public typing entry point — confirm its name with `grep -n "func update.*[Bb]uffer" Treemux/UI/FileBrowser/FileBrowserTabController.swift`; if it differs (e.g. `updateBuffer(content:forSubTab:)`), pass the active sub-tab id from `ctrl.activeSubTabID`. Likewise confirm the mock records writes (`writtenFiles` vs another name) via `grep -n "writeFile\|written" TreemuxTests/*.swift` and adjust the assertion accordingly.

- [ ] **Step 3: Run test to verify it fails (or passes for the wrong reason)**

Run:
```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -skipPackagePluginValidation -only-testing:TreemuxTests/FileBrowserTabControllerTests/test_saveCurrentFile_writesAndClearsDirtyOnReturn 2>&1 | xcbeautify || true
```
Expected: FAIL if the mock's API names differ (compile error) — fix names per Step 2's note until it compiles and passes against the *current* serial implementation. (This test passes before and after the refactor; it is a guard that the observable save contract — write + clear dirty — is preserved when we detach the refresh. The behavioral change, "refresh no longer blocks", is asserted by the implementation review, not a timing-flaky test.)

- [ ] **Step 4: Implement the non-blocking save**

In `Treemux/UI/FileBrowser/FileBrowserTabController.swift`, replace `saveCurrentFile()` (lines 581-590):

```swift
    /// Saves the current buffer back to disk via the data source. Returns as
    /// soon as the write completes and `dirty` is cleared; the git-status and
    /// diff refresh run off the save path so ⌘S never blocks on `git`.
    func saveCurrentFile() async throws {
        guard case .text(let path, let content, let encoding, _) = activeOpenFile else {
            return
        }
        let data = content.data(using: encoding) ?? Data()
        try await dataSource.writeFile(path, data: data)
        setActiveOpenFile(.text(path: path, content: content, encoding: encoding, dirty: false))
        // Fire-and-forget: diff + git status are non-essential to the save
        // completing and each is a `git` subprocess round-trip. Mirrors the
        // detached refresh already used after tree mutations (see line ~331).
        Task { [weak self] in
            await self?.refreshDiffForActive()
            await self?.refreshGitStatus()
        }
    }
```

- [ ] **Step 5: Run the focused test, then the full suite**

Run the Step 3 command (expect PASS), then the full-suite command (expect PASS — the detached `Task` must not leave the suite hanging; if a test that *asserts* git status after save exists, find it with `grep -rn "saveCurrentFile" TreemuxTests/` and `await` a refresh explicitly in that test instead of relying on the detached task).

- [ ] **Step 6: Commit**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift \
        TreemuxTests/FileBrowserTabControllerTests.swift
git commit -m "perf(editor): make file save non-blocking; detach git/diff refresh"
```

---

## Task 4: Verify the already-done sub-tab fix + audit the two secondary knobs

**Why:** This task does **no implementation unless profiling proves a need** — it confirms the spec's remaining items are already handled and documents the decision, so a future reader doesn't re-open them.

**Files:**
- Modify (docs only): `docs/superpowers/specs/2026-06-15-file-browser-experience-overhaul-design.md` (update the P2 progress note).

- [ ] **Step 1: Confirm the sub-tab-switch fix is in place**

Run:
```bash
grep -n "ZStack\|opacity\|allowsHitTesting\|activeSubTabID" Treemux/UI/FileBrowser/FileViewerPanelView.swift
```
Expected: the `ZStack { ForEach … .opacity(… == activeSubTabID ? 1 : 0) }` block (lines ~39-45) — editors are kept alive, not rebuilt. Record in the spec note that symptom #3 ("switching files/sub-tabs janky") is already resolved by P1's ZStack approach; no further work.

- [ ] **Step 2: Audit the 300 ms index debounce**

Read `Treemux/UI/FileBrowser/CompletionPopover.swift` around the `WordCompletionCoordinator` (the `debounceNanoseconds = 300_000_000` constant, ~line 251). Confirm the debounce only gates *re-indexing*, not the suggestion read path (which is now snapshot-backed and lock-free after Task 2). Decision: **leave at 300 ms** — it is off the typing critical path. Document this.

- [ ] **Step 3: Sanity-check highlighting on a large CJK file (manual)**

Build and run the app (per CLAUDE.md run instructions), open a representative large (~1–2 MB) CJK-heavy source file, and confirm: typing does not drop frames, the highlight gate behaves (highlight under 2 MB, plain over). If — and only if — profiling with Instruments (Time Profiler, main-thread) shows the 2 MB tree-sitter limit is itself the stall, file a follow-up; do **not** change the limit speculatively. Document the observation either way.

- [ ] **Step 4: Update the spec progress note**

In `docs/superpowers/specs/2026-06-15-file-browser-experience-overhaul-design.md`, update the line-7 progress note: mark **P2 done** (fixes #1 stat, #2 semaphore, #4 save), note #3 was already handled by the P1 ZStack, and that the 300 ms debounce / 2 MB limit were audited and intentionally left as-is.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-06-15-file-browser-experience-overhaul-design.md
git commit -m "docs: mark P2 editor smoothness done; record secondary-knob audit"
```

---

## Self-Review (completed during planning)

**Spec coverage** (feature 3 table, spec lines 168-175):
- "Open slow / typing drops frames → cache file size, never stat on render path" → **Task 1** (in-memory byte count via `EditorHighlightPolicy`, syscall removed). ✔
- "Typing drops frames → make completion async; drop the semaphore" → **Task 2** (lock-free snapshot read, semaphore + `ResultBox` deleted). ✔
- "Switching files/sub-tabs janky → keep editor alive, switch instead of rebuild" → **already done** on this branch (ZStack); verified + documented in **Task 4**. ✔
- "Save stutter → return immediately, run git/diff off the main path" → **Task 3** (detached refresh `Task`). ✔
- Secondary: 300 ms debounce + 2 MB highlight limit → audited, profile-gated in **Task 4**. ✔

**Design deviation from spec (intentional):** The spec suggests "cache file size at load time **into `OpenFileState`**." Adding a 5th associated value to `.text` ripples to ~20 pattern-match sites (including persistence/coding tests) for no functional gain. Task 1 instead uses the already-in-memory `content.utf8.count` through a pure policy function — this fully satisfies the actual requirement ("never stat on the render path") with no enum ripple and better fidelity (reflects loaded content, not on-disk size).

**Placeholder scan:** none — every code step contains complete code; every command shows expected output.

**Type consistency:** `EditorHighlightPolicy.shouldHighlight(path:byteCount:)` / `.highlightSizeLimit`, `WordIndexSnapshotStore.replace(_:)` / `.suggestions(prefix:limit:)`, `rankedWordSuggestions(from:prefix:limit:)`, and `BufferWordIndex.snapshot` are referenced with identical signatures across all tasks. ✔

**Validation (spec line 178):** before/after frame timing on a large + CJK file + manual feel check → Task 4 Step 3.
