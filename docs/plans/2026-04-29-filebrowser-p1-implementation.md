# File Browser P1 — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix three regressions, add copy-path context menus, fix remote empty-tree, build VSCode-style sub-tabs, and upgrade the editor (syntax highlighting, git diff, word completion) inside the file-browser tab.

**Architecture:** Most logic lives in `FileBrowserTabController` (state machine for sub-tabs, error surfacing, copy-path) plus a few new services (`GitDiffService`, `BufferWordIndex`). UI is split into `FileSubTabBarView` + the existing `FileViewerPanelView`. Editor swaps `NSTextView` for Runestone. Persistence extends `FileBrowserTabState` with `subTabs: [FileSubTabRecord]` and a Codable migration for legacy data.

**Tech Stack:** Swift 5, SwiftUI + AppKit, XCTest, Citadel (SFTP), Runestone + TreeSitterLanguages (new), Process (git CLI). macOS 15.

**Reference:** Full design in `docs/plans/2026-04-29-filebrowser-p1-design.md`.

**Worktree:** `.worktrees/feat+filebrowser-p1-fixes-and-subtabs/` on branch `feat/filebrowser-p1-fixes-and-subtabs`.

**Build/run reminder for卡皮巴拉:** After Xcode build succeeds, the user runs:
`rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<编号>/Build/Products/Debug/Treemux.app`
(检查 DerivedData 编号，避免打开旧版 app — see `feedback_deriveddata_path.md`.)

**i18n contract:** Every new `LocalizedStringKey` MUST land in `Treemux/Localizable.xcstrings` with a `zh-Hans` translation in the same task that introduces it. Manual QA includes a Chinese-locale pass.

---

## Stage 0: Setup

### Task 0.1: Create the worktree and branch

**Step 1: From the main repo, create the worktree**

Run:
```bash
cd /Users/yanu/Documents/code/Terminal/treemux
git worktree add .worktrees/feat+filebrowser-p1-fixes-and-subtabs -b feat/filebrowser-p1-fixes-and-subtabs
```

Expected: `Preparing worktree (new branch 'feat/filebrowser-p1-fixes-and-subtabs')` then `HEAD is now at e3f0137 docs: design for P1 …`.

**Step 2: Verify the worktree**

Run:
```bash
cd .worktrees/feat+filebrowser-p1-fixes-and-subtabs && git status && git branch --show-current
```

Expected: clean tree on `feat/filebrowser-p1-fixes-and-subtabs`.

**Step 3: All subsequent tasks happen inside this worktree.** Stay in `.worktrees/feat+filebrowser-p1-fixes-and-subtabs/` from here on.

---

## Stage A: Three bug fixes (issues #1, #3, #5)

### Task A1: Sidebar folder-icon — always visible (issue #1)

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarNodeRow.swift:91-104` and `:154-166`

**Step 1: Read the current file**

Open `Treemux/UI/Sidebar/SidebarNodeRow.swift`. Two `if isHovered { Button { … } }` blocks exist (one per row content type).

**Step 2: Modify `WorkspaceRowContent` (around line 91-104)**

Remove the `if isHovered` wrapper. Replace with:

```swift
Button {
    let root = workspace.repositoryRoot?.path ?? workspace.activeWorktreePath
    workspace.createFileBrowserTab(rootPath: root, rootKind: .project,
                                  title: workspace.name)
} label: {
    Image(systemName: "folder.badge.plus")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(theme.textSecondary.opacity(isHovered ? 1.0 : 0.5))
}
.buttonStyle(.plain)
.help(LocalizedStringKey("Open File Browser"))
.padding(.trailing, 2)
```

**Step 3: Modify `WorktreeRowContent` (around line 154-166) the same way**

Replace `if isHovered { Button { … } }` with the unconditional `Button { … }`. Use `.foregroundStyle(theme.textSecondary.opacity(isHovered ? 1.0 : 0.5))`. Keep all other props (font, padding, help text) as-is.

**Step 4: Build**

Run:
```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

**Step 5: Manual verify**

Tell the user to run with the post-build command (CLAUDE.md reminder). Observe: in the sidebar, every Project row and Worktree row shows the `folder.badge.plus` icon at all times; idle rows show it dimmed (50% opacity); hovered rows show it at full opacity.

**Step 6: Commit**

```bash
git add Treemux/UI/Sidebar/SidebarNodeRow.swift
git commit -m "fix: keep sidebar folder-browser icon visible at idle"
```

---

### Task A2: Eye-icon toggle refresh (issue #3) — failing test

**Files:**
- Test: `TreemuxTests/FileBrowserTabControllerTests.swift` (create if missing)

**Step 1: Check if the file exists**

```bash
ls TreemuxTests/FileBrowserTabControllerTests.swift 2>/dev/null || echo "missing"
```

If missing, create it with the standard preamble.

**Step 2: Add a fake data source helper (top of test file)**

```swift
import XCTest
@testable import Treemux

@MainActor
final class FileBrowserTabControllerTests: XCTestCase {
    final class FakeDataSource: FileBrowserDataSource {
        let supportsWrite = true
        var entries: [String: [FileNode]] = [:]
        func listDirectory(_ path: String) async throws -> [FileNode] {
            entries[path] ?? []
        }
        func fileMetadata(_ path: String) async throws -> FileMetadata {
            FileMetadata(path: path, sizeBytes: 0, modifiedAt: nil,
                         isDirectory: false, isSymbolicLink: false)
        }
        func readFile(_ path: String, maxBytes: Int) async throws -> Data { Data() }
        func writeFile(_ path: String, data: Data) async throws {}
        func downloadForQuickLook(_ path: String,
                                  progress: @escaping (Double) -> Void) async throws -> URL {
            URL(fileURLWithPath: "/tmp/x")
        }
    }
}
```

**Step 3: Add the failing test**

```swift
func test_setShowsHiddenFiles_recoversHiddenAfterToggleOff() async {
    let ds = FakeDataSource()
    let visible = FileNode(id: "/r/a", name: "a", path: "/r/a", kind: .file, sizeBytes: 0, modifiedAt: nil)
    let hidden  = FileNode(id: "/r/.b", name: ".b", path: "/r/.b", kind: .file, sizeBytes: 0, modifiedAt: nil)
    ds.entries["/r"] = [visible, hidden]
    let state = FileBrowserTabState(rootPath: "/r", rootKind: .project, showsHiddenFiles: true)
    let ctrl = FileBrowserTabController(initial: state, dataSource: ds)
    await ctrl.loadRoot()
    XCTAssertEqual(ctrl.rootChildren.count, 2)

    ctrl.setShowsHiddenFiles(false)
    XCTAssertEqual(ctrl.rootChildren.count, 1, "only visible file remains")

    ctrl.setShowsHiddenFiles(true)
    XCTAssertEqual(ctrl.rootChildren.count, 2, "hidden file must reappear without re-fetch")
}
```

**Step 4: Run the test (expect FAIL)**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing:TreemuxTests/FileBrowserTabControllerTests/test_setShowsHiddenFiles_recoversHiddenAfterToggleOff 2>&1 | tail -30
```

Expected: failure on the third assertion (count == 1, expected 2).

---

### Task A3: Eye-icon toggle refresh (issue #3) — implement

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift`

**Step 1: Add a raw cache and rewrite the filter pipeline**

In `FileBrowserTabController` (around line 19-23):

```swift
// Runtime state.
@Published private(set) var rootChildren: [FileNode] = []
@Published private(set) var childrenByPath: [String: [FileNode]] = [:]
private var rawChildrenByPath: [String: [FileNode]] = [:]
@Published private(set) var selectedFilePath: String?
@Published private(set) var openFile: OpenFileState = .empty
@Published private(set) var loadingPaths: Set<String> = []
```

**Step 2: Update writes — `loadRoot`, `toggleExpand`, `refresh`**

Replace each `childrenByPath[key] = filtered(kids)` with:
```swift
rawChildrenByPath[key] = kids
childrenByPath[key] = filtered(kids)
```

For `loadRoot` (around line 59-73):

```swift
func loadRoot() async {
    do {
        let children = try await dataSource.listDirectory(rootPath)
        rawChildrenByPath[rootPath] = children
        childrenByPath[rootPath] = filtered(children)
        rootChildren = childrenByPath[rootPath] ?? []
        for path in expandedDirs where path != rootPath {
            if let kids = try? await dataSource.listDirectory(path) {
                rawChildrenByPath[path] = kids
                childrenByPath[path] = filtered(kids)
            }
        }
    } catch {
        rootChildren = []
    }
}
```

For `toggleExpand` (around line 80-90):
```swift
let kids = try await dataSource.listDirectory(path)
rawChildrenByPath[path] = kids
childrenByPath[path] = filtered(kids)
expandedDirs.insert(path)
```

For `refresh` (around line 104-112):
```swift
let kids = try await dataSource.listDirectory(path)
rawChildrenByPath[path] = kids
childrenByPath[path] = filtered(kids)
if path == rootPath { rootChildren = childrenByPath[path] ?? [] }
```

**Step 3: Rewrite `setShowsHiddenFiles` to derive from raw**

```swift
func setShowsHiddenFiles(_ show: Bool) {
    guard showsHiddenFiles != show else { return }
    showsHiddenFiles = show
    var derived: [String: [FileNode]] = [:]
    for (key, value) in rawChildrenByPath {
        derived[key] = filtered(value)
    }
    childrenByPath = derived
    rootChildren = childrenByPath[rootPath] ?? []
    onPersistableStateChanged?()
}
```

**Step 4: Run the test (expect PASS)**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing:TreemuxTests/FileBrowserTabControllerTests/test_setShowsHiddenFiles_recoversHiddenAfterToggleOff 2>&1 | tail -20
```

Expected: PASS.

**Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift TreemuxTests/FileBrowserTabControllerTests.swift
git commit -m "fix: eye-icon toggle reveals hidden files without manual refresh

Two-layer cache: rawChildrenByPath holds unfiltered listings; the
public childrenByPath is derived. Toggling showsHiddenFiles re-derives
from raw, so hidden→visible transitions don't need to re-list."
```

---

### Task A4: File-tab → terminal-tab regression (issue #5) — failing test

**Files:**
- Test: `TreemuxTests/WorkspaceModelTabKindTests.swift` (likely exists; extend)

**Step 1: Locate or create the test file**

```bash
ls TreemuxTests/WorkspaceModelTabKindTests.swift 2>/dev/null || echo "missing"
```

If exists, extend; otherwise create with import preamble.

**Step 2: Add the regression test**

```swift
@MainActor
func test_saveActiveTabState_doesNotCorruptFileBrowserTab() {
    let ws = WorkspaceModel(name: "test", kind: .git)
    ws.createFileBrowserTab(rootPath: "/tmp", rootKind: .project, title: "tmp")
    let fbID = ws.activeTabID!
    XCTAssertEqual(ws.tabs.first(where: { $0.id == fbID })?.kind, .fileBrowser)

    // Simulate the AIHookBannerController path: external code touches
    // sessionController while a file-browser tab is active.
    _ = ws.sessionController

    // saveActiveTabState used to overwrite the FB tab as a terminal tab.
    ws.saveActiveTabState()

    let after = ws.tabs.first(where: { $0.id == fbID })
    XCTAssertEqual(after?.kind, .fileBrowser, "FB tab kind must survive sessionController access + save")
    XCTAssertNotNil(after?.fileBrowserState, "fileBrowserState must survive")
}
```

**Step 3: Run (expect FAIL)**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing:TreemuxTests/WorkspaceModelTabKindTests/test_saveActiveTabState_doesNotCorruptFileBrowserTab 2>&1 | tail -20
```

Expected: FAIL — kind became `.terminal` after save.

---

### Task A5: File-tab → terminal-tab regression (issue #5) — implement

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift`

**Step 1: Add tab-kind guard to `sessionController` getter (around line 290-294)**

```swift
var sessionController: WorkspaceSessionController? {
    guard let tabID = activeTabID,
          let tab = tabs.first(where: { $0.id == tabID }),
          tab.kind == .terminal else { return nil }
    return controller(forTabID: tabID, worktreePath: activeWorktreePath)
}
```

**Step 2: Defensive guard inside `controller(forTabID:worktreePath:)` (around line 682)**

At the very top of the function:

```swift
private func controller(forTabID tabID: UUID, worktreePath: String) -> WorkspaceSessionController {
    if let existing = tabControllers[worktreePath]?[tabID] {
        return existing
    }
    // Defensive: never lazily create a terminal session controller for
    // a file-browser tab. The caller (sessionController getter) already
    // gates on tab.kind, but this protects against future call sites.
    if let tab = tabs.first(where: { $0.id == tabID }), tab.kind != .terminal {
        // Return a dormant controller that's NOT registered in tabControllers.
        // Callers must check `tab.kind` first; this is a last-resort safety net.
        // We DO NOT want to insert this into tabControllers because that's the
        // mutation that corrupts saveActiveTabState. Returning a fresh,
        // unregistered controller is harmless to anyone reading state.
        // Simpler alternative: fatalError. But fatal is too aggressive while
        // the codebase still has fragile call sites; log + return inert.
        assertionFailure("controller(forTabID:) called for non-terminal tab \(tabID)")
    }
    // … existing code below unchanged …
```

(The asserts will surface during dev/test; release builds skip the check.)

**Step 3: Add tab-kind guard + explicit kind/state in `saveActiveTabState` (around line 587-604)**

```swift
func saveActiveTabState() {
    guard let tabID = activeTabID,
          let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
    let existingTab = tabs[index]
    // Only terminal tabs have a session controller to save from.
    guard existingTab.kind == .terminal,
          let ctrl = tabControllers[activeWorktreePath]?[tabID] else { return }

    let preferredTitle = suggestedTitle(for: ctrl, existingTab: existingTab)

    tabs[index] = WorkspaceTabStateRecord(
        id: tabID,
        title: preferredTitle,
        isManuallyNamed: existingTab.isManuallyNamed,
        kind: .terminal,                              // explicit
        layout: ctrl.layout,
        panes: ctrl.sessionSnapshots(),
        focusedPaneID: ctrl.focusedPaneID,
        zoomedPaneID: ctrl.zoomedPaneID,
        fileBrowserState: nil                         // explicit
    )
}
```

**Step 4: Run the test (expect PASS)**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing:TreemuxTests/WorkspaceModelTabKindTests 2>&1 | tail -20
```

Expected: PASS.

**Step 5: Manual verify with a built app**

Build, run, open a file-browser tab from a worktree, then create or click a terminal tab, then click back on the file-browser tab. The file-browser tree must reappear (not be replaced by terminal).

**Step 6: Commit**

```bash
git add Treemux/Domain/WorkspaceModels.swift TreemuxTests/WorkspaceModelTabKindTests.swift
git commit -m "fix: file-browser tab no longer corrupted into terminal on switch-back

The AIHookBannerController.evaluate path called workspace.sessionController
on every objectWillChange, which lazily created a terminal controller for
*any* active tabID and stored it in tabControllers. The next
saveActiveTabState then overwrote the file-browser tab record with default
WorkspaceTabStateRecord init (kind defaulted to .terminal,
fileBrowserState nil).

Three guards in defense-in-depth:
- sessionController getter checks tab.kind == .terminal
- controller(forTabID:) asserts against non-terminal calls
- saveActiveTabState gates on tab.kind and passes kind/fileBrowserState
  explicitly to the new record"
```

---

## Stage B: Remote empty-tree fix (issue #2)

### Task B1: Surface load errors in the controller — failing test

**Files:**
- Test: `TreemuxTests/FileBrowserTabControllerTests.swift` (extend)

**Step 1: Add an error-throwing fake**

In the existing test file, add:

```swift
final class ThrowingDataSource: FileBrowserDataSource {
    let supportsWrite = true
    var error: Error = SFTPServiceError.authenticationFailed
    func listDirectory(_ path: String) async throws -> [FileNode] { throw error }
    func fileMetadata(_ path: String) async throws -> FileMetadata { throw error }
    func readFile(_ path: String, maxBytes: Int) async throws -> Data { throw error }
    func writeFile(_ path: String, data: Data) async throws { throw error }
    func downloadForQuickLook(_ path: String, progress: @escaping (Double) -> Void) async throws -> URL { throw error }
}
```

**Step 2: Add the failing test**

```swift
func test_loadRoot_authFailed_setsNeedsPasswordError() async {
    let ds = ThrowingDataSource()
    ds.error = SFTPServiceError.authenticationFailed
    let state = FileBrowserTabState(rootPath: "/r", rootKind: .project)
    let ctrl = FileBrowserTabController(initial: state, dataSource: ds)
    await ctrl.loadRoot()
    if case .needsPassword(let host) = ctrl.loadError {
        XCTAssertFalse(host.isEmpty)
    } else {
        XCTFail("expected .needsPassword, got \(String(describing: ctrl.loadError))")
    }
}

func test_loadRoot_genericError_setsGenericError() async {
    let ds = ThrowingDataSource()
    struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
    ds.error = Boom()
    let ctrl = FileBrowserTabController(initial: .init(rootPath: "/r", rootKind: .project), dataSource: ds)
    await ctrl.loadRoot()
    if case .generic(let msg) = ctrl.loadError {
        XCTAssertEqual(msg, "boom")
    } else {
        XCTFail("expected .generic")
    }
}
```

**Step 3: Run (expect FAIL — `loadError` doesn't exist yet)**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing:TreemuxTests/FileBrowserTabControllerTests/test_loadRoot_authFailed_setsNeedsPasswordError 2>&1 | tail -10
```

Expected: compile error or test failure.

---

### Task B2: Implement `LoadError` and surface from the controller

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift`
- Modify: `Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift` (expose host for error)

**Step 1: Add `LoadError` enum and published property**

In `FileBrowserTabController`, near top:

```swift
enum LoadError: Equatable {
    case generic(String)
    case needsPassword(host: String)
}

@Published private(set) var loadError: LoadError?
```

**Step 2: Add a helper to map errors to `LoadError`**

```swift
private func mapError(_ error: Error) -> LoadError {
    if case SFTPServiceError.authenticationFailed = error {
        let host = (dataSource as? RemoteFileBrowserDataSource)?.sshTarget.host ?? ""
        return .needsPassword(host: host)
    }
    return .generic((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
}
```

**Step 3: Update `loadRoot` to set `loadError` instead of silently emptying**

```swift
func loadRoot() async {
    loadError = nil
    do {
        let children = try await dataSource.listDirectory(rootPath)
        rawChildrenByPath[rootPath] = children
        childrenByPath[rootPath] = filtered(children)
        rootChildren = childrenByPath[rootPath] ?? []
        for path in expandedDirs where path != rootPath {
            if let kids = try? await dataSource.listDirectory(path) {
                rawChildrenByPath[path] = kids
                childrenByPath[path] = filtered(kids)
            }
        }
    } catch {
        rootChildren = []
        loadError = mapError(error)
    }
}
```

**Step 4: Update `toggleExpand` and `refresh` similarly**

In their `catch` blocks: `loadError = mapError(error)`. Don't reset `loadError` at the start of these (only `loadRoot` resets, since user-initiated retries go through it).

**Step 5: Run (expect PASS)**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing:TreemuxTests/FileBrowserTabControllerTests 2>&1 | tail -20
```

Expected: both new tests PASS.

**Step 6: Commit**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift TreemuxTests/FileBrowserTabControllerTests.swift
git commit -m "feat: surface remote file-browser errors via loadError

loadRoot/toggleExpand/refresh now publish LoadError instead of silently
clearing the tree. SFTPServiceError.authenticationFailed becomes
.needsPassword(host:) so the UI banner can prompt for a password."
```

---

### Task B3: Password-fallback API on `RemoteFileBrowserDataSource`

**Files:**
- Modify: `Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift`
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift`
- Test: `TreemuxTests/FileBrowserTabControllerTests.swift`

**Step 1: Failing test — `retryWithPassword` clears `loadError` on success**

Extend `ThrowingDataSource` (or add a more capable fake that lets the test simulate success after a password is supplied) — simplest path: have a `passwordToAccept: String?` field. When `connectWithPassword(_:)` is called with the matching password, flip `error` to nil and let subsequent calls succeed.

(Easier approach: skip live retry test; only assert that the controller's retry path calls `connectWithPassword` on the data source. Use a `ProtocolWitnessFakeRemote` or expose a closure on the fake.)

For this plan, write a minimal test that just verifies the API exists and `loadError` clears when retry succeeds. Defer integration coverage to manual QA.

**Step 2: On `RemoteFileBrowserDataSource`, expose `connectWithPassword`**

Add:
```swift
func connectWithPassword(_ password: String) async throws {
    try await service.connectWithPassword(target: sshTarget, password: password)
    didConnect = true
}
```

Make `sshTarget` accessible to the controller (already `let`, just public-ish — it's already accessible since the type is in the same module).

**Step 3: On the controller, add `retryWithPassword`**

```swift
func retryWithPassword(_ password: String) async {
    guard let remote = dataSource as? RemoteFileBrowserDataSource else { return }
    do {
        try await remote.connectWithPassword(password)
        await loadRoot()
    } catch {
        loadError = mapError(error)
    }
}
```

**Step 4: Run tests**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing:TreemuxTests/FileBrowserTabControllerTests 2>&1 | tail -20
```

Expected: PASS.

**Step 5: Commit**

```bash
git add Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift Treemux/UI/FileBrowser/FileBrowserTabController.swift TreemuxTests/FileBrowserTabControllerTests.swift
git commit -m "feat: password retry path for remote file browser

RemoteFileBrowserDataSource exposes connectWithPassword(_:) mirroring
the existing RemoteDirectoryBrowserViewModel auth flow. Controller's
retryWithPassword(_:) routes through it and clears loadError on success."
```

---

### Task B4: Error/password banner in `FileTreePanelView`

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileTreePanelView.swift`
- Modify: `Treemux/Localizable.xcstrings`

**Step 1: Add a `FileTreeErrorBanner` subview to `FileTreePanelView.swift`**

```swift
private struct FileTreeErrorBanner: View {
    @ObservedObject var controller: FileBrowserTabController
    @State private var password: String = ""

    var body: some View {
        Group {
            switch controller.loadError {
            case .generic(let message):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.system(size: 11))
                        .lineLimit(2)
                    Spacer()
                    Button(LocalizedStringKey("Retry")) {
                        Task { await controller.loadRoot() }
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(.thickMaterial)

            case .needsPassword(let host):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "lock")
                            .foregroundStyle(.orange)
                        Text(String.localizedStringWithFormat(
                            String(localized: "Cannot connect to %@"), host))
                            .font(.system(size: 11, weight: .medium))
                    }
                    HStack(spacing: 6) {
                        SecureField(LocalizedStringKey("Enter Password"), text: $password)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                        Button(LocalizedStringKey("Connect")) {
                            let pw = password
                            password = ""
                            Task { await controller.retryWithPassword(pw) }
                        }
                        .controlSize(.small)
                        .disabled(password.isEmpty)
                    }
                }
                .padding(8)
                .background(.thickMaterial)

            case .none:
                EmptyView()
            }
        }
    }
}
```

**Step 2: Inject above the toolbar in `FileTreePanelView.body`**

```swift
var body: some View {
    VStack(spacing: 0) {
        FileTreeErrorBanner(controller: controller)
        FileTreeToolbar(controller: controller)
        Divider()
        // … existing ScrollView …
    }
    .background(Color(nsColor: .controlBackgroundColor))
}
```

**Step 3: Add localization keys to `Localizable.xcstrings`**

For each new key (`"Retry"`, `"Cannot connect to %@"`, `"Enter Password"`, `"Connect"`), add a string entry with `en` and `zh-Hans` translations:
- `"Retry"` → 重试
- `"Cannot connect to %@"` → 无法连接到 %@
- `"Enter Password"` → 输入密码
- `"Connect"` → 连接

Open `Treemux/Localizable.xcstrings` in Xcode (or edit JSON directly) and add entries following the existing schema.

**Step 4: Build**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

**Step 5: Manual verify**

Build + open a remote workspace where SSH key auth fails. Open file browser tab. Banner appears with `Cannot connect to <host>` + password field. Type password → file tree appears.

**Step 6: Commit**

```bash
git add Treemux/UI/FileBrowser/FileTreePanelView.swift Treemux/Localizable.xcstrings
git commit -m "feat: error banner with password retry in file tree panel

Replaces silent empty tree with a banner showing the underlying error
plus a Retry button or a password field for SFTPServiceError.authenticationFailed.
zh-Hans translations included."
```

---

### Task B5: Shared `SFTPService` per workspace (Tier-2)

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift`
- Modify: `Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift`

**Step 1: On `WorkspaceModel`, add a lazy shared service**

Near the other private storage (around line 280):

```swift
private var sharedSFTPService_: SFTPService?
func ensureSharedSFTPService() -> SFTPService {
    if let s = sharedSFTPService_ { return s }
    let s = SFTPService()
    sharedSFTPService_ = s
    return s
}
```

**Step 2: Update `makeDataSource()` to inject the shared service**

```swift
private func makeDataSource() -> any FileBrowserDataSource {
    if let target = sshTarget {
        return RemoteFileBrowserDataSource(sshTarget: target, service: ensureSharedSFTPService())
    }
    return LocalFileBrowserDataSource()
}
```

(`RemoteFileBrowserDataSource.init` already accepts a `service:` parameter — no signature change needed.)

**Step 3: Build + verify no test regressions**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux 2>&1 | tail -20
```

Expected: tests pass.

**Step 4: Manual verify**

In a remote workspace, open file browser tab → enter password. Open a SECOND file browser tab on a different worktree of the same workspace. The second tab loads without re-prompting.

**Step 5: Commit**

```bash
git add Treemux/Domain/WorkspaceModels.swift
git commit -m "feat: share authenticated SFTPService across a workspace

WorkspaceModel.ensureSharedSFTPService() returns a single SFTPService
instance per workspace, injected into every RemoteFileBrowserDataSource.
First tab triggers password prompt; siblings reuse the connection."
```

---

## Stage C: Copy-path context menus (issue #4)

### Task C1: `copyPath` helper on the controller — TDD

**Files:**
- Test: `TreemuxTests/FileBrowserTabControllerCopyPathTests.swift` (new)
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift`

**Step 1: Create the test file**

```swift
import XCTest
@testable import Treemux

@MainActor
final class FileBrowserTabControllerCopyPathTests: XCTestCase {
    func test_relativePath_stripsRootPrefix() {
        let ctrl = makeController(rootPath: "/Users/x/repo")
        XCTAssertEqual(ctrl.relativePath("/Users/x/repo/Sources/Foo.swift"), "Sources/Foo.swift")
    }
    func test_relativePath_returnsAbsoluteIfOutsideRoot() {
        let ctrl = makeController(rootPath: "/Users/x/repo")
        XCTAssertEqual(ctrl.relativePath("/etc/passwd"), "/etc/passwd")
    }
    func test_relativePath_handlesTrailingSlashRoot() {
        let ctrl = makeController(rootPath: "/Users/x/repo/")
        XCTAssertEqual(ctrl.relativePath("/Users/x/repo/a.txt"), "a.txt")
    }
    private func makeController(rootPath: String) -> FileBrowserTabController {
        FileBrowserTabController(
            initial: .init(rootPath: rootPath, rootKind: .project),
            dataSource: FileBrowserTabControllerTests.FakeDataSource())
    }
}
```

(`FakeDataSource` from Task A2 must be `internal` — make sure it isn't `private`.)

**Step 2: Run (expect FAIL)**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing:TreemuxTests/FileBrowserTabControllerCopyPathTests 2>&1 | tail -10
```

Expected: compile error — `relativePath` doesn't exist.

**Step 3: Implement `relativePath` and `copyPath` on the controller**

```swift
enum CopyPathMode { case absolute, relative }

func copyPath(_ path: String, mode: CopyPathMode) {
    let value = (mode == .absolute) ? path : relativePath(path)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}

func relativePath(_ path: String) -> String {
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
}
```

**Step 4: Run (expect PASS)**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing:TreemuxTests/FileBrowserTabControllerCopyPathTests 2>&1 | tail -10
```

Expected: PASS.

**Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift TreemuxTests/FileBrowserTabControllerCopyPathTests.swift
git commit -m "feat: copyPath/relativePath on FileBrowserTabController"
```

---

### Task C2: File-tree row context menu

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileTreePanelView.swift`
- Modify: `Treemux/Localizable.xcstrings`

**Step 1: Add `.contextMenu` to `NodeRow.row`**

At the end of the chain after `.onTapGesture { … }`:

```swift
.contextMenu {
    Button(LocalizedStringKey("Copy Absolute Path")) {
        controller.copyPath(node.path, mode: .absolute)
    }
    Button(LocalizedStringKey("Copy Relative Path")) {
        controller.copyPath(node.path, mode: .relative)
    }
    .disabled(node.path == controller.rootPath)
}
```

**Step 2: Add the two keys to `Localizable.xcstrings`**

- `"Copy Absolute Path"` → 复制绝对路径
- `"Copy Relative Path"` → 复制相对路径

**Step 3: Build**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

**Step 4: Manual verify**

Build, open file browser, right-click a file. Two menu items appear. Click each, paste into Terminal — both produce the right strings.

**Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/FileTreePanelView.swift Treemux/Localizable.xcstrings
git commit -m "feat: copy absolute/relative path from file tree right-click menu"
```

---

## Stage D: Sub-tab data model + controller (issue #6 part 1)

### Task D1: `FileSubTabRecord` type + Codable

**Files:**
- Create: `Treemux/Domain/FileSubTabRecord.swift`
- Test: `TreemuxTests/FileSubTabRecordCodingTests.swift` (new)

**Step 1: Failing test — round-trip**

```swift
import XCTest
@testable import Treemux

final class FileSubTabRecordCodingTests: XCTestCase {
    func test_roundTrip() throws {
        let r = FileSubTabRecord(id: UUID(), path: "/a/b.swift", isPinned: true)
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(FileSubTabRecord.self, from: data)
        XCTAssertEqual(decoded, r)
    }
}
```

**Step 2: Run (expect FAIL — type missing)**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing:TreemuxTests/FileSubTabRecordCodingTests 2>&1 | tail -10
```

**Step 3: Create the type**

`Treemux/Domain/FileSubTabRecord.swift`:

```swift
//
//  FileSubTabRecord.swift
//  Treemux

import Foundation

struct FileSubTabRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var path: String
    var isPinned: Bool

    init(id: UUID = UUID(), path: String, isPinned: Bool) {
        self.id = id
        self.path = path
        self.isPinned = isPinned
    }
}
```

**Step 4: Run (expect PASS)**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing:TreemuxTests/FileSubTabRecordCodingTests 2>&1 | tail -10
```

**Step 5: Commit**

```bash
git add Treemux/Domain/FileSubTabRecord.swift TreemuxTests/FileSubTabRecordCodingTests.swift
git commit -m "feat: FileSubTabRecord type for VSCode-style sub-tabs"
```

---

### Task D2: Extend `FileBrowserTabState` with `subTabs` + Codable migration — TDD

**Files:**
- Test: `TreemuxTests/FileBrowserTabStateCodingTests.swift` (new or extend)
- Modify: `Treemux/Domain/FileBrowserTabState.swift`

**Step 1: Failing test — legacy data without `subTabs` migrates**

```swift
import XCTest
@testable import Treemux

final class FileBrowserTabStateCodingTests: XCTestCase {
    func test_legacyDecode_withSelectedFilePath_migratesToPinnedSubTab() throws {
        let json = """
        {
            "rootPath": "/r",
            "rootKind": "project",
            "selectedFilePath": "/r/foo.swift",
            "splitRatio": 0.3,
            "expandedDirs": [],
            "showsHiddenFiles": false
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(FileBrowserTabState.self, from: json)
        XCTAssertEqual(s.subTabs.count, 1)
        XCTAssertEqual(s.subTabs.first?.path, "/r/foo.swift")
        XCTAssertEqual(s.subTabs.first?.isPinned, true)
        XCTAssertEqual(s.activeSubTabID, s.subTabs.first?.id)
    }

    func test_newDecode_withSubTabs() throws {
        let id = UUID().uuidString
        let json = """
        {
            "rootPath": "/r",
            "rootKind": "project",
            "splitRatio": 0.3,
            "expandedDirs": [],
            "showsHiddenFiles": false,
            "subTabs": [{"id":"\(id)","path":"/r/x.swift","isPinned":true}],
            "activeSubTabID": "\(id)"
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(FileBrowserTabState.self, from: json)
        XCTAssertEqual(s.subTabs.count, 1)
        XCTAssertEqual(s.activeSubTabID?.uuidString, id)
    }

    func test_legacyDecode_noSelectedFile_emptySubTabs() throws {
        let json = """
        {"rootPath":"/r","rootKind":"project","splitRatio":0.3,
         "expandedDirs":[],"showsHiddenFiles":false}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(FileBrowserTabState.self, from: json)
        XCTAssertEqual(s.subTabs, [])
        XCTAssertNil(s.activeSubTabID)
    }
}
```

**Step 2: Run (expect FAIL)**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing:TreemuxTests/FileBrowserTabStateCodingTests 2>&1 | tail -15
```

**Step 3: Update `FileBrowserTabState`**

```swift
struct FileBrowserTabState: Codable, Equatable {
    var rootPath: String
    var rootKind: FileBrowserRootKind
    var splitRatio: Double
    var expandedDirs: [String]
    var showsHiddenFiles: Bool
    var subTabs: [FileSubTabRecord]
    var activeSubTabID: UUID?

    init(
        rootPath: String,
        rootKind: FileBrowserRootKind,
        splitRatio: Double = 0.28,
        expandedDirs: [String] = [],
        showsHiddenFiles: Bool = false,
        subTabs: [FileSubTabRecord] = [],
        activeSubTabID: UUID? = nil
    ) {
        self.rootPath = rootPath
        self.rootKind = rootKind
        self.splitRatio = splitRatio
        self.expandedDirs = expandedDirs
        self.showsHiddenFiles = showsHiddenFiles
        self.subTabs = subTabs
        self.activeSubTabID = activeSubTabID
    }

    enum CodingKeys: String, CodingKey {
        case rootPath, rootKind, selectedFilePath  // legacy
        case splitRatio, expandedDirs, showsHiddenFiles, subTabs, activeSubTabID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rootPath = try c.decode(String.self, forKey: .rootPath)
        rootKind = try c.decode(FileBrowserRootKind.self, forKey: .rootKind)
        splitRatio = try c.decodeIfPresent(Double.self, forKey: .splitRatio) ?? 0.28
        expandedDirs = try c.decodeIfPresent([String].self, forKey: .expandedDirs) ?? []
        showsHiddenFiles = try c.decodeIfPresent(Bool.self, forKey: .showsHiddenFiles) ?? false
        if let new = try c.decodeIfPresent([FileSubTabRecord].self, forKey: .subTabs) {
            subTabs = new
            activeSubTabID = try c.decodeIfPresent(UUID.self, forKey: .activeSubTabID)
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .selectedFilePath) {
            let migrated = FileSubTabRecord(path: legacy, isPinned: true)
            subTabs = [migrated]
            activeSubTabID = migrated.id
        } else {
            subTabs = []
            activeSubTabID = nil
        }
    }
}
```

**Step 4: Run (expect PASS)**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing:TreemuxTests/FileBrowserTabStateCodingTests 2>&1 | tail -15
```

**Step 5: Commit**

```bash
git add Treemux/Domain/FileBrowserTabState.swift TreemuxTests/FileBrowserTabStateCodingTests.swift
git commit -m "feat: extend FileBrowserTabState with subTabs + legacy migration"
```

---

### Task D3: `FileBrowserTabController` sub-tab state machine — failing tests

**Files:**
- Test: `TreemuxTests/FileBrowserTabControllerSubTabTests.swift` (new)

**Step 1: Write the test cases (one per scenario)**

```swift
import XCTest
@testable import Treemux

@MainActor
final class FileBrowserTabControllerSubTabTests: XCTestCase {
    private func makeController(rootPath: String = "/r") -> FileBrowserTabController {
        let ds = FileBrowserTabControllerTests.FakeDataSource()
        ds.entries[rootPath] = []
        return FileBrowserTabController(
            initial: .init(rootPath: rootPath, rootKind: .project),
            dataSource: ds
        )
    }

    func test_singleClick_emptyTabs_opensPreview() async {
        let c = makeController()
        await c.openInTree("/r/a.swift")
        XCTAssertEqual(c.subTabs.count, 1)
        XCTAssertFalse(c.subTabs[0].isPinned)
        XCTAssertEqual(c.subTabs[0].path, "/r/a.swift")
        XCTAssertEqual(c.activeSubTabID, c.subTabs[0].id)
    }

    func test_singleClick_existingPreview_replacesPath() async {
        let c = makeController()
        await c.openInTree("/r/a.swift")
        let firstID = c.subTabs[0].id
        await c.openInTree("/r/b.swift")
        XCTAssertEqual(c.subTabs.count, 1)
        XCTAssertEqual(c.subTabs[0].id, firstID, "same preview tab reused")
        XCTAssertEqual(c.subTabs[0].path, "/r/b.swift")
        XCTAssertFalse(c.subTabs[0].isPinned)
    }

    func test_singleClick_alreadyPinned_focusesExisting() async {
        let c = makeController()
        await c.openInTree("/r/a.swift")
        c.pinActiveSubTab()
        let pinnedID = c.subTabs[0].id
        await c.openInTree("/r/b.swift")
        XCTAssertEqual(c.subTabs.count, 2, "pinned + new preview")
        await c.openInTree("/r/a.swift")
        XCTAssertEqual(c.activeSubTabID, pinnedID, "focuses existing pinned")
        XCTAssertEqual(c.subTabs.count, 2, "no extra tab created")
    }

    func test_doubleClick_promotesPreview() async {
        let c = makeController()
        await c.openInTree("/r/a.swift")
        await c.pinFile("/r/a.swift")
        XCTAssertTrue(c.subTabs[0].isPinned)
    }

    func test_closeActive_picksRightNeighbor() async {
        let c = makeController()
        await c.openInTree("/r/a.swift")
        c.pinActiveSubTab()
        await c.openInTree("/r/b.swift")
        c.pinActiveSubTab()
        await c.openInTree("/r/c.swift")
        c.pinActiveSubTab()
        // pinned: [a, b, c], active = c
        c.activateSubTab(c.subTabs[1].id)  // active = b
        c.closeSubTab(c.subTabs[1].id)
        XCTAssertEqual(c.subTabs.count, 2)
        XCTAssertEqual(c.subTabs.last?.path, "/r/c.swift")
        XCTAssertEqual(c.activeSubTabID, c.subTabs.last?.id, "right neighbor selected")
    }

    func test_closeRightmost_picksLeftNeighbor() async {
        let c = makeController()
        await c.openInTree("/r/a.swift")
        c.pinActiveSubTab()
        await c.openInTree("/r/b.swift")
        c.pinActiveSubTab()
        c.closeSubTab(c.subTabs.last!.id)
        XCTAssertEqual(c.subTabs.count, 1)
        XCTAssertEqual(c.activeSubTabID, c.subTabs.first?.id)
    }

    func test_persistableSnapshot_dropsPreviewTabs() async {
        let c = makeController()
        await c.openInTree("/r/a.swift")
        c.pinActiveSubTab()
        await c.openInTree("/r/b.swift")  // preview
        let snap = c.snapshot()
        XCTAssertEqual(snap.subTabs.count, 1, "preview not persisted")
        XCTAssertEqual(snap.subTabs.first?.path, "/r/a.swift")
    }

    func test_handleCloseShortcut_closesSubTabBeforeOuter() async {
        let c = makeController()
        await c.openInTree("/r/a.swift")
        XCTAssertTrue(c.handleCloseShortcut(), "claimed shortcut, closed sub-tab")
        XCTAssertEqual(c.subTabs.count, 0)
        XCTAssertFalse(c.handleCloseShortcut(), "no sub-tabs left, did not claim")
    }
}
```

**Step 2: Run (expect compile errors — APIs not implemented)**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing:TreemuxTests/FileBrowserTabControllerSubTabTests 2>&1 | tail -25
```

Expected: methods `openInTree`, `pinActiveSubTab`, `pinFile`, `closeSubTab`, `activateSubTab`, `handleCloseShortcut`, `snapshot()` (already exists, but its shape changes), and the `subTabs` / `activeSubTabID` fields don't exist yet.

---

### Task D4: Implement sub-tab state machine in the controller

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift`

**Step 1: Add the `SubTabRuntime` type at the top of the file (still in module scope)**

```swift
struct SubTabRuntime: Identifiable {
    let id: UUID
    var path: String
    var isPinned: Bool
    var openFile: OpenFileState
}
```

**Step 2: Replace `selectedFilePath` + single `openFile` with the sub-tab collection**

```swift
@Published private(set) var subTabs: [SubTabRuntime] = []
@Published private(set) var activeSubTabID: UUID?

var activeSubTab: SubTabRuntime? {
    subTabs.first(where: { $0.id == activeSubTabID })
}

// Backward-compat shims for views that still consume openFile/selectedFilePath:
var openFile: OpenFileState { activeSubTab?.openFile ?? .empty }
var selectedFilePath: String? { activeSubTab?.path }
```

**Step 3: Initialize from `state.subTabs` in `init`**

```swift
init(initial state: FileBrowserTabState, dataSource: any FileBrowserDataSource) {
    self.rootPath = state.rootPath
    self.rootKind = state.rootKind
    self.splitRatio = state.splitRatio
    self.expandedDirs = Set(state.expandedDirs)
    self.showsHiddenFiles = state.showsHiddenFiles
    self.dataSource = dataSource
    self.subTabs = state.subTabs.map {
        SubTabRuntime(id: $0.id, path: $0.path, isPinned: $0.isPinned, openFile: .empty)
    }
    self.activeSubTabID = state.activeSubTabID
        ?? subTabs.first?.id
}
```

**Step 4: Update `snapshot()`**

```swift
func snapshot() -> FileBrowserTabState {
    let pinned = subTabs.filter { $0.isPinned }.map {
        FileSubTabRecord(id: $0.id, path: $0.path, isPinned: true)
    }
    let activeID: UUID? = {
        if let active = activeSubTab, active.isPinned { return active.id }
        return pinned.last?.id
    }()
    return FileBrowserTabState(
        rootPath: rootPath,
        rootKind: rootKind,
        splitRatio: splitRatio,
        expandedDirs: Array(expandedDirs),
        showsHiddenFiles: showsHiddenFiles,
        subTabs: pinned,
        activeSubTabID: activeID
    )
}
```

**Step 5: Add the public sub-tab API**

```swift
// Tree single-click: focus pinned, replace preview, or open new preview.
func openInTree(_ path: String) async {
    if let pinned = subTabs.first(where: { $0.isPinned && $0.path == path }) {
        activeSubTabID = pinned.id
        return
    }
    if let previewIdx = subTabs.firstIndex(where: { !$0.isPinned }) {
        subTabs[previewIdx].path = path
        subTabs[previewIdx].openFile = .empty
        activeSubTabID = subTabs[previewIdx].id
        await loadActiveTab()
        onPersistableStateChanged?()
        return
    }
    let new = SubTabRuntime(id: UUID(), path: path, isPinned: false, openFile: .empty)
    subTabs.append(new)
    activeSubTabID = new.id
    await loadActiveTab()
    onPersistableStateChanged?()
}

// Tree double-click (or context-menu Pin): open and pin.
func pinFile(_ path: String) async {
    if let idx = subTabs.firstIndex(where: { $0.path == path }) {
        subTabs[idx].isPinned = true
        activeSubTabID = subTabs[idx].id
        if case .empty = subTabs[idx].openFile { await loadActiveTab() }
        onPersistableStateChanged?()
        return
    }
    let new = SubTabRuntime(id: UUID(), path: path, isPinned: true, openFile: .empty)
    subTabs.append(new)
    activeSubTabID = new.id
    await loadActiveTab()
    onPersistableStateChanged?()
}

func pinActiveSubTab() {
    guard let id = activeSubTabID,
          let idx = subTabs.firstIndex(where: { $0.id == id }) else { return }
    if !subTabs[idx].isPinned {
        subTabs[idx].isPinned = true
        onPersistableStateChanged?()
    }
}

func activateSubTab(_ id: UUID) {
    guard subTabs.contains(where: { $0.id == id }) else { return }
    activeSubTabID = id
    onPersistableStateChanged?()
}

func closeSubTab(_ id: UUID) {
    guard let idx = subTabs.firstIndex(where: { $0.id == id }) else { return }
    let wasActive = (activeSubTabID == id)
    subTabs.remove(at: idx)
    if wasActive {
        if idx < subTabs.count {
            activeSubTabID = subTabs[idx].id
        } else if !subTabs.isEmpty {
            activeSubTabID = subTabs[subTabs.count - 1].id
        } else {
            activeSubTabID = nil
        }
    }
    onPersistableStateChanged?()
}

func reorderSubTabs(from source: IndexSet, to destination: Int) {
    subTabs.move(fromOffsets: source, toOffset: destination)
    onPersistableStateChanged?()
}

/// Returns true if the shortcut was claimed (sub-tab closed).
func handleCloseShortcut() -> Bool {
    guard let id = activeSubTabID else { return false }
    closeSubTab(id)
    return true
}
```

**Step 6: Adapt file-loading paths to act on the active sub-tab**

Replace places that wrote `self.openFile = …` with a helper:

```swift
private func setActiveOpenFile(_ state: OpenFileState) {
    guard let id = activeSubTabID,
          let idx = subTabs.firstIndex(where: { $0.id == id }) else { return }
    subTabs[idx].openFile = state
}
```

Then `selectFile`, `loadText`, `loadImage`, `loadQuickLook`, `loadUnknown`, `confirmLargeFileLoad`, `cancelLargeFileLoad`, `updateBuffer`, `saveCurrentFile` all call `setActiveOpenFile(...)` and read the active sub-tab's path.

Add a shim that loads the active sub-tab's file (used by `openInTree` / `pinFile`):

```swift
private func loadActiveTab() async {
    guard let active = activeSubTab else { return }
    await selectFile(active.path)
}
```

**Step 7: `isDirty` looks at active tab**

```swift
var isDirty: Bool {
    if case .text(_, _, _, let dirty) = activeSubTab?.openFile { return dirty }
    return false
}
```

Add `var dirtySubTabs: [SubTabRuntime]` for the batch close sheet (Stage F):
```swift
var dirtySubTabs: [SubTabRuntime] {
    subTabs.filter {
        if case .text(_, _, _, let d) = $0.openFile { return d }
        return false
    }
}
```

**Step 8: Run tests (expect PASS)**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing:TreemuxTests/FileBrowserTabControllerSubTabTests 2>&1 | tail -25
```

If any test fails, fix the smallest piece and re-run.

**Step 9: Commit**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift TreemuxTests/FileBrowserTabControllerSubTabTests.swift
git commit -m "feat: VSCode-style sub-tab state machine in FileBrowserTabController

Introduces SubTabRuntime (per-sub-tab buffer), publishes subTabs +
activeSubTabID, adds openInTree/pinFile/pinActiveSubTab/closeSubTab/
reorderSubTabs/handleCloseShortcut. snapshot() persists only pinned tabs;
loadActiveTab routes file-loading through the active sub-tab."
```

---

### Task D5: Update tree-row click sites to call the new API

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileTreePanelView.swift`

**Step 1: Replace `controller.selectFile(...)` calls in `NodeRow.row.onTapGesture`**

Old:
```swift
.onTapGesture {
    if node.isDirectory {
        Task { await controller.toggleExpand(node.path) }
    } else {
        Task { await controller.selectFile(node.path) }
    }
}
```

New: SwiftUI's `onTapGesture` doesn't differentiate single vs double easily. Use `.gesture(TapGesture(count: 2))` first, then a fallback `TapGesture(count: 1)`:

```swift
.gesture(
    TapGesture(count: 2).onEnded {
        if !node.isDirectory {
            Task { await controller.pinFile(node.path) }
        }
    }
)
.simultaneousGesture(
    TapGesture(count: 1).onEnded {
        if node.isDirectory {
            Task { await controller.toggleExpand(node.path) }
        } else {
            Task { await controller.openInTree(node.path) }
        }
    }
)
```

(SwiftUI dispatches both for a double-click; the double-click handler is invoked after the single one. To prevent the single-click action from also pinning, the `pinFile(...)` call **after** `openInTree(...)` is idempotent — it just upgrades the matching tab to pinned. Confirm in manual QA.)

**Step 2: Build**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux build 2>&1 | tail -10
```

**Step 3: Manual verify**

Single-click file → preview opens; click another file → preview replaces; double-click → tab pinned (italic → regular).

**Step 4: Commit**

```bash
git add Treemux/UI/FileBrowser/FileTreePanelView.swift
git commit -m "feat: file tree single/double-click routes to sub-tab API"
```

---

## Stage E: Sub-tab UI (issue #6 part 2)

### Task E1: `FileSubTabBarView` skeleton

**Files:**
- Create: `Treemux/UI/FileBrowser/FileSubTabBarView.swift`

**Step 1: Initial implementation**

```swift
//
//  FileSubTabBarView.swift
//  Treemux

import SwiftUI

struct FileSubTabBarView: View {
    @ObservedObject var controller: FileBrowserTabController
    @State private var hoveredID: UUID?
    @State private var draggedID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(controller.subTabs) { tab in
                    SubTabButton(
                        tab: tab,
                        isActive: tab.id == controller.activeSubTabID,
                        isHovered: hoveredID == tab.id,
                        isDirty: dirtyState(for: tab),
                        rootPath: controller.rootPath,
                        onSelect: { controller.activateSubTab(tab.id) },
                        onClose: { controller.closeSubTab(tab.id) },
                        onCopyAbsolute: { controller.copyPath(tab.path, mode: .absolute) },
                        onCopyRelative: { controller.copyPath(tab.path, mode: .relative) },
                        onPin: { controller.pinActiveSubTab() },
                        onCloseOthers: { closeAllExcept(tab.id) },
                        onCloseAll: { closeAll() }
                    )
                    .onHover { hoveredID = $0 ? tab.id : nil }
                    .onDrag {
                        draggedID = tab.id
                        return NSItemProvider(object: tab.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], delegate: SubTabDropDelegate(
                        targetID: tab.id, controller: controller, draggedID: $draggedID))
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 32)
        .background(.thickMaterial)
    }

    private func dirtyState(for tab: SubTabRuntime) -> Bool {
        if case .text(_, _, _, let d) = tab.openFile { return d }
        return false
    }

    private func closeAllExcept(_ id: UUID) {
        let toClose = controller.subTabs.filter { $0.id != id }.map(\.id)
        toClose.forEach(controller.closeSubTab)
    }

    private func closeAll() {
        let ids = controller.subTabs.map(\.id)
        ids.forEach(controller.closeSubTab)
    }
}

private struct SubTabDropDelegate: DropDelegate {
    let targetID: UUID
    let controller: FileBrowserTabController
    @Binding var draggedID: UUID?

    func performDrop(info: DropInfo) -> Bool { draggedID = nil; return true }
    func dropEntered(info: DropInfo) {
        guard let from = draggedID, from != targetID,
              let i = controller.subTabs.firstIndex(where: { $0.id == from }),
              let j = controller.subTabs.firstIndex(where: { $0.id == targetID }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            controller.reorderSubTabs(from: IndexSet(integer: i),
                                      to: j > i ? j + 1 : j)
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

private struct SubTabButton: View {
    let tab: SubTabRuntime
    let isActive: Bool
    let isHovered: Bool
    let isDirty: Bool
    let rootPath: String
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCopyAbsolute: () -> Void
    let onCopyRelative: () -> Void
    let onPin: () -> Void
    let onCloseOthers: () -> Void
    let onCloseAll: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(isActive ? .primary : .secondary)
                Text(URL(fileURLWithPath: tab.path).lastPathComponent)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .italic(!tab.isPinned)
                    .foregroundStyle(isActive ? .primary : .secondary)
                if isDirty {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                }
                if isHovered || isActive {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isActive ? AnyShapeStyle(.white.opacity(0.12))
                : isHovered ? AnyShapeStyle(.white.opacity(0.06))
                : AnyShapeStyle(Color.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .bottom) {
                if isActive {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .padding(.horizontal, 4)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(LocalizedStringKey("Copy Absolute Path")) { onCopyAbsolute() }
            Button(LocalizedStringKey("Copy Relative Path")) { onCopyRelative() }
            Divider()
            if !tab.isPinned {
                Button(LocalizedStringKey("Pin Tab")) { onPin() }
            }
            Button(LocalizedStringKey("Close Tab")) { onClose() }
            Button(LocalizedStringKey("Close Other Tabs")) { onCloseOthers() }
            Button(LocalizedStringKey("Close All Tabs")) { onCloseAll() }
        }
    }

    private var iconName: String {
        switch FileTypeClassifier.classifyByName(tab.path) {
        case .text: return "doc.text"
        case .image: return "photo"
        case .quickLook: return "doc.richtext"
        case .binary, .unknown: return "doc"
        }
    }
}
```

**Step 2: Localize new keys in `Localizable.xcstrings`**

Add: `"Pin Tab"` (固定标签页), `"Close Tab"` (关闭标签页), `"Close Other Tabs"` (关闭其他标签页), `"Close All Tabs"` (关闭所有标签页).

**Step 3: Build**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux build 2>&1 | tail -10
```

**Step 4: Commit**

```bash
git add Treemux/UI/FileBrowser/FileSubTabBarView.swift Treemux/Localizable.xcstrings
git commit -m "feat: FileSubTabBarView with active highlight, dirty dot, drag, context menu"
```

---

### Task E2: Wire `FileSubTabBarView` into `FileViewerPanelView`

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileViewerPanelView.swift`

**Step 1: Wrap with `VStack` and inject the bar**

```swift
struct FileViewerPanelView: View {
    @ObservedObject var controller: FileBrowserTabController

    var body: some View {
        VStack(spacing: 0) {
            if !controller.subTabs.isEmpty {
                FileSubTabBarView(controller: controller)
                Divider()
            }
            content
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch controller.openFile {
        case .empty:
            EmptyViewerState(rootPath: controller.rootPath)
        // … remaining cases unchanged …
        }
    }
}
```

(Move the existing switch into the `content` computed property.)

**Step 2: Build + manual verify**

Single-click → bar appears with one preview tab; click another file → bar shows the same tab with new path; double-click → italic disappears (pinned).

**Step 3: Commit**

```bash
git add Treemux/UI/FileBrowser/FileViewerPanelView.swift
git commit -m "feat: render FileSubTabBarView above the viewer panel"
```

---

### Task E3: Cmd+W cascade through the active sub-tab

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift`
- Modify: `Treemux/AppDelegate.swift`

**Step 1: Add `handleCloseShortcut()` on `WorkspaceModel`**

```swift
/// Returns true if the shortcut was consumed (closed a sub-tab); false if the caller should fall through to closing the outer tab.
func handleCloseShortcut() -> Bool {
    guard let tabID = activeTabID,
          let tab = tabs.first(where: { $0.id == tabID }),
          tab.kind == .fileBrowser,
          let ctrl = fileBrowserControllers[activeWorktreePath]?[tabID] else {
        return false
    }
    return ctrl.handleCloseShortcut()
}
```

**Step 2: Route Cmd+W through it in `AppDelegate`**

Find the Cmd+W menu handler (probably `closeTab` action). Before calling `requestCloseTab(activeTabID)`, check:

```swift
if let workspace = WorkspaceStore.shared.selectedWorkspace,
   workspace.handleCloseShortcut() {
    return
}
// existing close-tab path
```

(Locate the exact site by grepping `closeTab` / `Cmd+W` / `key.W` in `AppDelegate.swift`.)

**Step 3: Build + manual verify**

3 sub-tabs open → Cmd+W closes one. Repeat → all closed → next Cmd+W closes the parent file-browser tab.

**Step 4: Commit**

```bash
git add Treemux/Domain/WorkspaceModels.swift Treemux/AppDelegate.swift
git commit -m "feat: Cmd+W cascades through file-browser sub-tabs first"
```

---

### Task E4: Empty state when sub-tabs is empty

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileViewerPanelView.swift`

**Step 1: When `controller.subTabs.isEmpty`, show empty state but keep the panel mounted**

The fallback already exists (`EmptyViewerState`). Confirm it's reached when `controller.openFile == .empty`, which is the case when `activeSubTab == nil`. No code change required — this task is a verify-only checkpoint.

**Step 2: Manual verify**

Open file browser, single-click + close → tree side empty → viewer shows "Select a file from the tree". File-browser parent tab stays open.

**Step 3: No commit needed** (no code change).

---

## Stage F: Dirty file sheets (issue #6 part 3)

### Task F1: Single-file dirty sheet

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift`
- Modify: `Treemux/Localizable.xcstrings`

**Step 1: Wrap `closeSubTab` with a dirty check**

Rename current `closeSubTab(_:)` to `closeSubTabImmediate(_:)` (private). Add public:

```swift
func closeSubTab(_ id: UUID) {
    guard let idx = subTabs.firstIndex(where: { $0.id == id }) else { return }
    let tab = subTabs[idx]
    if case .text(let path, _, _, let dirty) = tab.openFile, dirty {
        confirmCloseDirtySubTab(id: id, path: path)
    } else {
        closeSubTabImmediate(id)
    }
}

private func confirmCloseDirtySubTab(id: UUID, path: String) {
    let alert = NSAlert()
    let name = URL(fileURLWithPath: path).lastPathComponent
    alert.messageText = String.localizedStringWithFormat(
        String(localized: "%@ has unsaved changes."), name)
    alert.informativeText = String(localized: "Save changes before closing?")
    alert.alertStyle = .warning
    alert.addButton(withTitle: String(localized: "Save"))
    alert.addButton(withTitle: String(localized: "Don't Save"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    let response = alert.runModal()
    switch response {
    case .alertFirstButtonReturn:
        Task { @MainActor in
            do {
                activateSubTab(id)
                try await saveCurrentFile()
                closeSubTabImmediate(id)
            } catch {
                let err = NSAlert()
                err.messageText = String(localized: "Save failed")
                err.informativeText = error.localizedDescription
                err.runModal()
            }
        }
    case .alertSecondButtonReturn:
        closeSubTabImmediate(id)
    default:
        break
    }
}
```

**Step 2: Localize**

Add to `Localizable.xcstrings`: `"%@ has unsaved changes."` (zh-Hans: "%@" 存在未保存的修改。), `"Don't Save"` (zh-Hans: 不保存). `"Save"`, `"Cancel"`, `"Save failed"`, `"Save changes before closing?"` should already exist; verify and add if missing.

**Step 3: Run sub-tab tests to make sure non-dirty close paths still pass**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing:TreemuxTests/FileBrowserTabControllerSubTabTests 2>&1 | tail -15
```

Expected: PASS.

**Step 4: Manual verify**

Open file, edit, click ×. Sheet appears. Save / Don't Save / Cancel all behave correctly.

**Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift Treemux/Localizable.xcstrings
git commit -m "feat: dirty-file confirmation sheet for sub-tab close"
```

---

### Task F2: Batch unsaved-changes sheet on outer-tab close

**Files:**
- Create: `Treemux/UI/FileBrowser/BatchUnsavedChangesSheet.swift`
- Modify: `Treemux/Domain/WorkspaceModels.swift` (`requestCloseTab`)

**Step 1: Create `BatchUnsavedChangesSheet.swift`**

```swift
//
//  BatchUnsavedChangesSheet.swift
//  Treemux

import SwiftUI

struct BatchUnsavedChangesSheet: View {
    let dirtyRelativePaths: [String]
    let onSaveAll: () -> Void
    let onDiscardAll: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String.localizedStringWithFormat(
                String(localized: "%lld files have unsaved changes:"),
                dirtyRelativePaths.count))
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(dirtyRelativePaths, id: \.self) { p in
                        Text(p).font(.system(size: 12, design: .monospaced))
                    }
                }
            }
            .frame(minHeight: 80, maxHeight: 200)
            HStack {
                Button(LocalizedStringKey("Cancel")) { onCancel() }
                Spacer()
                Button(LocalizedStringKey("Don't Save")) { onDiscardAll() }
                Button(LocalizedStringKey("Save All")) { onSaveAll() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
```

**Step 2: Modify `WorkspaceModel.requestCloseTab(_:)` to detect ≥1 dirty sub-tab and present batch sheet**

Replace the existing dirty branch:

```swift
func requestCloseTab(_ tabID: UUID) {
    guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
    if tab.kind == .fileBrowser,
       let ctrl = fileBrowserControllers[activeWorktreePath]?[tabID] {
        let dirty = ctrl.dirtySubTabs
        if dirty.count == 1 {
            confirmCloseDirtySubTabThenCloseOuter(tabID: tabID, controller: ctrl, subTabID: dirty[0].id)
            return
        } else if dirty.count > 1 {
            presentBatchSheet(tabID: tabID, controller: ctrl)
            return
        }
    }
    closeTab(tabID)
}
```

Implement `presentBatchSheet` using SwiftUI sheet on the main window. Easiest path: post a `Notification` or assign a `@Published var pendingBatchSheet: BatchSheetModel?` on `WorkspaceStore`; `WorkspaceTabContainerView` already does `.sheet(item:)` — add another item there.

Concrete approach for this plan: extend `WorkspaceTabContainerView` with a `@State var batchSheet: BatchSheetModel?` and an `.onReceive` of a new `WorkspaceModel.batchSheetRequest` publisher. `BatchSheetModel` carries `tabID`, dirty list, and the callbacks.

**Step 3: Wire callbacks**

- Save All → iterate dirty sub-tabs, `activateSubTab(id) + saveCurrentFile()`. After all succeed, `closeTab(tabID)` on the workspace.
- Don't Save → `closeTab(tabID)`.
- Cancel → dismiss.

**Step 4: Build + manual verify**

Open 2 files, edit both. Click × on the file-browser tab. Batch sheet shows both relative paths.

**Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/BatchUnsavedChangesSheet.swift Treemux/Domain/WorkspaceModels.swift Treemux/UI/Workspace/WorkspaceDetailView.swift Treemux/Localizable.xcstrings
git commit -m "feat: batch unsaved-changes sheet for closing file-browser tab with multiple dirty sub-tabs"
```

---

## Stage G: Editor upgrade (Tier 1 + 2 + 3a)

### Task G1: Add Runestone + TreeSitterLanguages packages

**Files:**
- Modify: `project.yml`
- Run: `xcodegen` to regenerate the project

**Step 1: Update `project.yml`**

Add under `packages:`:

```yaml
Runestone:
  url: https://github.com/simonbs/Runestone
  from: "0.4.4"
TreeSitterLanguages:
  url: https://github.com/simonbs/TreeSitterLanguages
  from: "0.1.7"
```

Add under the Treemux target's `dependencies:`:

```yaml
- package: Runestone
- package: TreeSitterLanguages
```

**Step 2: Regenerate the Xcode project**

```bash
which xcodegen || brew install xcodegen
xcodegen generate
```

**Step 3: Build to fetch packages**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED. First build will take longer (SPM resolves new deps).

**Step 4: Commit**

```bash
git add project.yml Treemux.xcodeproj
git commit -m "build: add Runestone + TreeSitterLanguages packages"
```

---

### Task G2: Replace `NSTextView` with Runestone in `TextEditorView`

**Files:**
- Modify: `Treemux/UI/FileBrowser/TextEditorView.swift`
- Delete: `Treemux/UI/FileBrowser/LineNumberRulerView.swift`
- Modify: `Treemux/Domain/FileTypeClassifier.swift` (add language mapping)

**Step 1: Add language mapping**

In `FileTypeClassifier.swift`:

```swift
enum SupportedLanguage: String {
    case swift, javascript, typescript, tsx, python, go, rust, json, yaml, markdown, html, css, bash
}

static func language(forPath path: String) -> SupportedLanguage? {
    let ext = (path as NSString).pathExtension.lowercased()
    switch ext {
    case "swift": return .swift
    case "js", "mjs", "cjs": return .javascript
    case "ts": return .typescript
    case "tsx", "jsx": return .tsx
    case "py": return .python
    case "go": return .go
    case "rs": return .rust
    case "json": return .json
    case "yml", "yaml": return .yaml
    case "md", "markdown": return .markdown
    case "html", "htm": return .html
    case "css", "scss", "less": return .css
    case "sh", "bash", "zsh": return .bash
    default: return nil
    }
}
```

**Step 2: Replace `NSTextEditorView` with a Runestone-based `NSViewRepresentable`**

```swift
import Runestone
import TreeSitterLanguages
// per-language imports as needed (TreeSitterLanguages exposes them)

private struct RunestoneTextEditorView: NSViewRepresentable {
    let content: String
    let path: String
    let onChange: (String) -> Void

    func makeNSView(context: Context) -> TextView {
        let tv = TextView()
        tv.text = content
        tv.editorDelegate = context.coordinator
        tv.theme = TreemuxRunestoneTheme.current
        tv.showLineNumbers = true
        tv.lineHeightMultiplier = 1.2
        tv.isAutomaticTabReplacementEnabled = false
        applyLanguageMode(tv: tv)
        return tv
    }

    func updateNSView(_ tv: TextView, context: Context) {
        if tv.text != content { tv.text = content }
    }

    private func applyLanguageMode(tv: TextView) {
        guard let lang = FileTypeClassifier.language(forPath: path),
              fileSizeForPath(path) <= 2 * 1024 * 1024 else {
            tv.setLanguageMode(PlainTextLanguageMode())
            return
        }
        let mode = treeSitterLanguageMode(for: lang)
        tv.setLanguageMode(mode)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    final class Coordinator: NSObject, TextViewDelegate {
        let onChange: (String) -> Void
        init(onChange: @escaping (String) -> Void) { self.onChange = onChange }
        func textViewDidChange(_ textView: TextView) { onChange(textView.text) }
    }
}

private func treeSitterLanguageMode(for lang: SupportedLanguage) -> any LanguageMode {
    switch lang {
    case .swift:      return TreeSitterLanguageMode(language: .swift)
    case .javascript: return TreeSitterLanguageMode(language: .javaScript)
    case .typescript: return TreeSitterLanguageMode(language: .typeScript)
    case .tsx:        return TreeSitterLanguageMode(language: .tsx)
    case .python:     return TreeSitterLanguageMode(language: .python)
    case .go:         return TreeSitterLanguageMode(language: .go)
    case .rust:       return TreeSitterLanguageMode(language: .rust)
    case .json:       return TreeSitterLanguageMode(language: .json)
    case .yaml:       return TreeSitterLanguageMode(language: .yaml)
    case .markdown:   return TreeSitterLanguageMode(language: .markdown)
    case .html:       return TreeSitterLanguageMode(language: .html)
    case .css:        return TreeSitterLanguageMode(language: .css)
    case .bash:       return TreeSitterLanguageMode(language: .bash)
    }
}

private func fileSizeForPath(_ path: String) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
}
```

(Verify exact API names against `TreeSitterLanguages` README — `TreeSitterLanguageMode(language: .swift)` is the typical surface; adjust if the package version differs.)

**Step 3: Provide a basic theme**

Create a small `TreemuxRunestoneTheme` struct conforming to Runestone's `Theme` protocol, deriving colors from `ThemeManager` (light vs dark). Place in same file or a sibling.

**Step 4: Replace `TextEditorView.body` to use the new representable**

```swift
var body: some View {
    VStack(spacing: 0) {
        RunestoneTextEditorView(content: content, path: path,
                                onChange: { controller.updateBuffer(content: $0) })
        Divider()
        statusBar
    }
}
```

**Step 5: Delete `LineNumberRulerView.swift`**

```bash
git rm Treemux/UI/FileBrowser/LineNumberRulerView.swift
```

**Step 6: Build + manual verify**

Open a `.swift` file → tokens are colored. Open a `.txt` (no language) → plain text. Edit + Cmd+S works.

**Step 7: Commit**

```bash
git add Treemux/UI/FileBrowser/TextEditorView.swift Treemux/Domain/FileTypeClassifier.swift
git commit -m "feat: replace NSTextView with Runestone for syntax-highlighted editor

Adds language mapping by extension, Treemux theme bridge, and a 2 MB
guard that falls back to plain-text mode for large files. LineNumberRulerView
is no longer needed."
```

---

### Task G3: Git diff service — local

**Files:**
- Create: `Treemux/Services/Git/GitDiffService.swift`
- Create: `Treemux/Services/Git/LocalGitDiffService.swift`
- Test: `TreemuxTests/GitDiffServiceTests.swift`

**Step 1: Define types in `GitDiffService.swift`**

```swift
//
//  GitDiffService.swift
//  Treemux

import Foundation

protocol GitDiffService {
    func diffHunks(forFile path: String, repoRoot: String) async throws -> [DiffHunk]
    func fileStatus(in repoRoot: String) async throws -> [String: FileStatus]
}

struct DiffHunk: Equatable {
    enum Kind { case added, modified, removed }
    var newLineRange: ClosedRange<Int>
    var kind: Kind
}

enum FileStatus: Equatable {
    case untracked, modified, added, deleted
    case renamed(from: String)
}
```

**Step 2: Failing test for diff parser**

```swift
import XCTest
@testable import Treemux

final class GitDiffServiceTests: XCTestCase {
    func test_parseDiff_detectsAddedHunk() {
        let raw = """
        diff --git a/foo.swift b/foo.swift
        index 1234..5678 100644
        --- a/foo.swift
        +++ b/foo.swift
        @@ -10,3 +10,5 @@ class Foo {
             let a = 1
        +    let b = 2
        +    let c = 3
             let d = 4
        """
        let hunks = LocalGitDiffService.parseDiff(raw)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].kind, .modified)
        XCTAssertTrue(hunks[0].newLineRange.contains(11))
    }

    func test_parseStatus_classifiesPorcelainCodes() {
        let raw = """
         M Sources/Foo.swift
        ?? Sources/Bar.swift
        A  Sources/Baz.swift
        """
        let status = LocalGitDiffService.parseStatus(raw)
        XCTAssertEqual(status["Sources/Foo.swift"], .modified)
        XCTAssertEqual(status["Sources/Bar.swift"], .untracked)
        XCTAssertEqual(status["Sources/Baz.swift"], .added)
    }
}
```

**Step 3: Run (expect FAIL — no parsers yet)**

**Step 4: Implement `LocalGitDiffService.swift`**

```swift
import Foundation

struct LocalGitDiffService: GitDiffService {
    func diffHunks(forFile path: String, repoRoot: String) async throws -> [DiffHunk] {
        let raw = try await runGit(["diff", "--no-color", "HEAD", "--", path], in: repoRoot)
        return Self.parseDiff(raw)
    }

    func fileStatus(in repoRoot: String) async throws -> [String: FileStatus] {
        let raw = try await runGit(["status", "--porcelain"], in: repoRoot)
        return Self.parseStatus(raw)
    }

    static func parseDiff(_ raw: String) -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        for line in raw.split(separator: "\n") {
            guard line.hasPrefix("@@") else { continue }
            // @@ -a,b +c,d @@
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }
            let new = parts[2]   // "+c,d"
            let trimmed = new.dropFirst()
            let comps = trimmed.split(separator: ",")
            guard let start = Int(comps[0]) else { continue }
            let count = comps.count > 1 ? (Int(comps[1]) ?? 1) : 1
            if count == 0 { continue }
            hunks.append(DiffHunk(newLineRange: start...(start + count - 1), kind: .modified))
        }
        return hunks
    }

    static func parseStatus(_ raw: String) -> [String: FileStatus] {
        var out: [String: FileStatus] = [:]
        for line in raw.split(separator: "\n") {
            guard line.count >= 4 else { continue }
            let code = String(line.prefix(2))
            let path = String(line.dropFirst(3))
            switch code {
            case "??": out[path] = .untracked
            case " M", "M ", "MM": out[path] = .modified
            case "A ", " A": out[path] = .added
            case "D ", " D": out[path] = .deleted
            case let c where c.hasPrefix("R"):
                if let arrow = path.range(of: " -> ") {
                    let from = String(path[..<arrow.lowerBound])
                    let to = String(path[arrow.upperBound...])
                    out[to] = .renamed(from: from)
                }
            default: out[path] = .modified
            }
        }
        return out
    }

    private func runGit(_ args: [String], in cwd: String) async throws -> String {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git"] + args
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }
}
```

**Step 5: Run tests (expect PASS)**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing:TreemuxTests/GitDiffServiceTests 2>&1 | tail -20
```

**Step 6: Commit**

```bash
git add Treemux/Services/Git/GitDiffService.swift Treemux/Services/Git/LocalGitDiffService.swift TreemuxTests/GitDiffServiceTests.swift
git commit -m "feat: GitDiffService protocol + local impl with porcelain/diff parsers"
```

---

### Task G4: Git diff service — remote (via SFTPService runSSH)

**Files:**
- Create: `Treemux/Services/Git/RemoteGitDiffService.swift`
- Modify: `Treemux/Services/SFTP/SFTPService.swift` (expose `runSSH` if not already public)

**Step 1: If `runSSH` is private, expose `runCommand(_:in:)` on `SFTPService`**

Locate `runSSH` in `SFTPService.swift`. Add a public wrapper:

```swift
func runCommand(_ command: String, in cwd: String? = nil) async throws -> String {
    guard let mode else { throw SFTPServiceError.notConnected }
    switch mode {
    case .ssh(let target):
        let full = cwd.map { "cd \($0.shellQuoted) && \(command)" } ?? command
        let r = try await runSSH(target: target, command: full)
        return r.output
    case .citadel(let client, _):
        // Use SSHClient.executeCommand if available; otherwise fall through to ssh
        // For P1, only the .ssh path is exercised by file-browser flows.
        throw SFTPServiceError.commandFailed("Citadel runCommand not supported")
    }
}
```

(Add `String.shellQuoted` helper if missing — wraps in single quotes, escapes embedded quotes.)

**Step 2: Implement `RemoteGitDiffService.swift`**

```swift
struct RemoteGitDiffService: GitDiffService {
    let service: SFTPService

    func diffHunks(forFile path: String, repoRoot: String) async throws -> [DiffHunk] {
        let raw = try await service.runCommand("git diff --no-color HEAD -- \(path.shellQuoted)", in: repoRoot)
        return LocalGitDiffService.parseDiff(raw)
    }

    func fileStatus(in repoRoot: String) async throws -> [String: FileStatus] {
        let raw = try await service.runCommand("git status --porcelain", in: repoRoot)
        return LocalGitDiffService.parseStatus(raw)
    }
}
```

**Step 3: Build (no test for remote; manual)**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux build 2>&1 | tail -10
```

**Step 4: Commit**

```bash
git add Treemux/Services/Git/RemoteGitDiffService.swift Treemux/Services/SFTP/SFTPService.swift
git commit -m "feat: remote git diff service via SFTPService.runCommand"
```

---

### Task G5: Plumb diff data through the controller

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift`
- Modify: `Treemux/Domain/WorkspaceModels.swift` (init wires the right service)

**Step 1: Add `gitDiffService` to controller**

```swift
@Published private(set) var diffHunksByPath: [String: [DiffHunk]] = [:]
@Published private(set) var fileStatusByPath: [String: FileStatus] = [:]

let gitDiffService: GitDiffService?
let repoRoot: String?
```

(Compute `repoRoot` at init: for `rootKind == .worktree` or `.project`, treat `rootPath` as the repo root.)

**Step 2: Add init wiring**

```swift
init(initial state: FileBrowserTabState, dataSource: any FileBrowserDataSource,
     gitDiffService: GitDiffService? = nil, repoRoot: String? = nil) {
    // …existing assignments…
    self.gitDiffService = gitDiffService
    self.repoRoot = repoRoot
}
```

**Step 3: In `WorkspaceModel.fileBrowserController(forTabID:)`, build the right service**

```swift
let gitService: GitDiffService = {
    if let target = sshTarget {
        return RemoteGitDiffService(service: ensureSharedSFTPService())
    }
    return LocalGitDiffService()
}()
let ctrl = FileBrowserTabController(
    initial: state, dataSource: dataSource,
    gitDiffService: gitService, repoRoot: state.rootPath
)
```

**Step 4: Loading methods on the controller**

```swift
func refreshGitStatus() async {
    guard let svc = gitDiffService, let root = repoRoot else { return }
    if let s = try? await svc.fileStatus(in: root) {
        // Translate paths from repo-relative to absolute for lookup parity
        var byPath: [String: FileStatus] = [:]
        let prefix = root.hasSuffix("/") ? root : root + "/"
        for (rel, st) in s { byPath[prefix + rel] = st }
        fileStatusByPath = byPath
    }
}

func refreshDiffForActive() async {
    guard let svc = gitDiffService, let root = repoRoot,
          let path = activeSubTab?.path else { return }
    if let h = try? await svc.diffHunks(forFile: path, repoRoot: root) {
        diffHunksByPath[path] = h
    }
}
```

**Step 5: Trigger them**

- Call `await refreshGitStatus()` from `loadRoot()` after the tree loads.
- Call `await refreshDiffForActive()` whenever `activeSubTabID` changes (add a `didSet`-equivalent — easiest with a wrapper setter on `activeSubTabID`).
- In `saveCurrentFile()`, after success: `await refreshDiffForActive()`.

**Step 6: Build**

```bash
xcodebuild build -project Treemux.xcodeproj -scheme Treemux 2>&1 | tail -10
```

**Step 7: Commit**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift Treemux/Domain/WorkspaceModels.swift
git commit -m "feat: wire GitDiffService into FileBrowserTabController; cache diff/status"
```

---

### Task G6: File-tree status badges

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileTreePanelView.swift`

**Step 1: In `NodeRow.row`, render a small dot before `iconName`**

```swift
HStack(spacing: 4) {
    // … indent + chevron …
    if let status = controller.fileStatusByPath[node.path] {
        Circle()
            .fill(color(for: status))
            .frame(width: 4, height: 4)
    } else {
        Color.clear.frame(width: 4, height: 4)
    }
    Image(systemName: iconName)
    // … rest …
}
```

```swift
private func color(for status: FileStatus) -> Color {
    switch status {
    case .untracked: return .gray
    case .modified, .renamed: return .orange
    case .added: return .green
    case .deleted: return .red
    }
}
```

**Step 2: Build + manual verify on a repo with edits**

Status dots appear on modified/added/etc. files. Save a file → dot appears (after refresh).

**Step 3: Commit**

```bash
git add Treemux/UI/FileBrowser/FileTreePanelView.swift
git commit -m "feat: file-tree git status badges (M/A/U/D)"
```

---

### Task G7: Editor gutter diff stripes

**Files:**
- Modify: `Treemux/UI/FileBrowser/TextEditorView.swift`

**Step 1: Use Runestone's gutter customization**

Runestone exposes `TextView.gutterTrailingPadding`, plus a way to draw alongside line numbers (depending on version, often via subclassing `LineNumberPainter` or adding a `gutterRangeOverlay`). Pseudocode:

```swift
// In RunestoneTextEditorView.makeNSView:
tv.lineNumberPainter = DiffStripeLineNumberPainter(
    base: tv.lineNumberPainter,
    hunksProvider: { [weak controller] in
        guard let controller else { return [] }
        return controller.diffHunksByPath[path] ?? []
    }
)
```

If Runestone's API doesn't allow swap-in painters, fall back: subclass `TextView` and override `draw(_:)` to add stripes after super, computing line Y positions via Runestone's public layout API (`TextView.lineFrame(forLineAt:)` if available, else through `caretRect`).

**Step 2: Build + manual verify**

Edit a file in a git repo. Modified lines have an orange/green stripe in the gutter. Save → re-fetch hunks → stripes update.

**Step 3: Commit**

```bash
git add Treemux/UI/FileBrowser/TextEditorView.swift
git commit -m "feat: editor gutter stripes for git diff hunks"
```

---

### Task G8: Word completion — `BufferWordIndex` + popover

**Files:**
- Create: `Treemux/Services/Editor/BufferWordIndex.swift`
- Test: `TreemuxTests/BufferWordIndexTests.swift`
- Create: `Treemux/UI/FileBrowser/CompletionPopover.swift`

**Step 1: Failing test for `BufferWordIndex`**

```swift
import XCTest
@testable import Treemux

final class BufferWordIndexTests: XCTestCase {
    func test_extractsIdentifiers_excludingShortAndNumbers() async {
        let idx = BufferWordIndex()
        let id = UUID()
        await idx.update(bufferID: id, contents: "let foo = 42; var bar = 'hello'; a")
        let s = await idx.suggestions(prefix: "fo", limit: 10)
        XCTAssertTrue(s.contains("foo"))
        XCTAssertFalse(s.contains("a"), "single-char identifiers excluded")
    }

    func test_multipleBuffers_unionAndRanking() async {
        let idx = BufferWordIndex()
        let a = UUID(); let b = UUID()
        await idx.update(bufferID: a, contents: "fooBar fooBaz fooBar")
        await idx.update(bufferID: b, contents: "fooQux")
        let s = await idx.suggestions(prefix: "foo", limit: 10)
        XCTAssertEqual(Set(s), ["fooBar", "fooBaz", "fooQux"])
    }
}
```

**Step 2: Implement `BufferWordIndex.swift`**

```swift
import Foundation

actor BufferWordIndex {
    private var wordsByBuffer: [UUID: Set<String>] = [:]
    private var freq: [String: Int] = [:]

    func update(bufferID: UUID, contents: String) {
        let regex = try! NSRegularExpression(pattern: "\\b[\\p{L}_][\\p{L}\\p{N}_]{1,}\\b")
        let range = NSRange(contents.startIndex..., in: contents)
        var newWords: Set<String> = []
        regex.enumerateMatches(in: contents, range: range) { m, _, _ in
            guard let m else { return }
            if let r = Range(m.range, in: contents) {
                newWords.insert(String(contents[r]))
            }
        }
        if let prev = wordsByBuffer[bufferID] {
            for w in prev { freq[w] = (freq[w] ?? 1) - 1; if freq[w] ?? 0 <= 0 { freq.removeValue(forKey: w) } }
        }
        wordsByBuffer[bufferID] = newWords
        for w in newWords { freq[w, default: 0] += 1 }
    }

    func remove(bufferID: UUID) {
        if let prev = wordsByBuffer.removeValue(forKey: bufferID) {
            for w in prev { freq[w] = (freq[w] ?? 1) - 1; if freq[w] ?? 0 <= 0 { freq.removeValue(forKey: w) } }
        }
    }

    func suggestions(prefix: String, limit: Int) -> [String] {
        let lower = prefix.lowercased()
        let candidates = freq.keys.filter { $0.lowercased().hasPrefix(lower) && $0 != prefix }
        return candidates
            .sorted { (freq[$0] ?? 0, $0) > (freq[$1] ?? 0, $1) }
            .prefix(limit)
            .map { $0 }
    }
}
```

**Step 3: Run (expect PASS)**

**Step 4: Add `CompletionPopover.swift`** — minimal `NSPanel` containing an `NSTableView`. Hook into Runestone's `textViewDidChangeSelection` or coordinator's `textDidChange` to compute caret position, fetch prefix, query `BufferWordIndex`, and show/hide.

(This is a 60-100-line component — flesh out during implementation. Plan-level scope: spawn the panel, list 20 suggestions, accept on Tab/Enter, dismiss on Esc or selection change. Keystroke handling via `NSEvent.addLocalMonitorForEvents`.)

**Step 5: Settings toggle**

In `AppSettings`, add `var enableCodeCompletion: Bool = true`. In Settings UI, add toggle "Enable code completion in editor". Localize.

**Step 6: Wire into editor**

`RunestoneTextEditorView.Coordinator.textViewDidChange` debounces 300ms then calls `Task { await BufferWordIndex.shared.update(bufferID:contents:) }`. On caret movement / typing identifier chars with prefix length ≥2 and `appSettings.enableCodeCompletion == true`, present the popover.

**Step 7: Build + manual verify**

Type `priv` in a Swift file → popover shows `private`, `private(set)`, etc. (or whatever's in the buffer). Tab to accept, Esc to dismiss.

**Step 8: Commit**

```bash
git add Treemux/Services/Editor/BufferWordIndex.swift Treemux/UI/FileBrowser/CompletionPopover.swift Treemux/UI/FileBrowser/TextEditorView.swift Treemux/App/AppSettings.swift Treemux/UI/Settings/* Treemux/Localizable.xcstrings TreemuxTests/BufferWordIndexTests.swift
git commit -m "feat: word-based completion popover + Settings toggle"
```

---

## Stage H: Final QA + merge

### Task H1: Manual QA checklist document

**Files:**
- Create: `docs/plans/2026-04-29-filebrowser-p1-qa-checklist.md`

**Step 1: Write the checklist** (mirror `2026-04-28-sidebar-ai-attention-qa-checklist.md`):

- §1 Sidebar folder icon: idle visible, hover bright; appears on Project + Worktree rows for local + remote workspaces
- §2 Remote auth: empty key → password banner → Connect → tree loads; second tab on same workspace skips banner
- §3 Eye icon: hide → show → hide cycle reveals/hides hidden files without manual refresh
- §4 Copy paths: file-tree row right-click → both menu items work; sub-tab right-click → both work; relative path strips `rootPath` prefix
- §5 File-tab regression: file browser tab → terminal tab → back; tree reappears
- §6 Sub-tabs: single click opens preview; another single click replaces; double-click pins; close × works; Cmd+W cascades; drag-reorder works; persists across app restart (only pinned)
- §7 Dirty sheets: single dirty tab close + batch close
- §8 Editor: syntax highlighting on supported languages; plain text on unknown; >2MB plain mode; git diff stripes update on save; word completion popover; Settings toggle disables it

Each item: ✅/❌ + Chinese-locale verification.

**Step 2: Commit**

```bash
git add docs/plans/2026-04-29-filebrowser-p1-qa-checklist.md
git commit -m "docs: manual QA checklist for file-browser P1"
```

---

### Task H2: Full test suite + merge

**Step 1: Run full tests**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux 2>&1 | tail -40
```

Expected: all green.

**Step 2: Manual run-through**

Build the app, do the QA checklist end-to-end on local + Linux remote.

**Step 3: Hand off to user**

Report the worktree path and branch. The user decides when to merge into main (likely via the existing `superpowers:finishing-a-development-branch` flow or a manual `git merge --no-ff`).

---

## Notes for executors

- Every commit must build and pass tests. If a stage's commit breaks the build, fix in a follow-up commit before moving on.
- All new `LocalizedStringKey`s require zh-Hans translation in the SAME commit. CLAUDE.md is strict about this.
- Do not touch unrelated files. Each task's "Files" section is the complete list.
- If you hit an unexpected ambiguity (e.g. Runestone API shape differs from this plan), pause and report — don't paper over with hacks.
- Worktree rule: stay in `.worktrees/feat+filebrowser-p1-fixes-and-subtabs/` for the entire implementation. Don't commit to main directly.
- DerivedData reminder: after each build, instruct the user with the right `DerivedData/Treemux-<编号>` path so they don't open a stale binary (see `feedback_deriveddata_path.md`).
