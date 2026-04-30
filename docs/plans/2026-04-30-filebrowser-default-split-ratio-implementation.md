# File Browser Tab Default 2:8 Split Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Change the file browser tab's default left/right split from
absolute-pixel sizing (capped at 480 px, visually ~5:5 on wide windows) to a
proportional **2:8** default that still allows per-tab dragging within the
session.

**Architecture:** Wrap `HSplitView` in `GeometryReader` and feed
`idealWidth = max(180, width * 0.2)`. Remove the `maxWidth: 480` cap. Rely on
SwiftUI `HSplitView`'s built-in per-instance position cache for "draggable +
preserved-per-tab + reset-on-tab-reopen" semantics. No new persistence, no
new state on the controller. Reference design:
`docs/plans/2026-04-30-filebrowser-default-split-ratio-design.md`.

**Tech Stack:** Swift 5.x, SwiftUI on macOS, Xcode project (`Treemux.xcodeproj`,
scheme `Treemux`). No new dependencies.

**Worktree:** `/Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+filebrowser-default-2-8-split/`
**Branch:** `feat+filebrowser-default-2-8-split` (already created)

**Notes on TDD scope:** This is a pure SwiftUI layout change with no logic
branches. The project does not maintain SwiftUI snapshot/UI tests for layout,
and unit tests for `idealWidth` plumbing have negligible value. Validation
is a compile gate plus a structured manual QA pass against the 6-item
checklist in the design doc. Do not author throwaway unit tests just to
satisfy TDD ritual — invoke @superpowers:verification-before-completion
behavior by running real commands and visually confirming outcomes before
claiming completion.

---

## Task 1: Update `FileBrowserTabContentView` to drive `idealWidth` from `GeometryReader`

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabContentView.swift` (entire `body`)

### Step 1: Re-read the current file to confirm baseline

Run:
```
Read /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+filebrowser-default-2-8-split/Treemux/UI/FileBrowser/FileBrowserTabContentView.swift
```

Expected: file is exactly 24 lines and matches the snippet quoted in the
design doc (Background section). If anything has drifted, stop and reconcile
with the design before editing.

### Step 2: Apply the edit

Replace the existing `body` declaration with the version from the design.
The full new file content (24 lines unchanged outside `body`):

```swift
//
//  FileBrowserTabContentView.swift
//  Treemux

import SwiftUI

struct FileBrowserTabContentView: View {
    @ObservedObject var controller: FileBrowserTabController

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
        .task {
            await controller.loadRoot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .treemuxSaveCurrentFile)) { _ in
            Task { try? await controller.saveCurrentFile() }
        }
    }
}
```

Use the `Edit` tool, replacing exactly the old `HSplitView { … }` block and
nothing else. Do **not** restructure other parts of the file.

### Step 3: Build to verify it compiles

From the worktree root:

```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+filebrowser-default-2-8-split
xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build 2>&1 | tail -40
```

Expected: build succeeds (`** BUILD SUCCEEDED **` near the end). If any
error mentions `GeometryReader`, `HSplitView`, or `idealWidth`, do not
proceed — re-read the file, compare to the snippet above, and fix.

If `xcodebuild` complains that the project is open in Xcode and DerivedData
is locked, re-run after closing Xcode, or set
`-derivedDataPath /tmp/treemux-build` to use a sandboxed location for this
verification only. Note: the user's preferred run command (CLAUDE.md) opens
the build product from `~/Library/Developer/Xcode/DerivedData/Treemux-<id>/`,
so the **final** build that they will run must end up there. If you used a
sandboxed path, do a second build without `-derivedDataPath` before handing
off.

### Step 4: Commit

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabContentView.swift
git commit -m "feat(filebrowser): default tab split to 2:8 via GeometryReader

Replaces the static idealWidth: 240 / maxWidth: 480 layout in
FileBrowserTabContentView with a GeometryReader-driven idealWidth at 20%
of the available width (floored at minWidth: 180). HSplitView's built-in
per-instance position cache keeps the divider where the user drags it for
the lifetime of that tab's view; closing and reopening the tab resets back
to 2:8. No persistence, no new state."
```

Expected: one commit added on `feat+filebrowser-default-2-8-split`.

---

## Task 2: Manual QA against the design's validation checklist

This task is mandatory; do not skip it. Each step has a clear pass/fail
criterion. Record actual results inline so the parent session can review.

### Step 1: Identify the active DerivedData build directory

User-provided guidance: there is a known-correct DerivedData path stored in
auto-memory. Read `~/.claude/projects/-Users-yanu-Documents-code-Terminal-treemux/memory/feedback_deriveddata_path.md`
before guessing. If that memory says how to pick the right `Treemux-<id>`
folder (e.g. "use the most recently modified"), follow it.

If the memory is unhelpful or stale, list candidates and pick the most
recently modified:

```bash
ls -dt ~/Library/Developer/Xcode/DerivedData/Treemux-*/ | head -3
```

Expected: 1–3 candidate dirs; pick the top entry (most recent). Save the
full id (e.g. `Treemux-abc123def`) for the run command.

### Step 2: Launch the debug build

```bash
rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/<DerivedDataId>/Build/Products/Debug/Treemux.app
```

Expected: app window opens. If launch fails (Gatekeeper, missing build
product), confirm Task 1 Step 3 finished and that the DerivedData id is
correct.

### Step 3: Walk the 6-item validation checklist

For each item, observe and record PASS/FAIL with a short note:

1. **Initial 2:8 on first open** — open a file browser tab. The file tree
   should occupy roughly the left 20% of the tab content area; file viewer
   the right 80%. Eyeball acceptable; doesn't need to be pixel-perfect.
2. **Draggable** — drag the splitter left and right. It should move
   smoothly and stay where dropped.
3. **Per-tab in-session preservation** — drag the splitter to ~3:7. Switch
   to another tab in the same window. Switch back. Position must still be
   ~3:7 (not snapped back to 2:8).
4. **Reset on tab reopen** — close the file browser tab. Open a new file
   browser tab (same folder is fine). New tab must default to 2:8.
5. **Per-tab independence** — open two file browser tabs. Drag tab A to
   ~3:7. Tab B must remain at 2:8.
6. **Window resize behavior** — make the window very wide (>1500 px on
   first open). The 20% should scale up so the file tree is wider than
   320 px. Then make a fresh window very narrow (<900 px). The file tree
   must clamp at `minWidth: 180`.

If **all six** pass, this task is done. Proceed to Task 4.

If item 1 fails specifically because the file tree starts at 180 px (i.e.
20% wasn't applied because of a `geo.size.width == 0` first frame), proceed
to Task 3.

If any other item fails (drag broken, position not preserved between tab
switches, etc.), stop and escalate — the design's assumption about
`HSplitView` semantics is wrong, and the fallback to
`NSSplitViewController` bridging may be needed (out of scope for this
plan; document findings and exit).

### Step 4: Report results

Print a one-line summary per checklist item, e.g.:

```
[1] PASS – tree ~22% on 1440px window
[2] PASS – drag smooth, stays in place
[3] PASS – preserved across tab switch
[4] PASS – fresh tab snapped back to 2:8
[5] PASS – tab B unchanged after dragging tab A
[6] PASS – wide: ~360px tree at 1800px window; narrow: clamped at 180px
```

---

## Task 3 (Conditional): First-frame size-zero fallback

**Run this task only if** Task 2 Step 3 item 1 fails because the tree opens
at exactly `minWidth: 180` instead of ~20%.

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabContentView.swift`

### Step 1: Add a layout-readiness gate

Replace `body` with:

```swift
@State private var didLayoutOnce = false

var body: some View {
    GeometryReader { geo in
        Group {
            if didLayoutOnce {
                HSplitView {
                    FileTreePanelView(controller: controller)
                        .frame(
                            minWidth: 180,
                            idealWidth: max(180, geo.size.width * 0.2)
                        )
                    FileViewerPanelView(controller: controller)
                        .frame(minWidth: 200)
                }
            } else {
                Color.clear
            }
        }
        .onAppear {
            if geo.size.width > 0 { didLayoutOnce = true }
        }
        .onChange(of: geo.size.width) { newWidth in
            if !didLayoutOnce && newWidth > 0 { didLayoutOnce = true }
        }
    }
    .task { await controller.loadRoot() }
    .onReceive(NotificationCenter.default.publisher(for: .treemuxSaveCurrentFile)) { _ in
        Task { try? await controller.saveCurrentFile() }
    }
}
```

Notes:
- The `@State` flag flips to `true` once a non-zero width is observed,
  delaying the very first construction of `HSplitView` so its initial
  `idealWidth` is computed against a real width.
- `Color.clear` placeholder during the briefest first frame avoids a
  visible flash; if you observe a flash, replace with a neutral background
  matching the surrounding panel.

### Step 2: Build

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`.

### Step 3: Re-run Task 2 from Step 2

Validate item 1 specifically passes now. All other items should also
continue passing.

### Step 4: Commit

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabContentView.swift
git commit -m "fix(filebrowser): gate HSplitView on first non-zero size

Resolves a first-frame layout snap where GeometryReader briefly reports
size.zero and the HSplitView initial idealWidth resolves to minWidth: 180
instead of 20%. Delays HSplitView construction until the first non-zero
width is observed."
```

---

## Task 4: Hand-off

### Step 1: Confirm worktree state is clean

```bash
git -C /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+filebrowser-default-2-8-split status
git -C /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+filebrowser-default-2-8-split log --oneline main..HEAD
```

Expected: clean working tree. Log shows the design-doc commit plus the
implementation commit (and optionally the Task 3 fallback commit).

### Step 2: Announce completion to the user

Tell the user (in Chinese, addressing them as 卡皮巴拉):
- What was changed (one sentence).
- Whether Task 3 (the fallback) was needed.
- The exact debug-run command they can use, with the actual DerivedData id
  filled in (per CLAUDE.md):
  `rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<id>/Build/Products/Debug/Treemux.app`
- That this lives on branch `feat+filebrowser-default-2-8-split` and is
  ready for them to merge / open a PR per their preference.

Do **not** auto-merge to `main` or push the branch — those are
user-confirmation actions per the project's standing safety norms.

### Step 3: Suggest using @superpowers:requesting-code-review

Before merge, recommend `superpowers:requesting-code-review` to sanity-check
the implementation against this plan and the design.

---

## Out of Scope (do not do in this plan)

- Persisting split position to disk.
- A user-facing setting to change the default ratio.
- Replacing `HSplitView` with `NSSplitViewController`.
- Any change to `FileTreePanelView`, `FileViewerPanelView`, or
  `FileBrowserTabController`.
- Localization edits (no new strings introduced).
