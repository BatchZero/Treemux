# File Browser P1 — Manual QA Checklist

Date: 2026-04-29
Branch: `feat/filebrowser-p1-fixes-and-subtabs`
Worktree: `.worktrees/feat+filebrowser-p1-fixes-and-subtabs/`

For human reviewer to step through after the branch lands. Items map to `docs/plans/2026-04-29-filebrowser-p1-design.md` (issues #1–#6 + Stage G editor upgrade) and `docs/plans/2026-04-29-filebrowser-p1-implementation.md` (Tasks A1–G8).

Build:

```sh
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -skipPackagePluginValidation -configuration Debug
```

Run a fresh app instance:

```sh
rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<ID>/Build/Products/Debug/Treemux.app
```

Test in BOTH English and Simplified Chinese system locales (Settings → General → Language).

## §1 — Sidebar folder-browser icon visibility (Issue #1)

- [ ] Open Treemux. In the sidebar, every Project row shows a small folder-plus icon at the right edge — visible without hovering.
- [ ] Hovering the row makes the icon visibly brighter (idle ~50% opacity, hover 100%).
- [ ] Click the icon — a new file-browser tab opens for that workspace's repo root.
- [ ] Same checks for Worktree rows: idle visible, hover brighter, click opens file-browser tab for the worktree path.
- [ ] In zh-Hans locale, hover-tooltip reads "打开文件浏览器".

## §2 — Remote project file-browser opens correctly (Issue #2)

Setup: a remote workspace whose SSH host requires password auth (no key configured).

- [ ] Open file-browser tab on the remote worktree. Tree initially appears empty BUT shows an orange-bannered "Cannot connect to <host>" with a password field and Connect button.
- [ ] Enter the password and click Connect. The file tree populates with remote files.
- [ ] Open a SECOND file-browser tab in the same workspace (different worktree). It loads without re-prompting for the password (B5 shared `SFTPService`).
- [ ] Force a transient network drop while browsing — banner switches to a generic error with a Retry button. Click Retry — tree recovers.
- [ ] In zh-Hans locale, banner reads "无法连接到 <host>" / "重试" / "输入密码" / "连接" verbatim.

## §3 — Eye icon refresh fix (Issue #3)

- [ ] Open file-browser tab on a folder containing dotfiles (e.g. `.git`, `.DS_Store`).
- [ ] Initially hidden files are not shown.
- [ ] Click the eye icon (toolbar). Tree IMMEDIATELY repopulates with hidden files visible — no Refresh-button needed.
- [ ] Click again. Tree IMMEDIATELY hides them.
- [ ] Toggling repeatedly never desyncs the tree.

## §4 — File-tab → terminal-tab regression (Issue #5)

- [ ] Create a workspace. Open a file-browser tab from the sidebar (worktree row's folder icon). The outer tab bar shows: Tab 1 (terminal) + the new file-browser tab. The file-browser tab is active and shows the tree.
- [ ] Click Tab 1 (terminal) — terminal renders, no errors.
- [ ] Click back to the file-browser tab — the tree REAPPEARS (does NOT silently become a terminal tab as it did before this fix).
- [ ] Repeat the back-and-forth several times. State stays correct.
- [ ] If you have AI hint banners enabled, the issue reproducer is the `AIHookBanner` controller; verify with hints both on and off.

## §5 — Copy path context menu (Issue #4)

- [ ] In a file-browser tab, right-click a file in the tree. Menu shows "Copy Absolute Path" and "Copy Relative Path".
- [ ] "Copy Absolute Path" → paste in Terminal — full path verified.
- [ ] "Copy Relative Path" → paste in Terminal — path is relative to the file-browser-tab's `rootPath` (e.g. `Sources/Foo.swift`, NOT `/Users/yanu/.../Sources/Foo.swift`).
- [ ] On the root row itself, "Copy Relative Path" is disabled (greyed out).
- [ ] Right-click works on directories too.
- [ ] Same right-click menu on each sub-tab title (after opening files); verify Copy Absolute / Copy Relative work there.
- [ ] In zh-Hans, both menu items read "复制绝对路径" / "复制相对路径".

## §6 — Sub-tabs (Issue #6)

Setup: open a file-browser tab on a real codebase (e.g. the treemux project itself).

### Open / preview semantics
- [ ] Single-click a file in the tree → a sub-tab opens with the file. Title is italic (preview state). The viewer shows the file's content.
- [ ] Single-click another file → the SAME preview tab is reused (its content changes; no second tab created). Italic stays.
- [ ] Double-click the file → the preview tab promotes to permanent (italic disappears, regular weight). Title shows the icon corresponding to file type (`doc.text`, `photo`, `doc.richtext`, `doc`, ...).
- [ ] Double-click another file → a new permanent sub-tab is created next to the first. Active highlight (bottom accent stripe) follows the active sub-tab.
- [ ] Single-click a third file (different from any open) → a NEW preview tab is created (because no preview exists currently — it was promoted in the previous step). Subsequent single-clicks replace this preview.

### Focus existing
- [ ] Single-click a file that's already in a permanent sub-tab → that permanent sub-tab is focused. NO new tab; preview (if any) keeps its current path.

### Close × buttons
- [ ] Hover a sub-tab → × close icon appears.
- [ ] Click × on a non-active permanent sub-tab → it closes; active doesn't change.
- [ ] Click × on the active sub-tab → it closes; the right-neighbor sub-tab becomes active.
- [ ] Closing the rightmost sub-tab activates the LEFT neighbor.
- [ ] Closing the last sub-tab leaves the file-browser tab open with empty viewer state ("Select a file from the tree").

### Drag-reorder
- [ ] Drag a sub-tab horizontally to reorder. The order updates with animation. Re-order persists across `Cmd+R` rebuilds (or app restart per below).

### Cmd+W cascade
- [ ] With several sub-tabs open in a file-browser tab, press Cmd+W. The active sub-tab closes; outer tab stays.
- [ ] Repeat Cmd+W until all sub-tabs are gone. Next Cmd+W closes the outer file-browser tab itself.
- [ ] On a tab with no sub-tabs, Cmd+W immediately closes the outer tab.
- [ ] On a terminal tab, Cmd+W closes the terminal tab (no regression).

### Right-click menu on sub-tabs
- [ ] Copy Absolute Path / Copy Relative Path work.
- [ ] On a preview sub-tab, "Pin Tab" appears; clicking it promotes the tab.
- [ ] Pinned sub-tabs do NOT show "Pin Tab" (already pinned).
- [ ] "Close Tab" closes that tab.
- [ ] "Close Other Tabs" closes everything else.
- [ ] "Close All Tabs" closes everything (file-browser tab stays open, viewer empty).

### Persistence across restart
- [ ] With several pinned sub-tabs (A, B, C) and one preview (D), Cmd+Q the app and reopen.
- [ ] A, B, C are restored in their order. D is GONE (preview is not persisted).
- [ ] `activeSubTabID` lands on a previously-pinned tab.

### Dirty single-tab close
- [ ] Open a text file. Edit it. Click × on its sub-tab.
- [ ] NSAlert: "<filename> has unsaved changes" / Save / Don't Save / Cancel.
- [ ] Save → Cmd+S happens, tab closes.
- [ ] Don't Save → tab closes with edits discarded.
- [ ] Cancel → nothing happens.

### Dirty batch close (closing outer tab with multiple dirty sub-tabs)
- [ ] Open three files, edit two of them.
- [ ] Click × on the OUTER file-browser tab (the workspace tab bar).
- [ ] If exactly one is dirty: single-file NSAlert (same shape as above).
- [ ] If two or more are dirty: SwiftUI sheet listing each dirty file's relative path. Save All / Don't Save / Cancel.
- [ ] Save All saves them serially; first failure aborts and shows a Save-failed alert.

### zh-Hans
- [ ] All sub-tab strings localized: "固定标签页", "关闭标签页", "关闭其他标签页", "关闭所有标签页", "%@ 存在未保存的修改。", "不保存", "%lld 个文件有未保存的修改：", "全部保存".

## §7 — Editor upgrade (Stage G)

### Syntax highlighting (G2)
- [ ] Open a Swift file: keywords / strings / numbers are colored.
- [ ] Open Python, JS, TS, Go, Rust, JSON, YAML, Markdown, Bash, HTML, CSS — each gets reasonable highlighting.
- [ ] Open a `.txt` (no language) → plain text, no highlighting.
- [ ] Open a file >2MB → plain text mode (no highlighting); does NOT freeze the editor.
- [ ] Line numbers visible in the gutter for all files.

### Git diff: tree status badges (G6)
- [ ] In a worktree with uncommitted edits, file-browser tree shows colored dots:
  - Modified files → orange
  - Untracked files → gray
  - Added (staged) files → green
  - Deleted files → red
  - Renamed files → orange
- [ ] Save a clean file → no dot appears (status refreshed).
- [ ] Edit and save a tracked file → orange dot appears (status refreshed).
- [ ] Click the toolbar Refresh button → status re-pulls without a tree re-list visible glitch.

### Git diff: gutter stripes (G7)
- [ ] Open a file you've modified locally. The editor gutter shows orange stripes alongside line numbers for the modified line ranges.
- [ ] Save the file (no further edits) — stripes update / disappear if file matches HEAD.
- [ ] Add new lines and save → stripes appear in the new range.
- [ ] Switch sub-tabs — stripes for the new active file render correctly.

### Word completion (G8)
- [ ] In the editor, type 2+ characters of an existing word in the buffer. A popover appears listing matching words.
- [ ] ↑/↓ moves selection, Tab or Enter accepts (replaces the prefix), Esc dismisses.
- [ ] Suggestions ranked by frequency (most-used first).
- [ ] Numbers and single-character identifiers are NOT suggested.
- [ ] In Settings, toggle off "Enable code completion in editor" → popover never appears.
- [ ] Toggle back on → works again.
- [ ] zh-Hans: setting reads "启用编辑器代码补全".

## §8 — Cross-cutting

- [ ] No SwiftLint or compiler error in the build log (warnings from the `CodeEditSourceEditor` SPM SwiftLint plugin are expected and ignorable).
- [ ] Existing terminal tabs, AI hook banners, sidebar attention indicators all unaffected.
- [ ] Cmd+Q quits cleanly with all dirty buffers prompting (or, if "Hot Exit" not implemented, silently discarded — confirm match to existing project policy).

## Stability

- [ ] All unit tests pass (`xcodebuild test -project Treemux.xcodeproj -scheme Treemux -skipPackagePluginValidation`).
- [ ] App build succeeds with no localization-related warnings.
