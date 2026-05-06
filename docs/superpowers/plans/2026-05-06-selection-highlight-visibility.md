# Selection Highlight Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make mouse-dragged, ⌘A, and shift-arrow text selection in the Treemux file viewer render with a clearly visible, VSCode-style background — without breaking the existing horizontal scrolling for unwrapped long lines.

**Architecture:** Single-file change in `Treemux/UI/FileBrowser/TextEditorView.swift`. (1) Add a `SelectionRectFixDelegate` that wraps the textView's `TextLayoutManagerDelegate` and overrides `textViewportSize()` so `wrapLinesWidth` stays non-negative even when `ScrollBehaviorCoordinator` has inflated `edgeInsets.right` for horizontal scroll. (2) As a quality improvement, switch the `EditorTheme.selection` construction to a direct sRGB-from-hex factory at alpha 0.45, matching VSCode dark+/light contrast.

**Tech Stack:** Swift 5.x, AppKit (`NSColor`, `NSRect`, `CGSize`), CodeEditSourceEditor 0.15.2 with CodeEditTextView main HEAD (commit `d7ac3f1`).

**Spec:** [`docs/superpowers/specs/2026-05-06-selection-highlight-visibility-design.md`](../specs/2026-05-06-selection-highlight-visibility-design.md)

**Testing strategy:** Manual visual verification only, per spec. The fix's behavior is "selection background draws at non-zero width over each selected line, in both built-in themes, with horizontal scroll still working for long lines." That's not unit-testable here without a snapshot harness; the spec author and reviewer (卡皮巴拉) opted for manual verification.

---

## Pre-flight

Per project rules (`/Users/yanu/Documents/code/Terminal/treemux/.claude/CLAUDE.md`), code changes must happen in a worktree under `.worktrees/<branch-name>/`. The execution skill (`superpowers:using-git-worktrees`) is responsible for setting this up before Task 1 runs. Suggested branch name: `feat/selection-highlight-visibility`.

All file paths below are **relative to the worktree root**, identical in layout to the main repo.

---

## Task 1: Replace selection color construction in TreemuxEditorTheme

**Files:**
- Modify: `Treemux/UI/FileBrowser/TextEditorView.swift`

- [ ] **Step 1: Verify current state**

```bash
grep -nE "let selection = NSColor\(Color\(hex:|var editorThemeColor: NSColor" Treemux/UI/FileBrowser/TextEditorView.swift
```

Both lines must exist. If either doesn't, reconcile with the current file before editing.

- [ ] **Step 2: Replace the selection construction line**

Inside `TreemuxEditorTheme.from(uiColors:)`, replace:

```swift
        let selection = NSColor(Color(hex: ui.accentColor)).withAlphaComponent(0.3).editorThemeColor
```

with:

```swift
        let selection = NSColor.sRGBSelection(fromHex: ui.accentColor, alpha: 0.45)
```

- [ ] **Step 3: Add the `sRGBSelection(fromHex:alpha:)` helper**

Inside the existing `private extension NSColor` block, immediately after the `editorThemeColor` computed property:

```swift
    /// Builds a selection-highlight color directly in sRGB from a hex string,
    /// bypassing the SwiftUI `Color(hex:)` → `NSColor(_:)` → `withAlphaComponent`
    /// bridge. That bridge is unreliable across macOS versions.
    ///
    /// Only the low 24 bits of the hex are read; any embedded alpha is
    /// ignored so the explicit `alpha:` argument always wins.
    static func sRGBSelection(fromHex hex: String, alpha: CGFloat) -> NSColor {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&rgb)
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8)  & 0xFF) / 255.0
        let b = CGFloat( rgb        & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
```

After this step, `private extension NSColor` should contain exactly two members: `editorThemeColor` and `sRGBSelection(fromHex:alpha:)`.

---

## Task 2: Add `SelectionRectFixDelegate` and wire it into `ScrollBehaviorCoordinator`

**Files:**
- Modify: `Treemux/UI/FileBrowser/TextEditorView.swift`

- [ ] **Step 1: Add the wrapper delegate class**

Just above the `ScrollBehaviorCoordinator` class (and the `// MARK: - Scroll behavior` divider), insert a doc comment explaining the delegate's purpose, followed by:

```swift
private final class SelectionRectFixDelegate: NSObject, TextLayoutManagerDelegate {
    weak var textView: TextView?
    weak var layoutManager: TextLayoutManager?

    func layoutManagerHeightDidUpdate(newHeight: CGFloat) {
        textView?.layoutManagerHeightDidUpdate(newHeight: newHeight)
    }

    func layoutManagerMaxWidthDidChange(newWidth: CGFloat) {
        textView?.layoutManagerMaxWidthDidChange(newWidth: newWidth)
    }

    func layoutManagerTypingAttributes() -> [NSAttributedString.Key: Any] {
        textView?.layoutManagerTypingAttributes() ?? [:]
    }

    func textViewportSize() -> CGSize {
        guard let textView else { return .zero }
        var size = textView.textViewportSize()
        if let layoutManager {
            size.width += layoutManager.edgeInsets.horizontal
        }
        return size
    }

    func layoutManagerYAdjustment(_ yAdjustment: CGFloat) {
        textView?.layoutManagerYAdjustment(yAdjustment)
    }

    var visibleRect: NSRect {
        textView?.visibleRect ?? .zero
    }
}
```

The doc comment above the class must explain (a) why this exists, (b) that `textViewportSize()` is the only consumer of the inflated value, and (c) that the wrapper is forward-compatible if upstream eventually fixes `maxLineWidth`. See the spec for the exact text.

- [ ] **Step 2: Hold the wrapper strongly in `ScrollBehaviorCoordinator`**

Add two stored properties to `ScrollBehaviorCoordinator`:

```swift
    /// Held strongly because `TextLayoutManager.delegate` is `weak`. Owns the
    /// reference to the textView (also weak) so the wrapper itself is safe
    /// to outlive the textView; if the textView is gone we no-op forwards.
    private let selectionFixDelegate = SelectionRectFixDelegate()
    /// Captured at install time so we can restore the original delegate when
    /// the coordinator is destroyed. Weak: the textView owns it.
    private weak var originalLayoutDelegate: TextLayoutManagerDelegate?
```

- [ ] **Step 3: Install in `controllerDidAppear`, restore in `destroy()`**

Modify `controllerDidAppear` to call `installSelectionRectFix(on: controller.textView)` after `attach`. Modify `destroy()` to call `uninstallSelectionRectFix()` before nil-ing out `textView`.

Add these private methods to `ScrollBehaviorCoordinator`:

```swift
    private func installSelectionRectFix(on textView: TextView?) {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        if layoutManager.delegate === selectionFixDelegate {
            selectionFixDelegate.textView = textView
            selectionFixDelegate.layoutManager = layoutManager
            return
        }
        originalLayoutDelegate = layoutManager.delegate
        selectionFixDelegate.textView = textView
        selectionFixDelegate.layoutManager = layoutManager
        layoutManager.delegate = selectionFixDelegate
    }

    private func uninstallSelectionRectFix() {
        guard let layoutManager = textView?.layoutManager,
              layoutManager.delegate === selectionFixDelegate else { return }
        layoutManager.delegate = originalLayoutDelegate ?? textView
        originalLayoutDelegate = nil
        selectionFixDelegate.textView = nil
        selectionFixDelegate.layoutManager = nil
    }
```

- [ ] **Step 4: Correct the misleading doc-comment on `ScrollBehaviorCoordinator`**

The existing comment claims `edgeInsets.right` "does NOT change line-fragment origin or selection rects." That's wrong — it broke selection rects via `wrapLinesWidth`, which is the bug this whole change is repairing. Replace the misleading paragraph with a note pointing at the new wrapper delegate:

```swift
/// **Important:** the comment above used to claim `wrapLinesWidth` is unused
/// while `wrapLines == false`. That's wrong: `TextSelectionManager.getFillRects`
/// reads `wrapLinesWidth` unconditionally, and clamps every selection rect
/// to `validTextDrawingRect.width = max(maxLineWidth, wrapLinesWidth)`. With
/// `wrapLinesWidth = viewport_width − edgeInsets.horizontal` going negative
/// after we inflate `edgeInsets.right`, the clamp collapses every selection
/// rect to zero width and the selection background becomes invisible.
///
/// The fix is `SelectionRectFixDelegate` above: a wrapper around the layout
/// manager's existing delegate (the textView) that lies about
/// `textViewportSize().width`, returning `real_viewport + edgeInsets.horizontal`.
/// That makes `wrapLinesWidth` evaluate to the real viewport width regardless
/// of how much we've inflated `edgeInsets.right`, restoring selection draw
/// without sacrificing horizontal scroll. `textViewportSize()` is *only*
/// consumed by `wrapLinesWidth` in the package, so the lie is contained.
```

---

## Task 3: Build the app

**Files:** none (build only)

- [ ] **Step 1: Build Treemux for Debug**

```bash
xcodebuild \
  -project Treemux.xcodeproj \
  -scheme Treemux \
  -configuration Debug \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  build 2>&1 | tail -40
```

Expected: trailing line `** BUILD SUCCEEDED **`. The `-skipPackagePluginValidation` flag silences upstream SwiftLint plugin failures in CodeEditTextView/CodeEditSourceEditor that aren't blocking compilation.

If a compile error mentions `SelectionRectFixDelegate` not conforming to `TextLayoutManagerDelegate`, double-check that all six protocol members are present (the easy one to miss is `var visibleRect: NSRect { get }`).

- [ ] **Step 2: Locate the freshly built app bundle**

```bash
ls -dt ~/Library/Developer/Xcode/DerivedData/Treemux-*/Build/Products/Debug/Treemux.app | head -1
```

Capture the absolute path. The DerivedData hash differs between the main repo and any worktree, so always resolve it dynamically.

---

## Task 4: Manual visual verification

**Files:** none (runtime check only)

- [ ] **Step 1: Launch the freshly built app**

Substitute `<path-from-Task-3-Step-2>`:

```bash
rm -rf ~/.treemux-debug/ && open <path-from-Task-3-Step-2>
```

- [ ] **Step 2: Verify selection draws (Dark)**

In Treemux Dark theme, open any text file:

1. Drag-select 5–10 characters → expect a clearly visible blue selection background, comparable to VSCode dark+ (`#264F78` over `#1E1E1E`).
2. Press ⌘A → expect the entire visible buffer to be highlighted.
3. Click into the editor and press ⇧→ → expect a single character to be highlighted.

- [ ] **Step 3: Verify selection draws (Light)**

Switch to Treemux Light theme; repeat Step 2 on the same file. Expect a soft, visible blue selection background, comparable to VSCode light (`#ADD6FF` over `#FFFFFF`).

- [ ] **Step 4: Verify horizontal scroll still works for long unwrapped lines**

Open a file with at least one line wider than the editor viewport (e.g. a single-line minified JS bundle, or any document with a comment that exceeds the window width):

1. Trackpad-pan horizontally OR drag the bottom horizontal scrollbar → expect the buffer to scroll right and the line's tail to come into view.
2. Drag-select within the off-viewport region → expect the selection background to render correctly there too.

If horizontal scroll is broken, the wrapper delegate's `textViewportSize()` compensation is wrong (or `ScrollBehaviorCoordinator.applyDesiredWidth` is being short-circuited).

- [ ] **Step 5: Sanity-check unaffected paths**

1. Click into the editor without selecting → caret appears, no spurious background change.
2. Scroll vertically with a selection active → highlight tracks the selected text.
3. Drag-select, then click outside the editor (e.g. file tree) → selection background switches to its grayscale form (existing CodeEditTextView behavior, unchanged here).

If any of these regresses, stop and investigate before committing.

---

## Task 5: Commit

**Files:** none (git only)

- [ ] **Step 1: Stage the change**

```bash
git add Treemux/UI/FileBrowser/TextEditorView.swift \
        docs/superpowers/specs/2026-05-06-selection-highlight-visibility-design.md \
        docs/superpowers/plans/2026-05-06-selection-highlight-visibility.md
git status --short
```

Expected: exactly three staged files, no others.

- [ ] **Step 2: Commit**

```bash
git commit -m "$(cat <<'EOF'
fix(file-viewer): make text selection background visible without losing horizontal scroll

The selection background was rendering at zero width because of a
two-bug interaction:

  1. CodeEditTextView 0.x has an inout-shadowing bug at
     TextLayoutManager+Layout.swift:190 that prevents per-line widths
     from propagating to `maxLineWidth` (it stays at 0).
  2. Treemux's `ScrollBehaviorCoordinator` works around that by
     inflating `edgeInsets.right` so `estimatedWidth()` reports a
     usable doc width, which makes `wrapLinesWidth` go negative.
     `TextSelectionManager.getFillRects` then clamps every selection
     rect to `max(0, negative) = 0` width, painting nothing.

The fix slots a `SelectionRectFixDelegate` in front of the textView's
`TextLayoutManagerDelegate`, forwarding everything except
`textViewportSize()`, which returns
`real_viewport + edgeInsets.horizontal`. `wrapLinesWidth` then
evaluates to `real_viewport`, regardless of how much
`ScrollBehaviorCoordinator` has inflated the right inset. Selection
rects clamp to the actual viewport width and become visible; the
horizontal-scroll workaround keeps working untouched.

Independently, switch `EditorTheme.selection` construction to a direct
sRGB-from-hex helper at alpha 0.45 — bypassing the SwiftUI→AppKit
color bridge and bumping the contrast to match VSCode dark+/light
defaults. This is a quality improvement, not a correctness fix.

Containment: `textViewportSize()` is consumed at exactly one site in
CodeEditTextView (the `wrapLinesWidth` getter), and `wrapLinesWidth`
itself is consumed only by `maxLineLayoutWidth` (only when
`wrapLines == true`, which we never set) and by `getFillRects`. So the
inflation only affects selection-rect width — exactly what we want.

Long-term: the right fix is a one-line PR to CodeEditTextView removing
the `var maxFoundLineWidth = maxFoundLineWidth` shadow. Once that
lands upstream, the wrapper delegate and the whole
`ScrollBehaviorCoordinator` can be deleted. The wrapper here is
forward-compatible — when `edgeInsets.horizontal` shrinks to its
natural value, the compensation drops to roughly zero.
EOF
)"
```

- [ ] **Step 3: Confirm clean tree**

```bash
git status --short
```

Expected: empty output.

---

## Done criteria

- One commit on `feat/selection-highlight-visibility` modifying:
  - `Treemux/UI/FileBrowser/TextEditorView.swift`
  - `docs/superpowers/specs/2026-05-06-selection-highlight-visibility-design.md` (rewritten with the corrected diagnosis)
  - `docs/superpowers/plans/2026-05-06-selection-highlight-visibility.md` (new file matching this plan)
- Manual verification passed for both Treemux Dark and Treemux Light, plus horizontal-scroll preservation.
- No spec deviation; specifically, no new theme fields, settings toggles, or unit tests.

After this plan completes, hand back to `superpowers:finishing-a-development-branch` to choose between merge / PR / cleanup.
