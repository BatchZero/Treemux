# Detach Sidebar Node to New Window — Design

- **Date**: 2026-08-12
- **Branch**: `feat+detach-to-new-window`
- **Status**: Approved (brainstorming complete)

## 1. Goal

Allow any sidebar node — a **project (workspace)**, a **single worktree**, or a **remote server group** — to be "torn off" into its own independent app window. Two triggers:

1. **Drag** the node outside the main window / onto the desktop.
2. **Right-click → "Open in New Window"**.

When detached, the node is **hidden from the main window's sidebar**. When the detached child window is closed, the node **automatically reappears** in the main sidebar.

## 2. Confirmed Requirements

| Dimension | Decision |
|---|---|
| Child window content | Shows **only** the detached object (no full sidebar) |
| "Return to main list" semantics | Detached node is **hidden** in main sidebar while child window is open; **restored** when child closes |
| Triggers | (a) Drag outside window/desktop, (b) Right-click "Open in New Window" |
| Detachable node types | `workspace`, single `worktree`, `remoteGroup` section |
| Worktree detach | Only that worktree is hidden in main sidebar; parent workspace stays visible. Child window shows only that worktree's session |
| Window lifecycle | **Main window is root**: closing main window closes all child windows, then quits app. Minimize does NOT cascade |
| Restart restoration | **Restore full child-window layout** (position/size/selected node) after restart. Terminal session restoration follows existing tmux-based behavior |
| Architecture | Single process + multiple `NSWindow` sharing one `WorkspaceStore` (no `WindowGroup`, no multi-process) |

## 3. Architecture: Single Process + Multi-Window

### 3.1 `DetachedNodeRef`

New type (`Domain/DetachedNodeRef.swift`):

```swift
/// Identifies a sidebar node detached into its own window.
enum DetachedNodeRef: Hashable, Codable {
    case workspace(UUID)                                  // whole workspace
    case worktree(workspaceID: UUID, worktreeID: UUID)    // single worktree
    case remoteGroup(String)                              // remoteGroupKey
}
```

### 3.2 `WorkspaceStore` additions

```swift
@Observable final class WorkspaceStore {
    var workspaces: [WorkspaceModel] = []                 // existing
    var detachedNodes: Set<DetachedNodeRef> = []          // NEW (runtime + persisted)

    func isDetached(_ ref: DetachedNodeRef) -> Bool { detachedNodes.contains(ref) }

    // Returns workspaces belonging to a remote group (used by RemoteGroupWindowView).
    // Reuses the existing remoteGroupKey(for:) logic (WorkspaceStore.swift:378).
    func workspacesInRemoteGroup(_ key: String) -> [WorkspaceModel] { ... }
}
```

### 3.3 Main sidebar filtering rules

Applied in `SidebarCoordinator.buildNodes`:

| Node type | Filter rule |
|---|---|
| workspace | skip if `detachedNodes` contains `.workspace(id)` |
| worktree child | skip that child if contains `.worktree(wsID, wtID)` (parent workspace still shows) |
| remote section | skip whole section if contains `.remoteGroup(key)` |

### 3.4 Persistence

`PersistedWorkspaceState` gains:

```swift
struct PersistedWorkspaceState: Codable {
    // existing fields...
    var detachedNodes: Set<DetachedNodeRef>               // NEW
}
```

`detachedNodes` is written to `workspace-state.json` alongside `workspaces`. It is **not** a transient runtime-only field — it must survive restart so child windows can be rebuilt.

## 4. Window Manager

### 4.1 `WindowManager` (replaces `TreemuxApp.windowContext`)

```swift
@MainActor @Observable final class WindowManager {
    private(set) var mainWindowContext: WindowContext?
    private(set) var childContexts: [WindowContext] = []
    var isShuttingDown = false                            // suppresses per-node restore on cascade close

    let store: WorkspaceStore

    func launchMain()                                      // create/show main window
    func detach(_ ref: DetachedNodeRef)                    // hide node + open child window
    func closeChild(_ ctx: WindowContext)                  // child closed: restore node visibility
    func handleMainWindowWillClose()                       // close all children, then quit
    func restoreChildWindows()                             // rebuild from store.detachedNodes on launch
}
```

### 4.2 `WindowContext` changes

```swift
final class WindowContext {
    enum Kind {
        case main
        case detached(DetachedNodeRef)
    }

    let kind: Kind
    let store: WorkspaceStore

    func show()                                            // builds NSWindow with root view per `kind`
    func closeImmediately()                                // no restore side-effects (used during cascade)
}
```

### 4.3 Window frame persistence

- **Main window**: `window.setFrameAutosaveName("treemux.main")`
- **Child windows**: per-ref stable autosave key
  - workspace: `"treemux.detach.workspace.<uuid>"`
  - worktree: `"treemux.detach.worktree.<wsID>.<wtID>"`
  - remoteGroup: `"treemux.detach.remotegroup.<key>"`

`setFrameAutosaveName` is system-managed (stored in user defaults); no manual frame fields in JSON.

### 4.4 Root view dispatch

| `WindowContext.Kind` | Root view | Content |
|---|---|---|
| `.main` | `MainWindowView` | Full `NavigationSplitView`, sidebar filtered by `detachedNodes` |
| `.detached(.workspace(id))` | `SingleWorkspaceWindowView` | `WorkspaceDetailView` for that workspace, no sidebar |
| `.detached(.worktree(wsID, wtID))` | `SingleWorktreeWindowView` | `WorkspaceSessionDetailView` for that worktree, no tab bar |
| `.detached(.remoteGroup(key))` | `RemoteGroupWindowView` | Mini sidebar (SwiftUI `List`) with only that remote section + detail |

### 4.5 `TreemuxApp` changes

```swift
class TreemuxApp {
    let windowManager = WindowManager(store: WorkspaceStore())

    func launch() {
        windowManager.launchMain()
        windowManager.restoreChildWindows()
    }
}
```

### 4.6 `AppDelegate` changes

| Location | Change |
|---|---|
| `applicationShouldTerminateAfterLastWindowClosed` (L52) | Return `false` |
| New | Main window `windowWillClose` → `windowManager.handleMainWindowWillClose()` → `NSApp.terminate(nil)` |
| Window menu (L220-227) | Optional: add standard "Bring All to Front" |

## 5. Drag-to-Detach Detection

### 5.1 Mechanism: `NSDraggingSource.draggingSession(_:endedAt:operation:)`

When a drag ends with `operation == []` (no valid drop target) **and** the release point is outside the `NSOutlineView` frame, treat it as a tear-off:

```swift
extension SidebarCoordinator: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        guard operation == [] else { return }              // valid in-list reorder happened
        let outlineScreenFrame = outlineView.window?.convertToScreen(
            outlineView.convert(outlineView.bounds, to: nil)
        ) ?? .zero
        guard !outlineScreenFrame.contains(screenPoint) else { return }
        guard let ref = decodeDetachedRef(from: session.draggingPasteboard) else { return }
        onDetachNode?(ref)                                  // callback into WindowManager
    }
}
```

### 5.2 Pasteboard encoding

New internal pasteboard type `com.treemux.detach.ref` carries a codable `DetachedNodeRef`. `pasteboardWriterForItem` writes **both** the existing reorder payload (`com.treemux.workspace.ids` / `com.treemux.remote-group.key`) **and** the new detach payload, so in-list reordering keeps working.

### 5.3 Worktree becomes draggable

Currently `pasteboardWriterForItem` returns `nil` for worktree nodes. Change: worktree writes a `DetachPasteboardItem(ref: .worktree(...))`. In-list reorder for worktrees stays disabled (`validateDrop` returns `[]` for worktree drop targets), so dragging a worktree out always reaches `operation == []` → triggers detach.

### 5.4 Conflict avoidance

- Drag to valid in-list target → `operation != []` → `draggingEnded` does not detach.
- Drag outside **the outline view's frame** (including dropping onto the detail area, the toolbar, the desktop, or another screen) → `operation == []` + outside frame → detach.
- The two paths are mutually exclusive.

> "Outside" is defined relative to the `NSOutlineView` bounds, not the app window. A drop on the main window's detail pane or toolbar still counts as outside and triggers detach, because the sidebar list itself is no longer the target.

### 5.5 `SidebarCoordinator` injection

Add `var onDetachNode: ((DetachedNodeRef) -> Void)?` to `SidebarCoordinator` (matches existing `requestRename` / `requestDelete` closure style). Wired in `WorkspaceSidebarView` (or its parent) to `windowManager.detach(_:)`. Avoids holding a strong reference to `WindowManager`.

## 6. Right-Click "Open in New Window"

### 6.1 Menu placement

In `workspaceContextMenuItems(for:)` (`SidebarCoordinator.swift:372`), insert after "Change Icon…", before "Rename…":

- Title: `String(localized: "Open in New Window")`
- Action: `@objc openInNewWindow(_:)`
- Disabled (with different title) when node already detached.

### 6.2 Per-node-type availability

| Node type | Shows "Open in New Window"? | Action |
|---|---|---|
| workspace (`.repository` / `.localTerminal`, incl. built-in `~`) | Yes | `detach(.workspace(id))` |
| worktree | Yes | `detach(.worktree(wsID, wtID))` |
| remote section header | Yes (new — section currently returns `nil` menu) | `detach(.remoteGroup(key))` |
| local section header | No | — |

### 6.3 Already-detached state

If `store.isDetached(ref)` is true:
- Disable the menu item.
- Change title to `String(localized: "Already in New Window")` (zh-Hans: "已在独立窗口中打开").

### 6.4 i18n

Add to `Localizable.xcstrings`:

| English | zh-Hans |
|---|---|
| "Open in New Window" | "在新窗口中打开" |
| "Already in New Window" | "已在独立窗口中打开" |

## 7. Child Window Root Views

### 7.1 `SingleWorkspaceWindowView`

```swift
struct SingleWorkspaceWindowView: View {
    let workspace: WorkspaceModel
    var body: some View {
        WorkspaceDetailView()
            .environment(workspace)             // injected directly
    }
}
```

Requires minor change to `WorkspaceDetailView`: prefer `@Environment(WorkspaceModel.self)` when present, fall back to `store.selectedWorkspace`. This lets the detail view work both in the main window (selection-driven) and in a child window (injection-driven).

### 7.2 `SingleWorktreeWindowView`

```swift
struct SingleWorktreeWindowView: View {
    let workspace: WorkspaceModel
    let worktree: WorktreeModel
    var body: some View {
        WorkspaceSessionDetailView()
            .environment(workspace)
            .onAppear { workspace.switchToWorktree(path: worktree.path) }
    }
}
```

No tab bar — focused single-session view.

### 7.3 `RemoteGroupWindowView`

```swift
struct RemoteGroupWindowView: View {
    let groupKey: String
    @Environment(WorkspaceStore.self) private var store
    @State private var localSelection: UUID?             // does not pollute main store selection

    var body: some View {
        NavigationSplitView {
            List(store.workspacesInRemoteGroup(groupKey)) { ws in
                SidebarNodeRow(node: .init(kind: .workspace(ws)))
                    .onTapGesture { localSelection = ws.id }
            }
        } detail: {
            if let ws = store.workspace(id: localSelection) {
                WorkspaceDetailView().environment(ws)
            }
        }
    }
}
```

Uses SwiftUI `List` (not `NSOutlineView`) — only one flat section, no need for AppKit outline machinery.

## 8. Lifecycle & Restoration

### 8.1 Close cascade (main is root)

```swift
func handleMainWindowWillClose() {
    isShuttingDown = true                              // suppress per-node restore
    for ctx in childContexts { ctx.closeImmediately() }
    childContexts.removeAll()
    NSApp.terminate(nil)
}

func closeChild(_ ctx: WindowContext) {
    if !isShuttingDown, case .detached(let ref) = ctx.kind {
        store.detachedNodes.remove(ref)                // restore main sidebar visibility
    }
    childContexts.removeAll { $0 === ctx }
}
```

`isShuttingDown` prevents the main sidebar from briefly flashing all hidden nodes back in before termination.

### 8.2 Restart restoration

```swift
func restoreChildWindows() {
    for ref in store.detachedNodes {
        guard isValid(ref) else {
            store.detachedNodes.remove(ref)            // stale data, clean up
            continue
        }
        let ctx = WindowContext(store: store, kind: .detached(ref))
        childContexts.append(ctx)
        ctx.show()                                     // setFrameAutosaveName restores frame
    }
}
```

### 8.3 `ref` validity checks

- `.workspace(id)`: `store.workspaces` still contains `id`.
- `.worktree(wsID, wtID)`: workspace exists and `wtID` still in `ws.worktrees`.
- `.remoteGroup(key)`: at least one workspace still has this `remoteGroupKey`.

Stale refs are dropped and removed from persistence on next save.

### 8.4 Persistence triggers

- `detach(ref)` → `insert` → debounced save (existing `DebouncedSaver`).
- `closeChild` → `remove` → debounced save.
- App exit → `TreemuxApp.shutdown()` synchronous flush (existing).

## 9. Out of Scope

- System-level `NSWindowRestoration` protocol (we use `setFrameAutosaveName` instead).
- Drag worktree **between** workspaces (only tear-off, no cross-workspace reparenting).
- Tearing off the **local section header** (not detachable — only remote section headers are).
- Changing the existing in-list reorder behavior (preserved as-is).
- Per-child-window independent theme/locale (child windows inherit the global `ThemeManager` / `LanguageManager`).

## 10. Files Touched (Summary)

| File | Change |
|---|---|
| `Domain/DetachedNodeRef.swift` | NEW — enum type |
| `Domain/WorkspaceModels.swift` | Add `detachedNodes` to `PersistedWorkspaceState`; `WorkspaceStore` validity helpers |
| `App/WorkspaceStore.swift` | `detachedNodes` field + `isDetached` + `workspacesInRemoteGroup` |
| `App/WindowManager.swift` | NEW — multi-window coordinator |
| `App/WindowContext.swift` | `Kind` enum, root-view dispatch, `setFrameAutosaveName` |
| `App/TreemuxApp.swift` | Replace `windowContext` with `windowManager`; `restoreChildWindows` |
| `AppDelegate.swift` | `applicationShouldTerminateAfterLastWindowClosed = false`; main-window close cascade |
| `UI/Sidebar/SidebarCoordinator.swift` | `NSDraggingSource` impl, worktree pasteboard writer, context menu item, `onDetachNode` closure |
| `UI/Sidebar/WorkspaceSidebarView.swift` | Wire `onDetachNode` to `windowManager.detach` |
| `UI/Detached/SingleWorkspaceWindowView.swift` | NEW |
| `UI/Detached/SingleWorktreeWindowView.swift` | NEW |
| `UI/Detached/RemoteGroupWindowView.swift` | NEW |
| `UI/Workspace/WorkspaceDetailView.swift` | Prefer injected `@Environment(WorkspaceModel.self)` |
| `Localizable.xcstrings` | "Open in New Window" / "Already in New Window" (zh-Hans) |
| `TreemuxTests/SidebarContextMenuTests.swift` | Cover new menu item + detach state |
