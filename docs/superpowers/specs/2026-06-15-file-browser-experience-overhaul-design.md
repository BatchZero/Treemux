# File Browser Experience Overhaul — Design

**Date:** 2026-06-15
**Author:** 卡皮巴拉 (via brainstorming with Claude)
**Status:** In progress (phased; one plan per phase, except P1 which splits into P1a/P1b)

**Progress (2026-06-15):** **P1a** (design-system foundation) ✅ and **P1b** (visual surfaces — features 0/1/2/5/7: hover button, Files/Shell tab grouping + phosphor underline, colorful file-tree icons, density sizing) ✅ implemented (TDD, two-stage subagent review, 273/273 tests), merged into this branch. **P2** (editor smoothness — feature 3) ✅ implemented (TDD, two-stage subagent review): (1) dropped the per-render `FileManager.attributesOfItem` syscall — highlight gating now uses the in-memory buffer size via the pure `EditorHighlightPolicy`; (2) removed the main-thread completion `DispatchSemaphore` — `completionOnCursorMove` now reads a lock-free `WordIndexSnapshotStore` mirror of the `BufferWordIndex` actor; (3) made `saveCurrentFile()` non-blocking — git status/diff refresh now runs in a detached `Task`. The spec's 4th symptom (sub-tab switch rebuild) was **already resolved** by P1's `FileViewerPanelView` ZStack keep-alive (no re-init on switch). Secondary knobs audited and intentionally left as-is: the 300 ms index debounce gates only re-indexing (off the typing/read path, which is now lock-free), and the 2 MB tree-sitter limit is unchanged. **Pending manual validation:** before/after frame timing on a large CJK source file (Instruments). **Remaining: P3** (remote acceleration — feature 4), **P4** (markdown/HTML rendering — feature 6). Tracked follow-up: light-theme variants for the dark-tuned Phosphor tokens.

> **Reading note:** sections below are ordered by implementation grouping, not feature number. Each
> heading is tagged with its phase (`[P1a]`/`[P1b]`/`[P2]`/`[P3]`/`[P4]`). See the Phasing table at the end.

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
- Full **App Sandbox** adoption is *not* in scope (see §6 scope note); only the hardened WebView is.

---

## 0. Design System — "Phosphor Instrument" [P1a]

A shared token layer that every visual feature (1/2/5/6/7) derives from. Implemented as an
extension on the existing theme (`Treemux/UI/Theme/ThemeManager.swift`, `Treemux/Domain/ThemeDefinition.swift`)
plus a new `FileTreeSettings` group in `Treemux/Domain/AppSettings.swift` — **distinct** from the existing
top-level `appearance: String` field (AppSettings.swift:15, the system/dark/light selector), which stays.

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
| type accents | swift `#E8865A`, json `#E2A55C`, image `#5FC98A` (examples) | per-file-type tint for **single-color baseline glyphs only** |

The full per-type accent map is defined in `FileIconCatalog` at plan time; the table shows examples.

**Typography** — the signature aesthetic decision:
- **Data layer** (tab titles, file names, file-tree rows, group eyebrows) → monospace.
  **Binding default for v1: reuse the existing terminal font setting; no new bundled font** (revisit later).
- **Chrome** (menus, settings, dialogs, sheets) → `SF Pro` (system).

**Signature element** — the **phosphor underline**: the selected tab's bottom edge glows in its
kind's accent (green for shell, azure for files), reusing the existing CodeEdit-style bottom stripe.

**i18n:** every new user-visible string uses `LocalizedStringKey` and gets a `zh-Hans` entry in
`Treemux/Localizable.xcstrings` (settings labels, density options, view-mode segmented control, etc.).

---

## 1. Hover-Reveal Worktree File-Browser Button — *Small* [P1b]

**Current:** `Treemux/UI/Sidebar/SidebarNodeRow.swift` renders a file-browser button in every
workspace **and** worktree row. It is always present, fading via
`.foregroundStyle(theme.textSecondary.opacity(isHovered ? 1.0 : 0.5))` on the Image
(workspace button ~lines 90–101, opacity at :97; worktree button ~lines 151–161, opacity at :157),
with `@State isHovered` already wired via `.onHover`.

**Change:**
- **Worktree row only:** change the existing opacity expression to `isHovered ? 1.0 : 0` (or wrap the
  button in `.opacity`) so it is fully hidden until the row is hovered. A 0-opacity button stays
  hit-testable — decide at plan time whether to also gate it (`.allowsHitTesting(isHovered)`).
- **Workspace (project) row:** unchanged (button stays visible).

Keep layout stable (reserve the button's width so rows don't reflow on hover). No new dependencies.

---

## 2 + 7. File-Tree Icons + Row Sizing — *Medium* [P1b]

These ship together (both rewrite file-tree row rendering in `Treemux/UI/FileBrowser/FileTreePanelView.swift`).

### 2 — Icons

**Current:** `FileTreePanelView.swift:213-226` hard-codes a handful of SF Symbols keyed off
`FileNode.kind` + `FileTypeClassifier.classifyByName`: `folder`/`folder.fill` (directory),
`arrow.up.right.square` (symlink), `doc.text` (text), `photo` (image), `doc.richtext` (quickLook),
`doc` (binary/unknown). The new catalog must also cover **symlink + stateful-folder** glyphs.

**Target system (from license research):**
- **Baseline:** Material Design Icons / Pictogrammers **abstract subset** (Apache-2.0, zero trademark
  risk). Filter `meta.json` to exclude `tag == "Brand / Logo"` and `deprecated == true`. Gives rich
  abstract file + **stateful folder** glyphs (`folder`, `folder-open`, `folder-lock`, `folder-git`, …).
- **Colorful per-language layer:** **Material Icon Theme** (PKief) for per-language file icons
  (swift, ts, py, docker, …). MIT-licensed for source and original artwork, **but many
  language/framework glyphs are third-party brand logos — MIT conveys copyright, not trademark.**
  Apply the trademark-hygiene rule below per bundled glyph and verify per-glyph provenance before
  shipping. These colorful icons render **untinted** (the type-accent tint applies only to the
  single-color MDI baseline glyphs).
- **Explicitly avoid `vscode-icons`** (CC BY-SA copyleft on its non-branded art) and **Codicons**
  unless attributed (CC BY 4.0, not MIT).

**Integration:**
- Convert chosen SVGs → PDF, import into `Assets.xcassets` with **Single Scale + Preserve Vector Data**.
  Single-color glyphs → `renderingMode(.template)` + theme tint; multicolor (Material Icon Theme) → original.
- New `FileIconCatalog` (`Treemux/Domain/` or `Treemux/Services/FileBrowser/`): maps extension/basename →
  icon asset name, adapting the **MIT** VS Code theme JSON manifests. Bundle only the glyphs we actually
  map (target ~60, cap ~80).
- Add an in-app **Acknowledgements/Licenses** screen listing every MIT/Apache/CC notice. Note: the
  project already depends transitively on **CodeEditSymbols** (Codicons-derived, CC BY 4.0); if any of
  its glyphs ship in the binary, that attribution is already required, independent of this work.

**Trademark hygiene:** brand logos used only as in-tree file-type labels (nominative use); never on the
app icon, App Store screenshots, or marketing; never redrawn into derivatives.

### 7 — Row sizing & polish

- File names rendered in **monospace** (data-layer typography).
- Row height + font size read from `FileTreeSettings.treeDensity`:
  **Compact 28 / Comfortable 32 / Spacious 38** (default **Comfortable** — larger than the current
  ~24px row; confirm the exact current value at plan time).
  Settings panel (`Treemux/UI/Settings/SettingsSheet.swift`) gains a density picker.
- **Indent guides:** 1px `line` vertical rule per depth level.
- **Selected row:** `surface` background + 2.5px `files`-colored left marker.
- Remote project root shows a small **SSH host chip** (`⇅ host`).

---

## 5. Tab Distinction (file vs terminal) — *Small* [P1b]

**Current:** `Treemux/UI/Workspace/WorkspaceTabBarView.swift:120-123` only differs by a small SF Symbol
(`folder` vs `terminal`) + a dirty dot for file tabs. `WorkspaceTabKind` already distinguishes kinds; an
existing selected-tab bottom stripe lives at lines 173-179.

**Change (combines the user's A + D choices; shape unchanged):**
- Group tabs by kind into **`Files`** and **`Shell`** sections with tiny uppercase mono **eyebrow labels**
  and a vertical **divider** between groups.
- Selected-tab **phosphor underline** colored by kind (`files` azure / `shell` green) — reuses the existing
  bottom-stripe; **tab shape stays exactly as today** (fully rounded rect, `cornerRadius 6` per
  WorkspaceTabBarView.swift:172, no pill).
- Tab title in monospace; terminal tabs keep a `❯` prompt glyph (proposed flourish; confirm at plan time —
  not part of the confirmed A+D decision).

Tab ordering: grouping keeps **stable insertion order within each kind group** (binding default; this is the
single home for the within-kind ordering decision — the cross-kind drag case is the lone Open Question).

---

## 3. Editor Smoothness — Targeted Fixes — *Medium* [P2]

**Keep** `CodeEditSourceEditor` (0.15.2) + the BatchZero `CodeEditTextView` fork. The user reports jank in
**all four** dimensions (typing, open, save, tab switch). Diagnosed candidate hot spots (confirm with
Instruments during implementation):

| Symptom | Diagnosed cause | Fix |
|---------|-----------------|-----|
| Open slow / typing drops frames | `TextEditorView.swift:157` calls `FileManager.attributesOfItem` **synchronously on every body eval** (in `shouldHighlight`) | Cache file size at load time into `OpenFileState`; never stat on the render path |
| Typing drops frames | `CompletionPopover.swift:215-226` uses a **semaphore (50ms) blocking the main thread** for cursor-move completion | Make completion fully async; drop the semaphore fallback |
| Switching files/sub-tabs janky | Suspected full **SourceEditor re-init + re-highlight** on every sub-tab switch | Keep an editor instance + highlight state alive per open sub-tab; switch instead of rebuild |
| Save stutter | `FileBrowserTabController.swift:581-590` runs `refreshDiffForActive()` (:588) + `refreshGitStatus()` (:589) **serially after** the write before returning | Return from save immediately; run git/diff refresh off the main path |

Secondary: re-check the word-index debounce (`CompletionPopover` ~300ms) and tree-sitter highlight limit
(`TextEditorView` 2MB) for large/CJK files; raise/incrementalize only if profiling shows need.

**Validation:** before/after frame timing on a representative large + CJK file; manual feel check.

---

## 4. Remote Directory Acceleration — *Large* [P3]

**Current:** `RemoteFileBrowserDataSource` calls `SFTPService.listAllEntries(at:)` once **per folder
expand** — sequential, no prefetch, no cross-session cache (`FileBrowserTabController.swift:189-207`,
`childrenByPath` is in-session only). Each remote list is one SSH round-trip (`ls -lA` parse, or Citadel
`listDirectory` on the password path).

**New architecture (bulk + cache + background refresh):**

1. **`DirectoryTreeCache`** — on-disk, persistent, in App Support, keyed by `(host, normalizedPath)` with
   stored entry `mtime`. On project reopen, the tree is **rendered instantly from cache**.
2. **Bulk fetch** — add `listTree(root, maxDepth)` to `FileBrowserDataSource`.
   - Remote (system-SSH path): **one recursive command** returning many levels in a single round-trip.
     ⚠️ `find -printf` is GNU-only; BSD/macOS servers lack it. Pin a portable strategy at P3 plan time
     (e.g. `find … -exec stat …`, or recursive `ls -lAR` parse, branching on detected server OS).
   - Citadel password path (no arbitrary command exec): **parallel** per-directory listing instead of serial.
   - `maxDepth` default ~2–3 levels (balance payload vs round-trips), then lazy/background-fetch deeper.
3. **Background refresh + diff** — after showing cache, re-run the bulk fetch in the background and **diff →
   apply** changes to the live tree without blocking or collapsing the user's expansion state.
4. **Prefetch on expand** — expanding a folder kicks off a background fetch of its children's children.
5. Manual refresh (`FileTreePanelView.swift:39`) retained; it forces a full re-fetch + cache update.

**Edge cases:** symlink loops (depth cap + visited-set), permission-denied subtrees (skip, mark), very large
directories (cap entries shown + "load more"), stale cache after external changes (background refresh covers it;
no remote FSEvents available).

---

## 6. Markdown & HTML Rendering — *Large* [P4]

**Markdown engine:** **MarkdownUI** (gonzalezreal, MIT). Decisive reason: it has **no WebView / no JS / no
HTML execution path**, so a malicious remote `.md` cannot run code or phone home. Dependencies all permissive
(MarkdownUI MIT, NetworkImage MIT, swift-cmark BSD-2).
- **Mandatory hardening:** install a custom `.markdownImageProvider` that **blocks all remote (non-`data:`)
  image URLs** — only `data:` URIs render (the default provider silently fetches arbitrary URLs — SSRF/
  tracking risk for untrusted docs; explicit user opt-in is a possible future addition);
  sanitize link schemes via `OpenURLAction` (allow `http`/`https`/`mailto`; block `javascript:`/`file:`/custom).
- Add a `CodeSyntaxHighlighter` (Splash or reuse tree-sitter) for code blocks.
- Note: MarkdownUI is in maintenance mode (2.x stable); acceptable now, re-evaluate successor later.

**HTML engine:** hardened, sandboxed **WKWebView** (free system framework). **Two explicit code paths:**
- **Untrusted remote (SSH/SFTP):** `WKWebpagePreferences.allowsContentJavaScript = false`;
  load via `loadHTMLString` with **`baseURL = about:blank`** (never `nil`/`file:`); attach a
  `WKContentRuleList` blocking **all network egress from the rendering WebView**; inject strict CSP
  (`default-src 'none'; img-src data:; style-src 'unsafe-inline'`); cancel in-view navigations
  (route external links to the system browser). (Note: `data:` images can embed SVG, but
  `allowsContentJavaScript=false` + `default-src 'none'` block script execution; restrict to raster if
  raw SVG ever becomes a concern.)
- **Trusted local:** may relax (e.g. `loadFileURL` scoped to the file's own folder) if desired.
- Markdown-derived HTML, when needed, feeds the **same** locked-down WKWebView (one hardened surface).

**View layer** (`Treemux/UI/FileBrowser/FileViewerPanelView.swift`, `.text` branch for md/html):
- A **segmented control: Source / Split / Render** in the viewer toolbar.
- `.md` first open → **Split**; thereafter **remember the last-used mode per file**, persisted in a
  **durable store keyed by file path** so it survives app relaunch (extend `FileSubTabRecord` persistence;
  `OpenFileState` alone is session-only).
- `.html` default → **Source** (toggle to Render).
- **Live preview** while typing, debounced; editing always happens in the Source side.
- New components: `RenderedMarkdownView` and `HardenedWebView`.

**Scope note:** P4 ships the hardened WebView only. Full **App Sandbox** adoption is a separate, app-wide
effort (out of scope). `com.apple.security.network.client` is already required by the SSH/SFTP transport, so
it is not a new attack surface (it also covers the offline local-HTML-load quirk, FB6993802).

---

## Licensing / Security Watch-List

- MIT/Apache/CC grant **copyright, not trademark** — keep brand logos to in-tree functional labeling only.
- **vscode-icons** = CC BY-SA copyleft (avoid); **Codicons** = CC BY 4.0 (attribution, not MIT). The existing
  **CodeEditSymbols** dependency is Codicons-derived — its attribution is already owed if its glyphs ship.
- MDI has announced brand-logo removal in an upcoming major (**verify the exact version at integration**); the
  load-bearing mitigation is pinning the version and shipping the filtered abstract subset.
- MarkdownUI's **default ImageProvider fetches remote images** — overriding it is **mandatory**, not optional.
- WKWebView is **insecure by default** (JS on; `nil`/`file:` baseURL leaks local files) — the `baseURL`
  choice is the #1 footgun.
- Never use `NSAttributedString(html:)` for untrusted content (WebKit-backed, fetches remote subresources).
- Ship an in-app **Acknowledgements/Licenses** screen for every bundled asset/library.

---

## Implementation Phasing (one branch/worktree per phase; one plan per phase, except P1 which splits)

P1 is too large for a single plan (it bundles the cross-cutting token/typography foundation, the SVG→PDF
asset pipeline, the new `FileIconCatalog`, and four UI surfaces), so it splits into two sub-plans.

| Phase | Features | Size | Notes |
|-------|----------|------|-------|
| **P1a — Design-system foundation** | 0 | S–M | Tokens, data-layer typography, `FileTreeSettings`, phosphor-underline primitive. Mono-font default decided first (reuse terminal font). |
| **P1b — Visual surfaces** | 1, 5, 2, 7 | M | Hover button, tab grouping, file-tree icons (asset pipeline + `FileIconCatalog`), row density. Builds on P1a. |
| **P2 — Editor smoothness** | 3 | M | Independent; profile-driven |
| **P3 — Remote acceleration** | 4 | L | Largest; cache + bulk + background refresh |
| **P4 — Rendering** | 6 | L | Depends on P1a style tokens |

Each phase: branch under `.worktrees/<branch-name>/`, build, then the run command per CLAUDE.md
(`rm -rf ~/.treemux-debug/ && open .../Treemux-<id>/.../Debug/Treemux.app`).

## Open Questions (resolve at plan time, not blocking)

- `listTree` entry-count cap for very large remote directories (the `maxDepth` default and the portable
  remote-command strategy are already decided inline in §4; this is only the per-directory entry cap).
- Splash vs tree-sitter for markdown code-block highlighting.
- Whether tab grouping changes drag-reorder semantics **across** kinds (within-kind order is decided in §5).

*(Resolved and moved inline: bundled mono font → reuse terminal font, §0; tab within-kind ordering → stable
insertion order, §5.)*
