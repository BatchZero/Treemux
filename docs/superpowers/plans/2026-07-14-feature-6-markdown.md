# Feature 6 — Markdown Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give markdown files (1) visibly styled source highlighting, (2) proportional split-pane sync scrolling, and (3) selectable rendered text — in the file-browser document viewer.

**Architecture:** A pure `MarkdownHighlightScanner` tokenizes markdown; a `MarkdownHighlightProvider: HighlightProviding` wraps it and maps tokens onto existing `CaptureName` slots, injected into `SourceEditor(highlightProviders:)` for `.md` files with a markdown-tuned `EditorTheme`. Split sync-scroll uses a shared `ScrollSync` + a `ScrollSyncCoordinator` (editor side) and macOS 15 `ScrollPosition` (render side). Rendered text gets `.textSelection(.enabled)`.

**Tech Stack:** Swift, SwiftUI (macOS 15), AppKit, CodeEditSourceEditor, MarkdownUI, XCTest.

## Global Constraints

- Communicate with the user in Chinese; code comments in English.
- All code changes happen in a git worktree under `.worktrees/<branch>/` (`/` → `+`); the main repo stays on `main`.
- Colors must use theme tokens — the markdown-tuned `EditorTheme` derives all colors from the active theme (`accent`, `textPrimary`, `textSecondary`, plus an existing code color). NO hardcoded hex.
- No new user-visible strings → no `Localizable.xcstrings` change.
- This repo uses xcodegen with a checked-in `Treemux.xcodeproj/project.pbxproj`: NEW source files require `xcodegen generate` + committing the pbxproj (verify it only registers the new files).
- Build/test non-interactively with `-skipPackagePluginValidation`.
- Non-markdown files must keep their existing tree-sitter highlighting and code theme, unchanged.

## Reference: verified library facts

- `SourceEditor.init(..., highlightProviders: [any HighlightProviding]? = nil, coordinators: [...], ...)` — pass a custom provider here; `nil` = default tree-sitter.
- `HighlightProviding` requires `setUp(textView:codeLanguage:)`, `willApplyEdit(textView:range:)`, `applyEdit(textView:range:delta:completion:)` → `Result<IndexSet,Error>`, `queryHighlightsFor(textView:range:completion:)` → `Result<[HighlightRange],Error>`. `HighlightRange(range: NSRange, capture: CaptureName?)`.
- `EditorTheme.mapCapture` slots (each an `Attribute{color,bold,italic}`): `.keyword→keywords`, `.type→types`, `.comment→comments`, `.string→strings`, `.variable→variables`, `.number→numbers`, `.typeAlternate→attributes`, default→`text`.
- `TextViewCoordinator.prepareCoordinator(controller:)` / `controllerDidAppear(controller:)` give `controller.scrollView` (NSScrollView) and `controller.textView` — see the existing `DiffStripeCoordinator` in `TextEditorView.swift`.

---

### Task 1: `MarkdownHighlightScanner` (pure) + tests

**Files:**
- Create: `Treemux/UI/FileBrowser/MarkdownHighlightScanner.swift`
- Test: `TreemuxTests/MarkdownHighlightScannerTests.swift`

**Interfaces:**
- Produces: `enum MarkdownElement { case heading, strong, emphasis, code, link, listMarker, blockquote }`; `enum MarkdownHighlightScanner` with `struct Token: Equatable { let range: NSRange; let element: MarkdownElement }` and `static func scan(_ text: String) -> [Token]`. Task 2 consumes both.

- [ ] **Step 1: Write the failing tests**

Create `TreemuxTests/MarkdownHighlightScannerTests.swift`:

```swift
//
//  MarkdownHighlightScannerTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class MarkdownHighlightScannerTests: XCTestCase {
    private func elements(_ text: String) -> [MarkdownElement] {
        MarkdownHighlightScanner.scan(text).map(\.element)
    }

    private func hasElement(_ text: String, _ element: MarkdownElement, over substring: String) -> Bool {
        let expected = (text as NSString).range(of: substring)
        return MarkdownHighlightScanner.scan(text).contains {
            $0.element == element && NSIntersectionRange($0.range, expected).length > 0
        }
    }

    func testHeading() {
        XCTAssertTrue(hasElement("# Title", .heading, over: "# Title"))
        XCTAssertTrue(hasElement("### Sub", .heading, over: "### Sub"))
    }

    func testStrong() {
        XCTAssertTrue(hasElement("a **bold** b", .strong, over: "**bold**"))
        XCTAssertTrue(hasElement("a __bold__ b", .strong, over: "__bold__"))
    }

    func testEmphasis() {
        XCTAssertTrue(hasElement("a *em* b", .emphasis, over: "*em*"))
        XCTAssertTrue(hasElement("a _em_ b", .emphasis, over: "_em_"))
    }

    func testInlineCode() {
        XCTAssertTrue(hasElement("use `code` here", .code, over: "`code`"))
    }

    func testFencedCode() {
        let md = "```\nlet x = 1\n```"
        // The inner line is a code element.
        XCTAssertTrue(hasElement(md, .code, over: "let x = 1"))
    }

    func testLink() {
        XCTAssertTrue(hasElement("see [docs](https://x.y)", .link, over: "[docs](https://x.y)"))
        XCTAssertTrue(hasElement("see <https://x.y>", .link, over: "<https://x.y>"))
    }

    func testListMarkers() {
        XCTAssertTrue(hasElement("- item", .listMarker, over: "- "))
        XCTAssertTrue(hasElement("* item", .listMarker, over: "* "))
        XCTAssertTrue(hasElement("1. item", .listMarker, over: "1. "))
    }

    func testBlockquote() {
        XCTAssertTrue(hasElement("> quote", .blockquote, over: ">"))
    }

    func testPlainText_noElements() {
        XCTAssertTrue(elements("just a normal paragraph.").isEmpty)
    }

    func testCodeSpanSuppressesEmphasisInside() {
        // `*not emphasis*` inside a code span must not produce an emphasis token.
        let md = "`a*b*c`"
        XCTAssertFalse(MarkdownHighlightScanner.scan(md).contains { $0.element == .emphasis })
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
cd .worktrees/feat+feature-6-markdown
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -skipPackagePluginValidation \
  -only-testing:TreemuxTests/MarkdownHighlightScannerTests 2>&1 | tail -20
```
Expected: FAIL — `MarkdownHighlightScanner` unresolved.

- [ ] **Step 3: Create the implementation**

Create `Treemux/UI/FileBrowser/MarkdownHighlightScanner.swift`:

```swift
//
//  MarkdownHighlightScanner.swift
//  Treemux
//

import Foundation

/// A markdown source element kind, used to drive source-editor highlighting.
enum MarkdownElement: Equatable {
    case heading, strong, emphasis, code, link, listMarker, blockquote
}

/// Pragmatic line + inline scanner for markdown SOURCE highlighting (not a full
/// CommonMark parser). Returns non-overlapping-per-priority tokens with NSRanges
/// into the original string. Pure and unit-testable.
enum MarkdownHighlightScanner {
    struct Token: Equatable {
        let range: NSRange
        let element: MarkdownElement
    }

    // swiftlint:disable force_try
    private static let heading = try! NSRegularExpression(pattern: "^#{1,6}\\s.*$")
    private static let unordered = try! NSRegularExpression(pattern: "^\\s*[-*+]\\s")
    private static let ordered = try! NSRegularExpression(pattern: "^\\s*\\d+[.)]\\s")
    private static let blockquote = try! NSRegularExpression(pattern: "^\\s*>")
    private static let code = try! NSRegularExpression(pattern: "`[^`\\n]+`")
    private static let link = try! NSRegularExpression(pattern: "\\[[^\\]\\n]*\\]\\([^)\\n]*\\)|<https?://[^>\\s]+>")
    private static let strong = try! NSRegularExpression(pattern: "(\\*\\*|__)(?=\\S).+?(?<=\\S)\\1")
    private static let emphasis = try! NSRegularExpression(
        pattern: "(?<![*\\w])\\*(?!\\*)(?=\\S).+?(?<=\\S)\\*(?!\\*)|(?<![_\\w])_(?!_)(?=\\S).+?(?<=\\S)_(?!_)")
    // swiftlint:enable force_try

    static func scan(_ text: String) -> [Token] {
        let ns = text as NSString
        var tokens: [Token] = []
        var inFence = false
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byLines]) { sub, lineRange, _, _ in
            let line = sub ?? ""
            let lineNS = line as NSString
            let lineFull = NSRange(location: 0, length: lineNS.length)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                tokens.append(Token(range: lineRange, element: .code))
                inFence.toggle()
                return
            }
            if inFence {
                tokens.append(Token(range: lineRange, element: .code))
                return
            }
            if heading.firstMatch(in: line, range: lineFull) != nil {
                tokens.append(Token(range: lineRange, element: .heading))
                return
            }
            if let m = blockquote.firstMatch(in: line, range: lineFull) {
                tokens.append(Token(range: shift(m.range, by: lineRange.location), element: .blockquote))
            }
            for rx in [unordered, ordered] {
                if let m = rx.firstMatch(in: line, range: lineFull) {
                    tokens.append(Token(range: shift(m.range, by: lineRange.location), element: .listMarker))
                    break
                }
            }
            appendInline(line: line, lineNS: lineNS, lineFull: lineFull,
                         offset: lineRange.location, into: &tokens)
        }
        return tokens
    }

    private static func shift(_ r: NSRange, by delta: Int) -> NSRange {
        NSRange(location: r.location + delta, length: r.length)
    }

    /// Inline pass. Code spans are matched first and "claim" their ranges so
    /// `*`/`_` inside code are not mistaken for emphasis.
    private static func appendInline(line: String, lineNS: NSString, lineFull: NSRange,
                                     offset: Int, into tokens: inout [Token]) {
        var claimed: [NSRange] = []
        func add(_ rx: NSRegularExpression, _ el: MarkdownElement, respectClaimed: Bool) {
            rx.enumerateMatches(in: line, range: lineFull) { m, _, _ in
                guard let r = m?.range else { return }
                if respectClaimed && claimed.contains(where: { NSIntersectionRange($0, r).length > 0 }) {
                    return
                }
                claimed.append(r)
                tokens.append(Token(range: shift(r, by: offset), element: el))
            }
        }
        add(code, .code, respectClaimed: false)
        add(link, .link, respectClaimed: true)
        add(strong, .strong, respectClaimed: true)
        add(emphasis, .emphasis, respectClaimed: true)
    }
}
```

- [ ] **Step 4: Register new files (xcodegen) and run tests**

```bash
cd .worktrees/feat+feature-6-markdown
xcodegen generate
git diff --stat Treemux.xcodeproj/project.pbxproj   # only the 2 new files
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -skipPackagePluginValidation \
  -only-testing:TreemuxTests/MarkdownHighlightScannerTests 2>&1 | tail -20
```
Expected: PASS. If a regex case fails, adjust the regex (the tests are the contract) — do not weaken a test.

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/MarkdownHighlightScanner.swift \
        TreemuxTests/MarkdownHighlightScannerTests.swift Treemux.xcodeproj/project.pbxproj
git commit -m "feat(markdown): add pure MarkdownHighlightScanner + tests"
```

---

### Task 2: `MarkdownHighlightProvider` + markdown-tuned theme + wire into editor

**Files:**
- Create: `Treemux/UI/FileBrowser/MarkdownHighlightProvider.swift`
- Modify: `Treemux/UI/FileBrowser/TextEditorView.swift` (markdown-tuned theme, inject provider)

**Interfaces:**
- Consumes: `MarkdownHighlightScanner`, `MarkdownElement` (Task 1); `HighlightProviding`, `HighlightRange`, `CaptureName`, `EditorTheme`, `FileTypeClassifier.language(forPath:)`.
- Produces: `MarkdownHighlightProvider` (a `HighlightProviding` class), `MarkdownHighlightProvider.captureName(for: MarkdownElement) -> CaptureName` (pure, testable mapping), `TreemuxEditorTheme.markdown(uiColors:)`.

- [ ] **Step 1: Write a failing mapping test**

Add to `TreemuxTests/MarkdownHighlightScannerTests.swift` (or a new `MarkdownHighlightProviderTests.swift`) — the pure element→capture mapping:

```swift
final class MarkdownHighlightMappingTests: XCTestCase {
    func testElementToCaptureMapping() {
        XCTAssertEqual(MarkdownHighlightProvider.captureName(for: .heading), .keyword)
        XCTAssertEqual(MarkdownHighlightProvider.captureName(for: .strong), .type)
        XCTAssertEqual(MarkdownHighlightProvider.captureName(for: .emphasis), .comment)
        XCTAssertEqual(MarkdownHighlightProvider.captureName(for: .code), .string)
        XCTAssertEqual(MarkdownHighlightProvider.captureName(for: .link), .variable)
        XCTAssertEqual(MarkdownHighlightProvider.captureName(for: .listMarker), .number)
        XCTAssertEqual(MarkdownHighlightProvider.captureName(for: .blockquote), .typeAlternate)
    }
}
```

Run to confirm it fails (unresolved `MarkdownHighlightProvider`).

- [ ] **Step 2: Create `MarkdownHighlightProvider`**

Create `Treemux/UI/FileBrowser/MarkdownHighlightProvider.swift`:

```swift
//
//  MarkdownHighlightProvider.swift
//  Treemux
//

import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import CodeEditLanguages

/// Custom highlight provider for markdown SOURCE editing. CodeEditSourceEditor's
/// tree-sitter path drops all markdown captures (its `CaptureName` enum has no
/// markdown cases), so markdown files render flat. This provider scans the
/// buffer itself and maps markdown elements onto existing `CaptureName` slots,
/// which a markdown-tuned `EditorTheme` styles.
final class MarkdownHighlightProvider: HighlightProviding {
    /// Maps a markdown element to the CaptureName slot whose EditorTheme
    /// attribute we tune for markdown. See `TreemuxEditorTheme.markdown`.
    static func captureName(for element: MarkdownElement) -> CaptureName {
        switch element {
        case .heading: return .keyword       // keywords slot: bold + accent
        case .strong: return .type           // types slot: bold
        case .emphasis: return .comment      // comments slot: italic
        case .code: return .string           // strings slot: code color
        case .link: return .variable         // variables slot: link color
        case .listMarker: return .number     // numbers slot: muted
        case .blockquote: return .typeAlternate // attributes slot: muted
        }
    }

    func setUp(textView: TextView, codeLanguage: CodeLanguage) { }

    func willApplyEdit(textView: TextView, range: NSRange) { }

    func applyEdit(textView: TextView, range: NSRange, delta: Int,
                   completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void) {
        // A markdown edit (e.g. opening/closing a fence) can change styling from
        // the edit point to the end of the document. Invalidate from the edit
        // start to EOF; bounded by the editor's 2MB highlight cap.
        let length = (textView.string as NSString).length
        let start = min(range.location, length)
        completion(.success(IndexSet(integersIn: start..<length)))
    }

    func queryHighlightsFor(textView: TextView, range: NSRange,
                            completion: @escaping @MainActor (Result<[HighlightRange], Error>) -> Void) {
        let tokens = MarkdownHighlightScanner.scan(textView.string)
        let ranges = tokens.compactMap { token -> HighlightRange? in
            guard NSIntersectionRange(token.range, range).length > 0 else { return nil }
            return HighlightRange(range: token.range, capture: Self.captureName(for: token.element))
        }
        completion(.success(ranges))
    }
}
```

- [ ] **Step 3: Add the markdown-tuned `EditorTheme` and wire the editor**

In `Treemux/UI/FileBrowser/TextEditorView.swift`, extend `TreemuxEditorTheme` with a markdown variant. Add this static method next to `from(uiColors:)`:

```swift
    /// Markdown-tuned variant: the code-token slots are repurposed by
    /// `MarkdownHighlightProvider` for markdown elements, so tune each slot's
    /// color/bold/italic to read like markdown rather than code.
    static func markdown(uiColors ui: ThemeUIColors) -> EditorTheme {
        var theme = from(uiColors: ui)
        let accent = NSColor(Color(hex: ui.accent)).editorThemeColor
        let primary = NSColor(Color(hex: ui.textPrimary)).editorThemeColor
        let secondary = NSColor(Color(hex: ui.textSecondary)).editorThemeColor
        let code = NSColor(Color(hex: ui.textPrimary)).editorThemeColor
        theme.keywords = .init(color: accent, bold: true)   // headings
        theme.types = .init(color: primary, bold: true)     // strong
        theme.comments = .init(color: primary, italic: true) // emphasis
        theme.strings = .init(color: code)                   // code
        theme.variables = .init(color: accent)               // links
        theme.numbers = .init(color: secondary)              // list markers
        theme.attributes = .init(color: secondary)           // blockquote
        return theme
    }
```

In `TextEditorView.body`, choose the theme and pass through an `isMarkdown` flag. Change the `editorTheme:` argument (line ~47) to:

```swift
                editorTheme: isMarkdown
                    ? TreemuxEditorTheme.markdown(uiColors: themeManager.activeTheme.ui)
                    : TreemuxEditorTheme.from(uiColors: themeManager.activeTheme.ui),
```

Add to `TextEditorView`:

```swift
    private var isMarkdown: Bool {
        FileTypeClassifier.language(forPath: path) == .markdown
    }
```

Pass `isMarkdown` into `CodeEditorRepresentable`: add `let isMarkdown: Bool` (and the init param), and pass `isMarkdown: isMarkdown` at the call site.

In `CodeEditorRepresentable`, add a persisted provider and inject it:

```swift
    @State private var markdownProvider = MarkdownHighlightProvider()
```

Change the `SourceEditor(...)` call (line ~148) to pass `highlightProviders`:

```swift
        SourceEditor(
            Binding<String>( ... ),          // unchanged
            language: language,
            configuration: configuration,
            state: $editorState,
            highlightProviders: isMarkdown ? [markdownProvider] : nil,
            coordinators: [stripeCoordinator, completionCoordinator],
            completionDelegate: completionCoordinator.delegate
        )
```

(When `isMarkdown` is false, `nil` keeps the default tree-sitter provider — non-markdown files are unchanged. Add `isMarkdown` to the `init` and store it.)

- [ ] **Step 4: xcodegen + build + full suite**

```bash
cd .worktrees/feat+feature-6-markdown
xcodegen generate    # registers MarkdownHighlightProvider.swift (+ mapping test file if separate)
git diff --stat Treemux.xcodeproj/project.pbxproj
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -skipPackagePluginValidation 2>&1 | tail -15
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -skipPackagePluginValidation 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`; all tests pass (scanner + mapping). Fix compile errors (e.g. `language` availability of `.markdown`, provider param name) until green.

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/MarkdownHighlightProvider.swift \
        Treemux/UI/FileBrowser/TextEditorView.swift \
        TreemuxTests/ Treemux.xcodeproj/project.pbxproj
git commit -m "feat(markdown): inject MarkdownHighlightProvider + markdown-tuned theme for .md"
```

---

### Task 3: Selectable rendered text

**Files:**
- Modify: `Treemux/UI/FileBrowser/RenderedMarkdownView.swift`

**Interfaces:**
- Consumes: nothing new.

- [ ] **Step 1: Enable text selection**

In `RenderedMarkdownView.body`, add `.textSelection(.enabled)` to the `Markdown(content)` view (it may be added on the `Markdown(...)` modifier chain, e.g. right after `.markdownTextStyle { ... }`):

```swift
            Markdown(content)
                .markdownImageProvider(DataURIImageProvider())
                .markdownInlineImageProvider(DataURIInlineImageProvider())
                .markdownCodeSyntaxHighlighter( ... )
                .markdownTextStyle {
                    ForegroundColor(theme.textPrimary)
                }
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
```

- [ ] **Step 2: Build**

```bash
cd .worktrees/feat+feature-6-markdown
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -skipPackagePluginValidation 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Treemux/UI/FileBrowser/RenderedMarkdownView.swift
git commit -m "feat(markdown): make rendered markdown text selectable"
```

---

### Task 4: Split synchronized scrolling

**Files:**
- Create: `Treemux/UI/FileBrowser/ScrollSync.swift` (the `ScrollSync` observable + `ScrollSyncCoordinator`)
- Modify: `Treemux/UI/FileBrowser/TextEditorView.swift` (accept optional `ScrollSync`, add coordinator)
- Modify: `Treemux/UI/FileBrowser/RenderedMarkdownView.swift` (accept optional `ScrollSync`, drive/follow)
- Modify: `Treemux/UI/FileBrowser/DocumentViewerView.swift` (own `ScrollSync`, wire both panes in `.split`)

**Interfaces:**
- Consumes: `TextViewCoordinator`, `TextViewController` (`.scrollView`).
- Produces: `@Observable final class ScrollSync { var fraction: CGFloat; enum Driver {case none, source, render}; var driver: Driver }`; `ScrollSyncCoordinator: TextViewCoordinator`.

- [ ] **Step 1: Create `ScrollSync` + `ScrollSyncCoordinator`**

Create `Treemux/UI/FileBrowser/ScrollSync.swift`:

```swift
//
//  ScrollSync.swift
//  Treemux
//

import AppKit
import SwiftUI
import CodeEditSourceEditor

/// Shared proportional scroll state for the Split document viewer. `fraction` is
/// `offsetY / max(1, contentH - viewportH)` in [0, 1]. `driver` is a
/// re-entrancy guard: the side the user is actively scrolling sets itself as the
/// driver; the driven side applies the fraction without re-publishing.
@Observable final class ScrollSync {
    enum Driver: Equatable { case none, source, render }
    var fraction: CGFloat = 0
    var driver: Driver = .none
}

/// Editor-side scroll bridge. Observes the source editor's scroll and publishes
/// its fraction; applies the render side's fraction when the render pane drives.
final class ScrollSyncCoordinator: TextViewCoordinator {
    private let sync: ScrollSync
    private weak var scrollView: NSScrollView?
    private var observer: NSObjectProtocol?

    init(sync: ScrollSync) { self.sync = sync }

    func prepareCoordinator(controller: TextViewController) {
        scrollView = controller.scrollView
    }

    func controllerDidAppear(controller: TextViewController) {
        scrollView = controller.scrollView
        guard let clip = scrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            self?.sourceDidScroll()
        }
    }

    func controllerDidDisappear(controller: TextViewController) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func maxScroll(_ sv: NSScrollView) -> CGFloat {
        max(1, (sv.documentView?.frame.height ?? 0) - sv.contentView.bounds.height)
    }

    private func sourceDidScroll() {
        guard let sv = scrollView, sync.driver != .render else { return }
        sync.driver = .source
        sync.fraction = min(max(sv.contentView.bounds.origin.y / maxScroll(sv), 0), 1)
        // Release the driver on the next runloop tick so the render side can
        // follow without immediately echoing back.
        DispatchQueue.main.async { [weak self] in
            if self?.sync.driver == .source { self?.sync.driver = .none }
        }
    }

    /// Called by the view layer when the render side is driving.
    func applyFractionFromRender() {
        guard let sv = scrollView, sync.driver == .render else { return }
        let y = sync.fraction * maxScroll(sv)
        sv.contentView.scroll(to: NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }
}
```

- [ ] **Step 2: Wire the editor side (`TextEditorView`)**

- Add `var scrollSync: ScrollSync? = nil` to `TextEditorView`.
- Create the coordinator once and hold it: add `@State private var scrollSyncCoordinator: ScrollSyncCoordinator?` to `CodeEditorRepresentable`, initialized from an injected `scrollSync`. Add `let scrollSync: ScrollSync?` to `CodeEditorRepresentable` (and its `init`), pass `scrollSync: scrollSync` from `TextEditorView`.
- In `init`, build the coordinator: `self._scrollSyncCoordinator = State(initialValue: scrollSync.map { ScrollSyncCoordinator(sync: $0) })`.
- In the `SourceEditor(coordinators:)` array, append the sync coordinator when present:
  ```swift
  coordinators: [stripeCoordinator, completionCoordinator] + (scrollSyncCoordinator.map { [$0] } ?? []),
  ```
- Observe the shared fraction to drive the editor when render is the driver — add to the `SourceEditor(...)` view:
  ```swift
  .onChange(of: scrollSync?.fraction) { _, _ in
      if scrollSync?.driver == .render { scrollSyncCoordinator?.applyFractionFromRender() }
  }
  ```

- [ ] **Step 3: Wire the render side (`RenderedMarkdownView`)**

- Add `var scrollSync: ScrollSync? = nil` to `RenderedMarkdownView`.
- Add scroll state: `@State private var scrollPosition = ScrollPosition()`; attach `.scrollPosition($scrollPosition)` to the `ScrollView` and read the fraction:
  ```swift
  .onScrollGeometryChange(for: CGFloat.self) { geo in
      let maxY = max(1, geo.contentSize.height - geo.containerSize.height)
      return min(max(geo.contentOffset.y / maxY, 0), 1)
  } action: { _, frac in
      guard let sync = scrollSync, sync.driver != .source else { return }
      sync.driver = .render
      sync.fraction = frac
      DispatchQueue.main.async { if sync.driver == .render { sync.driver = .none } }
  }
  ```
- Follow the source when it drives:
  ```swift
  .onChange(of: scrollSync?.fraction) { _, _ in
      guard let sync = scrollSync, sync.driver == .source else { return }
      // Convert fraction back to a y offset using the last known geometry.
      scrollPosition.scrollTo(y: renderMaxY * sync.fraction)
  }
  ```
  Track `renderMaxY` in a `@State` updated inside `onScrollGeometryChange` (store `geo.contentSize.height - geo.containerSize.height`).

- [ ] **Step 4: Own & wire `ScrollSync` in `DocumentViewerView` (split only)**

In `DocumentViewerView`, add `@State private var scrollSync = ScrollSync()`. In the `.split` branch (the `HSplitView`), pass `scrollSync` to BOTH panes:

```swift
        case .split:
            HSplitView {
                sourceEditor(scrollSync: scrollSync)
                renderedSide(scrollSync: scrollSync)
            }
```

Thread `scrollSync` into the existing `sourceEditor` (which builds `TextEditorView`) and `renderedSide` (which builds `RenderedMarkdownView`) — pass `scrollSync:` to each. For `.source` and `.render` single modes, pass `nil` (no sync). Reset `scrollSync.driver = .none` when entering split (harmless default already `.none`).

- [ ] **Step 5: xcodegen + build + full suite**

```bash
cd .worktrees/feat+feature-6-markdown
xcodegen generate     # registers ScrollSync.swift
git diff --stat Treemux.xcodeproj/project.pbxproj
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -skipPackagePluginValidation 2>&1 | tail -15
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -skipPackagePluginValidation 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`; all tests pass. Fix compile errors (coordinator protocol method names via the `TextViewCoordinator` docs / `DiffStripeCoordinator` precedent; `onScrollGeometryChange` geometry field names) until green. The sync FEEL (direction, no oscillation) is validated in GUI smoke — adjust the driver-release timing if it jitters.

- [ ] **Step 6: Commit**

```bash
git add Treemux/UI/FileBrowser/ScrollSync.swift \
        Treemux/UI/FileBrowser/TextEditorView.swift \
        Treemux/UI/FileBrowser/RenderedMarkdownView.swift \
        Treemux/UI/FileBrowser/DocumentViewerView.swift \
        Treemux.xcodeproj/project.pbxproj
git commit -m "feat(markdown): proportional split-pane synchronized scrolling"
```

---

## Manual Verification (final review / GUI smoke)

- Open a `.md` file (e.g. CLAUDE.md). Source pane: headings colored+bold, `**bold**` bold, `*italic*` italic, `` `code` `` and fenced blocks colored, `[links](...)` colored, `-`/`1.` markers and `>` quotes styled. Type to edit → highlighting updates live. Open a `.swift` file → normal code highlighting still works.
- Switch to Split. Scroll the source pane → the rendered pane follows proportionally; scroll the rendered pane → the source follows; no jitter/oscillation. Source-only and Render-only modes scroll independently (unaffected).
- Rendered pane: drag-select text and ⌘C copies it.
- Switch the app theme → markdown source colors follow.
