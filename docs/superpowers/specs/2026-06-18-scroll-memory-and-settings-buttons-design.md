# File Tree Scroll Memory & Settings Footer Buttons

Date: 2026-06-18
Branch: `feat/scroll-memory-and-settings-buttons`

## Problem

Three independent issues raised from trial feedback:

1. **File tree scroll position resets.** Scroll the file browser tree down, switch
   to a terminal tab, switch back — the tree jumps back to the top. The user wants
   the scroll position remembered across tab switches.

2. **Settings footer "Save" button is misleading.** When no setting has changed,
   the Save button still renders at full accent fill (looks clickable), but is in
   fact disabled — clicking does nothing, confusing the user. Additionally, Save
   and Cancel are visually different sizes.

3. **DESIGN.md is being retired.** The CLAUDE.md constraint that makes
   `.claude/DESIGN.md` the sole basis for all UI work (and its derived principles)
   should be removed. The theme/YAML colour rule must be kept and strengthened.

## Root Causes

1. **Scroll reset** — `WorkspaceDetailView.swift:50` routes tab content through a
   `Group { switch tab.kind }` with `.id(tabID)`. Switching the active tab removes
   `FileBrowserTabContentView` from the view tree and rebuilds it on return. The
   `ScrollView` in `FileTreePanelView.swift:17` holds its scroll offset as ephemeral
   view state, so the rebuild resets it to zero. The `FileBrowserTabController`
   (tree data, expanded dirs, selection) persists — only the scroll offset has no
   owner.

2. **Misleading Save button** — `PillButtonStyle` (`ButtonStyles.swift:13`) does not
   read `@Environment(\.isEnabled)`, so `.disabled(!hasChanges)` only blocks the
   action; the accent fill stays at full strength. Cancel uses `UtilityButtonStyle`
   (padding 8/15, `Radius.sm`) while Save uses `PillButtonStyle` (padding 11/22, full
   pill), so the two are inherently different sizes.

## Design

### 1. File tree scroll memory (in-memory, session only)

- Add a plain stored property to `FileBrowserTabController`:
  ```swift
  /// Last known vertical scroll offset of the file tree. Cached in-memory so the
  /// tree restores its position when the tab is re-mounted (e.g. after switching
  /// to a terminal tab and back). Not @Published — it must not trigger re-render.
  var treeScrollOffset: CGFloat = 0
  ```
- In `FileTreePanelView`, the tree `ScrollView`:
  - reads the live offset via `.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action:` and writes it to `controller.treeScrollOffset`;
  - on mount, restores the offset through a `ScrollPosition` binding initialised from `controller.treeScrollOffset` (macOS 15+ API; the deployment target satisfies this).
- **Scope is intentionally in-memory only.** Restarting the app returns to the top.
  Nothing is written to `FileBrowserTabState` / disk.

### 2. Settings footer buttons (keep draft + Save, fixed)

- **Disabled state must be visible.** `PillButtonStyle` and `UtilityButtonStyle`
  read `@Environment(\.isEnabled)`; when disabled they drop to ~0.4 opacity and skip
  the press-scale animation. This fixes the misleading Save button and benefits every
  other sheet that uses these styles.
- **Equal-sized buttons.** The settings footer renders Save and Cancel at the same
  utility dimensions (same padding, same `Radius.sm`). `UtilityButtonStyle` gains a
  filled variant (an optional accent fill colour):
  - Save = accent fill + `onAccent` text;
  - Cancel = transparent fill + hairline border.
  Same width/height; hierarchy comes from the fill, not the size.
- `hasChanges` logic (`draft != originalSettings`) is correct and stays unchanged.
  This is a visual-only fix.

### 3. CLAUDE.md constraint changes

- **Remove** the constraint making `.claude/DESIGN.md` the sole basis for UI work,
  and the derived "core principles" bullet (single accent, two button grammars,
  fixed non-colour tokens, etc.).
- **Keep and strengthen** the theme/YAML rule: every visible colour goes through a
  theme token (`~/.treemux/themes/*.yaml`, driven by `Theme` / `ThemeLoader` /
  `ThemeManager`); themes drive both the App UI and Ghostty terminal colours;
  hardcoding colours is forbidden.

## Components Touched

- `Treemux/UI/FileBrowser/FileBrowserTabController.swift` — add `treeScrollOffset`.
- `Treemux/UI/FileBrowser/FileTreePanelView.swift` — read/restore scroll offset.
- `Treemux/UI/Components/ButtonStyles.swift` — disabled dimming; filled utility variant.
- `Treemux/UI/Settings/SettingsSheet.swift` — footer uses equal-sized utility buttons.
- `.claude/CLAUDE.md` — retire DESIGN.md governance; keep/strengthen theme YAML rule.

## Out of Scope

- Switching settings to live-apply (System Settings style) — explicitly rejected;
  draft + Save model is kept.
- Persisting scroll position across app restarts.
- Any unrelated refactor of the file tree or settings forms.

## i18n

No new user-visible strings are introduced. Existing Save / Cancel labels already
have zh-Hans entries in `Localizable.xcstrings`.

## Manual Verification

1. Scroll the file tree down, switch to a terminal tab, switch back — the tree stays
   at the same scroll position.
2. Open Settings without changing anything — the Save button appears greyed/disabled
   and clearly non-clickable; clicking it does nothing (as expected).
3. Change a setting — Save lights up to accent fill and saves on click.
4. Save and Cancel are the same width and height.
