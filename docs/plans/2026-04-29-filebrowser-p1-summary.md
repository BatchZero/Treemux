# File Browser P1 — Branch Summary

Branch: `feat/filebrowser-p1-fixes-and-subtabs`
Date: 2026-04-29
Total commits on branch: 22
Total tests: 287 / 287 passing (was 252 at branch start, +35 net)

Plan documents:

- Design: `docs/plans/2026-04-29-filebrowser-p1-design.md`
- Implementation: `docs/plans/2026-04-29-filebrowser-p1-implementation.md`
- QA checklist: `docs/plans/2026-04-29-filebrowser-p1-qa-checklist.md`

## Commits in order

| #  | SHA      | Subject                                                                       | Stage  |
|----|----------|-------------------------------------------------------------------------------|--------|
| 1  | d2affc1  | fix: keep sidebar folder-browser icon visible at idle                         | A1     |
| 2  | f1af53d  | fix: eye-icon toggle reveals hidden files without manual refresh              | A2+A3  |
| 3  | 7f83213  | refactor(test): reuse MockFileBrowserDataSource; drop new FakeDataSource      | A2+A3  |
| 4  | 09ffa2e  | fix: file-browser tab no longer corrupted into terminal on switch-back        | A4+A5  |
| 5  | 929aa48  | feat: surface remote file-browser errors with password-retry path             | B1+B2  |
| 6  | aaae1c9  | feat: error/password banner in file tree + map noAuthMethodAvailable          | B3+B4  |
| 7  | 933946d  | feat: share authenticated SFTPService across a workspace                      | B5     |
| 8  | 112ecc5  | fix: shared SFTPService no longer disconnects sibling data sources            | B5 fu  |
| 9  | b77b615  | feat: copy absolute/relative path from file-tree right-click menu             | C1+C2  |
| 10 | 012c042  | feat: FileSubTabRecord type + extend FileBrowserTabState with subTabs         | D1+D2  |
| 11 | b2c872b  | feat: VSCode-style sub-tab state machine inside file-browser tab              | D3+D4  |
| 12 | e8a0a67  | feat: FileSubTabBarView with active highlight, dirty dot, drag, context menu  | E1     |
| 13 | 3303164  | feat: render FileSubTabBarView above the viewer panel                         | E2     |
| 14 | 7c74932  | feat: Cmd+W cascades through file-browser sub-tabs first                      | E3     |
| 15 | 89d691a  | feat: dirty-confirmation NSAlert when closing a sub-tab with unsaved edits    | F1     |
| 16 | 71ca081  | feat: batch unsaved-changes sheet when closing file-browser tab               | F2     |
| 17 | 0d92925  | build: add CodeEditSourceEditor for macOS-native tree-sitter editor           | G1     |
| 18 | 8f1b969  | feat: switch in-app editor to CodeEditSourceEditor for syntax highlighting    | G2     |
| 19 | 2b129ac  | feat: GitDiffService protocol + Local/Remote impls + parser tests             | G3+G4  |
| 20 | 66bc6ea  | feat: pipe git diff/status into controller + file-tree badges                 | G5+G6  |
| 21 | a0e33a4  | feat: editor gutter shows orange stripe for git-diff hunks                    | G7     |
| 22 | ed4517f  | feat: word-based code completion popover + Settings toggle                    | G8     |

## What landed

- **Stage A** — bug fixes for issues #1 (sidebar folder-browser icon visibility), #3 (eye-icon toggle without manual refresh), #5 (file-tab → terminal-tab silent corruption regression).
- **Stage B** — remote empty-tree fix with error/password-retry banner, plus shared per-workspace `SFTPService` so a second file-browser tab in the same workspace reuses the authenticated session.
- **Stage C** — Copy Absolute Path / Copy Relative Path right-click menu in the file tree (and on sub-tab titles).
- **Stage D–F** — VSCode-style sub-tabs inside each file-browser tab: data model (`FileSubTabRecord`), state machine (single-click preview, double-click promote, focus-existing, close cascade, drag-reorder), bar UI, Cmd+W cascade, and dirty-close confirmation (single-file `NSAlert` and multi-file SwiftUI sheet).
- **Stage G** — editor upgrade with `CodeEditSourceEditor` 0.15.2: tree-sitter syntax highlighting (Swift, Python, JS, TS, Go, Rust, JSON, YAML, Markdown, Bash, HTML, CSS); `GitDiffService` protocol with local + remote (`SFTPService.runSSH`) implementations; hunk parser with unit tests; file-tree git-status colored badges; editor gutter orange stripes for diff hunks; word-based code-completion popover with `BufferWordIndex` + Settings toggle.
- **Stage H** — this summary + the manual QA checklist.

## Plan deviations

- **Runestone → CodeEditSourceEditor.** The original implementation plan named Runestone for the editor. Runestone is iOS-only (its `Package.swift` declares `.iOS(.v14)` as the only supported platform; sources hard-import UIKit). After confirming the package would not compile on macOS, the substitution is **`CodeEditSourceEditor` 0.15.2** from the CodeEdit project — a macOS-native AppKit editor with bundled tree-sitter highlighting. Same intent, same tier coverage, no regressions in the Stage G acceptance criteria. **Flag at PR review** so the design doc can be updated post-merge.

- **Build flag dependency.** `CodeEditSourceEditor` ships a transitive SwiftLint SPM plugin. Every `xcodebuild` invocation now requires `-skipPackagePluginValidation`, otherwise the build aborts on first-party SwiftLint plugin validation. The `xcodebuild test` flow still works (`** TEST SUCCEEDED **`) — the 2 "failed" SwiftLint plugin lines in the trailing log are cosmetic and expected. **Action item for merge time:** update `scripts/deploy.sh` to pass `-skipPackagePluginValidation` if it currently invokes plain `xcodebuild`.

## Out of scope (explicit non-goals — captured here for the next P1 / P2 tranche)

- File-tree create / rename / delete operations (no FS mutations from the tree).
- Side-by-side diff view inside the editor — gutter stripes + tree badges only.
- Real LSP, local or remote (deferred to P2).
- Real-time file-system / git-status watching — refresh is manual via the toolbar Refresh button or save events.
- Sidebar Project / Worktree right-click "Copy Path" entries — folded into the deferred "Project right-click menu" P1 item rather than added piecemeal here.
- DiffHunk added/removed differentiation. The current parser returns all hunks as `.modified`, so the gutter renders a uniform orange stripe regardless of insertion/deletion. A future iteration can split into added (green) / deleted (red) with a thinner stripe per kind.

## Manual QA

See `docs/plans/2026-04-29-filebrowser-p1-qa-checklist.md`. The checklist covers all six product issues (#1–#6), the entire Stage G editor upgrade (G2 / G6 / G7 / G8), and a zh-Hans verification pass.

## Handoff

The branch is ready for manual QA + merge.

Build:

```sh
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -skipPackagePluginValidation -configuration Debug
```

Run a fresh app instance (replace the DerivedData ID with whatever your local build produced — Xcode prints it on the last line of the build log, or `ls -td ~/Library/Developer/Xcode/DerivedData/Treemux-*/Build/Products/Debug/Treemux.app | head -1`):

```sh
rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<ID>/Build/Products/Debug/Treemux.app
```
