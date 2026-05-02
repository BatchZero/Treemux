# File Browser Tab — Default Split Ratio 2:8 Design

Date: 2026-04-30
Status: Approved (brainstorming)
Branch: `feat+filebrowser-default-2-8-split`

## Background

The file browser tab uses a SwiftUI `HSplitView` with two panels: the file tree on
the left and the file viewer on the right. Today's layout in
`Treemux/UI/FileBrowser/FileBrowserTabContentView.swift`:

```swift
HSplitView {
    FileTreePanelView(controller: controller)
        .frame(minWidth: 180, idealWidth: 240, maxWidth: 480)
    FileViewerPanelView(controller: controller)
        .frame(minWidth: 200)
}
```

There is no notion of a *ratio* — the file tree is given an absolute
`idealWidth: 240` and capped by `maxWidth: 480`, so on wider windows it ends up
visually around 5:5 (capped at 480) rather than truly proportional. There is
also no persisted split position.

## Goal

Make a freshly opened file browser tab default to a **2:8** split (file tree
~20%, file viewer ~80%) while still letting the user drag the splitter
afterwards. Drag positions are remembered for the lifetime of that tab's view
instance and reset when the tab is reopened. Each file browser tab tracks its
own position independently.

## Non-Goals

- No persistence of split position across app launches.
- No global "shared" split ratio across tabs.
- No locked/forced 2:8 ratio on window resize (after initial layout, the
  user's drag position takes over and is preserved by `HSplitView`'s built-in
  state, not re-projected to 20%).
- No replacement of `HSplitView` with `NSSplitViewController` or a custom
  `HStack` splitter.

## Approach

Wrap the existing `HSplitView` in a `GeometryReader` and feed `idealWidth`
based on 20% of the available width. SwiftUI's `HSplitView` consults
`idealWidth` only on initial layout; once the user drags the divider, that
position is cached for the view instance and `idealWidth` updates do not
override it. This mechanic naturally satisfies:

- **Default 2:8 on first open** — initial `idealWidth` is `width * 0.2`.
- **Draggable** — `HSplitView` ships its own draggable divider.
- **Per-tab independent** — `HSplitView` state is tied to the SwiftUI view
  instance, so each tab has its own cached position.
- **Session-scope only** — no `@AppStorage` / `UserDefaults` involved.

The `maxWidth: 480` constraint is removed so 2:8 holds at any window width.
`minWidth: 180` is kept to prevent the file tree from collapsing on narrow
windows.

## Components

### `FileBrowserTabContentView`

Single-file change. New body:

```swift
var body: some View {
    GeometryReader { geo in
        HSplitView {
            FileTreePanelView(controller: controller)
                .frame(
                    minWidth: 180,
                    idealWidth: max(180, geo.size.width * 0.2)
                )
            FileViewerPanelView(controller: controller)
                .frame(minWidth: 200)
        }
    }
    .task { await controller.loadRoot() }
    .onReceive(NotificationCenter.default.publisher(for: .treemuxSaveCurrentFile)) { _ in
        Task { try? await controller.saveCurrentFile() }
    }
}
```

Notes:
- `max(180, …)` floors `idealWidth` at the existing `minWidth`, guarding
  against `geo.size.width == 0` first-frame transients.
- The `GeometryReader` does not introduce additional layout containers —
  `HSplitView` already fills available space.

### Other files

No other files require changes:
- `FileTreePanelView`, `FileViewerPanelView`: unchanged.
- `FileBrowserTabController`: unchanged (no new state).
- `Localizable.xcstrings`: no new user-visible strings.
- Persistence layer: unchanged.

## Edge Cases & Fallback

`GeometryReader` can yield `size.zero` on the very first layout pass before
its parent has a finalized size. The `max(180, …)` floor ensures the layout
remains valid in that frame. If real-world testing shows a visible "snap"
from 180 → 20% on first open, add a `@State var didLayoutOnce = false` flag
and gate the `HSplitView` render on it (i.e. delay constructing `HSplitView`
until the first non-zero size is observed). Only add this guard if testing
shows the issue — otherwise it is unnecessary indirection.

## Risks

- **`HSplitView` ignoring `idealWidth` on subsequent re-renders**: SwiftUI is
  expected to apply `idealWidth` only on the initial layout. If a future
  SwiftUI version changes this so that updating `idealWidth` (e.g. via window
  resize) re-snaps the divider back to 20% and overrides user drags, the
  approach breaks. Mitigation: the `idealWidth` value is computed from
  `geo.size.width`, but the value only changes when the user resizes the
  window. We accept this risk; if it surfaces, escalate to Approach 2
  (`NSSplitViewController` bridge) per the brainstorming notes.
- **Multiple SwiftUI versions across macOS**: behavior of `HSplitView` is
  somewhat undocumented. The fallback in *Edge Cases* covers the most likely
  symptom. No other macOS-specific shims are anticipated.

## Validation

This is a pure UI layout change; unit tests are low-value. Validation is
manual on a debug build:

1. Compile, then run via the project's standard debug command:
   `rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<id>/Build/Products/Debug/Treemux.app`
2. Open a file browser tab. Confirm initial split ≈ 2:8.
3. Drag the splitter. Confirm it moves and stays where dropped.
4. Switch to another tab and back to the same file tab — drag position must
   be preserved (HSplitView's built-in state).
5. Close the file tab and reopen — split must reset to 2:8.
6. Open two file tabs. Drag tab A to ~3:7. Confirm tab B is still at 2:8.
7. Resize the window very wide (>1500px) — file tree should scale up
   proportionally on first layout. Resize very narrow (<900px) — file tree
   should be clamped at `minWidth: 180`.

## Out of Scope / Future Work

- Persisted per-tab or per-window split positions (would require introducing
  `@AppStorage` keyed by tab identity). Defer until users ask.
- Global "shared" split ratio across all file tabs.
- Forcing constant 20%-on-resize (currently the user's absolute drag
  position is preserved by `HSplitView` and does not re-project to 20% when
  the window is resized — that is intentional and matches macOS norms).
