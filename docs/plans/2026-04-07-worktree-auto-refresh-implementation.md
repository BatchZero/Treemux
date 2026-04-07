# Worktree Sidebar Auto-Refresh Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the project sidebar auto-refresh worktree nodes (<1 second) when external `git worktree add`/`remove` commands modify the worktree set.

**Architecture:** Two focused changes — (1) extend `WorkspaceMetadataWatchService` to resolve the common (main) git directory from any worktree's gitdir and watch `<common>/worktrees/`; (2) re-establish watchers in `WorkspaceStore.refreshWorkspace` after each successful refresh so newly discovered worktrees get observers and stale handles are cleaned up.

**Tech Stack:** Swift, SwiftUI, `DispatchSourceFileSystemObject`, XCTest, git CLI (`git worktree add`).

**Worktree:** `.worktrees/feat+worktree-auto-refresh/` (branch: `feat/worktree-auto-refresh`)

**Design doc:** `docs/plans/2026-04-07-worktree-auto-refresh-design.md`

---

## Pre-Flight

Verify you are operating inside the worktree:

```bash
pwd
# Expected: /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+worktree-auto-refresh
git branch --show-current
# Expected: feat/worktree-auto-refresh
```

If not in the worktree, `cd` into it before continuing.

---

## Task 1: Failing test for `resolveCommonGitDirectory` (main worktree case)

**Files:**
- Modify: `TreemuxTests/GitRepositoryServiceTests.swift` (append a new test class at the end)

**Step 1: Make `resolveCommonGitDirectory` and `gitMetadataPaths` testable**

Open `Treemux/Services/Git/WorkspaceMetadataWatchService.swift`. The methods we will add (`resolveCommonGitDirectory`) and modify (`gitMetadataPaths`) are currently `private`. To allow `@testable import Treemux` to call them, change them from `private func` to `func` (which defaults to `internal`).

We will also need to add the method itself in Task 3. For now (Task 1) we are only writing tests that will fail because the method does not exist yet — the test compilation will fail. That is the intended TDD failure.

Skip the method modifier change for this task — leave it for Task 3, where we add the new method as `func` (internal default) directly.

**Step 2: Append the failing test class to `GitRepositoryServiceTests.swift`**

Add the following at the end of the file (after the closing brace of `GitRepositoryServiceTests`):

```swift
// MARK: - WorkspaceMetadataWatchService Tests

@MainActor
final class WorkspaceMetadataWatchServiceTests: XCTestCase {

    private var testRepoURL: URL!
    private let watchService = WorkspaceMetadataWatchService()

    override func setUp() async throws {
        testRepoURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: testRepoURL, withIntermediateDirectories: true)
        _ = try await ShellCommandRunner.shell(
            "git init && git commit --allow-empty -m 'init'",
            workingDirectory: testRepoURL
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: testRepoURL)
    }

    func testResolveCommonGitDirectory_forMainWorktree_returnsItself() throws {
        let mainGitDir = testRepoURL.appendingPathComponent(".git").path
        let resolved = watchService.resolveCommonGitDirectory(for: mainGitDir)
        XCTAssertEqual(
            URL(fileURLWithPath: resolved).standardizedFileURL,
            URL(fileURLWithPath: mainGitDir).standardizedFileURL
        )
    }
}
```

**Step 3: Run test to verify it fails**

Build the test target and run only this test. From the worktree root:

```bash
xcodebuild test \
  -project Treemux.xcodeproj \
  -scheme Treemux \
  -destination 'platform=macOS' \
  -only-testing:TreemuxTests/WorkspaceMetadataWatchServiceTests/testResolveCommonGitDirectory_forMainWorktree_returnsItself
```

Expected: **build failure** with error like "value of type 'WorkspaceMetadataWatchService' has no member 'resolveCommonGitDirectory'". This confirms the TDD red state.

**Step 4: Commit the failing test (optional, can be folded into next commit)**

We will commit together with the implementation in Task 3 to keep the working tree compilable on `main`. Skip the commit here.

---

## Task 2: Failing test for `resolveCommonGitDirectory` (linked worktree case)

**Files:**
- Modify: `TreemuxTests/GitRepositoryServiceTests.swift` (add a second test method to `WorkspaceMetadataWatchServiceTests`)

**Step 1: Add the second failing test**

Inside the `WorkspaceMetadataWatchServiceTests` class, add this method:

```swift
func testResolveCommonGitDirectory_forLinkedWorktree_returnsMainGitDir() async throws {
    // Create a linked worktree on a new branch in a sibling directory.
    let linkedURL = testRepoURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: linkedURL) }

    _ = try await ShellCommandRunner.shell(
        "git worktree add \(linkedURL.path) -b test-linked",
        workingDirectory: testRepoURL
    )

    let mainGitDir = testRepoURL.appendingPathComponent(".git").path
    let linkedGitDir = mainGitDir + "/worktrees/" + linkedURL.lastPathComponent

    let resolved = watchService.resolveCommonGitDirectory(for: linkedGitDir)
    XCTAssertEqual(
        URL(fileURLWithPath: resolved).standardizedFileURL,
        URL(fileURLWithPath: mainGitDir).standardizedFileURL
    )
}
```

**Step 2: Verify the new test also fails to compile (still missing the method)**

Same `xcodebuild test` command pattern with `-only-testing:TreemuxTests/WorkspaceMetadataWatchServiceTests/testResolveCommonGitDirectory_forLinkedWorktree_returnsMainGitDir` — expected: build error referencing the missing method.

---

## Task 3: Implement `resolveCommonGitDirectory` and extend `gitMetadataPaths`

**Files:**
- Modify: `Treemux/Services/Git/WorkspaceMetadataWatchService.swift`

**Step 1: Add the new method**

Locate the `// MARK: - Private` section of `WorkspaceMetadataWatchService`, then find the existing `private func resolveGitDirectory(for worktreePath: String) -> String?` method (near the bottom of the class). Add a new method **immediately above** `resolveGitDirectory`:

```swift
/// Resolves the main repository's git directory from any worktree's gitdir.
/// Linked worktrees contain a `commondir` file inside their gitdir whose
/// contents are a path (typically relative) pointing back to the main gitdir.
/// Main worktrees have no `commondir` file, so the input is returned as-is.
func resolveCommonGitDirectory(for gitDirectory: String) -> String {
    let commondirURL = URL(fileURLWithPath: gitDirectory).appendingPathComponent("commondir")
    guard let contents = try? String(contentsOf: commondirURL, encoding: .utf8) else {
        return gitDirectory
    }
    let raw = contents.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return gitDirectory }

    let resolvedURL: URL
    if raw.hasPrefix("/") {
        resolvedURL = URL(fileURLWithPath: raw)
    } else {
        resolvedURL = URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: gitDirectory))
    }
    return resolvedURL.standardizedFileURL.path
}
```

Note: this method is `func` (default `internal`) so the tests using `@testable import Treemux` can call it.

**Step 2: Extend `gitMetadataPaths` to include the common worktrees directory**

Replace the existing `gitMetadataPaths(in:)` method body with:

```swift
/// Returns the standard set of git metadata paths to watch within a git directory.
/// Also includes the common gitdir's `worktrees/` sub-directory so external
/// `git worktree add`/`remove` operations are detected.
private func gitMetadataPaths(in gitDirectory: String) -> [String] {
    let base = URL(fileURLWithPath: gitDirectory)
    let common = resolveCommonGitDirectory(for: gitDirectory)
    let commonBase = URL(fileURLWithPath: common)
    return [
        gitDirectory,
        base.appendingPathComponent("HEAD").path,
        base.appendingPathComponent("index").path,
        base.appendingPathComponent("FETCH_HEAD").path,
        base.appendingPathComponent("refs").path,
        base.appendingPathComponent("refs/heads").path,
        base.appendingPathComponent("refs/remotes").path,
        // Watch the common gitdir and its worktrees/ subdirectory so that
        // external `git worktree add`/`remove` operations trigger refresh.
        common,
        commonBase.appendingPathComponent("worktrees").path,
    ]
    .filter { fileManager.fileExists(atPath: $0) }
}
```

**Step 3: Run both tests to verify they pass**

```bash
xcodebuild test \
  -project Treemux.xcodeproj \
  -scheme Treemux \
  -destination 'platform=macOS' \
  -only-testing:TreemuxTests/WorkspaceMetadataWatchServiceTests
```

Expected: both tests **PASS**.

If they fail, do not move on. Read the output and diagnose:
- "no such file" → `commondir` path resolution wrong
- "expected X, got Y" with `/private/var` vs `/var` → standardization difference; both sides should already be standardized via `.standardizedFileURL`

**Step 4: Commit**

```bash
git add Treemux/Services/Git/WorkspaceMetadataWatchService.swift TreemuxTests/GitRepositoryServiceTests.swift
git commit -m "$(cat <<'EOF'
feat(watch): resolve common gitdir and watch worktrees/ subdir

Add WorkspaceMetadataWatchService.resolveCommonGitDirectory(for:) which
reads the `commondir` file inside a linked worktree's gitdir to locate
the main repository's git directory. Extend gitMetadataPaths to include
both the common gitdir and its `worktrees/` subdirectory so that external
`git worktree add` and `git worktree remove` commands fire vnode events
that trigger sidebar refresh.
EOF
)"
```

---

## Task 4: Re-establish watchers in `WorkspaceStore.refreshWorkspace`

**Files:**
- Modify: `Treemux/App/WorkspaceStore.swift`

**Step 1: Locate the insertion point**

Open `Treemux/App/WorkspaceStore.swift` and find the `refreshWorkspace(_:)` method (around line 329). Locate this exact block near the end of the method:

```swift
            // If selected worktree was removed, fall back to workspace selection
            if let selID = selectedWorkspaceID,
               previousWorktreeIDs.contains(selID),
               !merged.contains(where: { $0.id == selID }) {
                selectedWorkspaceID = workspace.id
            }

            // Notify SwiftUI that child model data changed so the sidebar rebuilds.
            objectWillChange.send()
```

**Step 2: Insert watcher re-establishment before `objectWillChange.send()`**

Modify the block to:

```swift
            // If selected worktree was removed, fall back to workspace selection
            if let selID = selectedWorkspaceID,
               previousWorktreeIDs.contains(selID),
               !merged.contains(where: { $0.id == selID }) {
                selectedWorkspaceID = workspace.id
            }

            // Re-establish watchers so newly added worktrees get their own
            // observers and removed worktrees have their stale handles cleaned up.
            // `watch(workspace:)` is idempotent (stops existing watchers first).
            metadataWatcher.watch(workspace: workspace) { [weak self] workspaceID in
                Task { @MainActor [weak self] in
                    guard let self,
                          let ws = self.workspaces.first(where: { $0.id == workspaceID }) else { return }
                    await self.refreshWorkspace(ws)
                }
            }

            // Notify SwiftUI that child model data changed so the sidebar rebuilds.
            objectWillChange.send()
```

**Step 3: Build the project to confirm it compiles**

```bash
xcodebuild build \
  -project Treemux.xcodeproj \
  -scheme Treemux \
  -destination 'platform=macOS'
```

Expected: **BUILD SUCCEEDED**.

**Step 4: Run the existing test suite to confirm nothing regressed**

```bash
xcodebuild test \
  -project Treemux.xcodeproj \
  -scheme Treemux \
  -destination 'platform=macOS' \
  -only-testing:TreemuxTests
```

Expected: all tests **PASS**.

**Step 5: Commit**

```bash
git add Treemux/App/WorkspaceStore.swift
git commit -m "$(cat <<'EOF'
feat(store): re-establish watchers after every workspace refresh

After refreshWorkspace updates the merged worktree list, call
metadataWatcher.watch(workspace:) so that newly discovered worktrees
get their own file system observers and stale handles for removed
worktrees are cleaned up. The watch method is idempotent.

This closes the loop on auto-refresh: external `git worktree add`
fires the parent `.git/worktrees/` vnode event → debounced refresh
runs → new merged list → watchers rebuilt → subsequent changes to
the new worktree are also observed.
EOF
)"
```

---

## Task 5: Manual acceptance verification

**Files:** none (manual test)

**Step 1: Determine the DerivedData build folder**

The user (卡皮巴拉) prefers running the built app from DerivedData. Find the current build folder:

```bash
ls -td ~/Library/Developer/Xcode/DerivedData/Treemux-* | head -1
```

Note the suffix (e.g. `abc123def456`).

**Step 2: Build the Debug configuration**

```bash
xcodebuild build \
  -project Treemux.xcodeproj \
  -scheme Treemux \
  -configuration Debug \
  -destination 'platform=macOS'
```

Expected: **BUILD SUCCEEDED**.

**Step 3: Tell 卡皮巴拉 the run command**

Per `.claude/CLAUDE.md`, after building, tell the user the exact run command:

```
rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<编号>/Build/Products/Debug/Treemux.app
```

with `<编号>` replaced by the suffix from Step 1.

**Step 4: Acceptance checklist (user runs)**

The user should manually verify:

1. Open a repo with at least one linked worktree → sidebar shows it.
2. From an external terminal: `git worktree add ../wt-test -b feat/test` in that repo
   → sidebar shows `wt-test` within ~1 second. ✅
3. From the same terminal: `git worktree remove ../wt-test`
   → sidebar removes `wt-test` within ~1 second. ✅
4. Repeat add/remove ten times → sidebar stays consistent, no leaks (optional: `lsof -p $(pgrep Treemux) | wc -l` before and after should be similar). ✅
5. Open a repo with **zero** linked worktrees, then `git worktree add ../first -b feat/first` → `first` appears in sidebar. ✅
6. Select a worktree, then delete it from CLI → selection falls back to the parent workspace with no crash. ✅

If any step fails, gather logs (`Console.app` filtered by Treemux process) and stop.

**Step 5: Do not commit anything for this task**

This is verification only.

---

## Task 6: Push the branch

**Files:** none

**Step 1: Push the feature branch**

```bash
git push -u origin feat/worktree-auto-refresh
```

**Step 2: Stop**

Do **not** open a PR automatically. The user (卡皮巴拉) will decide when and how to merge.

---

## Notes for the Implementer

- **Read the design doc first:** `docs/plans/2026-04-07-worktree-auto-refresh-design.md` (in this same worktree).
- **All user-facing strings unchanged:** This change touches no UI strings, so no `Localizable.xcstrings` updates required.
- **Comments in English, communication in Chinese (call the user 卡皮巴拉)** per project rules in `.claude/CLAUDE.md`.
- **Do not** add features beyond what is in this plan. No polling fallback. No FSEventStream rewrite. No "while we're here" cleanups.
- **Path standardization gotcha:** macOS temp dirs are often under `/var/folders/...` which symlinks to `/private/var/folders/...`. Always compare with `.standardizedFileURL` on both sides.
- If a test flakes due to git not being on PATH, check `/usr/bin/git` exists. The repo's `ShellCommandRunner.shell` uses the user's shell, which should resolve git correctly.
