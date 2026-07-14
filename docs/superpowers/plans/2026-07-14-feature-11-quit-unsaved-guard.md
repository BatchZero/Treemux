# Feature 11 — Quit-Time Unsaved-Files Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Warn with one aggregate alert (listing filenames) when the user quits the app while any file sub-tab has unsaved edits; Cancel aborts the quit, Quit Anyway proceeds.

**Architecture:** A pure `UnsavedQuitPrompt` decomposes the unsaved paths into a locale-independent `Plan` (dedup + name list + overflow) and composes localized alert copy from it. Thin `unsavedFilePaths` accessors on `WorkspaceModel` and `WorkspaceStore` walk the existing file-browser controllers' `dirtySubTabs`. `AppDelegate.applicationShouldTerminate(_:)` gathers the paths, builds the prompt, and shows an `NSAlert`.

**Tech Stack:** Swift, AppKit (`NSApplicationDelegate`, `NSAlert`), XCTest.

## Global Constraints

- Communicate with the user in Chinese; code comments in English.
- All code changes happen in a git worktree under `.worktrees/<branch>/` (`/` → `+`); the main repo stays on `main`.
- Colors must use theme tokens — N/A here (system `NSAlert`, no custom colors).
- User-visible strings use `String(localized:)` (AppKit context) + a `zh-Hans` entry in `Treemux/Localizable.xcstrings`. This feature ADDS user-visible strings — every new one needs a zh-Hans translation.
- Guard is discard-only: NO "Save All" action, NO cross-restart preservation.
- Cancel is the alert's keyboard default (Return) to prevent accidental quit; Quit Anyway is marked destructive.
- This repo uses xcodegen with a checked-in `Treemux.xcodeproj/project.pbxproj`: adding NEW source files requires running `xcodegen generate` and committing the pbxproj change (verify it only registers the new files).
- Build/test non-interactively with `-skipPackagePluginValidation` (SwiftLint plugin).

---

### Task 1: `UnsavedQuitPrompt` pure builder + tests

**Files:**
- Create: `Treemux/Domain/UnsavedQuitPrompt.swift`
- Test: `TreemuxTests/UnsavedQuitPromptTests.swift`

**Interfaces:**
- Produces: `enum UnsavedQuitPrompt` with `static let maxListed = 5`, a nested
  `struct Plan: Equatable { let uniqueCount: Int; let listedNames: [String]; let overflowCount: Int }`,
  `static func plan(paths: [String]) -> Plan?` (pure, locale-independent), and
  `static func build(paths: [String]) -> (message: String, informative: String)?`
  (localized copy; nil when nothing unsaved). Task 2's AppDelegate hook calls `build`.

- [ ] **Step 1: Write the failing tests**

Create `TreemuxTests/UnsavedQuitPromptTests.swift`:

```swift
//
//  UnsavedQuitPromptTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class UnsavedQuitPromptTests: XCTestCase {
    func testEmpty_returnsNil() {
        XCTAssertNil(UnsavedQuitPrompt.plan(paths: []))
        XCTAssertNil(UnsavedQuitPrompt.build(paths: []))
    }

    func testSingle_oneNameNoOverflow() {
        let plan = UnsavedQuitPrompt.plan(paths: ["/a/b/notes.md"])
        XCTAssertEqual(plan, UnsavedQuitPrompt.Plan(
            uniqueCount: 1, listedNames: ["notes.md"], overflowCount: 0))
    }

    func testFew_allListedNoOverflow() {
        let plan = UnsavedQuitPrompt.plan(paths: ["/x/a.txt", "/x/b.txt", "/x/c.txt"])
        XCTAssertEqual(plan?.uniqueCount, 3)
        XCTAssertEqual(plan?.listedNames, ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(plan?.overflowCount, 0)
    }

    func testMany_listsMaxThenOverflow() {
        let paths = (1...7).map { "/x/f\($0).swift" }
        let plan = UnsavedQuitPrompt.plan(paths: paths)
        XCTAssertEqual(plan?.uniqueCount, 7)
        XCTAssertEqual(plan?.listedNames.count, UnsavedQuitPrompt.maxListed) // 5
        XCTAssertEqual(plan?.listedNames, ["f1.swift", "f2.swift", "f3.swift", "f4.swift", "f5.swift"])
        XCTAssertEqual(plan?.overflowCount, 2)
    }

    func testDuplicatePaths_deduped() {
        let plan = UnsavedQuitPrompt.plan(paths: ["/a/x.txt", "/a/x.txt", "/b/y.txt"])
        XCTAssertEqual(plan?.uniqueCount, 2)
        XCTAssertEqual(plan?.listedNames, ["x.txt", "y.txt"])
        XCTAssertEqual(plan?.overflowCount, 0)
    }

    func testBuild_nonNilForNonEmpty() {
        // Locale-independent structural checks: message + informative present,
        // informative contains the filename and the discard hint.
        let out = UnsavedQuitPrompt.build(paths: ["/a/b/report.md"])
        XCTAssertNotNil(out)
        XCTAssertFalse(out!.message.isEmpty)
        XCTAssertTrue(out!.informative.contains("report.md"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
cd .worktrees/feat+feature-11-quit-unsaved-guard
xcodebuild test -project Treemux.xcodeproj -scheme Treemux \
  -skipPackagePluginValidation \
  -only-testing:TreemuxTests/UnsavedQuitPromptTests 2>&1 | tail -20
```
Expected: FAIL — `UnsavedQuitPrompt` does not exist (unresolved identifier / compile error).

- [ ] **Step 3: Create the implementation**

Create `Treemux/Domain/UnsavedQuitPrompt.swift`:

```swift
//
//  UnsavedQuitPrompt.swift
//  Treemux
//

import Foundation

/// Builds the aggregate "you have unsaved files" alert copy shown when quitting
/// the app. Split into a pure, locale-independent `plan(paths:)` (dedup + name
/// list + overflow count) and a thin `build(paths:)` that composes localized
/// strings from it.
enum UnsavedQuitPrompt {
    /// Maximum number of filenames listed before collapsing the rest into an
    /// "…and N more." line.
    static let maxListed = 5

    /// Locale-independent decomposition of the unsaved paths. `nil` when there
    /// is nothing unsaved (caller lets the quit proceed).
    struct Plan: Equatable {
        let uniqueCount: Int
        let listedNames: [String]
        let overflowCount: Int
    }

    static func plan(paths: [String]) -> Plan? {
        var seen = Set<String>()
        var unique: [String] = []
        for path in paths where seen.insert(path).inserted {
            unique.append(path)
        }
        guard !unique.isEmpty else { return nil }
        let names = unique.map { URL(fileURLWithPath: $0).lastPathComponent }
        let listed = Array(names.prefix(maxListed))
        return Plan(
            uniqueCount: unique.count,
            listedNames: listed,
            overflowCount: unique.count - listed.count
        )
    }

    /// Localized `(message, informative)` for the alert, or `nil` when nothing
    /// is unsaved.
    static func build(paths: [String]) -> (message: String, informative: String)? {
        guard let plan = plan(paths: paths) else { return nil }
        let message = plan.uniqueCount == 1
            ? String(localized: "1 file has unsaved changes.")
            : String.localizedStringWithFormat(
                String(localized: "%d files have unsaved changes."), plan.uniqueCount)
        var lines = plan.listedNames
        if plan.overflowCount > 0 {
            lines.append(String.localizedStringWithFormat(
                String(localized: "…and %d more."), plan.overflowCount))
        }
        lines.append("")
        lines.append(String(localized: "Quitting now will discard these changes."))
        return (message, lines.joined(separator: "\n"))
    }
}
```

- [ ] **Step 4: Register the new files (xcodegen) and run the tests**

The repo uses xcodegen with a checked-in pbxproj; the two new files must be
registered before they build.

Run:
```bash
cd .worktrees/feat+feature-11-quit-unsaved-guard
xcodegen generate
git diff --stat Treemux.xcodeproj/project.pbxproj
```
Confirm the pbxproj diff only adds references to `UnsavedQuitPrompt.swift` and `UnsavedQuitPromptTests.swift` (no unrelated churn).

Then:
```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux \
  -skipPackagePluginValidation \
  -only-testing:TreemuxTests/UnsavedQuitPromptTests 2>&1 | tail -20
```
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Treemux/Domain/UnsavedQuitPrompt.swift TreemuxTests/UnsavedQuitPromptTests.swift Treemux.xcodeproj/project.pbxproj
git commit -m "feat(quit): add UnsavedQuitPrompt pure alert-copy builder"
```

---

### Task 2: Enumeration accessors + `applicationShouldTerminate` guard + i18n

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift` (add `WorkspaceModel.unsavedFilePaths`)
- Modify: `Treemux/App/WorkspaceStore.swift` (add `WorkspaceStore.unsavedFilePaths`)
- Modify: `Treemux/AppDelegate.swift` (add `applicationShouldTerminate(_:)`)
- Modify: `Treemux/Localizable.xcstrings` (zh-Hans for the new strings)

**Interfaces:**
- Consumes: `UnsavedQuitPrompt.build(paths:)` (Task 1); the existing
  `FileBrowserTabController.dirtySubTabs` (each `SubTabRuntime` has `.path`);
  `WorkspaceModel.fileBrowserControllers` (private `[String: [UUID: FileBrowserTabController]]`);
  `WorkspaceStore.workspaces: [WorkspaceModel]`; `AppDelegate.store` (`treemuxApp?.store`).
- Produces: `WorkspaceModel.unsavedFilePaths: [String]`, `WorkspaceStore.unsavedFilePaths: [String]`, and the terminate guard.

- [ ] **Step 1: Add `WorkspaceModel.unsavedFilePaths`**

In `Treemux/Domain/WorkspaceModels.swift`, next to the `fileBrowserController(forTabID:)` method on `WorkspaceModel`, add:

```swift
    /// Paths of all file sub-tabs, across this workspace's instantiated
    /// file-browser controllers, that currently have unsaved text edits.
    var unsavedFilePaths: [String] {
        fileBrowserControllers.values
            .flatMap { $0.values }
            .flatMap { $0.dirtySubTabs.map(\.path) }
    }
```

- [ ] **Step 2: Add `WorkspaceStore.unsavedFilePaths`**

In `Treemux/App/WorkspaceStore.swift`, on `WorkspaceStore`, add:

```swift
    /// Paths of all file sub-tabs with unsaved edits across every workspace.
    /// Used by the quit guard to decide whether to warn before terminating.
    var unsavedFilePaths: [String] {
        workspaces.flatMap { $0.unsavedFilePaths }
    }
```

- [ ] **Step 3: Add the terminate guard to `AppDelegate`**

In `Treemux/AppDelegate.swift`, add this method immediately after
`applicationWillTerminate(_:)` (note: `applicationShouldTerminate` is called by
AppKit BEFORE `applicationWillTerminate`, so ordering is correct — the guard runs
first, and only a `.terminateNow` leads to the existing `shutdown()`):

```swift
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store,
              let prompt = UnsavedQuitPrompt.build(paths: store.unsavedFilePaths) else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prompt.message
        alert.informativeText = prompt.informative
        let quit = alert.addButton(withTitle: String(localized: "Quit Anyway"))
        quit.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        cancel.keyEquivalent = "\r" // Return = Cancel, prevents accidental quit
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
```

(Use the existing `store` computed accessor — `private var store: WorkspaceStore? { treemuxApp?.store }` — already defined in this file.)

- [ ] **Step 4: Add zh-Hans translations**

Open `Treemux/Localizable.xcstrings` and add a `zh-Hans` translation for each new
string key (create the key entry if absent, following the existing entries'
JSON shape). Use these translations:

| Key (en, source) | zh-Hans |
|---|---|
| `1 file has unsaved changes.` | `有 1 个文件未保存更改。` |
| `%d files have unsaved changes.` | `有 %d 个文件未保存更改。` |
| `…and %d more.` | `…以及另外 %d 个。` |
| `Quitting now will discard these changes.` | `现在退出将丢弃这些更改。` |
| `Quit Anyway` | `仍然退出` |
| `Cancel` | `取消` |

If `Cancel` already has a `zh-Hans` entry in the catalog, leave the existing one
as-is (do not duplicate). Verify the file remains valid JSON after editing.

- [ ] **Step 5: Build and run the full suite**

Run:
```bash
cd .worktrees/feat+feature-11-quit-unsaved-guard
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -skipPackagePluginValidation 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`. Fix any compile errors until it builds.

Then:
```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -skipPackagePluginValidation 2>&1 | tail -15
```
Expected: all tests pass (the `UnsavedQuitPromptTests` from Task 1 included).

- [ ] **Step 6: Commit**

```bash
git add Treemux/Domain/WorkspaceModels.swift Treemux/App/WorkspaceStore.swift \
        Treemux/AppDelegate.swift Treemux/Localizable.xcstrings
git commit -m "feat(quit): warn on quit when file tabs have unsaved edits"
```

---

## Manual Verification (final review / GUI smoke)

- Edit a file so a sub-tab is dirty (title shows the dirty marker). Press ⌘Q →
  an alert appears listing that filename with the discard hint; press Cancel →
  the app stays open. Press ⌘Q again → Quit Anyway → the app quits.
- Make several files dirty across tabs / workspaces → all listed (up to 5, then
  "…and N more.").
- With no dirty files, ⌘Q quits immediately with no alert.
- Switch the app language to 简体中文 and repeat → the alert text is in Chinese.
