# File Browser Tab — Design

Date: 2026-04-28
Branch: `feat/file-browser-tab`

## Goal

Add a VSCode-like file browser as a first-class tab type alongside terminal tabs. Users open it from the sidebar (Project row + Worktree row buttons) or with `Cmd+Shift+T`. Inside the tab: a left file tree + right viewer that switches between code editor (Cmd+S to save), image preview, Quick Look fallback, and binary metadata view. Works for both local and remote (SSH/SFTP) workspaces.

## Architecture overview

```
WorkspaceSidebar
  Project Row    → [hover-reveal "open file browser" button]
  Worktree Row   → [hover-reveal "open file browser" button]

WorkspaceDetailView
  TabBar (icon differs: terminal vs folder; title shows file name + dirty dot)
  Tab content (dispatch on WorkspaceTabKind)
    .terminal     → existing TerminalTabContentView (SplitNodeView)
    .fileBrowser  → FileBrowserTabContentView
                      HSplitView
                        FileTreePanel (left ~28%, persisted ratio)
                        FileViewerPanel (right ~72%)
                          one of: TextEditorView | ImagePreviewView |
                                  QuickLookPreviewView | BinaryInfoView |
                                  EmptyState | LargeFileConfirmView
```

## Data model

### Tab kind

```swift
enum WorkspaceTabKind: String, Codable {
    case terminal
    case fileBrowser
}
```

### `WorkspaceTabStateRecord` extension

Add two fields, mutually exclusive based on `kind`:

- `kind: WorkspaceTabKind` (default `.terminal` when decoding legacy data)
- `fileBrowserState: FileBrowserTabState?` (nil for terminal tabs)
- existing `panes/layout/focusedPaneID/zoomedPaneID` are nil for fileBrowser tabs

### File browser state

```swift
struct FileBrowserTabState: Codable {
    var rootPath: String
    var rootKind: FileBrowserRootKind   // .project | .worktree
    var selectedFilePath: String?
    var splitRatio: Double               // default 0.28
    var expandedDirs: [String]           // persisted
    var showsHiddenFiles: Bool           // default false
    // Note: dirty buffer / unsaved content NOT persisted
}
```

### Controllers

```swift
final class FileBrowserTabController: ObservableObject {
    @Published var rootPath: String
    @Published var dataSource: any FileBrowserDataSource
    @Published var tree: [FileNode]
    @Published var selectedFilePath: String?
    @Published var openFile: OpenFileState
    @Published var splitRatio: Double
    @Published var expandedDirs: Set<String>
    @Published var showsHiddenFiles: Bool

    func toggleExpand(_ path: String) async
    func selectFile(_ path: String) async
    func saveCurrentFile() async throws
    func closeRequested(force: Bool) -> CloseDecision
}
```

`OpenFileState` enum:
- `.empty`
- `.loadingMeta(path)` / `.loading(path)` / `.confirmingLargeFile(path, sizeBytes)`
- `.text(path, content, encoding, dirty)`
- `.image(path, NSImage)`
- `.quickLook(path, localFileURL)`
- `.binary(path, FileMetadata)`
- `.error(path, Error)`

### Data source protocol

```swift
protocol FileBrowserDataSource {
    var supportsWrite: Bool { get }
    func listDirectory(_ path: String) async throws -> [FileNode]
    func fileMetadata(_ path: String) async throws -> FileMetadata
    func readFile(_ path: String, maxBytes: Int) async throws -> Data
    func writeFile(_ path: String, data: Data) async throws
    func downloadForQuickLook(_ path: String,
                              progress: @escaping (Double) -> Void) async throws -> URL
}
```

Implementations:
- `LocalFileBrowserDataSource` — wraps `FileManager` on a background queue
- `RemoteFileBrowserDataSource` — wraps existing `SFTPService`

### Workspace integration

`WorkspaceModel.createTab()` splits into:
- `createTerminalTab()` (existing behavior)
- `createFileBrowserTab(rootPath:rootKind:)` (new)

`WorkspaceDetailView` routes by `tab.kind`.

## UI components

### Sidebar buttons (entry 1)

Hover-reveal button on `SidebarNodeRow` trailing edge, matching the existing trailing accessory style.

- Project row: opens with `repositoryPath`, `rootKind = .project`
- Worktree row: opens with worktree path, `rootKind = .worktree`
- Remote workspaces: button visible; click triggers lazy SSH connect (same as terminal tab)

### Keyboard shortcut (entry 2)

- New `ShortcutAction.newFileBrowserTab`, default `Cmd+Shift+T`
- Registered in main menu and command palette as "New File Browser Tab"
- Root path resolution: selected worktree path → else selected project's main path → else no-op

### Tab bar visual

- Terminal tab: `terminal` SF Symbol + existing title
- File browser tab: `folder` SF Symbol + title (root folder name → switches to file name once one is opened) + dirty dot when unsaved
- Remote workspaces: small remote badge prefix matching sidebar styling
- Tab drag/close/reorder/persistence: identical to terminal tabs

### File tree panel

- `NSOutlineView` (consistent with sidebar, predictable performance)
- Lazy children: load on expand
- Default hide dotfiles; toggle in toolbar
- Toolbar: refresh / show-hidden toggle / breadcrumb path
- Right-click menu: Reveal in Finder (local) / Copy Path / Refresh (rename/delete deferred)

### File viewer panel

Dispatched by file classification (extension + byte sniff):

| Type | View | Editable |
|---|---|---|
| Text (≤5MB) | `TextEditorView` (Runestone) | Yes (Cmd+S) |
| Image | `ImagePreviewView` (`NSImage`) | No |
| PDF / video / Office / etc. | `QuickLookPreviewView` | No |
| Binary / unknown | `BinaryInfoView` | No |
| > 5MB | `LargeFileConfirmView` (confirm gate) | — |
| > 100MB | force Quick Look only, never enter editor | — |

`TextEditorView` features:
- Runestone-based (CodeEditor as fallback if integration friction)
- Status bar: relative path / encoding / line:col / dirty dot / line endings / size
- Cmd+F search (Runestone built-in)
- Save: Cmd+S binding scoped to focused editor

## Data flow

### Open tab

```
Entry → WorkspaceModel.createFileBrowserTab(rootPath, rootKind)
  → new WorkspaceTabStateRecord(kind: .fileBrowser, fileBrowserState: ...)
  → activeTabID set
  → WorkspaceDetailView dispatches to FileBrowserTabContentView
  → FileBrowserTabController bootstraps; dataSource = workspace.sshTarget == nil ? Local : Remote
  → controller.tree = try await dataSource.listDirectory(rootPath)
```

### Select file

```
Click node → controller.selectFile(path)
  → fileMetadata(path) (size + mime hint)
  → classify:
      text + small  → readFile → openFile = .text(...)
      image         → readFile → openFile = .image(...)
      large (>5MB)  → openFile = .confirmingLargeFile; user confirms → fall through
      quickLook     → downloadForQuickLook → openFile = .quickLook(localURL)
      binary        → openFile = .binary(metadata)
      error         → openFile = .error(...)
```

### Save

```
Cmd+S in TextEditorView
  → controller.saveCurrentFile()
  → dataSource.writeFile(path, data)
  → success: dirty = false
  → failure: toast; dirty preserved
```

### Dirty check on switch / close

```
Switching files OR closing tab while dirty:
  → sheet: [Save] [Discard] [Cancel]
  → Save    → saveCurrentFile(); on success, proceed
  → Discard → proceed
  → Cancel  → abort
```

## Error handling and edge cases

| Scenario | Behavior |
|---|---|
| Remote SFTP not connected | Lazy connect (existing terminal-tab path); failure toast |
| Large file (>5MB) | Confirm gate; remote shows download progress; >100MB Quick Look only |
| Non-UTF-8 text | Detect → fallback GBK / Latin-1; encoding shown in status bar; save uses current encoding |
| External modification before save | Not detected in P1 (overwrites); P2 may add mtime check |
| Slow remote directory | Per-node loading spinner |
| Workspace deletion with dirty file browser tab | Reuse existing tab-close dirty path |
| `.git` and dotfiles | Hidden by default; toggle reveals (greyed `.git`) |
| Symbolic links | Shown with arrow badge |
| Tab persistence | rootPath / selectedFilePath / splitRatio / expandedDirs / showsHiddenFiles persisted; dirty buffer NOT persisted |
| Legacy `WorkspaceTabStateRecord` decode | Missing `kind` defaults to `.terminal`; missing `fileBrowserState` is nil |

## Testing strategy

### Unit tests (XCTest, in `TreemuxTests/`)

- `WorkspaceTabStateRecordCodingTests` — legacy decode (no `kind`) → `.terminal`
- `FileBrowserTabStateCodingTests` — round-trip
- `LocalFileBrowserDataSourceTests` — temp directory list/read/write
- `FileBrowserTabControllerTests` — `selectFile` state machine, dirty toggle, save success/failure paths (mock dataSource)
- `FileTypeClassifierTests` — extension + sniff coverage
- `WorkspaceModelTabKindTests` — `createFileBrowserTab` path, persistence integration

### Manual checklist

- Local + remote: open tab → browse → edit → save
- Large-file confirm dialog (local + remote)
- Switch / close with dirty changes — three options each
- `Cmd+Shift+T` from different selection states (worktree / project / nothing)
- Legacy schema data loads without crash
- Tab drag / close / reorder mixed terminal + fileBrowser tabs

`RemoteFileBrowserDataSource` is not unit-tested (needs live SFTP); covered manually.

## Out of scope (P1)

- File tree create / rename / delete operations
- LSP / autocompletion / formatter integration
- External-modification detection
- Multi-file editor sub-tabs inside a single file browser tab
- Diff view / git integration

## Open implementation choices

- **Editor library**: Runestone preferred (more featureful, active); CodeEditor fallback if Runestone integration on macOS proves unstable. Decision happens in implementation phase via spike.
- **Local file watch**: Out of P1 (covered by manual refresh button).
- **Sidebar button icon**: TBD — `folder.badge.gearshape` candidate, will validate against design language during implementation.
