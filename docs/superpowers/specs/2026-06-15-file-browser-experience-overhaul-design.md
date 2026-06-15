# File Browser Experience Overhaul — Design

**Date:** 2026-06-15
**Author:** 卡皮巴拉 (via brainstorming with Claude)
**Status:** Approved for implementation (phased; one plan per phase)

## Goal

Seven coupled improvements to Treemux's file-browser / sidebar experience, unified under a
single visual direction ("Phosphor Instrument"):

1. **Hover-reveal** the worktree file-browser button (project rows stay as-is).
2. **Nicer file-tree icons** — a license-clean icon system, colorful per file type.
3. **Smoother file edit / save** — precise fixes to the existing CodeEditSourceEditor stack (no engine swap).
4. **Faster remote directory browsing** — bulk fetch + on-disk cache + background refresh.
5. **Visually distinct** file-browser vs terminal tabs.
6. **Markdown & HTML rendering** — native SwiftUI markdown + hardened sandboxed WKWebView for HTML.
7. **Larger, adjustable** file-tree rows (size as a setting).

Sole user is the project maintainer. The app is **commercially distributed** (DMG/Sparkle), so
third-party asset licensing and untrusted-remote-content security are first-class constraints.

## Non-Goals

- No replacement of the CodeEditSourceEditor engine (feature 3 is targeted fixes only).
- No redesign of the project list's existing custom icon system (`SidebarIcon`/`SidebarIconCatalog`);
  this overhaul touches the **file tree** icons. The same icon catalog *may* be reused later, out of scope here.
- No new remote transport; we reuse the existing `SFTPService` (system SSH + Citadel fallback).
- Markdown/HTML rendering is **view-only** for HTML; markdown remains editable via its source view.

---

## 0. Design System — "Phosphor Instrument"

A shared token layer that every visual feature (1/2/5/6/7) derives from. Implemented as an
extension on the existing theme (`Treemux/UI/Theme/ThemeManager.swift`, `Treemux/Domain/ThemeDefinition.swift`)
plus a new `AppearanceSettings` group in `Treemux/Domain/AppSettings.swift`.

**Color tokens**

| Token | Hex | Role |
|-------|-----|------|
| `ink` | `#13161D` | app base (blue-charcoal, not pure black) |
| `panel` | `#191D26` | sidebar / tree / tab-bar background |
| `surface` | `#232936` | active tab, hover, selected row |
| `line` | `#2C333F` | hairlines, dividers, indent guides |
| `text` / `muted` / `faint` | `#D7DCE4` / `#7C8694` / `#525B69` | text ramp |
| `shell` | `#54D38B` | terminal/shell semantic accent (phosphor green) |
| `files` | `#5BA6F2` | file semantic accent (azure) |
| type accents | swift `#E8865A`, json `#E2A55C`, image `#5FC98A`, … | per-file-type icon tint |

**Typography** — the signature aesthetic decision:
- **Data layer** (tab titles, file names, file-tree rows, group eyebrows) → monospace
  (`JetBrains Mono` / `SF Mono` fallback; ship a bundled mono or reuse the terminal font).
- **Chrome** (menus, settings, dialogs, sheets) → `SF Pro` (system).

**Signature element** — the **phosphor underline**: the selected tab's bottom edge glows in its
kind's accent (green for shell, azure for files), reusing the existing CodeEdit-style bottom stripe.

**i18n:** every new user-visible string uses `LocalizedStringKey` and gets a `zh-Hans` entry in
`Treemux/Localizable.xcstrings` (settings labels, density options, view-mode segmented control, etc.).

---

## 1. Hover-Reveal Worktree File-Browser Button — *Small*

**Current:** `Treemux/UI/Sidebar/SidebarNodeRow.swift` renders a file-browser button in every
workspace **and** worktree row; it is always present, fading `opacity 0.5 → 1.0` on row hover
(workspace row ~line 90–101; worktree row ~line 157), with `@State isHovered` already wired via `.onHover`.

**Change:**
- **Worktree row only:** button `opacity(isHovered ? 1 : 0)` — fully hidden until the row is hovered.
- **Workspace (project) row:** unchanged (button stays visible).

Keep layout stable (reserve the button's width so rows don't reflow on hover). No new dependencies.

---

## 2 + 7. File-Tree Icons + Row Sizing — *Medium*

These ship together (both rewrite file-tree row rendering in `Treemux/UI/FileBrowser/FileTreePanelView.swift`).

### 2 — Icons

**Current:** `FileTreePanelView.swift:213-226` hard-codes a handful of SF Symbols
(`folder`/`folder.fill`, `doc.text`, `photo`, `doc`) keyed off `FileNode.kind` + `FileTypeClassifier`.

**Target system (from license research):**
- **Baseline:** Material Design Icons / Pictogrammers **abstract subset** (Apache-2.0, zero trademark
  risk). Filter `meta.json` to exclude `tag == "Brand / Logo"` and `deprecated == true`. Gives rich
  abstract file + **stateful folder** glyphs (`folder`, `folder-open`, `folder-lock`, `folder-git`, …).
- **Colorful per-language layer:** **Material Icon Theme** (PKief, full MIT incl. artwork) for
  per-language file icons (swift, ts, py, docker, …), tinted per the type-accent palette.
- **Explicitly avoid `vscode-icons`** (CC BY-SA copyleft on its non-branded art) and **Codicons**
  unless attributed (CC BY 4.0, not MIT).

**Integration:**
- Convert chosen SVGs → PDF, import into `Assets.xcassets` with **Single Scale + Preserve Vector Data**.
  Single-color glyphs → `renderingMode(.template)` + theme tint; multicolor (Material Icon Theme) → original.
- New `FileIconCatalog` (`Treemux/Domain/` or `Treemux/Services/FileBrowser/`): maps extension/basename →
  icon asset name, adapting the **MIT** VS Code theme JSON manifests. Ship **only the ~40–80 glyphs we map.**
- Bundle only what we map; add an in-app **Acknowledgements/Licenses** screen listing every
  MIT/Apache/CC notice.

**Trademark hygiene:** brand logos used only as in-tree file-type labels (nominative use); never on the
app icon, App Store screenshots, or marketing; never redrawn into derivatives.

### 7 — Row sizing & polish

- File names rendered in **monospace** (data-layer typography).
- Row height + font size read from `AppearanceSettings.treeDensity`:
  **Compact 28 / Comfortable 32 / Spacious 38** (default **Comfortable** — larger than today).
  Settings panel (`Treemux/UI/Settings/SettingsSheet.swift`) gains a density picker.
- **Indent guides:** 1px `line` vertical rule per depth level.
- **Selected row:** `surface` background + 2.5px `files`-colored left marker.
- Remote project root shows a small **SSH host chip** (`⇅ host`).

---

## 5. Tab Distinction (file vs terminal) — *Small*

**Current:** `Treemux/UI/Workspace/WorkspaceTabBarView.swift:120-123` only differs by a small SF Symbol
(`folder` vs `terminal`) + a dirty dot for file tabs. `WorkspaceTabKind` already distinguishes kinds.

**Change (combines the user's A + D choices; shape unchanged):**
- Group tabs by kind into **`Files`** and **`Shell`** sections with tiny uppercase mono **eyebrow labels**
  and a vertical **divider** between groups.
- Selected-tab **phosphor underline** colored by kind (`files` azure / `shell` green) — reuses the existing
  bottom-stripe; **tab shape stays exactly as today** (rounded-top, no pill).
- Tab title in monospace; terminal tabs keep a `❯` prompt glyph.

Open question for implementation: whether grouping reorders tabs or keeps insertion order within groups —
default to **stable insertion order within each kind group**.

---

## 3. Editor Smoothness — Targeted Fixes — *Medium*

**Keep** `CodeEditSourceEditor` (0.15.2) + the BatchZero `CodeEditTextView` fork. The user reports jank in
**all four** dimensions (typing, open, save, tab switch). Diagnosed candidate hot spots (confirm with
Instruments during implementation):

| Symptom | Diagnosed cause | Fix |
|---------|-----------------|-----|
| Open slow / typing drops frames | `TextEditorView.swift:157` calls `FileManager.attributesOfItem` **synchronously on every body eval** (in `shouldHighlight`) | Cache file size at load time into `OpenFileState`; never stat on the render path |
| Typing drops frames | `CompletionPopover.swift:215-226` uses a **semaphore (50ms) blocking the main thread** for cursor-move completion | Make completion fully async; drop the semaphore fallback |
| Switching files/sub-tabs janky | Suspected full **SourceEditor re-init + re-highlight** on every sub-tab switch | Keep an editor instance + highlight state alive per open sub-tab; switch instead of rebuild |
| Save stutter | `FileBrowserTabController.swift:581-590` runs `refreshDiff` + `refreshGitStatus` **serially after** the write before returning | Return from save immediately; run git/diff refresh off the main path |

Secondary: re-check the word-index debounce (`CompletionPopover` ~300ms) and tree-sitter highlight limit
(`TextEditorView` 2MB) for large/CJK files; raise/incrementalize only if profiling shows need.

**Validation:** before/after frame timing on a representative large + CJK file; manual feel check.

---

## 4. Remote Directory Acceleration — *Large*

**Current:** `RemoteFileBrowserDataSource` calls `SFTPService.listAllEntries(at:)` once **per folder
expand** — sequential, no prefetch, no cross-session cache (`FileBrowserTabController.swift:189-207`,
`childrenByPath` is in-session only). Each remote list is one SSH round-trip (`ls -lA` parse, or Citadel
`listDirectory` on the password path).

**New architecture (bulk + cache + background refresh):**

1. **`DirectoryTreeCache`** — on-disk, persistent, in App Support, keyed by `(host, normalizedPath)` with
   stored entry `mtime`. On project reopen, the tree is **rendered instantly from cache**.
2. **Bulk fetch** — add `listTree(root, maxDepth)` to `FileBrowserDataSource`.
   - Remote (system-SSH path): **one recursive command** (e.g. `find <root> -maxdepth N -printf ...`,
     macOS-server fallback considered) returning many levels in a single round-trip.
   - Citadel password path (no arbitrary command exec): **parallel** per-directory listing instead of serial.
   - Pick `maxDepth` to balance payload vs round-trips (default ~2–3 levels), then lazy/background-fetch deeper.
3. **Background refresh + diff** — after showing cache, re-run the bulk fetch in the background and **diff →
   apply** changes to the live tree without blocking or collapsing the user's expansion state.
4. **Prefetch on expand** — expanding a folder kicks off a background fetch of its children's children.
5. Manual refresh (`FileTreePanelView.swift:39`) retained; it forces a full re-fetch + cache update.

**Edge cases:** symlink loops (depth cap + visited-set), permission-denied subtrees (skip, mark), very large
directories (cap entries shown + "load more"), stale cache after external changes (background refresh covers it;
no remote FSEvents available).

---

## 6. Markdown & HTML Rendering — *Large*

**Markdown engine:** **MarkdownUI** (gonzalezreal, MIT). Decisive reason: it has **no WebView / no JS / no
HTML execution path**, so a malicious remote `.md` cannot run code or phone home. Dependencies all permissive
(MarkdownUI MIT, NetworkImage MIT, swift-cmark BSD-2).
- **Mandatory hardening:** install a custom `.markdownImageProvider` that **blocks/!routes remote image
  fetches** (the default provider silently fetches arbitrary URLs — SSRF/tracking risk for untrusted docs);
  sanitize link schemes via `OpenURLAction` (allow `http`/`https`/`mailto`; block `javascript:`/`file:`/custom).
- Add a `CodeSyntaxHighlighter` (Splash or reuse tree-sitter) for code blocks.
- Note: MarkdownUI is in maintenance mode (2.x stable); acceptable now, re-evaluate successor later.

**HTML engine:** hardened, sandboxed **WKWebView** (free system framework). **Two explicit code paths:**
- **Untrusted remote (SSH/SFTP):** `WKWebpagePreferences.allowsContentJavaScript = false`;
  load via `loadHTMLString` with **`baseURL = about:blank`** (never `nil`/`file:`); attach a
  `WKContentRuleList` blocking **all** network egress; inject strict CSP
  (`default-src 'none'; img-src data:; style-src 'unsafe-inline'`); cancel in-view navigations
  (route external links to the system browser).
- **Trusted local:** may relax (e.g. `loadFileURL` scoped to the file's own folder) if desired.
- Markdown-derived HTML, when needed, feeds the **same** locked-down WKWebView (one hardened surface).

**View layer** (`Treemux/UI/FileBrowser/FileViewerPanelView.swift`, `.text` branch for md/html):
- A **segmented control: Source / Split / Render** in the viewer toolbar.
- `.md` first open → **Split**; thereafter **remember the last-used mode per file** (persist in the
  file/sub-tab state, `FileSubTabRecord` / `OpenFileState`).
- `.html` default → **Source** (toggle to Render).
- **Live preview** while typing, debounced; editing always happens in the Source side.
- New components: `RenderedMarkdownView` and `HardenedWebView`.

**Run the whole app under the App Sandbox** (note: local HTML load historically needs
`com.apple.security.network.client` even offline — FB6993802).

---

## Licensing / Security Watch-List

- MIT/Apache/CC grant **copyright, not trademark** — keep brand logos to in-tree functional labeling only.
- **vscode-icons** = CC BY-SA copyleft (avoid); **Codicons** = CC BY 4.0 (attribution, not MIT).
- MDI v8 will delete brand logos — pin the version and ship the filtered abstract subset.
- MarkdownUI's **default ImageProvider fetches remote images** — overriding it is **mandatory**, not optional.
- WKWebView is **insecure by default** (JS on; `nil`/`file:` baseURL leaks local files) — the `baseURL`
  choice is the #1 footgun.
- Never use `NSAttributedString(html:)` for untrusted content (WebKit-backed, fetches remote subresources).
- Ship an in-app **Acknowledgements/Licenses** screen for every bundled asset/library.

---

## Implementation Phasing (one branch/worktree + one plan per phase)

| Phase | Features | Size | Notes |
|-------|----------|------|-------|
| **P1 — Design system + visuals** | 0, 1, 5, 2, 7 | M | Low risk, high visible payoff; foundation tokens first |
| **P2 — Editor smoothness** | 3 | M | Independent; profile-driven |
| **P3 — Remote acceleration** | 4 | L | Largest; cache + bulk + background refresh |
| **P4 — Rendering** | 6 | L | Depends on P1 style tokens |

Each phase: branch under `.worktrees/<branch-name>/`, build, then the run command per CLAUDE.md
(`rm -rf ~/.treemux-debug/ && open .../Treemux-<id>/.../Debug/Treemux.app`).

## Open Questions (resolve at plan time, not blocking)

- Exact bundled mono font (ship one vs reuse terminal font setting).
- `listTree` `maxDepth` default + payload cap for huge remote trees.
- Whether tab grouping affects drag-reorder semantics across kinds.
- Splash vs tree-sitter for markdown code-block highlighting.
