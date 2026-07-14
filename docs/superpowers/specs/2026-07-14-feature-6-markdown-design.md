# Feature 6 — Markdown: Source Highlighting + Split Sync-Scroll + Selectable Render

Date: 2026-07-14
Batch: B–H (markdown subsystem), requirement (6)
Status: Design approved

## Goal

Three markdown improvements to the file-browser document viewer:

1. **Source highlighting** — the markdown SOURCE editor currently renders flat
   monochrome; make headings, bold, italic, code, links, and list/quote markers
   visibly styled.
2. **Split sync-scroll** — in Split mode the source and rendered panes scroll
   independently; make them scroll together (proportionally).
3. **Selectable rendered text** — the rendered pane's text is not selectable;
   make it selectable/copyable.

## Investigation Summary (why source highlighting is currently flat)

- The source editor is `CodeEditSourceEditor.SourceEditor`. For `.md` files it
  is given `language: .markdown`, and `EditorHighlightPolicy.shouldHighlight`
  allows it — so tree-sitter markdown highlighting DOES run.
- The bundled `tree-sitter-markdown` grammar captures the right nodes
  (`@text.title`, `@text.strong`, `@text.emphasis`, `@text.literal`,
  `@text.uri`, …).
- **Root cause:** `CodeEditSourceEditor`'s `CaptureName.fromString(_:)` enum has
  NO markdown cases — every markdown capture (`text.title`, `text.strong`, …)
  hits `default → nil` and is dropped before it reaches the theme. So the theme
  never sees a markdown capture and everything renders as plain `text`. This is
  a hard limitation of the pinned library version; tuning `EditorTheme` colors
  alone cannot fix it.
- **No drop-in off-the-shelf fix exists** (no native markdown theming in this
  version; no community markdown `HighlightProviding` provider). Upgrading the
  editor is uncertain and risks the project's BatchZero fork of
  `CodeEditTextView`; forking `CodeEditSourceEditor` adds a maintenance burden.
- **Clean extension point (chosen):** the SwiftUI `SourceEditor` init accepts
  `highlightProviders: [any HighlightProviding]? = nil` (the same init our
  `CodeEditorRepresentable` already uses). A custom `HighlightProviding` can be
  injected without forking. Its returned `HighlightRange.capture` must be an
  existing `CaptureName`, so markdown elements are MAPPED onto existing capture
  slots, styled by a markdown-tuned `EditorTheme`.

`EditorTheme.mapCapture` (verified) routes CaptureNames to styleable slots
(`keywords`, `types`, `comments`, `strings`, `variables`, `numbers`,
`attributes`, `text`), and each slot's `Attribute` carries `color` + `bold` +
`italic` (font traits are applied). ~7 distinct slots — enough for markdown's
element set.

## Requirements

### Part 1 — Markdown source highlighting
1. In the `.md` source editor, these elements are visibly styled: ATX/setext
   headings, `**strong**`, `*emphasis*`/`_emphasis_`, inline `` `code` ``,
   fenced code blocks, `[text](url)` links (and bare `<uri>`), unordered
   (`-`/`*`/`+`) and ordered (`1.`) list markers, and `>` blockquote markers.
2. Bold renders bold, emphasis renders italic; headings are bold + accented.
3. Colors come from the active app theme (theme tokens) — no hardcoded hex.
4. Highlighting updates as the buffer is edited (uses the editor's incremental
   highlight pipeline).
5. Non-markdown files are unaffected (they keep tree-sitter highlighting).

### Part 2 — Split synchronized scrolling
1. In Split mode, scrolling either pane scrolls the other proportionally
   (fraction = `offsetY / max(1, contentH − viewportH)`).
2. No feedback oscillation (the pane being driven does not echo back).
3. Source-only and Render-only modes are unaffected.

### Part 3 — Selectable rendered text
1. Text in the rendered markdown pane can be selected and copied.

## Design

### Part 1 — `MarkdownHighlightProvider` + markdown-tuned theme

New `MarkdownHighlightProvider: HighlightProviding`
(`Treemux/UI/FileBrowser/MarkdownHighlightProvider.swift`):

- Wraps a pure scanner `MarkdownHighlightScanner` (separate type/file, unit-
  testable) that takes a `String` (or an `NSString` + range) and returns
  `[(range: NSRange, element: MarkdownElement)]`.
- `queryHighlightsFor(textView:range:completion:)` scans the queried range's
  lines and returns `[HighlightRange]`, mapping each `MarkdownElement` to a
  `CaptureName` slot (below). `setUp`/`applyEdit`/`willApplyEdit` are minimal:
  on edit, invalidate the edited line range (return the affected `IndexSet`) so
  the editor re-queries — line-oriented, so re-scanning the touched lines is
  cheap and correct.

`MarkdownElement` → `CaptureName` slot → tuned `EditorTheme` field:

| Element | CaptureName emitted | Theme slot | Tuned style |
|---|---|---|---|
| Heading (`#`, setext) | `.keyword` | `keywords` | bold, accent color |
| Strong (`**`/`__`) | `.type` | `types` | bold, primary color |
| Emphasis (`*`/`_`) | `.comment` | `comments` | italic, primary color |
| Inline + fenced code | `.string` | `strings` | code color (mono already) |
| Link / URI | `.variable` | `variables` | link/accent color, (underline optional) |
| List marker (`-`/`*`/`+`/`1.`) | `.number` | `numbers` | muted/secondary color |
| Blockquote marker (`>`) | `.typeAlternate` | `attributes` | muted/secondary color |

- A markdown-tuned `EditorTheme` variant is built (in `TreemuxEditorTheme`) so
  the reused slots carry markdown-appropriate color/bold/italic derived from the
  active theme (`accent`, `textPrimary`, `textSecondary`, a code color). The
  `CodeEditorRepresentable` selects the markdown-tuned theme + injects
  `[MarkdownHighlightProvider()]` as `highlightProviders` only when the file is
  markdown; other files keep the existing code theme + default tree-sitter
  provider (pass `nil`).
- The scanner is pragmatic (line + inline regex/scan), not a full CommonMark
  parser — adequate for source highlighting and keeps it testable and
  incremental. Fenced code spans multiple lines: the provider tracks fence
  state across the queried range.

### Part 2 — Split synchronized scrolling

- `DocumentViewerView` owns a small `ScrollSync` observable: a current
  `fraction: CGFloat` and a `driver` enum (`.none/.source/.render`) re-entrancy
  guard. Only wired in `.split` mode.
- Source side: a new `ScrollSyncCoordinator: TextViewCoordinator` (mirrors
  `DiffStripeCoordinator`'s access pattern) grabs `controller.scrollView` in
  `prepareCoordinator`, observes the contentView `NSView.boundsDidChangeNotification`,
  computes `fraction = offsetY / max(1, docH − viewportH)`, and — when it is the
  driver — publishes it. When the render side is the driver, it sets the editor
  scroll via `scrollView.contentView.scroll(to:)` + `reflectScrolledClipView`.
- Render side: `RenderedMarkdownView` (in split) uses macOS 15
  `ScrollPosition` + `.onScrollGeometryChange(for: CGFloat.self)` to read its
  fraction and `scrollTo(y:)` to be driven, wired to the same `ScrollSync`.
- Re-entrancy: the side the user is actively scrolling sets `driver`; the driven
  side applies the fraction without re-publishing (guarded by `driver`),
  clearing back to `.none` shortly after.
- Fraction-based (proportional) sync only — NOT line-anchored mapping.

### Part 3 — Selectable rendered text

- Add `.textSelection(.enabled)` to the `Markdown(content)` view in
  `RenderedMarkdownView` (MarkdownUI honors SwiftUI text selection). No other
  change.

### Theme / i18n

- All colors from theme tokens (markdown-tuned `EditorTheme` derives from the
  active theme). No hardcoded hex.
- No new user-visible strings → no `Localizable.xcstrings` change.

## Testing

**Unit tests** — new `MarkdownHighlightScannerTests` (pure scanner):

- Heading `# H1` / `## H2` / setext → heading range covers the line/text.
- `**bold**` → strong range over the inner (and/or full) span; `*it*`/`_it_` →
  emphasis; not misfiring on `a*b*c` vs intraword per chosen rule (pick one and
  assert it).
- Inline `` `code` `` and a fenced ```` ``` ```` block → code element over the
  right ranges (fence state across lines).
- `[text](url)` and `<https://x>` → link element over the right span.
- List markers `-`, `*`, `+`, `1.` at line start → marker element; blockquote
  `>` → quote element.
- Plain paragraph text → no elements (stays default `text`).
- Element → CaptureName mapping is asserted (a small pure mapping function
  `captureName(for: MarkdownElement)` is tested against the table above).

**Manual smoke (GUI)** — behavior tied to the real editor/scroll/selection:

- Open a `.md` file: headings/bold/italic/code/links/list markers are visibly
  styled in the source pane; editing updates highlighting live; a non-`.md`
  code file still highlights normally.
- Split mode: scrolling the source pane scrolls the render pane proportionally
  and vice versa, with no jitter; Source-only / Render-only unaffected.
- Rendered pane: text can be selected and ⌘C copies it.
- Theme switch: markdown source colors follow the new theme.

## Acceptance Criteria

- Markdown source shows styled headings/bold/italic/code/links/markers, live on
  edit, theme-driven; non-markdown unaffected.
- Split panes scroll in sync (proportional), no oscillation.
- Rendered text is selectable and copyable.
- `MarkdownHighlightScanner` unit tests pass; full suite green.

## Out of Scope

- Line-anchored (element-precise) scroll mapping — proportional only.
- "Format markdown on save" / prettier-style normalization.
- Rich rendered-side interactions (TOC, in-doc anchor nav).
- Upgrading or forking `CodeEditSourceEditor`.
- HTML documents' source highlighting (this feature is markdown-scoped;
  HTML keeps its current behavior).
