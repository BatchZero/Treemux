# Hook Preview Diff Highlighting & Manual Backup — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add line-level red/green diff highlighting to `HookPreviewSheet` and a per-file manual `Backup` button that snapshots the existing config to `~/.treemux/backups/<targetID>/<providerKind>/<basename>.<timestamp>` with success / failure feedback.

**Architecture:** Pure Swift `HookDiff` algorithm built on `CollectionDifference` produces `[DiffLine]` arrays for each side; the sheet renders them with monospaced text and per-line backgrounds. A new `@MainActor` `HookBackupService` writes `HookInstallChange.current` strings to a deterministic local path; `HookPreviewSheet` keeps a per-change `BackupState` map and surfaces success / `Show in Finder` / failure inline. Provider, installer, and filesystem layers are not modified.

**Tech Stack:** Swift 5.9+ / SwiftUI, XCTest, Foundation `FileManager` + `DateFormatter`, `NSWorkspace.activateFileViewerSelecting`, Xcode strings catalog (`Localizable.xcstrings`).

**Reference design:** `docs/plans/2026-04-29-hook-preview-diff-and-backup-design.md`

---

## Task 0: Set up worktree

**Files:** none

**Step 1: Create the worktree**

Run from repo root:
```bash
git worktree add .worktrees/feat+hook-preview-diff-and-backup -b feat/hook-preview-diff-and-backup
```

**Step 2: Verify**

Run: `git worktree list`
Expected: a line showing `.worktrees/feat+hook-preview-diff-and-backup [feat/hook-preview-diff-and-backup]`.

**Step 3: cd into the worktree**

All subsequent paths in this plan are relative to `.worktrees/feat+hook-preview-diff-and-backup/`.

```bash
cd .worktrees/feat+hook-preview-diff-and-backup
```

---

## Task 1: HookDiff types + identical-input case

**Files:**
- Create: `Treemux/UI/Sheets/HookDiff.swift`
- Create: `TreemuxTests/HookDiffTests.swift`

**Step 1: Write the failing test**

Create `TreemuxTests/HookDiffTests.swift`:
```swift
import XCTest
@testable import Treemux

final class HookDiffTests: XCTestCase {

    func testIdenticalInputsAllUnchanged() {
        let text = "alpha\nbeta\ngamma"
        let result = HookDiff.compute(current: text, proposed: text)

        XCTAssertEqual(result.before.map(\.text), ["alpha", "beta", "gamma"])
        XCTAssertEqual(result.after.map(\.text),  ["alpha", "beta", "gamma"])
        XCTAssertTrue(result.before.allSatisfy { $0.mark == .unchanged })
        XCTAssertTrue(result.after.allSatisfy  { $0.mark == .unchanged })
    }
}
```

**Step 2: Run test to verify it fails**

Run from repo root (the project itself lives at the worktree root):
```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' test -only-testing:TreemuxTests/HookDiffTests 2>&1 | tail -30
```
Expected: compilation fails — `HookDiff` / `DiffLine` / `DiffMark` undefined.

**Step 3: Create the type stubs and minimal implementation**

Create `Treemux/UI/Sheets/HookDiff.swift`:
```swift
//
//  HookDiff.swift
//  Treemux
//

import Foundation

enum DiffMark: Equatable {
    case unchanged
    case removed
    case added
}

struct DiffLine: Identifiable, Equatable {
    let id: Int
    let text: String
    let mark: DiffMark
}

enum HookDiff {
    /// Compute line-level diff between `current` and `proposed`.
    /// `before` contains only `.unchanged` and `.removed` lines.
    /// `after`  contains only `.unchanged` and `.added` lines.
    /// When `current == nil`, before is a single placeholder
    /// `(file does not exist)` line and after is all `.added`.
    static func compute(current: String?, proposed: String) -> (before: [DiffLine], after: [DiffLine]) {
        let oldLines = current.map { splitLines($0) } ?? []
        let newLines = splitLines(proposed)

        if current == nil {
            let placeholder = [DiffLine(id: 0, text: "(file does not exist)", mark: .unchanged)]
            let after = newLines.enumerated().map { DiffLine(id: $0.offset, text: $0.element, mark: .added) }
            return (placeholder, after)
        }

        let diff = newLines.difference(from: oldLines)
        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removedOffsets.insert(offset)
            case .insert(let offset, _, _): insertedOffsets.insert(offset)
            }
        }

        let before = oldLines.enumerated().map { idx, text in
            DiffLine(id: idx, text: text, mark: removedOffsets.contains(idx) ? .removed : .unchanged)
        }
        let after = newLines.enumerated().map { idx, text in
            DiffLine(id: idx, text: text, mark: insertedOffsets.contains(idx) ? .added : .unchanged)
        }
        return (before, after)
    }

    /// Split on `\n` but preserve empty trailing lines so a file ending
    /// in `\n` shows the same line count before and after.
    private static func splitLines(_ s: String) -> [String] {
        s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
```

**Step 4: Add `HookDiff.swift` and `HookDiffTests.swift` to the Xcode project**

Open `Treemux.xcodeproj` and add the two files to:
- `HookDiff.swift` → `Treemux` target, group `UI/Sheets`
- `HookDiffTests.swift` → `TreemuxTests` target, group `TreemuxTests`

(The repo uses a real `pbxproj`; new files must be referenced before they can be compiled.)

**Step 5: Run test to verify it passes**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' test -only-testing:TreemuxTests/HookDiffTests/testIdenticalInputsAllUnchanged 2>&1 | tail -20
```
Expected: `Test Suite ... passed`.

**Step 6: Commit**

```bash
git add Treemux/UI/Sheets/HookDiff.swift TreemuxTests/HookDiffTests.swift Treemux.xcodeproj/project.pbxproj
git commit -m "feat: HookDiff line-level differ with identical-input baseline test"
```

---

## Task 2: HookDiff additions, removals, and mixed cases

**Files:**
- Modify: `TreemuxTests/HookDiffTests.swift`

**Step 1: Add three failing tests**

Append to `TreemuxTests/HookDiffTests.swift`:
```swift
extension HookDiffTests {

    func testPureAdditions() {
        let result = HookDiff.compute(
            current:  "alpha\nbeta",
            proposed: "alpha\nbeta\ngamma\ndelta"
        )

        XCTAssertEqual(result.before.map(\.mark), [.unchanged, .unchanged])
        XCTAssertEqual(result.after.map(\.mark),  [.unchanged, .unchanged, .added, .added])
        XCTAssertEqual(result.after.map(\.text),  ["alpha", "beta", "gamma", "delta"])
    }

    func testPureRemovals() {
        let result = HookDiff.compute(
            current:  "alpha\nbeta\ngamma\ndelta",
            proposed: "alpha\nbeta"
        )

        XCTAssertEqual(result.before.map(\.mark), [.unchanged, .unchanged, .removed, .removed])
        XCTAssertEqual(result.before.map(\.text), ["alpha", "beta", "gamma", "delta"])
        XCTAssertEqual(result.after.map(\.mark),  [.unchanged, .unchanged])
    }

    func testMixedInsertAndDelete() {
        let result = HookDiff.compute(
            current:  "a\nb\nc\nd",
            proposed: "a\nB\nc\nE"
        )

        // before: a (unchanged), b (removed), c (unchanged), d (removed)
        XCTAssertEqual(result.before.map(\.text), ["a", "b", "c", "d"])
        XCTAssertEqual(result.before.map(\.mark),
                       [.unchanged, .removed, .unchanged, .removed])

        // after: a (unchanged), B (added), c (unchanged), E (added)
        XCTAssertEqual(result.after.map(\.text), ["a", "B", "c", "E"])
        XCTAssertEqual(result.after.map(\.mark),
                       [.unchanged, .added, .unchanged, .added])
    }
}
```

**Step 2: Run tests to verify they pass**

The implementation from Task 1 should already cover these cases.
```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' test -only-testing:TreemuxTests/HookDiffTests 2>&1 | tail -20
```
Expected: all 4 tests pass.

If a case fails, debug `HookDiff.compute` (most likely culprit: incorrect handling of `CollectionDifference.Change.offset` semantics — `.remove` offsets are indices into the old array; `.insert` offsets are indices into the new array, which is exactly what we want).

**Step 3: Commit**

```bash
git add TreemuxTests/HookDiffTests.swift
git commit -m "test: HookDiff add/remove/mixed cases"
```

---

## Task 3: HookDiff edge cases — nil current and trailing blank line

**Files:**
- Modify: `TreemuxTests/HookDiffTests.swift`

**Step 1: Add two failing tests**

Append to `TreemuxTests/HookDiffTests.swift`:
```swift
extension HookDiffTests {

    func testCurrentNilUsesPlaceholderBefore() {
        let result = HookDiff.compute(current: nil, proposed: "first\nsecond")

        XCTAssertEqual(result.before.count, 1)
        XCTAssertEqual(result.before[0].text, "(file does not exist)")
        XCTAssertEqual(result.before[0].mark, .unchanged)

        XCTAssertEqual(result.after.map(\.text), ["first", "second"])
        XCTAssertTrue(result.after.allSatisfy { $0.mark == .added })
    }

    func testTrailingNewlinePreservedAsEmptyLine() {
        // "a\nb\n" splits into ["a", "b", ""]; the empty trailing line
        // must round-trip through the diff with an .unchanged mark.
        let result = HookDiff.compute(current: "a\nb\n", proposed: "a\nb\n")

        XCTAssertEqual(result.before.map(\.text), ["a", "b", ""])
        XCTAssertEqual(result.after.map(\.text),  ["a", "b", ""])
        XCTAssertTrue(result.before.allSatisfy { $0.mark == .unchanged })
    }
}
```

**Step 2: Run tests**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' test -only-testing:TreemuxTests/HookDiffTests 2>&1 | tail -20
```
Expected: 6 tests pass.

**Step 3: Commit**

```bash
git add TreemuxTests/HookDiffTests.swift
git commit -m "test: HookDiff nil-current and trailing-newline edge cases"
```

---

## Task 4: HookBackupService skeleton + happy-path local backup test

**Files:**
- Create: `Treemux/Services/AITool/HookBackupService.swift`
- Create: `TreemuxTests/HookBackupServiceTests.swift`

**Step 1: Write the failing test**

Create `TreemuxTests/HookBackupServiceTests.swift`:
```swift
import XCTest
@testable import Treemux

@MainActor
final class HookBackupServiceTests: XCTestCase {

    private var tempHome: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("treemux-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempHome)
        try await super.tearDown()
    }

    // Fixed timestamp for deterministic file names.
    private func fixedNow(_ y: Int = 2026, _ mo: Int = 4, _ d: Int = 29,
                          _ h: Int = 15, _ mi: Int = 30, _ s: Int = 12) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d
        c.hour = h; c.minute = mi; c.second = s
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func testBackupLocalWritesExpectedPath() async throws {
        let service = HookBackupService(now: { self.fixedNow() }, home: tempHome)
        let change = HookInstallChange(
            path: "~/.claude/settings.json",
            proposed: "{}",
            current: "{\n  \"hooks\": {}\n}\n"
        )

        let result = try await service.backup(
            change: change,
            target: .local,
            provider: ClaudeCodeHookProvider()
        )

        let expected = tempHome
            .appendingPathComponent(".treemux/backups/local/claude/settings.json.20260429-153012")
        XCTAssertEqual(result.localPath.path, expected.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
        XCTAssertEqual(try String(contentsOf: expected), "{\n  \"hooks\": {}\n}\n")
    }
}
```

**Step 2: Run test to verify it fails**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' test -only-testing:TreemuxTests/HookBackupServiceTests/testBackupLocalWritesExpectedPath 2>&1 | tail -30
```
Expected: compilation fails — `HookBackupService` undefined.

**Step 3: Create the service**

Create `Treemux/Services/AITool/HookBackupService.swift`:
```swift
//
//  HookBackupService.swift
//  Treemux
//

import Foundation

/// Result of a successful backup write.
struct HookBackupResult: Equatable {
    let localPath: URL
    let timestamp: Date
}

/// Persist a `HookInstallChange.current` snapshot to a deterministic local path
/// before `AIHookInstaller.install` overwrites it. Always writes to the user's
/// home — remote targets back up the previously-fetched `current` text locally,
/// not back to the remote host.
@MainActor
final class HookBackupService {
    private let now: () -> Date
    private let home: URL
    private let fm: FileManager

    init(now: @escaping () -> Date = Date.init,
         home: URL = URL(fileURLWithPath: NSHomeDirectory()),
         fm: FileManager = .default) {
        self.now = now
        self.home = home
        self.fm = fm
    }

    func backup(
        change: HookInstallChange,
        target: HookTarget,
        provider: AIHookProvider
    ) async throws -> HookBackupResult {
        guard let current = change.current else {
            throw HookInstallError.ioError("Nothing to back up: file does not exist")
        }

        let timestamp = now()
        let dir = home
            .appendingPathComponent(".treemux/backups", isDirectory: true)
            .appendingPathComponent(Self.sanitize(target.id), isDirectory: true)
            .appendingPathComponent(provider.kind.rawValue, isDirectory: true)
        let basename = (change.path as NSString).lastPathComponent
        let filename = "\(basename).\(Self.formatter.string(from: timestamp))"
        let url = dir.appendingPathComponent(filename)

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try current.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw HookInstallError.ioError("backup \(url.path): \(error.localizedDescription)")
        }
        return HookBackupResult(localPath: url, timestamp: timestamp)
    }

    /// Replace `:` (used in `remote:user@host`) so Finder displays the path
    /// correctly. Leave other characters alone.
    private static func sanitize(_ id: String) -> String {
        id.replacingOccurrences(of: ":", with: "_")
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
```

**Step 4: Add both files to the Xcode project**

- `HookBackupService.swift` → `Treemux` target, group `Services/AITool`
- `HookBackupServiceTests.swift` → `TreemuxTests` target

**Step 5: Run test**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' test -only-testing:TreemuxTests/HookBackupServiceTests 2>&1 | tail -20
```
Expected: pass.

**Step 6: Commit**

```bash
git add Treemux/Services/AITool/HookBackupService.swift TreemuxTests/HookBackupServiceTests.swift Treemux.xcodeproj/project.pbxproj
git commit -m "feat: HookBackupService writes timestamped snapshots under ~/.treemux/backups/"
```

---

## Task 5: HookBackupService remote sanitization, missing-current error, intermediate dirs

**Files:**
- Modify: `TreemuxTests/HookBackupServiceTests.swift`

**Step 1: Add three failing tests**

Append to `TreemuxTests/HookBackupServiceTests.swift`:
```swift
extension HookBackupServiceTests {

    func testBackupRemoteSanitizesColonInTargetID() async throws {
        let service = HookBackupService(now: { self.fixedNow() }, home: tempHome)
        let target = HookTarget.remote(SSHTarget(host: "user@example.com",
                                                 port: 22,
                                                 user: "user",
                                                 identityFile: nil))
        let change = HookInstallChange(
            path: "~/.codex/config.toml",
            proposed: "x = 2",
            current: "x = 1"
        )

        let result = try await service.backup(
            change: change,
            target: target,
            provider: CodexHookProvider()
        )

        // target.id is "remote:user@example.com" → sanitized "remote_user@example.com"
        let expected = tempHome
            .appendingPathComponent(".treemux/backups/remote_user@example.com/codex/config.toml.20260429-153012")
        XCTAssertEqual(result.localPath.path, expected.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    }

    func testBackupThrowsWhenCurrentIsNil() async throws {
        let service = HookBackupService(now: { self.fixedNow() }, home: tempHome)
        let change = HookInstallChange(
            path: "~/.claude/settings.json",
            proposed: "{}",
            current: nil
        )

        do {
            _ = try await service.backup(
                change: change,
                target: .local,
                provider: ClaudeCodeHookProvider()
            )
            XCTFail("Expected error")
        } catch HookInstallError.ioError(let msg) {
            XCTAssertTrue(msg.contains("Nothing to back up"))
        }
    }

    func testBackupCreatesMissingIntermediateDirectories() async throws {
        // tempHome contains no .treemux subtree yet — service must create it.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempHome.appendingPathComponent(".treemux").path))

        let service = HookBackupService(now: { self.fixedNow() }, home: tempHome)
        let change = HookInstallChange(
            path: "~/.claude/settings.json",
            proposed: "{}",
            current: "{}"
        )

        _ = try await service.backup(change: change, target: .local,
                                     provider: ClaudeCodeHookProvider())

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempHome.appendingPathComponent(".treemux/backups/local/claude").path))
    }
}
```

**Step 2: Verify the SSHTarget initializer matches what the project ships**

Run: `grep -n "init" Treemux/Services/SSH/SSHTarget.swift 2>/dev/null || grep -rn "struct SSHTarget" Treemux/`
Reconcile the test's `SSHTarget(...)` call with the actual initializer signature; adjust args if needed.

**Step 3: Run tests**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' test -only-testing:TreemuxTests/HookBackupServiceTests 2>&1 | tail -20
```
Expected: all 4 tests pass.

**Step 4: Commit**

```bash
git add TreemuxTests/HookBackupServiceTests.swift
git commit -m "test: HookBackupService remote sanitization, nil-current error, intermediate dirs"
```

---

## Task 6: HookBackupService produces distinct timestamped files

**Files:**
- Modify: `TreemuxTests/HookBackupServiceTests.swift`

**Step 1: Add the failing test**

Append to `TreemuxTests/HookBackupServiceTests.swift`:
```swift
extension HookBackupServiceTests {

    func testBackupTwiceProducesDistinctFiles() async throws {
        var counter = 0
        let service = HookBackupService(
            now: {
                counter += 1
                return self.fixedNow(2026, 4, 29, 15, 30, counter)
            },
            home: tempHome
        )
        let change = HookInstallChange(
            path: "~/.claude/settings.json",
            proposed: "{}",
            current: "{}"
        )

        let first = try await service.backup(change: change, target: .local,
                                             provider: ClaudeCodeHookProvider())
        let second = try await service.backup(change: change, target: .local,
                                              provider: ClaudeCodeHookProvider())

        XCTAssertNotEqual(first.localPath, second.localPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.localPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.localPath.path))
    }
}
```

**Step 2: Run tests**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' test -only-testing:TreemuxTests/HookBackupServiceTests 2>&1 | tail -20
```
Expected: 5 tests pass.

**Step 3: Commit**

```bash
git add TreemuxTests/HookBackupServiceTests.swift
git commit -m "test: HookBackupService distinguishes consecutive backups by timestamp"
```

---

## Task 7: HookPreviewSheet renders line-level diff highlighting

**Files:**
- Modify: `Treemux/UI/Sheets/HookPreviewSheet.swift`

**Step 1: Replace the `column` and `changeView` rendering with diff-aware versions**

The current implementation renders raw text in two `ScrollView`s. Refactor to compute the diff once per change and render `LazyVStack` rows with per-line backgrounds.

Replace `private func changeView(_ change:)` and `private func column(title:text:)` with the following:

```swift
    private func changeView(_ change: HookInstallChange) -> some View {
        let diff = HookDiff.compute(current: change.current, proposed: change.proposed)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(change.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                // Backup button slot — wired in Task 8.
            }
            HStack(alignment: .top, spacing: 8) {
                diffColumn(title: "Before", lines: diff.before, side: .before)
                diffColumn(title: "After",  lines: diff.after,  side: .after)
            }
            .frame(minHeight: 180, idealHeight: 220)
        }
    }

    private enum DiffSide { case before, after }

    private func diffColumn(title: LocalizedStringKey, lines: [DiffLine], side: DiffSide) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        diffLineRow(line, side: side)
                    }
                }
                .padding(.vertical, 4)
            }
            .background(Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func diffLineRow(_ line: DiffLine, side: DiffSide) -> some View {
        let prefix: String = {
            switch line.mark {
            case .unchanged: return "  "
            case .removed:   return "- "
            case .added:     return "+ "
            }
        }()
        let bg: Color = {
            switch line.mark {
            case .unchanged: return .clear
            case .removed:   return Color.red.opacity(0.18)
            case .added:     return Color.green.opacity(0.18)
            }
        }()
        let fg: Color = {
            switch line.mark {
            case .unchanged: return .primary
            case .removed:   return .red
            case .added:     return .green
            }
        }()

        Text(prefix + line.text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(bg)
            .textSelection(.enabled)
    }
```

Note: the `Backup button slot` placeholder in `changeView` is intentional — Task 8 fills it in.

**Step 2: Build to ensure no compile errors**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' build 2>&1 | tail -10
```
Expected: `BUILD SUCCEEDED`.

**Step 3: Visual sanity-check via Xcode preview**

Open `HookPreviewSheet.swift` in Xcode and resume the preview if a `#Preview` block exists. If none exists, add one for testing only (do not commit it):
```swift
#Preview {
    HookPreviewSheet(model: HookPreviewModel(
        kind: .claudeCode,
        target: .local,
        displayName: "Claude Code",
        changes: [
            HookInstallChange(
                path: "~/.claude/settings.json",
                proposed: "{\n  \"hooks\": {\n    \"Notification\": []\n  }\n}",
                current:  "{\n  \"hooks\": {}\n}"
            )
        ],
        onApply: { }
    ))
}
```
Confirm:
- Removed lines have a red-tinted background and red text.
- Added lines have a green-tinted background and green text.
- Unchanged lines have no background.
- The before/after columns scroll independently.

Remove the temporary `#Preview` block before committing if you added one.

**Step 4: Commit**

```bash
git add Treemux/UI/Sheets/HookPreviewSheet.swift
git commit -m "feat: HookPreviewSheet renders line-level diff with red/green highlights"
```

---

## Task 8: Add per-change Backup button with state machine

**Files:**
- Modify: `Treemux/UI/Sheets/HookPreviewSheet.swift`

**Step 1: Add backup state types and instance state**

Inside `struct HookPreviewSheet`, add:
```swift
    private enum BackupState: Equatable {
        case idle
        case inProgress
        case success(URL)
        case failure(String)
    }

    @State private var backupStates: [String: BackupState] = [:]
    private let backupService = HookBackupService()
```

**Step 2: Replace the `Backup button slot` placeholder with the real button**

In `changeView`, replace the placeholder comment line with:
```swift
                backupControl(for: change)
```

**Step 3: Implement `backupControl`**

Add to `HookPreviewSheet`:
```swift
    @ViewBuilder
    private func backupControl(for change: HookInstallChange) -> some View {
        let state = backupStates[change.path] ?? .idle
        switch state {
        case .idle:
            Button("Backup") { triggerBackup(change) }
                .disabled(change.current == nil)
                .help(change.current == nil
                      ? Text("Nothing to back up (new file)")
                      : Text("Save the current file to ~/.treemux/backups/"))
        case .inProgress:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Backing up…").font(.caption)
            }
        case .success(let url):
            HStack(spacing: 6) {
                Text("Backed up ✓").font(.caption).foregroundStyle(.secondary)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        case .failure:
            // Failure restores the Backup button; the message renders below
            // the diff in `failureMessage(for:)` (added in Task 9).
            Button("Backup") { triggerBackup(change) }
        }
    }

    private func triggerBackup(_ change: HookInstallChange) {
        backupStates[change.path] = .inProgress
        Task {
            do {
                let result = try await backupService.backup(
                    change: change,
                    target: model.target,
                    provider: providerForCurrentChange(change) ?? ClaudeCodeHookProvider()
                )
                backupStates[change.path] = .success(result.localPath)
            } catch {
                backupStates[change.path] = .failure(error.localizedDescription)
            }
        }
    }

    /// Resolve a provider instance from the model's `kind`. The sheet
    /// already has `model.kind`, so look it up in the registry.
    private func providerForCurrentChange(_ change: HookInstallChange) -> AIHookProvider? {
        AIHookProviderRegistry.providers().first { $0.kind == model.kind }
    }
```

**Step 4: Build**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' build 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED.

**Step 5: Manual smoke (Xcode preview or dev run)**

Click `Backup` on a change. Verify:
- Idle state shows `Backup` button (disabled when `change.current == nil`).
- During click, `Backing up…` flashes briefly.
- On success, `Backed up ✓ Show in Finder` appears; click `Show in Finder` opens Finder with the file selected.

If running the app, after building locate the binary dynamically (do not hardcode):
```bash
ls -dt ~/Library/Developer/Xcode/DerivedData/Treemux-*/Build/Products/Debug/Treemux.app | head -1
```

**Step 6: Commit**

```bash
git add Treemux/UI/Sheets/HookPreviewSheet.swift
git commit -m "feat: per-change Backup button with idle/inProgress/success states"
```

---

## Task 9: Render backup failure message inline

**Files:**
- Modify: `Treemux/UI/Sheets/HookPreviewSheet.swift`

**Step 1: Add `failureMessage` view + wire into `changeView`**

Add to `HookPreviewSheet`:
```swift
    @ViewBuilder
    private func failureMessage(for change: HookInstallChange) -> some View {
        if case .failure(let msg) = backupStates[change.path] ?? .idle {
            Text("Backup failed: \(msg)")
                .font(.system(size: 11))
                .foregroundStyle(.red)
        } else {
            EmptyView()
        }
    }
```

In `changeView`, append after the diff `HStack`:
```swift
            failureMessage(for: change)
```

**Step 2: Manually force-fail to verify**

Temporarily edit `HookBackupService.backup` to `throw HookInstallError.ioError("forced for QA")` at the top, run the app, click `Backup`, confirm the red error appears beneath the diff and that the `Backup` button returns to idle (clickable). Then revert the forced throw.

**Step 3: Build clean**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED.

**Step 4: Commit**

```bash
git add Treemux/UI/Sheets/HookPreviewSheet.swift
git commit -m "feat: surface backup failure inline below diff"
```

---

## Task 10: Add zh-Hans translations

**Files:**
- Modify: `Treemux/Localizable.xcstrings`

**Step 1: Build once to let Xcode auto-extract any new strings**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' build 2>&1 | tail -5
```
Xcode's strings catalog auto-extraction picks up new `LocalizedStringKey` literals from the SwiftUI views.

**Step 2: Open `Treemux/Localizable.xcstrings` in Xcode**

Confirm the following keys appear (auto-extracted). If any are missing, add them manually in the catalog editor.

| Key | zh-Hans translation |
|---|---|
| `Backup` | `备份` |
| `Backing up…` | `正在备份…` |
| `Backed up ✓` | `已备份 ✓` |
| `Show in Finder` | `在 Finder 中显示` |
| `Backup failed: %@` | `备份失败：%@` |
| `Nothing to back up (new file)` | `无需备份（新文件）` |
| `Save the current file to ~/.treemux/backups/` | `把当前文件保存到 ~/.treemux/backups/` |

For each entry, set the `zh-Hans` localization to `translated` state.

**Step 3: Verify all entries are marked translated**

Quick grep sanity check:
```bash
grep -A4 '"Backup"' Treemux/Localizable.xcstrings | head -20
grep -A4 '"Backed up ✓"' Treemux/Localizable.xcstrings | head -20
```
Each should show a `"value" : "..."` for `zh-Hans` with the expected Chinese string and `"state" : "translated"`.

**Step 4: Build to confirm catalog is well-formed**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED.

**Step 5: Commit**

```bash
git add Treemux/Localizable.xcstrings
git commit -m "i18n: zh-Hans for hook preview backup UI"
```

---

## Task 11: Build, run full test suite, manual QA

**Files:** none

**Step 1: Run the full test suite**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' test 2>&1 | tail -30
```
Expected: all tests pass (existing + new `HookDiffTests` + `HookBackupServiceTests`).

**Step 2: Build a debug app**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED.

**Step 3: Locate the freshly-built app**

```bash
ls -dt ~/Library/Developer/Xcode/DerivedData/Treemux-*/Build/Products/Debug/Treemux.app | head -1
```
Note the printed path; substitute it into the launch command in step 4.

**Step 4: Run the app with a clean sandbox**

```bash
rm -rf ~/.treemux-debug/ && open <path-from-step-3>
```

**Step 5: Manual QA checklist**

In the running app, open Settings → AI Activity. For each detected agent:

- [ ] Click `Install` (or `Reinstall`/`Update`). Sheet opens with the diff highlighted: removed lines red, added lines green, unchanged lines uncolored.
- [ ] For a change where `current != nil`, the `Backup` button is enabled. Click it.
- [ ] Button shows `Backing up…` momentarily, then resolves to `Backed up ✓ Show in Finder`.
- [ ] Click `Show in Finder`; Finder opens with the timestamped backup file selected at `~/.treemux/backups/<targetID>/<providerKind>/<basename>.<timestamp>`.
- [ ] Open the backup file; contents match the `Before` column of the diff.
- [ ] Click `Backup` on the same change a second time after re-opening the sheet — a new file with a later timestamp is created (the first one is not overwritten).
- [ ] For a change where `current == nil` (e.g. fresh install of `notify.sh`), the `Backup` button is disabled with a tooltip "Nothing to back up (new file)".
- [ ] Force a failure by temporarily revoking write permission on `~/.treemux/backups/` (`chmod a-w`); confirm the inline `Backup failed: …` text appears in red and the button returns to idle. Restore permissions afterward.
- [ ] Click `Apply`; install completes and the sheet dismisses.
- [ ] Switch macOS appearance between light and dark; the red/green highlights remain readable in both.
- [ ] Switch system language to 简体中文; reopen the sheet; all new strings render in Chinese (`备份`, `已备份 ✓`, `在 Finder 中显示`, etc.).
- [ ] (If you have a remote SSH workspace registered) Repeat the install + backup flow for a remote provider. Confirm the backup is written under `~/.treemux/backups/remote_<host>/<kind>/...` (with `:` replaced by `_`), still on the **local** machine.

**Step 6: Commit any QA-driven fixes**

If any QA item failed, commit the fix(es) with appropriate `fix:` messages, then re-run from Step 1.

**Step 7: Final commit (no-op if nothing pending)**

```bash
git status
```
Expected: working tree clean.

---

## Wrap-Up

After Task 11, the worktree branch `feat/hook-preview-diff-and-backup` is ready for review / merge. Open a PR with the design doc as context and the QA checklist results in the description.

When invoking the `superpowers:finishing-a-development-branch` skill at the end, point it at this branch.
