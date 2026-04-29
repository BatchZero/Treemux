# File Browser P1 — Bug Fixes + Sub-Tabs + Editor Upgrade — Design

Date: 2026-04-29
Branch: `feat/filebrowser-p1-fixes-and-subtabs` (worktree: `.worktrees/feat+filebrowser-p1-fixes-and-subtabs/`)

## Goal

Fix three regressions in the existing file-browser tab and remote workflow,
add a missing copy-path interaction, then build a VSCode-style sub-tab
system inside each file-browser tab and upgrade the editor with syntax
highlighting, git-diff visualization, and word-based completion.

Six product asks, in source order:

1. Sidebar folder-icon button is hover-only — should be always visible.
2. Opening a file-browser tab on a remote project shows an empty file
   tree (no error feedback).
3. Toggling the eye icon (show hidden files) does not refresh; only
   the explicit refresh button does.
4. Right-click on file-tree rows must offer "Copy Absolute Path" /
   "Copy Relative Path".
5. Switching from a file-browser tab to another tab and back turns the
   file-browser tab into a terminal tab (data corruption).
6. A file-browser tab should host VSCode-style sub-tabs: single-click
   in tree opens a preview sub-tab (replaceable); double-click pins.

Plus an editor scope expansion the user added during brainstorming:
syntax highlighting, git diff (gutter + tree badges), and basic word
completion. Realistic P1 scope was negotiated to **Tier 1 + Tier 2 +
Tier 3a**; LSP is deferred to P2.

## Architecture overview

```
WorkspaceModel
  sessionController getter        → tab.kind == .terminal guard (FIX #5)
  controller(forTabID:)            → same guard (defense in depth)
  saveActiveTabState               → same guard + explicit kind/fileBrowserState
  sharedSFTPService                → NEW: lazy authenticated client (#2 Tier-2)

WorkspaceDetailView
  Tab content dispatch by tab.kind (unchanged)

FileBrowserTabContentView (HSplitView)
  FileTreePanelView (left)
    NodeRow
      .contextMenu { Copy Absolute / Copy Relative Path }   ← NEW (#4)
      git status badge prefix                               ← NEW (#5.4)
    FileTreeToolbar (path / refresh / show-hidden)
  FileViewerColumn (right)
    FileSubTabBarView                                       ← NEW (#6)
      sub-tab buttons (preview vs pinned visual)
      drag-reorder, × close, .contextMenu (copy paths)
    Divider
    FileViewerSwitch
      RunestoneTextEditorView                               ← REPLACES NSTextView (#5)
        gutter: line numbers + git diff +/~/− stripes
        completion popover (Tier 3a)
```

Three persistence-layer changes:

```
FileBrowserTabState
  - selectedFilePath   (REMOVED)
  + subTabs: [FileSubTabRecord]    (only isPinned == true persisted)
  + activeSubTabID: UUID?

FileSubTabRecord                                            ← NEW
  id: UUID, path: String, isPinned: Bool

WorkspaceTabStateRecord
  // saveActiveTabState now passes kind + fileBrowserState explicitly
```

## § 1 — Bug fixes

### 1.1 Sidebar folder icon (issue #1)

`Treemux/UI/Sidebar/SidebarNodeRow.swift:91, 154` — replace
`if isHovered { Button { … } }` with unconditional `Button { … }`.
Visual quietness via `theme.textSecondary.opacity(0.5)` at idle,
restoring full opacity on hover. Applies to both `WorkspaceRowContent`
and `WorktreeRowContent`.

### 1.2 Eye-icon toggle refresh (issue #3)

`FileBrowserTabController.swift` currently caches filtered children in
`childrenByPath`. Toggling `showsHiddenFiles` re-filters the cached
data, but cached data is already filtered, so hidden→visible transition
loses the hidden entries forever.

Fix: split the cache.

```swift
private var rawChildrenByPath: [String: [FileNode]] = [:]   // unfiltered
@Published private(set) var childrenByPath: [String: [FileNode]] = [:]  // derived

func setShowsHiddenFiles(_ show: Bool) {
    guard showsHiddenFiles != show else { return }
    showsHiddenFiles = show
    childrenByPath = rawChildrenByPath.mapValues(filtered)
    rootChildren = childrenByPath[rootPath] ?? []
    onPersistableStateChanged?()
}
```

`loadRoot` / `toggleExpand` / `refresh` write into `rawChildrenByPath`
first, then derive `childrenByPath`.

### 1.3 File-tab → terminal-tab regression (issue #5)

Three-step root cause:

1. `AIHookBannerController.evaluate` runs on every `objectWillChange`
   and calls `workspace.sessionController` (line 118).
2. `sessionController` getter delegates to
   `controller(forTabID:worktreePath:)` which **lazily creates** a
   `WorkspaceSessionController` for any `activeTabID`, including a
   file-browser tab id, and stores it in
   `tabControllers[worktreePath][fileBrowserTabID]`.
3. Next `saveActiveTabState()` finds that phantom controller, passes
   the `tabControllers[…]?[tabID]` guard, then writes
   `tabs[index] = WorkspaceTabStateRecord(…)` **without `kind` or
   `fileBrowserState`**. The default initializer makes `kind = .terminal`,
   so the tab record is rewritten as a terminal tab.

Fix in three places (defense in depth):

- `WorkspaceModels.swift` `sessionController` getter — guard:
  `guard let tab = tabs.first(where: { $0.id == tabID }), tab.kind == .terminal else { return nil }`
- `controller(forTabID:worktreePath:)` private factory — same guard,
  return-or-fatalError; document that callers must check kind first
- `saveActiveTabState` — same guard at the top, AND pass `kind` and
  `fileBrowserState` explicitly to the new `WorkspaceTabStateRecord`

## § 2 — Remote opens empty (issue #2)

### Root cause

`RemoteFileBrowserDataSource.ensureConnected()` only calls
`service.connect(target:)` (system-SSH key auth). When the remote needs
password auth, that throws `SFTPServiceError.authenticationFailed`,
which `FileBrowserTabController.loadRoot()` silently catches with
`self.rootChildren = []`. UI shows an empty tree with no feedback.

Compounding factor: each `RemoteFileBrowserDataSource` instantiates its
own `SFTPService()`, so the authenticated session from a sibling tab
isn't reused — every new file-browser tab re-authenticates from scratch.

### Fix — Tier 1 (mandatory): surface errors and add password fallback

`FileBrowserTabController` adds:

```swift
@Published private(set) var loadError: LoadError?

enum LoadError {
    case generic(String)
    case needsPassword(host: String)
}
```

Calls in `loadRoot` / `toggleExpand` / `refresh` set `loadError`
instead of silently emptying the tree. On
`SFTPServiceError.authenticationFailed`, set `.needsPassword(host:)`.

`FileTreePanelView` renders a banner above the tree when
`loadError != nil`:

- `.generic(msg)` → red banner with message + Retry button
- `.needsPassword(host)` → banner with `SecureField` for password +
  Connect button → calls `controller.retryWithPassword(_:)` which
  routes through `RemoteFileBrowserDataSource.connectWithPassword`

`RemoteFileBrowserDataSource` exposes a new
`func connectWithPassword(_ password: String) async throws` that mirrors
`RemoteDirectoryBrowserViewModel.connectWithPassword`.

### Fix — Tier 2 (strongly recommended): shared SFTP service

`WorkspaceModel` exposes a lazy shared SFTP client:

```swift
@MainActor
final class WorkspaceModel: ObservableObject, Identifiable {
    private(set) var sharedSFTPService: SFTPService?
    func ensureSharedSFTPService() -> SFTPService {
        if let s = sharedSFTPService { return s }
        let s = SFTPService()
        sharedSFTPService = s
        return s
    }
}
```

`WorkspaceModel.makeDataSource()` passes
`ensureSharedSFTPService()` into `RemoteFileBrowserDataSource`. Result:
within a workspace, only the **first** remote file-browser tab triggers
the password prompt; later tabs reuse the authenticated client.

Note: the terminal session uses ghostty's own SSH path, so this share
covers SFTP/git-diff side only. That's fine for P1.

## § 3 — Copy path context menu (issue #4)

Scope: file-tree rows + sub-tab titles only. Sidebar Project/Worktree
copy-path is deferred and folded into the future P1 "Project right-click
menu" item (already in memory).

### Helper

`FileBrowserTabController` adds:

```swift
enum CopyPathMode { case absolute, relative }

func copyPath(_ path: String, mode: CopyPathMode) {
    let value: String = (mode == .absolute) ? path : relativePath(path)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}

private func relativePath(_ path: String) -> String {
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
}
```

### UI injection points

1. `FileTreePanelView.NodeRow.row` — `.contextMenu { … }`:
   - "Copy Absolute Path"
   - "Copy Relative Path" (disabled when row equals `rootPath`)
2. `FileSubTabBarView` sub-tab Button — same `.contextMenu`, plus
   sub-tab-specific items (Pin, Close, Close Others, Close All).

### Localization

`Localizable.xcstrings` adds:

| Key | en | zh-Hans |
|---|---|---|
| Copy Absolute Path | Copy Absolute Path | 复制绝对路径 |
| Copy Relative Path | Copy Relative Path | 复制相对路径 |

## § 4 — VSCode-style sub-tabs (issue #6)

### 4.1 Data model

```swift
struct FileSubTabRecord: Codable, Identifiable {
    var id: UUID
    var path: String
    var isPinned: Bool
}

struct FileBrowserTabState: Codable {
    var rootPath: String
    var rootKind: FileBrowserRootKind
    var splitRatio: Double
    var expandedDirs: [String]
    var showsHiddenFiles: Bool
    var subTabs: [FileSubTabRecord]   // only isPinned == true persisted
    var activeSubTabID: UUID?
    // selectedFilePath REMOVED; legacy decode migrates
}
```

Codable migration: if decoded JSON lacks `subTabs` but contains
`selectedFilePath`, synthesize
`[FileSubTabRecord(id: UUID(), path: selectedFilePath, isPinned: true)]`
and set `activeSubTabID` to that id.

### 4.2 Controller refactor

`FileBrowserTabController` replaces the single `openFile` with a
collection of runtime sub-tabs:

```swift
struct SubTabRuntime: Identifiable {
    let id: UUID
    var path: String
    var isPinned: Bool
    var openFile: OpenFileState   // each sub-tab has its own buffer
}

@Published private(set) var subTabs: [SubTabRuntime] = []
@Published private(set) var activeSubTabID: UUID?

var activeSubTab: SubTabRuntime? {
    subTabs.first(where: { $0.id == activeSubTabID })
}
```

`isDirty` / `saveCurrentFile` / `updateBuffer` / `selectFile` mutate the
active sub-tab. Existing public surface is preserved where possible.

### 4.3 Interaction logic

**Single click on file `X` in tree** (`controller.openInTree(_:)`):

```
if let existing = subTabs.first(where: { $0.isPinned && $0.path == X }) {
    activeSubTabID = existing.id          // focus, no replace
    return
}
if let preview = subTabs.first(where: { !$0.isPinned }) {
    preview.path = X
    activeSubTabID = preview.id
    await loadFile(into: preview)
} else {
    let new = SubTabRuntime(id: UUID(), path: X, isPinned: false, openFile: .empty)
    subTabs.append(new)
    activeSubTabID = new.id
    await loadFile(into: new)
}
```

**Double click** (in tree, or on preview sub-tab title):
- If a sub-tab already has `path == X`, set `isPinned = true` in place.
- Else: open + pin in one step.

Invariant: at most one preview sub-tab; pinning the preview tab
discards no state, just flips the flag.

**Close sub-tab** (× button, Cmd+W on active, or context-menu Close):

```
if subTab.isDirty {
    showSingleFileDirtySheet(subTab) → save / discard / cancel
}
remove subTab from subTabs
if activeSubTabID == subTab.id {
    activeSubTabID = neighborToTheRight ?? neighborToTheLeft
}
```

When `subTabs.isEmpty`, do **not** auto-close the parent file-browser
tab — show empty state ("Select a file from the tree"). User must close
the parent tab explicitly.

**Cmd+W cascade**:

`AppDelegate` Cmd+W menu action routes to a new
`WorkspaceModel.handleCloseShortcut()` that:

1. If active tab is a file-browser tab with at least one sub-tab → close
   the active sub-tab.
2. Else → existing `requestCloseTab(activeTabID)` path.

**Drag-reorder sub-tabs**: new `FileSubTabDropDelegate` mirroring the
existing `TabDropDelegate`. Updates `controller.subTabs` order, fires
`onPersistableStateChanged`. Only `isPinned == true` order is persisted.

### 4.4 UI

New file: `Treemux/UI/FileBrowser/FileSubTabBarView.swift`. Per sub-tab
button:

| Element | Visual |
|---|---|
| File-type icon | reused from `iconName(for:)` in `FileTreePanelView` |
| File name | preview = italic + secondary; pinned = regular + primary |
| Dirty dot | accent-color circle when buffer dirty |
| Close × | hover-revealed |
| Active highlight | bottom 3pt accent stripe (mirrors outer tab bar) |

Context menu: Copy Absolute Path / Copy Relative Path / divider /
Pin Tab (when preview) / Close / Close Other Tabs / Close All Tabs.

`FileViewerPanelView` becomes:

```swift
VStack(spacing: 0) {
    if !controller.subTabs.isEmpty {
        FileSubTabBarView(controller: controller)
        Divider()
    }
    FileViewerSwitch(state: controller.activeSubTab?.openFile ?? .empty,
                     controller: controller)
}
```

### 4.5 Dirty handling

| Scenario | Behavior |
|---|---|
| Switch sub-tabs (any direction) | Never prompts; buffer kept in memory |
| Close single dirty sub-tab | NSAlert: "<filename> has unsaved changes" / Save · Don't Save · Cancel |
| Close parent file-browser tab with ≥1 dirty sub-tab | SwiftUI sheet `BatchUnsavedChangesSheet`: lists relative paths of all dirty files / Save All · Don't Save · Cancel |
| Quit app with dirty buffers | Reuses existing app-quit path; batch sheet path can be reused |

### 4.6 Persistence

`onPersistableStateChanged` debounce (existing) writes back to
`fileBrowserState`:

- `subTabs`: filter to `isPinned == true`, preserve order
- `activeSubTabID`: if it points to a preview sub-tab, fall back to the
  most-recently-active pinned sub-tab; else nil
- Dirty buffers: never persisted (consistent with original design)

## § 5 — Editor upgrade (Tier 1 + 2 + 3a)

### 5.1 Library decision: Runestone

`project.yml` `packages:` adds:

```yaml
Runestone:
  url: https://github.com/simonbs/Runestone
  from: "0.4.4"
TreeSitterLanguages:
  url: https://github.com/simonbs/TreeSitterLanguages
  from: "0.1.7"
```

`TextEditorView.swift` replaces `NSTextView + LineNumberRulerView` with
a `RunestoneTextView` `NSViewRepresentable`. Public init signature
stays the same. `LineNumberRulerView.swift` is deleted.

### 5.2 Tier 1 — syntax highlighting + editor basics

Languages in first cut: Swift, JavaScript, TypeScript, TSX, Python, Go,
Rust, JSON, YAML, Markdown, HTML, CSS, Bash.

`FileTypeClassifier` adds
`func languageMode(for path: String) -> TreeSitterLanguageMode?` —
extension-first, falls back to shebang sniff for unknown extensions.

Theme via `ThemeManager` → derived `RunestoneTheme` (separate light /
dark palettes). Hooked into existing app-theme change publisher.

Enabled features (Runestone config):
- Bracket / quote auto-pair
- Per-language indent rules
- Find / replace via Cmd+F (Runestone built-in)
- Cmd+/ comment toggle (Runestone built-in)

Performance guard: files over 2 MB are opened in plain-text mode (no
tree-sitter parse) to keep the editor responsive. Files over 5 MB
continue to hit the existing large-file confirmation gate.

### 5.3 Tier 2 — git diff visualization

New `Treemux/Services/Git/GitDiffService.swift`:

```swift
protocol GitDiffService {
    func diffHunks(forFile path: String, repoRoot: String) async throws -> [DiffHunk]
    func fileStatus(in repoRoot: String) async throws -> [String: FileStatus]
}

struct DiffHunk {
    var oldRange: Range<Int>      // line numbers
    var newRange: Range<Int>
    var kind: Kind                 // .added / .modified / .removed
}

enum FileStatus { case untracked, modified, added, deleted, renamed(from: String) }
```

Two implementations:

- `LocalGitDiffService`: `Process` running `git diff --no-color HEAD --
  <path>` and `git status --porcelain` from `repoRoot`. Parser handles
  `@@ -a,b +c,d @@` hunk headers.
- `RemoteGitDiffService`: same commands via the shared
  `SFTPService.runSSH` (uses the workspace's `sharedSFTPService`).

Editor gutter integration: Runestone exposes
`gutterTrailingPadding` + a custom drawing hook (`gutterDidDraw`).
Draw 2pt-wide colored stripes (green / yellow / red) on the lines that
fall within hunks for the current file's `diffHunksByPath` cache.

File-tree badges: extend `FileNode` with a non-persisted
`var gitStatus: FileStatus?`. `FileTreePanelView.NodeRow` renders a
4×4 dot before the icon when status is non-nil. Color map:
M=orange, A=green, U=gray, D=red.

Refresh policy:
- Initial load on tab open
- After `saveCurrentFile` succeeds (just that file)
- The existing toolbar Refresh button also re-pulls full status
- No FSEvents / inotify listener (deferred to P2)

### 5.4 Tier 3a — word-based completion

New `Treemux/Services/Editor/BufferWordIndex.swift`:

```swift
actor BufferWordIndex {
    private var wordsByBufferID: [UUID: Set<String>] = [:]
    private var freqByWord: [String: Int] = [:]
    func update(bufferID: UUID, contents: String)   // debounced 300 ms by caller
    func remove(bufferID: UUID)
    func suggestions(prefix: String, limit: Int) -> [String]
}
```

Word regex: `\b[\p{L}_][\p{L}\p{N}_]{1,}\b` (excludes pure numbers,
single-char identifiers).

Completion popover `Treemux/UI/FileBrowser/CompletionPopover.swift`:
- `NSPanel`, no titlebar, anchored to caret
- ↑↓ select, Tab/Enter accept, Esc dismiss
- Triggers when `prefix.length >= 2` after typing identifier chars
- Hidden when caret moves outside the prefix or buffer focus changes

Settings entry: existing `Settings` panel adds toggle "Enable code
completion in editor" (default on). Stored in `AppSettings`. When
disabled, popover never opens.

### 5.5 Risks and rollbacks

| Risk | Mitigation |
|---|---|
| Runestone perf on large files | 2 MB hard cap to plain-text mode; 5 MB confirm gate (already exists) |
| Remote `git status` slow on large repos | Async load; absent badges until ready; never blocks tree expansion |
| Completion popover annoying | Settings toggle; opt-out preserves current bare-editor behavior |
| TreeSitterLanguages bundle size | Acceptable (~5 MB); revisit if app size becomes a concern |

## § 6 — Implementation order, file map, out of scope

### 6.1 Branch / worktree

- Worktree: `.worktrees/feat+filebrowser-p1-fixes-and-subtabs/`
- Branch: `feat/filebrowser-p1-fixes-and-subtabs`

### 6.2 Stages (each an independent commit)

| Stage | Scope | Verification |
|---|---|---|
| A | §1 three bug fixes | Per-bug unit tests + manual reproduce |
| B | §2 Tier-1 + Tier-2 remote auth & error surfacing | Manual on Linux remote: blank tree → password → file list |
| C | §3 copy-path context menus | Unit + manual |
| D | §4.1–4.3 sub-tab data model + controller | Codable migration test |
| E | §4.4 sub-tab UI + interactions | Manual + unit (state machine) |
| F | §4.5 dirty sheets (single + batch) | Manual |
| G | §5 editor upgrade (sub-stages G1=Runestone, G2=highlight, G3=git diff, G4=completion) | Per-substage unit + manual |

Stages A–C are deliverable on their own as a "fixes and copy-path"
release; D–G are the sub-tab feature.

### 6.3 New files

- `Treemux/Domain/FileSubTabRecord.swift`
- `Treemux/Services/Git/GitDiffService.swift`
- `Treemux/Services/Git/LocalGitDiffService.swift`
- `Treemux/Services/Git/RemoteGitDiffService.swift`
- `Treemux/Services/Editor/BufferWordIndex.swift`
- `Treemux/UI/FileBrowser/FileSubTabBarView.swift`
- `Treemux/UI/FileBrowser/CompletionPopover.swift`
- `Treemux/UI/FileBrowser/BatchUnsavedChangesSheet.swift`
- `TreemuxTests/FileSubTabRecordCodingTests.swift`
- `TreemuxTests/FileBrowserTabControllerSubTabTests.swift`
- `TreemuxTests/GitDiffServiceTests.swift`
- `TreemuxTests/BufferWordIndexTests.swift`
- `TreemuxTests/FileBrowserTabControllerCopyPathTests.swift`

### 6.4 Modified files

- `Treemux/Domain/WorkspaceModels.swift` — §1.3 guards, §2 shared SFTP, §4 Codable migration
- `Treemux/UI/Sidebar/SidebarNodeRow.swift` — §1.1
- `Treemux/UI/FileBrowser/FileBrowserTabController.swift` — §1.2, §2 errors, §3 copyPath, §4 sub-tab state
- `Treemux/UI/FileBrowser/FileTreePanelView.swift` — §3 contextMenu, §5.4 git badges
- `Treemux/UI/FileBrowser/FileViewerPanelView.swift` — §4 sub-tab bar wiring
- `Treemux/UI/FileBrowser/TextEditorView.swift` — §5 Runestone replacement
- `Treemux/UI/FileBrowser/LineNumberRulerView.swift` — DELETED (§5)
- `Treemux/UI/FileBrowser/OpenFileState.swift` — minor (sub-tab embedding)
- `Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift` — §2 password fallback, accept external SFTPService
- `Treemux/AppDelegate.swift` — Cmd+W routes through `handleCloseShortcut`
- `Treemux/Localizable.xcstrings` — all new keys (§3, §4, §5 settings, §2 banners)
- `project.yml` — Runestone + TreeSitterLanguages packages

### 6.5 Localization keys (zh-Hans must accompany every addition)

| Key | en | zh-Hans |
|---|---|---|
| Copy Absolute Path | Copy Absolute Path | 复制绝对路径 |
| Copy Relative Path | Copy Relative Path | 复制相对路径 |
| Pin Tab | Pin Tab | 固定标签页 |
| Close Tab | Close Tab | 关闭标签页 |
| Close Other Tabs | Close Other Tabs | 关闭其他标签页 |
| Close All Tabs | Close All Tabs | 关闭所有标签页 |
| %@ has unsaved changes. | %@ has unsaved changes. | "%@" 存在未保存的修改。 |
| Save | Save | 保存 |
| Don't Save | Don't Save | 不保存 |
| Cancel | Cancel | 取消 |
| Save All | Save All | 全部保存 |
| %lld files have unsaved changes: | %lld files have unsaved changes: | %lld 个文件有未保存的修改： |
| Cannot connect to %@ | Cannot connect to %@ | 无法连接到 %@ |
| Retry | Retry | 重试 |
| Enter Password | Enter Password | 输入密码 |
| Connect | Connect | 连接 |
| Enable code completion in editor | Enable code completion in editor | 启用编辑器代码补全 |
| Select a file from the tree | Select a file from the tree | 从左侧选择一个文件 |

(Existing keys like "Toggle Hidden Files", "Refresh", "Open File
Browser", "New File Browser Tab", "Save changes before closing?", etc.
are reused unchanged.)

### 6.6 Out of scope (explicit non-goals)

- File-tree create / rename / delete (already deferred in
  `2026-04-28-file-browser-tab-design.md`)
- Side-by-side diff view in editor (gutter + tree badges only this round)
- Real LSP — local or remote (deferred to P2)
- File-system / git-status real-time watching (FSEvents, inotify)
- Sidebar Project / Worktree right-click copy-path (folded into the
  future P1 "Project right-click menu" item)
- External-modification-on-disk detection during edit (still no mtime
  check at save; keeps the original P1 contract)

### 6.7 Testing strategy

XCTest in `TreemuxTests/`:

- `FileSubTabRecordCodingTests` — round-trip + legacy migration
- `FileBrowserTabControllerSubTabTests` — open/replace/pin/close-active/cascade
- `FileBrowserTabControllerCopyPathTests` — abs / rel correctness
- `GitDiffServiceTests` — sample-output parser (LocalGitDiffService only)
- `BufferWordIndexTests` — extraction, multi-buffer ranking
- Existing `FileBrowserTabStateCodingTests` extended for `subTabs`

Manual QA checklist saved to
`docs/plans/2026-04-29-filebrowser-p1-qa-checklist.md` before merge,
mirroring the `2026-04-28-sidebar-ai-attention-qa-checklist.md` format.

`RemoteFileBrowserDataSource` and `RemoteGitDiffService` keep the
existing manual-only stance (no live SFTP unit tests).

## Open implementation choices (decided during execution)

- **Codable migration test fixture**: include an actual JSON sample of
  a pre-`subTabs` `FileBrowserTabState` to lock down the migration path.
- **Runestone version**: pin to a specific minor release once a spike
  validates macOS 15 + tree-sitter behavior.
- **Completion popover styling**: match terminal autocomplete look if
  one exists; otherwise default `NSPanel` chrome.
- **Git status refresh granularity after save**: file-only initially;
  full refresh only on toolbar button click.
