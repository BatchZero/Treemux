# File Browser Core — Design (Batch A)

**Date:** 2026-07-13
**Author:** 卡皮巴拉 (via brainstorming with Claude)
**Status:** Design approved; pending implementation plan

## Context

This is **Batch A** of a larger multi-feature effort. The full request spanned 12 independent
features across 6 subsystems; they were decomposed into batches (A–H), each with its own
spec → plan → implementation cycle. Batch A covers the three features that share the
file-browser core and unblock later batches (transfer, preview-tab lifecycle):

- **Feature 2 — File-tree search**
- **Feature 8 — New folder / new file**
- **Feature 10 — Symlink-directory reading**

Sole user is the project maintainer. The app is commercially distributed (DMG/Sparkle) and
supports both **local** and **remote (SFTP/SSH)** workspaces through the
`FileBrowserDataSource` protocol. Remote round-trips are expensive — a first-class constraint
for every design below.

## Goal

Make the file tree usable for real work: find files without scrolling, create files/folders
in place, and stop treating symlinked directories as dead ends — across both local and remote
data sources.

## Non-Goals

- No content search (grep inside files). Search is **filename/path only**.
- No rename or delete in this batch (context-menu real estate is prepared, but the actions are
  out of scope here).
- No new remote transport; reuse the existing `SFTPService` (system SSH + Citadel fallback).
- No change to the lazy-load tree architecture or the scroll-restoration machinery in
  `FileTreePanelView`.

## Affected code

- `Treemux/Domain/FileNode.swift` — node model (`Kind`, `isDirectory`).
- `Treemux/Services/FileBrowser/FileBrowserDataSource.swift` — protocol (add create + symlink-target-type).
- `Treemux/Services/FileBrowser/{Local,Remote}FileBrowserDataSource.swift` — implementations.
- `Treemux/Services/FileBrowser/DirectoryTreeFetch.swift` — `BFSTreeLister` (symlink recursion guard).
- `Treemux/Services/SFTP/SFTPService.swift` — remote `find`, `mkdir`, touch, symlink target stat.
- `Treemux/UI/FileBrowser/FileBrowserTabController.swift` — search state, create flow, expand-through-symlink.
- `Treemux/UI/FileBrowser/FileTreePanelView.swift` — toolbar search field, inline-edit row, context menu.
- `Treemux/UI/FileBrowser/FileTreeRowModel.swift` — new row kind for the inline editor.
- `Treemux/Localizable.xcstrings` — zh-Hans for every new visible string.

---

## Feature 2 — File-tree search

### Chosen model: Cyberduck-style escalating single field

Researched against VSCode, Zed, Sublime, Nova, Cyberduck, FileZilla, ForkLift, Termius. The
dominant safe pattern for a **lazily-loaded tree with an expensive remote backend** is a single
field whose scope escalates on demand:

- **Type → filter the already-loaded tree** (zero network).
- **Enter → recursive search** of the subtree under the current root (explicit, bounded, cancellable).

Indexed fuzzy palettes (Cmd+P style) are rejected: they require the whole tree in memory, which
is impossible for remote. Auto-recursing on every keystroke is rejected: universally avoided by
SFTP browsers because of round-trip cost.

### UX

- A search field lives in `FileTreeToolbar` (currently just title + refresh + hidden-toggle).
  Focus via **Cmd+F** when the tree pane is active; Esc clears and unfocuses.
- **Local filter (default, while typing):**
  - Case-insensitive **substring** match on the node name (optionally the relative path).
  - Debounced ~150 ms.
  - Non-matching rows are hidden; **ancestor directories of matches are auto-expanded** and the
    matched span is **highlighted** in the row label.
  - A subtle **match count** is shown, plus a discoverable affordance: *"Press ⏎ to search the
    server for '…'"* (remote) / *"…search all files"* (local) so escalation is findable — the gap
    Termius leaves open.
- **Recursive search (on Enter):**
  - **Remote:** one server-side `find` round-trip under the current root (e.g.
    `find <root> -iname '*query*'`), with a `-maxdepth` cap and a **result cap** (e.g. 500 hits).
    Falls back to an SFTP walk only if `find` is unavailable. Results **stream in**; the action is
    **cancellable** (typing again / Esc / explicit cancel) and shows **progress + count**.
  - **Local:** bounded recursive walk off the main actor, same caps and cancel semantics.
  - Recursive hits are merged into the tree by materializing their ancestor paths and
    auto-expanding to reveal them, reusing the existing lazy children cache.
- **Match style:** substring for the local filter; the recursive mode may use the same substring
  semantics (fuzzy is explicitly deferred — fuzzy over a partial tree misleads).

### Controller responsibilities

- Hold `searchQuery`, `searchMode` (`.filter` / `.recursive`), `searchResults`, `isSearching`,
  and the in-flight recursive `Task` (cancel on query change — mirror the existing
  `pendingHiddenFilterTask` generation-guard pattern).
- `visibleRows()` composes the existing hidden-file filter with the search filter. Both run off
  the main actor and apply atomically under a generation guard, consistent with
  `rederiveFilteredChildren()`.
- The recursive walk lives behind the `FileBrowserDataSource` (below) so local and remote share
  the controller path.

### Data-source additions

```
protocol FileBrowserDataSource {
    // Recursive name search under `root`. Streams matches via `onMatch` until
    // done or `maxResults` reached. Honors Task cancellation. Remote uses
    // server-side `find`; local walks the FS off-thread.
    func searchNames(root: String, query: String, maxResults: Int,
                     onMatch: @escaping (FileNode) -> Void) async throws
}
```

---

## Feature 8 — New folder / new file

### Chosen interaction: inline editing (VSCode/Finder style)

A temporary editor row is inserted **in place** under the target directory: an icon + an
auto-focused `TextField`. **Enter** confirms (creates + selects/reveals the new node), **Esc**
cancels (removes the temp row). No modal sheet.

### Entry points

- **Context menu** on a directory row → "New Folder" / "New File". (The row already has a
  `.contextMenu` with copy-path actions; extend it.) Right-clicking a **file** targets its
  **parent** directory.
- **Toolbar buttons** in `FileTreeToolbar` → create under the current selection's directory, or
  the root if nothing is selected.

### Behavior

- Creating auto-expands the target directory (so the new inline row is visible), inserts the
  editor row, and focuses it. On confirm:
  - Validate the name (non-empty; reject `/`; reject names that already exist in the listing → show
    an inline error and keep editing).
  - Call the data source; on success, refresh that directory's listing (reuse the existing
    per-directory reload), select the new node, and — for a new **file** — optionally open it in a
    preview tab (decide in plan; default: select only).
  - On failure (permission, remote error), surface via the existing `FileTreeErrorBanner` /
    inline error; keep the editor row for retry.
- Only available when `dataSource.supportsWrite == true` (local always; remote per capability).

### Inline-edit infrastructure

- Add a `FileTreeRowModel.Kind.editor(parentPath:, intent: .folder | .file)` alongside the
  existing `.node` / `.loadMore`.
- `visibleRows()` injects the editor row at the right position under its parent.
- `FileTreeRow` renders the editor kind as a focused `TextField` with the appropriate icon; the
  view reports commit/cancel back to the controller.
- This inline-edit substrate is intentionally reusable for a future **rename** action (out of
  scope now, but the shape should not preclude it).

### Data-source additions

```
protocol FileBrowserDataSource {
    var supportsWrite: Bool { get }                 // already exists
    func createDirectory(_ path: String) async throws
    func createFile(_ path: String) async throws    // empty file
}
```

- **Local:** `FileManager.createDirectory(withIntermediateDirectories: false)` /
  `createFile(atPath:contents:nil)`.
- **Remote:** SFTP `mkdir` / write an empty file (reuse the existing atomic-write path with empty
  data). Reject if the target already exists.

---

## Feature 10 — Symlink-directory reading

### Root cause

A symlink's `FileNode.Kind` is `.symlink(target:)`, and `isDirectory` returns `true` only for
`.directory`. So a symlink pointing at a directory shows no disclosure triangle, and
`BFSTreeLister` (`where child.isDirectory`) never recurses into it. Result: symlinked directories
are dead ends.

### Design

1. **Detect "symlink resolves to a directory."** Enrich the node so a symlink carries whether its
   target is a directory:
   - Extend `FileNode.Kind.symlink` to `symlink(target: String?, targetIsDirectory: Bool)` (or add
     a derived flag), and a computed `isExpandableDirectory` = real directory **or** symlink whose
     target is a directory.
   - **Local:** stat the resolved target (`FileManager`/`URLResourceValues` on the destination).
   - **Remote:** `SFTPService` already has dereference (`ls -1paL`) and stat logic with symlink
     handling — extend it to record the target's type.
2. **Make symlink-directories expandable.** UI treats `isExpandableDirectory` like a directory:
   show the disclosure triangle; on expand, `listDirectory` follows the link and lists the target's
   contents. The **icon stays the symlink variant** (user can tell it's a link but can still enter).
3. **Cycle protection (required).**
   - The eager BFS prefetch (`BFSTreeLister`) still recurses **only real directories**, never
     symlink-directories. Symlink-directories are **lazy** — expanded only on explicit user action.
     This keeps the prefetch immune to symlink loops and avoids remote blow-up.
   - When expanding, maintain a visited-set of **resolved real paths**; if an expansion resolves to
     an already-visited ancestor path, stop (do not recurse further), so a cyclic link can't loop.

### Trade-off

Real directories keep eager prefetch (fast browsing); symlink-directories are lazy/on-demand. This
fixes "can't read" without introducing cycles or unbounded remote cost.

---

## Testing

- **Feature 2:** unit-test the pure filter (substring, ancestor auto-expand set, match count) and
  the recursive-search cancellation/generation guard. Mock data source for streamed matches +
  result cap. Manual: remote `find` on a large tree (progress, cancel, cap).
- **Feature 8:** unit-test name validation (empty, `/`, duplicate) and the editor-row injection in
  `visibleRows()`. Data-source create tests (local real FS temp dir; remote mocked). Manual:
  create under root / nested / remote; error path (permission).
- **Feature 10:** unit-test `isExpandableDirectory` for real dir / symlink-to-dir / symlink-to-file;
  the BFS guard (symlink-dirs not eagerly recursed); the visited-set cycle stop. Manual: local
  symlinked dir, remote symlinked dir, a symlink cycle.

## i18n

Every new visible string (`Search`, `New Folder`, `New File`, `Press ⏎ to search the server for
'%@'`, match-count, validation errors, progress) uses `LocalizedStringKey` with a synced
`zh-Hans` entry in `Localizable.xcstrings`.

## Suggested implementation order

1. **Feature 10** (smallest, self-contained model + BFS change) — establishes `isExpandableDirectory`.
2. **Feature 8** (inline-edit substrate + data-source create) — reusable row infra.
3. **Feature 2** (search field + recursive data-source search) — the largest, builds on the tree
   filter machinery.

Each may become its own plan, or one plan with three ordered phases — decided in writing-plans.
