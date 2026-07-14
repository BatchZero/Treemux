# Feature 11 — Quit-Time Unsaved-Files Guard

Date: 2026-07-14
Batch: B–H (preview-tab lifecycle subsystem), requirement (11)
Status: Design approved

## Goal

Warn the user with a single aggregate alert when they quit the app while any
file sub-tab has unsaved edits, listing the affected filenames, so unsaved work
is not silently discarded.

## Scope Clarification

Requirement (11) originally read "preview-tab unsaved handling: open a new tab
on edit, keep unsaved tabs, warn on close." Two of its three parts are **already
implemented** and confirmed as the desired behavior:

- **Edit promotes in place** — `FileBrowserTabController.updateLiveBuffer`
  already flips a preview (unpinned) tab to `isPinned = true` on the first edit
  (VSCode-style), so editing "keeps" the tab. No change wanted.
- **Warn on tab close** — `closeSubTab` → `confirmCloseDirtySubTab` already shows
  a Save / Don't Save / Cancel modal for a dirty sub-tab. No change wanted.

The remaining work is the **app-level quit guard**: an aggregate warning shown
when quitting the whole app with unsaved files. This spec covers only that.

## Current State

- `AppDelegate` (the `NSApplicationDelegate`) implements
  `applicationWillTerminate(_:)` and
  `applicationShouldTerminateAfterLastWindowClosed(_:)` but NOT
  `applicationShouldTerminate(_:)` — the hook that can cancel/allow termination.
- `AppDelegate` can reach the store via `treemuxApp?.store` (a `WorkspaceStore?`).
- `WorkspaceStore.workspaces: [WorkspaceModel]`.
- `WorkspaceModel.fileBrowserControllers: [String: [UUID: FileBrowserTabController]]`
  (private, `@ObservationIgnored`) — the registry of instantiated file-browser
  controllers.
- `FileBrowserTabController.dirtySubTabs: [SubTabRuntime]` already exists; its
  doc comment anticipates exactly this feature ("Stage F1 will use this to drive
  the 'X files have unsaved changes' sheet").
- `confirmCloseDirtySubTab` already uses `String(localized:)` for alert copy —
  the i18n pattern to follow, with matching entries in `Localizable.xcstrings`.

## Requirements

1. On app quit, if one or more file sub-tabs (across all workspaces and their
   file-browser controllers) have unsaved edits, show one aggregate `NSAlert`.
2. The alert lists the unsaved filenames (deduplicated by path).
3. Buttons: **Quit Anyway** (proceeds, discarding changes) and **Cancel**
   (aborts the quit). Cancel is the keyboard default (Return) to prevent an
   accidental quit; Quit Anyway is marked destructive.
4. With no unsaved files, quitting proceeds silently (no alert).
5. No save action is offered (out of scope — see below). No cross-restart
   preservation of unsaved buffers.
6. All alert strings are localized (en + zh-Hans), including singular/plural.

## Design

### Enumeration (thin accessors)

- `WorkspaceModel` gains a computed `var unsavedFilePaths: [String]`:
  ```swift
  var unsavedFilePaths: [String] {
      fileBrowserControllers.values
          .flatMap { $0.values }
          .flatMap { $0.dirtySubTabs.map(\.path) }
  }
  ```
- `WorkspaceStore` gains a computed `var unsavedFilePaths: [String]`:
  ```swift
  var unsavedFilePaths: [String] {
      workspaces.flatMap { $0.unsavedFilePaths }
  }
  ```
  Deduplication by path (order-preserving) happens in the prompt builder so the
  raw accessors stay simple.

### Pure prompt builder (unit-testable)

New `enum UnsavedQuitPrompt` (file `Treemux/Domain/UnsavedQuitPrompt.swift`):

```swift
enum UnsavedQuitPrompt {
    static let maxListed = 5

    /// Returns the alert copy for the given unsaved file paths, or nil when
    /// there is nothing unsaved (caller lets the quit proceed). Paths are
    /// deduplicated (order-preserving); names use the last path component.
    static func build(paths: [String]) -> (message: String, informative: String)?
}
```

Behavior:
- Empty (after dedup) → `nil`.
- `message`: `"1 file has unsaved changes."` / `"N files have unsaved changes."`
  (singular vs plural).
- `informative`: up to `maxListed` filenames, one per line; if more,
  append a line `"…and K more."`; then a trailing line
  `"Quitting now will discard these changes."`.
- All literals via `String(localized:)` / `String.localizedStringWithFormat`
  so they localize; the returned tuple holds resolved strings.

### Quit hook

`AppDelegate.applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply`:

```
guard let store = treemuxApp?.store else { return .terminateNow }
guard let prompt = UnsavedQuitPrompt.build(paths: store.unsavedFilePaths) else {
    return .terminateNow
}
let alert = NSAlert()
alert.alertStyle = .warning
alert.messageText = prompt.message
alert.informativeText = prompt.informative
let quit = alert.addButton(withTitle: String(localized: "Quit Anyway"))
quit.hasDestructiveAction = true
let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
cancel.keyEquivalent = "\r"   // Return = Cancel, prevents accidental quit
return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
```

### Theme / i18n

- NSAlert is a system dialog — no custom colors, no theme tokens involved.
- New user-visible strings ("Quit Anyway", "Cancel", the message/informative
  formats) get `zh-Hans` entries in `Localizable.xcstrings`, including the
  singular and plural message variants.

## Testing

**Unit tests** — new `UnsavedQuitPromptTests`:

- Empty paths → `nil`.
- One path → message uses the singular form; informative lists the one filename
  and the discard line.
- A few paths (≤ maxListed) → plural message; all filenames listed.
- More than `maxListed` paths → exactly `maxListed` filenames listed plus an
  "…and K more." line with the correct K.
- Duplicate paths → deduplicated (count and list reflect unique paths).
- Filenames derive from the last path component (e.g. `/a/b/notes.md` → `notes.md`).

The `WorkspaceModel` / `WorkspaceStore` accessors are thin; add a lightweight
test only if a controller with a dirty sub-tab is easily constructible in the
existing test harness, otherwise rely on the existing `dirtySubTabs` coverage.

**Manual smoke (GUI)** — `applicationShouldTerminate` is an AppKit modal:

- Edit a file (make a sub-tab dirty), press ⌘Q → alert appears listing the file;
  Cancel aborts the quit; ⌘Q again → Quit Anyway quits.
- Multiple dirty files across tabs/workspaces → all listed (up to 5, then
  "…and K more").
- No dirty files → ⌘Q quits with no alert.

## Acceptance Criteria

- Quitting with unsaved file tabs shows one aggregate alert listing the
  filenames; Cancel aborts, Quit Anyway quits.
- Quitting with nothing unsaved is silent.
- `UnsavedQuitPrompt` unit tests pass; full suite green.
- zh-Hans translations present for all new strings.

## Out of Scope

- Any "Save All" / save action in the quit alert (option 1 chosen: guard only).
- Cross-restart preservation of unsaved buffer content (hot exit).
- Per-tab close warning (already implemented) and edit-promotes-tab behavior
  (already implemented).
- Unsaved-state warnings for terminal sessions.
