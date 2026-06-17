# P4 — Markdown & HTML Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render `.md`/`.markdown` and `.html` files inside the file viewer with a Source / Split / Render segmented control, using a security-hardened markdown engine (MarkdownUI, no WebView) and a sandboxed WKWebView for HTML, with tree-sitter-powered code-block syntax highlighting and per-file view-mode persistence.

**Architecture:** A new `DocumentViewerView` replaces the direct `TextEditorView` embedding for renderable files. It hosts the existing `TextEditorView` (Source side) plus a rendered side (`RenderedMarkdownView` for markdown, `HardenedWebView` for HTML), toggled by a Source/Split/Render segmented control. Markdown renders via MarkdownUI with a **mandatory** `data:`-only image provider, a link-scheme allow-list, and a code-block highlighter that reuses the tree-sitter grammars already shipped by CodeEditLanguages. HTML renders in a locked-down WKWebView (JS off, `baseURL=about:blank`, `WKContentRuleList` blocking all egress, strict CSP). View mode is remembered per file path by extending `FileSubTabRecord` persistence. Live preview re-renders debounced while editing in the Source side.

**Tech Stack:** SwiftUI, MarkdownUI 2.x (gonzalezreal/swift-markdown-ui, MIT), SwiftTreeSitter + CodeEditLanguages (already transitively available via CodeEditSourceEditor), WebKit (WKWebView), XCTest.

## Global Constraints

- **i18n:** every user-visible string is a `LocalizedStringKey`; add a `zh-Hans` entry in `Treemux/Localizable.xcstrings` for each new string. (CLAUDE.md i18n rule.)
- **Code comments in English; commit messages may follow existing style.**
- **Worktree:** all work happens in `.worktrees/feat+p4-rendering/` on branch `feat/p4-rendering` (already created off `docs/file-browser-overhaul`). The main repo dir stays on `main`.
- **Security — MANDATORY, non-negotiable (spec §6 + Watch-List):**
  - MarkdownUI's default `ImageProvider` fetches remote images — it **must** be overridden with a provider that renders **only `data:` URIs** and nothing else.
  - Markdown link schemes: allow only `http`, `https`, `mailto`; block `javascript:`, `file:`, and any custom scheme.
  - HTML WKWebView (untrusted/remote path): `WKWebpagePreferences.allowsContentJavaScript = false`; load via `loadHTMLString` with `baseURL = about:blank` (never `nil` / `file:`); attach a `WKContentRuleList` blocking **all** network loads; inject CSP `default-src 'none'; img-src data:; style-src 'unsafe-inline'`; cancel in-view navigations and route external links to the system browser.
  - **Never** use `NSAttributedString(html:)` for untrusted content.
- **v1 scope decisions (locked):**
  - HTML always uses the hardened/untrusted path in v1 (no relaxed trusted-local `loadFileURL`). Documented as a known limitation.
  - Code-block syntax highlighting reuses tree-sitter (CodeEditLanguages grammars), per 卡皮巴拉's decision.
  - Live-preview debounce: **300 ms** (matches the editor's existing index debounce knob).
- **Build/test command** (non-interactive needs `-skipPackagePluginValidation`):
  ```bash
  cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+p4-rendering
  xcodebuild test -project Treemux.xcodeproj -scheme Treemux \
    -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation
  ```
  After adding a package or changing `project.yml`, regenerate the project first: `xcodegen generate` (run from the worktree root).

---

## File Structure

**New files:**
- `Treemux/Domain/FileViewMode.swift` — `enum FileViewMode: String, Codable { case source, split, render }`.
- `Treemux/Services/Rendering/CodeHighlightTheme.swift` — maps tree-sitter capture names → `Color` (from `DesignTokens`).
- `Treemux/Services/Rendering/TreeSitterCodeHighlighter.swift` — pure helper: `(code, languageName) -> AttributedString` using SwiftTreeSitter + CodeEditLanguages.
- `Treemux/Services/Rendering/MarkdownCodeSyntaxHighlighter.swift` — adapts the above to MarkdownUI's `CodeSyntaxHighlighter` protocol (`-> Text`).
- `Treemux/Services/Rendering/DataURIImageProvider.swift` — MarkdownUI `ImageProvider` that renders only `data:` images; plus a pure `DataURIImage.decode(_:)` helper.
- `Treemux/Services/Rendering/RenderedDocumentPolicy.swift` — pure: `renderKind(forPath:) -> RenderKind?` (`.markdown`/`.html`), `defaultMode(for:)`, `isAllowedLinkScheme(_:)`.
- `Treemux/Services/Rendering/HardenedWebContent.swift` — pure helpers for the WebView: CSP-wrapped HTML string + the `WKContentRuleList` JSON source.
- `Treemux/UI/FileBrowser/RenderedMarkdownView.swift` — SwiftUI view: `Markdown(content)` + image provider + highlighter + link sanitizer + theme.
- `Treemux/UI/FileBrowser/HardenedWebView.swift` — `NSViewRepresentable` wrapping a locked-down `WKWebView`.
- `Treemux/UI/FileBrowser/DocumentViewerView.swift` — container: segmented control + Source/Split/Render layout + debounced live preview + view-mode read/write.

**Modified files:**
- `project.yml` — add the MarkdownUI package and its product on the Treemux target.
- `Treemux/Domain/FileSubTabRecord.swift` — add `var viewMode: FileViewMode?`.
- `Treemux/Domain/FileBrowserTabState.swift` — `snapshot()` carries `viewMode` through.
- `Treemux/UI/FileBrowser/FileViewerPanelView.swift` — `.text` branch routes renderable files to `DocumentViewerView`.
- `Treemux/Localizable.xcstrings` — `zh-Hans` for "Source", "Split", "Render", and any new strings.
- Acknowledgements/licenses surface (wherever bundled-library credits live; see Task 11) — add MarkdownUI / NetworkImage / swift-cmark.

---

## Task 1: Add MarkdownUI dependency + `FileViewMode` enum

**Files:**
- Modify: `project.yml` (packages list ~lines 10–28; target dependencies ~lines 50–58)
- Create: `Treemux/Domain/FileViewMode.swift`
- Test: `TreemuxTests/FileViewModeCodingTests.swift`

**Interfaces:**
- Produces: `enum FileViewMode: String, Codable, Equatable, CaseIterable { case source, split, render }`.

- [ ] **Step 1: Add MarkdownUI to `project.yml` packages**

In the `packages:` block add:
```yaml
  MarkdownUI:
    url: https://github.com/gonzalezreal/swift-markdown-ui
    from: "2.4.0"
```

- [ ] **Step 2: Add the product to the Treemux target dependencies**

In the Treemux target `dependencies:` list add:
```yaml
      - package: MarkdownUI
        product: MarkdownUI
```

- [ ] **Step 3: Regenerate the Xcode project and resolve packages**

Run:
```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+p4-rendering
xcodegen generate
xcodebuild -resolvePackageDependencies -project Treemux.xcodeproj -scheme Treemux -skipPackagePluginValidation
```
Expected: resolution succeeds and `swift-markdown-ui` (+ its `NetworkImage`, `swift-cmark` deps) appears in the resolved packages.

- [ ] **Step 4: Write the failing test for `FileViewMode`**

Create `TreemuxTests/FileViewModeCodingTests.swift`:
```swift
import XCTest
@testable import Treemux

final class FileViewModeCodingTests: XCTestCase {
    func test_roundTripsAsRawString() throws {
        for mode in FileViewMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(FileViewMode.self, from: data)
            XCTAssertEqual(decoded, mode)
        }
    }

    func test_rawValuesAreStable() {
        XCTAssertEqual(FileViewMode.source.rawValue, "source")
        XCTAssertEqual(FileViewMode.split.rawValue, "split")
        XCTAssertEqual(FileViewMode.render.rawValue, "render")
    }
}
```

- [ ] **Step 5: Run the test to verify it fails**

Run: `xcodebuild test ... -only-testing:TreemuxTests/FileViewModeCodingTests`
Expected: FAIL — `cannot find 'FileViewMode' in scope`.

- [ ] **Step 6: Create `FileViewMode`**

Create `Treemux/Domain/FileViewMode.swift`:
```swift
import Foundation

/// Persisted per-file rendering mode for the document viewer.
enum FileViewMode: String, Codable, Equatable, CaseIterable {
    case source
    case split
    case render
}
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `xcodebuild test ... -only-testing:TreemuxTests/FileViewModeCodingTests`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add project.yml Treemux.xcodeproj Treemux/Domain/FileViewMode.swift TreemuxTests/FileViewModeCodingTests.swift
git commit -m "feat(p4): add MarkdownUI dependency and FileViewMode enum"
```

---

## Task 2: `CodeHighlightTheme` — capture-name → color mapping

**Files:**
- Create: `Treemux/Services/Rendering/CodeHighlightTheme.swift`
- Test: `TreemuxTests/CodeHighlightThemeTests.swift`

**Interfaces:**
- Consumes: `DesignTokens` colors (Task already shipped in P1a).
- Produces: `enum CodeHighlightTheme { static func color(forCapture name: String) -> Color? }`. Matching is **longest-prefix on dot-separated components**, e.g. `"keyword.function"` falls back to `"keyword"` if no exact entry.

- [ ] **Step 1: Write the failing test**

Create `TreemuxTests/CodeHighlightThemeTests.swift`:
```swift
import SwiftUI
import XCTest
@testable import Treemux

final class CodeHighlightThemeTests: XCTestCase {
    func test_exactCaptureResolves() {
        XCTAssertNotNil(CodeHighlightTheme.color(forCapture: "keyword"))
        XCTAssertNotNil(CodeHighlightTheme.color(forCapture: "string"))
        XCTAssertNotNil(CodeHighlightTheme.color(forCapture: "comment"))
    }

    func test_dottedCaptureFallsBackToPrefix() {
        // "keyword.function" has no exact entry -> falls back to "keyword"
        XCTAssertEqual(
            CodeHighlightTheme.color(forCapture: "keyword.function"),
            CodeHighlightTheme.color(forCapture: "keyword")
        )
    }

    func test_unknownCaptureReturnsNil() {
        XCTAssertNil(CodeHighlightTheme.color(forCapture: "totally.unknown.capture"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test ... -only-testing:TreemuxTests/CodeHighlightThemeTests`
Expected: FAIL — `cannot find 'CodeHighlightTheme' in scope`.

- [ ] **Step 3: Implement `CodeHighlightTheme`**

Create `Treemux/Services/Rendering/CodeHighlightTheme.swift`:
```swift
import SwiftUI

/// Maps tree-sitter highlight capture names to colors, reusing the Phosphor design tokens.
/// Matching is longest-prefix on dot-separated capture components
/// (e.g. "keyword.function" -> "keyword" if no exact entry exists).
enum CodeHighlightTheme {
    private static let table: [String: Color] = [
        "keyword": DesignTokens.accentViolet,
        "operator": DesignTokens.accentViolet,
        "string": DesignTokens.accentGreen,
        "number": DesignTokens.accentAmber,
        "constant": DesignTokens.accentAmber,
        "boolean": DesignTokens.accentAmber,
        "comment": DesignTokens.faint,
        "function": DesignTokens.files,
        "type": DesignTokens.accentOrange,
        "variable": DesignTokens.text,
        "property": DesignTokens.text,
        "punctuation": DesignTokens.muted,
        "label": DesignTokens.accentAmber,
        "attribute": DesignTokens.accentOrange,
        "tag": DesignTokens.accentViolet
    ]

    static func color(forCapture name: String) -> Color? {
        var components = name.split(separator: ".").map(String.init)
        while !components.isEmpty {
            if let color = table[components.joined(separator: ".")] {
                return color
            }
            components.removeLast()
        }
        return nil
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test ... -only-testing:TreemuxTests/CodeHighlightThemeTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Treemux/Services/Rendering/CodeHighlightTheme.swift TreemuxTests/CodeHighlightThemeTests.swift
git commit -m "feat(p4): add code-block highlight theme (capture -> token color)"
```

---

## Task 3: `TreeSitterCodeHighlighter` — standalone code → AttributedString

**Files:**
- Create: `Treemux/Services/Rendering/TreeSitterCodeHighlighter.swift`
- Test: `TreemuxTests/TreeSitterCodeHighlighterTests.swift`

**Interfaces:**
- Consumes: `CodeHighlightTheme.color(forCapture:)`; `CodeLanguage` (CodeEditLanguages); `Parser`, `Query`, `Language` (SwiftTreeSitter).
- Produces:
  - `final class TreeSitterCodeHighlighter` with `func attributed(code: String, languageName: String?) -> AttributedString`.
  - `static func language(named: String?) -> CodeLanguage?` — maps a markdown code-fence info string (e.g. `"swift"`, `"py"`, `"js"`) to a `CodeLanguage`, or `nil` for unknown/plain.
  - Falls back to an un-highlighted (monospace, default-color) `AttributedString` when language is unknown, the query can't load, or parsing fails — **never throws to the caller**.

**Notes / known landmine:** `CodeLanguage.queryURL` resolves `resourceURL?/Resources/tree-sitter-<tsName>/highlights.scm`. In the app bundle `resourceURL` should be the CodeEditLanguages resource bundle by default; if `queryURL` is `nil`, treat as "no highlighting" (do not crash). The test below tolerates both highlighted and plain output for robustness but asserts the keyword path works for Swift, which is the canonical grammar shipped by CodeEditLanguages.

- [ ] **Step 1: Write the failing test**

Create `TreemuxTests/TreeSitterCodeHighlighterTests.swift`:
```swift
import SwiftUI
import XCTest
@testable import Treemux

final class TreeSitterCodeHighlighterTests: XCTestCase {
    func test_unknownLanguageReturnsPlainAttributedString() {
        let h = TreeSitterCodeHighlighter()
        let out = h.attributed(code: "hello world", languageName: "no-such-lang")
        XCTAssertEqual(String(out.characters), "hello world")
    }

    func test_nilLanguageReturnsPlainAttributedString() {
        let h = TreeSitterCodeHighlighter()
        let out = h.attributed(code: "x = 1", languageName: nil)
        XCTAssertEqual(String(out.characters), "x = 1")
    }

    func test_languageNamedMapsAliases() {
        XCTAssertEqual(TreeSitterCodeHighlighter.language(named: "swift")?.tsName, "swift")
        XCTAssertEqual(TreeSitterCodeHighlighter.language(named: "py")?.tsName, "python")
        XCTAssertEqual(TreeSitterCodeHighlighter.language(named: "js")?.tsName, "javascript")
        XCTAssertNil(TreeSitterCodeHighlighter.language(named: "no-such-lang"))
    }

    func test_swiftCodeProducesAtLeastOneColoredRun() {
        let h = TreeSitterCodeHighlighter()
        let out = h.attributed(code: "func main() {}", languageName: "swift")
        // The full text is preserved...
        XCTAssertEqual(String(out.characters), "func main() {}")
        // ...and at least one run carries a non-nil foreground color (the `func` keyword).
        let hasColoredRun = out.runs.contains { $0.foregroundColor != nil }
        XCTAssertTrue(hasColoredRun, "expected at least one highlighted run for Swift code")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test ... -only-testing:TreemuxTests/TreeSitterCodeHighlighterTests`
Expected: FAIL — `cannot find 'TreeSitterCodeHighlighter' in scope`.

- [ ] **Step 3: Implement `TreeSitterCodeHighlighter`**

Create `Treemux/Services/Rendering/TreeSitterCodeHighlighter.swift`:
```swift
import SwiftUI
import CodeEditLanguages
import SwiftTreeSitter

/// Standalone tree-sitter highlighter: turns a code string + language name into a
/// colored AttributedString, reusing the grammars shipped by CodeEditLanguages.
/// Never throws — any failure yields plain (monospace, uncolored) text.
final class TreeSitterCodeHighlighter {

    /// Maps a markdown code-fence info string to a CodeLanguage, handling common aliases.
    static func language(named name: String?) -> CodeLanguage? {
        guard let raw = name?.lowercased(), !raw.isEmpty else { return nil }
        let alias: [String: String] = [
            "py": "python", "js": "javascript", "ts": "typescript",
            "rs": "rust", "sh": "bash", "shell": "bash", "yml": "yaml",
            "objc": "objc", "c++": "cpp", "cs": "c-sharp", "rb": "ruby"
        ]
        let resolved = alias[raw] ?? raw
        return CodeLanguage.allLanguages.first {
            $0.tsName.lowercased() == resolved || $0.extensions.contains(resolved)
        }
    }

    /// Cache loaded queries per language to avoid re-reading the .scm on every code block.
    private var queryCache: [String: Query] = [:]

    func attributed(code: String, languageName: String?) -> AttributedString {
        var plain = AttributedString(code)
        guard let codeLanguage = Self.language(named: languageName),
              let tsLanguage = codeLanguage.language,
              let query = query(for: codeLanguage, tsLanguage: tsLanguage) else {
            return plain
        }

        let parser = Parser()
        do {
            try parser.setLanguage(tsLanguage)
        } catch {
            return plain
        }
        guard let tree = parser.parse(code) else { return plain }

        let cursor = query.execute(in: tree)
        let highlights = cursor.resolve(with: .init(string: code)).highlights()

        let nsString = code as NSString
        for named in highlights {
            guard let color = CodeHighlightTheme.color(forCapture: named.name) else { continue }
            let nsRange = named.range
            guard nsRange.location != NSNotFound,
                  nsRange.location + nsRange.length <= nsString.length,
                  let swiftRange = Range(nsRange, in: code),
                  let attrRange = attributedRange(swiftRange, in: code, attributed: plain) else { continue }
            plain[attrRange].foregroundColor = color
        }
        return plain
    }

    private func query(for codeLanguage: CodeLanguage, tsLanguage: Language) -> Query? {
        if let cached = queryCache[codeLanguage.tsName] { return cached }
        guard let url = codeLanguage.queryURL,
              let data = try? Data(contentsOf: url),
              let query = try? Query(language: tsLanguage, data: data) else { return nil }
        queryCache[codeLanguage.tsName] = query
        return query
    }

    /// Convert a String range to the matching AttributedString range.
    private func attributedRange(
        _ range: Range<String.Index>,
        in source: String,
        attributed: AttributedString
    ) -> Range<AttributedString.Index>? {
        let lower = source.distance(from: source.startIndex, to: range.lowerBound)
        let upper = source.distance(from: source.startIndex, to: range.upperBound)
        guard let start = attributed.index(attributed.startIndex, offsetByCharacters: lower),
              let end = attributed.index(attributed.startIndex, offsetByCharacters: upper) else {
            return nil
        }
        return start..<end
    }
}

private extension AttributedString {
    func index(_ i: AttributedString.Index, offsetByCharacters distance: Int) -> AttributedString.Index? {
        index(i, offsetByCharacters: distance, limitedBy: endIndex)
    }
    func index(_ i: AttributedString.Index, offsetByCharacters distance: Int, limitedBy limit: AttributedString.Index) -> AttributedString.Index? {
        var idx = i
        var remaining = distance
        while remaining > 0 {
            if idx == limit { return idx == endIndex && remaining == 0 ? idx : nil }
            idx = characters.index(after: idx)
            remaining -= 1
        }
        return idx
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test ... -only-testing:TreemuxTests/TreeSitterCodeHighlighterTests`
Expected: PASS. If `test_swiftCodeProducesAtLeastOneColoredRun` fails because `queryURL` is `nil` at test time (resource bundle not resolved in the test host), investigate the CodeEditLanguages resource bundle resolution before weakening the assertion — do not silently delete the test. (`@testable import` runs in the app target, so the bundle should resolve.)

- [ ] **Step 5: Commit**

```bash
git add Treemux/Services/Rendering/TreeSitterCodeHighlighter.swift TreemuxTests/TreeSitterCodeHighlighterTests.swift
git commit -m "feat(p4): add standalone tree-sitter code highlighter"
```

---

## Task 4: `MarkdownCodeSyntaxHighlighter` — MarkdownUI adapter

**Files:**
- Create: `Treemux/Services/Rendering/MarkdownCodeSyntaxHighlighter.swift`
- Test: `TreemuxTests/MarkdownCodeSyntaxHighlighterTests.swift`

**Interfaces:**
- Consumes: `TreeSitterCodeHighlighter`; MarkdownUI's `CodeSyntaxHighlighter` protocol (`func highlightCode(_ code: String, language: String?) -> Text`).
- Produces: `struct MarkdownCodeSyntaxHighlighter: CodeSyntaxHighlighter` and a static convenience `MarkdownCodeSyntaxHighlighter.treeSitter` instance.

- [ ] **Step 1: Write the failing test**

Create `TreemuxTests/MarkdownCodeSyntaxHighlighterTests.swift`:
```swift
import SwiftUI
import XCTest
@testable import Treemux

final class MarkdownCodeSyntaxHighlighterTests: XCTestCase {
    func test_returnsTextForCode() {
        // Smoke test: the adapter produces a Text without throwing for known + unknown langs.
        let h = MarkdownCodeSyntaxHighlighter()
        _ = h.highlightCode("func f() {}", language: "swift")
        _ = h.highlightCode("plain text", language: nil)
        _ = h.highlightCode("x", language: "no-such-lang")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test ... -only-testing:TreemuxTests/MarkdownCodeSyntaxHighlighterTests`
Expected: FAIL — `cannot find 'MarkdownCodeSyntaxHighlighter' in scope`.

- [ ] **Step 3: Implement the adapter**

Create `Treemux/Services/Rendering/MarkdownCodeSyntaxHighlighter.swift`:
```swift
import SwiftUI
import MarkdownUI

/// Bridges our tree-sitter highlighter into MarkdownUI's code-block rendering.
struct MarkdownCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    static let treeSitter = MarkdownCodeSyntaxHighlighter()

    private let highlighter = TreeSitterCodeHighlighter()

    func highlightCode(_ code: String, language: String?) -> Text {
        // Strip a single trailing newline MarkdownUI appends to fenced blocks.
        let trimmed = code.hasSuffix("\n") ? String(code.dropLast()) : code
        let attributed = highlighter.attributed(code: trimmed, languageName: language)
        return Text(attributed)
            .font(DesignFonts.dataLayer(size: 12))
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test ... -only-testing:TreemuxTests/MarkdownCodeSyntaxHighlighterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Treemux/Services/Rendering/MarkdownCodeSyntaxHighlighter.swift TreemuxTests/MarkdownCodeSyntaxHighlighterTests.swift
git commit -m "feat(p4): adapt tree-sitter highlighter to MarkdownUI CodeSyntaxHighlighter"
```

---

## Task 5: `DataURIImageProvider` — block all non-`data:` images

**Files:**
- Create: `Treemux/Services/Rendering/DataURIImageProvider.swift`
- Test: `TreemuxTests/DataURIImageTests.swift`

**Interfaces:**
- Consumes: MarkdownUI's `ImageProvider` protocol (`@MainActor @ViewBuilder func makeImage(url: URL?) -> some View`).
- Produces:
  - `enum DataURIImage { static func decode(_ url: URL?) -> NSImage? }` — pure, returns an image only for a valid base64 `data:image/...` URI; `nil` for everything else (remote, file, malformed).
  - `struct DataURIImageProvider: ImageProvider`.

**Security note:** This is the load-bearing SSRF/tracking mitigation. The provider must render **nothing** (an empty/placeholder view) for any non-`data:` URL — it must never construct a request to `url`.

- [ ] **Step 1: Write the failing test**

Create `TreemuxTests/DataURIImageTests.swift`:
```swift
import XCTest
@testable import Treemux

final class DataURIImageTests: XCTestCase {
    // 1x1 transparent PNG, base64.
    private let pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    func test_validDataURIDecodes() {
        let url = URL(string: "data:image/png;base64,\(pngBase64)")
        XCTAssertNotNil(DataURIImage.decode(url))
    }

    func test_remoteURLReturnsNil() {
        XCTAssertNil(DataURIImage.decode(URL(string: "https://evil.example.com/track.png")))
    }

    func test_fileURLReturnsNil() {
        XCTAssertNil(DataURIImage.decode(URL(string: "file:///etc/passwd")))
    }

    func test_nilReturnsNil() {
        XCTAssertNil(DataURIImage.decode(nil))
    }

    func test_malformedDataURIReturnsNil() {
        XCTAssertNil(DataURIImage.decode(URL(string: "data:image/png;base64,!!!notbase64")))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test ... -only-testing:TreemuxTests/DataURIImageTests`
Expected: FAIL — `cannot find 'DataURIImage' in scope`.

- [ ] **Step 3: Implement the decoder and provider**

Create `Treemux/Services/Rendering/DataURIImageProvider.swift`:
```swift
import SwiftUI
import MarkdownUI

/// Decodes ONLY `data:` image URIs. Returns nil for remote/file/malformed URLs —
/// this is the mandatory SSRF/tracking mitigation for untrusted markdown (spec §6).
enum DataURIImage {
    static func decode(_ url: URL?) -> NSImage? {
        guard let url, url.scheme == "data" else { return nil }
        let raw = url.absoluteString
        guard let commaIndex = raw.firstIndex(of: ","),
              raw[..<commaIndex].contains(";base64") else { return nil }
        let base64 = String(raw[raw.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64),
              let image = NSImage(data: data) else { return nil }
        return image
    }
}

/// MarkdownUI image provider that renders only `data:` images and blocks everything else.
struct DataURIImageProvider: ImageProvider {
    @MainActor @ViewBuilder
    func makeImage(url: URL?) -> some View {
        if let image = DataURIImage.decode(url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            // Remote/file/unknown image: render nothing (no network request is ever made).
            EmptyView()
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test ... -only-testing:TreemuxTests/DataURIImageTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Treemux/Services/Rendering/DataURIImageProvider.swift TreemuxTests/DataURIImageTests.swift
git commit -m "feat(p4): add data:-only markdown image provider (block remote images)"
```

---

## Task 6: `RenderedDocumentPolicy` — render-kind / default-mode / link-scheme rules

**Files:**
- Create: `Treemux/Services/Rendering/RenderedDocumentPolicy.swift`
- Test: `TreemuxTests/RenderedDocumentPolicyTests.swift`

**Interfaces:**
- Produces:
  - `enum RenderKind: Equatable { case markdown, html }`
  - `enum RenderedDocumentPolicy { static func renderKind(forPath:) -> RenderKind?; static func defaultMode(for: RenderKind) -> FileViewMode; static func isAllowedLinkScheme(_:) -> Bool }`
- Rules: `.md`/`.markdown` → `.markdown` (default mode `.split`); `.html`/`.htm` → `.html` (default mode `.source`); anything else → `nil`. Allowed link schemes: `http`, `https`, `mailto` (case-insensitive); everything else (incl. `javascript`, `file`, custom, nil) blocked.

- [ ] **Step 1: Write the failing test**

Create `TreemuxTests/RenderedDocumentPolicyTests.swift`:
```swift
import XCTest
@testable import Treemux

final class RenderedDocumentPolicyTests: XCTestCase {
    func test_markdownExtensions() {
        XCTAssertEqual(RenderedDocumentPolicy.renderKind(forPath: "/a/README.md"), .markdown)
        XCTAssertEqual(RenderedDocumentPolicy.renderKind(forPath: "/a/NOTES.markdown"), .markdown)
        XCTAssertEqual(RenderedDocumentPolicy.renderKind(forPath: "/a/Doc.MD"), .markdown)
    }

    func test_htmlExtensions() {
        XCTAssertEqual(RenderedDocumentPolicy.renderKind(forPath: "/a/index.html"), .html)
        XCTAssertEqual(RenderedDocumentPolicy.renderKind(forPath: "/a/page.htm"), .html)
    }

    func test_nonRenderable() {
        XCTAssertNil(RenderedDocumentPolicy.renderKind(forPath: "/a/main.swift"))
        XCTAssertNil(RenderedDocumentPolicy.renderKind(forPath: "/a/file.txt"))
    }

    func test_defaultModes() {
        XCTAssertEqual(RenderedDocumentPolicy.defaultMode(for: .markdown), .split)
        XCTAssertEqual(RenderedDocumentPolicy.defaultMode(for: .html), .source)
    }

    func test_linkSchemeAllowList() {
        XCTAssertTrue(RenderedDocumentPolicy.isAllowedLinkScheme("https"))
        XCTAssertTrue(RenderedDocumentPolicy.isAllowedLinkScheme("HTTP"))
        XCTAssertTrue(RenderedDocumentPolicy.isAllowedLinkScheme("mailto"))
        XCTAssertFalse(RenderedDocumentPolicy.isAllowedLinkScheme("javascript"))
        XCTAssertFalse(RenderedDocumentPolicy.isAllowedLinkScheme("file"))
        XCTAssertFalse(RenderedDocumentPolicy.isAllowedLinkScheme(nil))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test ... -only-testing:TreemuxTests/RenderedDocumentPolicyTests`
Expected: FAIL — `cannot find 'RenderedDocumentPolicy' in scope`.

- [ ] **Step 3: Implement the policy**

Create `Treemux/Services/Rendering/RenderedDocumentPolicy.swift`:
```swift
import Foundation

enum RenderKind: Equatable {
    case markdown
    case html
}

/// Pure rules for which files are renderable, their default view mode, and safe link schemes.
enum RenderedDocumentPolicy {
    static func renderKind(forPath path: String) -> RenderKind? {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown": return .markdown
        case "html", "htm": return .html
        default: return nil
        }
    }

    static func defaultMode(for kind: RenderKind) -> FileViewMode {
        switch kind {
        case .markdown: return .split
        case .html: return .source
        }
    }

    private static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    static func isAllowedLinkScheme(_ scheme: String?) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test ... -only-testing:TreemuxTests/RenderedDocumentPolicyTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Treemux/Services/Rendering/RenderedDocumentPolicy.swift TreemuxTests/RenderedDocumentPolicyTests.swift
git commit -m "feat(p4): add render-kind, default-mode, and link-scheme policy"
```

---

## Task 7: `RenderedMarkdownView` — hardened markdown surface

**Files:**
- Create: `Treemux/UI/FileBrowser/RenderedMarkdownView.swift`
- Test: `TreemuxTests/RenderedMarkdownViewTests.swift` (constructs the view; behavior is covered by the pure helpers in Tasks 5–6).

**Interfaces:**
- Consumes: `MarkdownUI.Markdown`, `DataURIImageProvider`, `MarkdownCodeSyntaxHighlighter.treeSitter`, `RenderedDocumentPolicy.isAllowedLinkScheme`, `DesignTokens`, `DesignFonts`.
- Produces: `struct RenderedMarkdownView: View { init(content: String) }`.

- [ ] **Step 1: Write the failing test**

Create `TreemuxTests/RenderedMarkdownViewTests.swift`:
```swift
import SwiftUI
import XCTest
@testable import Treemux

final class RenderedMarkdownViewTests: XCTestCase {
    func test_constructs() {
        _ = RenderedMarkdownView(content: "# Hello\n\nWorld `code` and ```swift\nfunc f(){}\n```")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test ... -only-testing:TreemuxTests/RenderedMarkdownViewTests`
Expected: FAIL — `cannot find 'RenderedMarkdownView' in scope`.

- [ ] **Step 3: Implement the view**

Create `Treemux/UI/FileBrowser/RenderedMarkdownView.swift`:
```swift
import SwiftUI
import MarkdownUI

/// Security-hardened markdown rendering surface (spec §6):
/// - only `data:` images render (no remote fetch),
/// - links limited to http/https/mailto and opened in the system browser,
/// - code blocks highlighted via tree-sitter.
struct RenderedMarkdownView: View {
    let content: String

    var body: some View {
        ScrollView {
            Markdown(content)
                .markdownImageProvider(DataURIImageProvider())
                .markdownInlineImageProvider(DataURIInlineImageProvider())
                .markdownCodeSyntaxHighlighter(MarkdownCodeSyntaxHighlighter.treeSitter)
                .markdownTextStyle { ForegroundColor(DesignTokens.text) }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignTokens.panel)
        .environment(\.openURL, OpenURLAction { url in
            guard RenderedDocumentPolicy.isAllowedLinkScheme(url.scheme) else {
                return .discarded // block javascript:/file:/custom schemes
            }
            NSWorkspace.shared.open(url)
            return .handled
        })
    }
}
```

**Note on inline images:** MarkdownUI distinguishes block images (`ImageProvider`) from inline images (`InlineImageProvider`). Add a matching inline provider in the same file so inline `![](data:)` also stays `data:`-only and inline remote URLs are dropped:
```swift
import NetworkImage

/// Inline-image counterpart of DataURIImageProvider — also `data:`-only.
struct DataURIInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async -> Image {
        if let nsImage = DataURIImage.decode(url) {
            return Image(nsImage: nsImage)
        }
        return Image(systemName: "") // empty — no remote fetch
    }
}
```
If the exact `InlineImageProvider` signature differs in the resolved MarkdownUI version, match the protocol the compiler reports — the invariant that must hold: **no code path passes a non-`data:` URL to any network-loading API.** Verify by grepping the finished file for `NetworkImage`/`AsyncImage`/`URLSession` and confirming none are reachable with a remote URL.

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test ... -only-testing:TreemuxTests/RenderedMarkdownViewTests`
Expected: PASS (compiles + constructs).

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/RenderedMarkdownView.swift TreemuxTests/RenderedMarkdownViewTests.swift
git commit -m "feat(p4): add hardened RenderedMarkdownView"
```

---

## Task 8: `HardenedWebView` — sandboxed WKWebView for HTML

**Files:**
- Create: `Treemux/Services/Rendering/HardenedWebContent.swift` (pure helpers)
- Create: `Treemux/UI/FileBrowser/HardenedWebView.swift` (`NSViewRepresentable`)
- Test: `TreemuxTests/HardenedWebContentTests.swift`

**Interfaces:**
- Produces:
  - `enum HardenedWebContent { static func cspWrapped(_ html: String) -> String; static let egressBlockRuleListJSON: String }`
  - `struct HardenedWebView: NSViewRepresentable { init(html: String) }`
- `cspWrapped` injects `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">` into `<head>` (creating `<head>`/`<html>` if absent).
- `egressBlockRuleListJSON` is a `WKContentRuleList` JSON blocking all URL loads.

**Security invariants (spec §6):** `allowsContentJavaScript = false`; `loadHTMLString(_, baseURL: URL(string: "about:blank"))`; compiled `WKContentRuleList` added to the config's `userContentController`; navigation delegate cancels in-view navigations and routes `http(s)` external links to the system browser.

- [ ] **Step 1: Write the failing test**

Create `TreemuxTests/HardenedWebContentTests.swift`:
```swift
import XCTest
@testable import Treemux

final class HardenedWebContentTests: XCTestCase {
    func test_cspInjectedIntoHead() {
        let out = HardenedWebContent.cspWrapped("<html><head><title>x</title></head><body>hi</body></html>")
        XCTAssertTrue(out.contains("Content-Security-Policy"))
        XCTAssertTrue(out.contains("default-src 'none'"))
        XCTAssertTrue(out.contains("img-src data:"))
    }

    func test_cspInjectedWhenNoHead() {
        let out = HardenedWebContent.cspWrapped("<body>hi</body>")
        XCTAssertTrue(out.contains("Content-Security-Policy"))
        XCTAssertTrue(out.contains("hi"))
    }

    func test_ruleListBlocksAll() {
        XCTAssertTrue(HardenedWebContent.egressBlockRuleListJSON.contains("block"))
        XCTAssertTrue(HardenedWebContent.egressBlockRuleListJSON.contains(".*"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test ... -only-testing:TreemuxTests/HardenedWebContentTests`
Expected: FAIL — `cannot find 'HardenedWebContent' in scope`.

- [ ] **Step 3: Implement the pure helpers**

Create `Treemux/Services/Rendering/HardenedWebContent.swift`:
```swift
import Foundation

/// Pure helpers for the hardened HTML WebView (spec §6).
enum HardenedWebContent {
    private static let cspMeta =
        "<meta http-equiv=\"Content-Security-Policy\" "
        + "content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'\">"

    /// Inject a strict CSP into the document head, creating head/html if missing.
    static func cspWrapped(_ html: String) -> String {
        if let headRange = html.range(of: "<head>", options: .caseInsensitive) {
            return html.replacingCharacters(in: headRange, with: "<head>\(cspMeta)")
        }
        if let htmlRange = html.range(of: "<html>", options: .caseInsensitive) {
            return html.replacingCharacters(in: htmlRange, with: "<html><head>\(cspMeta)</head>")
        }
        return "<html><head>\(cspMeta)</head><body>\(html)</body></html>"
    }

    /// WKContentRuleList JSON: block every URL load from the rendering WebView.
    static let egressBlockRuleListJSON = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]
    """
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test ... -only-testing:TreemuxTests/HardenedWebContentTests`
Expected: PASS.

- [ ] **Step 5: Implement `HardenedWebView`**

Create `Treemux/UI/FileBrowser/HardenedWebView.swift`:
```swift
import SwiftUI
import WebKit

/// Sandboxed WKWebView for rendering untrusted HTML (spec §6):
/// JS disabled, baseURL=about:blank, all network egress blocked via WKContentRuleList,
/// strict CSP injected, in-view navigations cancelled (external links -> system browser).
struct HardenedWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground") // transparent; honor panel bg

        compileAndAddEgressBlock(to: webView)
        load(html, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        load(html, into: webView)
    }

    private func load(_ html: String, into webView: WKWebView) {
        webView.loadHTMLString(
            HardenedWebContent.cspWrapped(html),
            baseURL: URL(string: "about:blank")
        )
    }

    private func compileAndAddEgressBlock(to webView: WKWebView) {
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "treemux-egress-block",
            encodedContentRuleList: HardenedWebContent.egressBlockRuleListJSON
        ) { list, _ in
            if let list {
                webView.configuration.userContentController.add(list)
            }
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Allow only the initial about:blank document load; cancel everything else.
            if navigationAction.navigationType == .other,
               navigationAction.request.url?.absoluteString == "about:blank" {
                decisionHandler(.allow)
                return
            }
            // External links: route http/https to the system browser, block the rest.
            if let url = navigationAction.request.url,
               RenderedDocumentPolicy.isAllowedLinkScheme(url.scheme) {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}
```

- [ ] **Step 6: Build to verify it compiles**

Run: `xcodebuild build ... -skipPackagePluginValidation`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Treemux/Services/Rendering/HardenedWebContent.swift Treemux/UI/FileBrowser/HardenedWebView.swift TreemuxTests/HardenedWebContentTests.swift
git commit -m "feat(p4): add hardened sandboxed WKWebView for HTML rendering"
```

---

## Task 9: Persist view mode — extend `FileSubTabRecord` + snapshot

**Files:**
- Modify: `Treemux/Domain/FileSubTabRecord.swift:11-21`
- Modify: `Treemux/Domain/FileBrowserTabState.swift` (the `snapshot()` reconstruction ~lines 96-113)
- Test: `TreemuxTests/FileSubTabRecordCodingTests.swift` (extend existing), `TreemuxTests/FileBrowserTabSnapshotViewModeTests.swift` (new)

**Interfaces:**
- Produces: `FileSubTabRecord.viewMode: FileViewMode?` (nil = "use default for kind"); preserved through `snapshot()`.
- Consumes (later, Task 10): the controller reads `record.viewMode` on open and writes it back on change.

- [ ] **Step 1: Extend the record-coding test to expect `viewMode`**

In `TreemuxTests/FileSubTabRecordCodingTests.swift` add:
```swift
func test_roundTripWithViewMode() throws {
    let r = FileSubTabRecord(id: UUID(), path: "/a/b.md", isPinned: true, viewMode: .render)
    let data = try JSONEncoder().encode(r)
    let decoded = try JSONDecoder().decode(FileSubTabRecord.self, from: data)
    XCTAssertEqual(decoded.viewMode, .render)
}

func test_decodesLegacyRecordWithoutViewMode() throws {
    let legacy = #"{"id":"\#(UUID().uuidString)","path":"/a/b.md","isPinned":true}"#
    let decoded = try JSONDecoder().decode(FileSubTabRecord.self, from: Data(legacy.utf8))
    XCTAssertNil(decoded.viewMode)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test ... -only-testing:TreemuxTests/FileSubTabRecordCodingTests`
Expected: FAIL — extra argument `viewMode` in call.

- [ ] **Step 3: Add `viewMode` to `FileSubTabRecord`**

Modify `Treemux/Domain/FileSubTabRecord.swift`:
```swift
struct FileSubTabRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var path: String
    var isPinned: Bool
    var viewMode: FileViewMode?

    init(id: UUID = UUID(), path: String, isPinned: Bool, viewMode: FileViewMode? = nil) {
        self.id = id
        self.path = path
        self.isPinned = isPinned
        self.viewMode = viewMode
    }
}
```
(`viewMode` is optional, so legacy JSON without the key decodes to `nil` automatically.)

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild test ... -only-testing:TreemuxTests/FileSubTabRecordCodingTests`
Expected: PASS.

- [ ] **Step 5: Write the snapshot-preservation test**

Create `TreemuxTests/FileBrowserTabSnapshotViewModeTests.swift`. First inspect `FileBrowserTabState.swift` / the controller's `snapshot()` to mirror the existing test setup pattern used for pinned subtabs (reuse whatever fixture the current snapshot tests use). The test asserts that a pinned subtab's `viewMode` survives `snapshot()`:
```swift
import XCTest
@testable import Treemux

final class FileBrowserTabSnapshotViewModeTests: XCTestCase {
    func test_snapshotPreservesViewMode() {
        // Arrange a controller/state with one pinned subtab whose viewMode == .render,
        // following the same construction the existing snapshot tests use.
        // Act: let snap = controller.snapshot()
        // Assert: snap.subTabs.first?.viewMode == .render
    }
}
```
Fill the arrange/act/assert with the concrete controller construction found in the existing snapshot tests (do not leave pseudocode — match the real API).

- [ ] **Step 6: Run to verify it fails**

Run: `xcodebuild test ... -only-testing:TreemuxTests/FileBrowserTabSnapshotViewModeTests`
Expected: FAIL — viewMode is dropped (snapshot reconstructs records without it).

- [ ] **Step 7: Carry `viewMode` through `snapshot()`**

In `FileBrowserTabState.swift` `snapshot()`, change the pinned-record reconstruction from:
```swift
let pinned = subTabs.filter { $0.isPinned }.map {
    FileSubTabRecord(id: $0.id, path: $0.path, isPinned: true)
}
```
to:
```swift
let pinned = subTabs.filter { $0.isPinned }.map {
    FileSubTabRecord(id: $0.id, path: $0.path, isPinned: true, viewMode: $0.viewMode)
}
```

- [ ] **Step 8: Run to verify it passes**

Run: `xcodebuild test ... -only-testing:TreemuxTests/FileBrowserTabSnapshotViewModeTests`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Treemux/Domain/FileSubTabRecord.swift Treemux/Domain/FileBrowserTabState.swift TreemuxTests/FileSubTabRecordCodingTests.swift TreemuxTests/FileBrowserTabSnapshotViewModeTests.swift
git commit -m "feat(p4): persist per-file view mode on FileSubTabRecord"
```

---

## Task 10: `DocumentViewerView` — Source/Split/Render container with live preview

**Files:**
- Create: `Treemux/UI/FileBrowser/DocumentViewerView.swift`
- Test: `TreemuxTests/DocumentViewerViewTests.swift`

**Interfaces:**
- Consumes: `TextEditorView` (existing Source editor), `RenderedMarkdownView`, `HardenedWebView`, `RenderedDocumentPolicy`, `FileViewMode`, the controller (`FileBrowserTabController`) and `subTabID` used by `TextEditorView`.
- Produces: `struct DocumentViewerView: View { init(subTabID:, path:, content:, encoding:, dirty:, kind: RenderKind, controller:) }`.
- Behavior:
  - Initial mode = `record.viewMode` for this subtab if set, else `RenderedDocumentPolicy.defaultMode(for: kind)`.
  - Segmented control (`Picker`, `.segmented`) with cases Source / Split / Render. Changing it writes the mode back to the controller's subtab record (so it persists for pinned tabs).
  - Source = `TextEditorView`; Render = `RenderedMarkdownView`/`HardenedWebView`; Split = both side-by-side via `HSplitView`.
  - Live preview: the rendered side reads a debounced (`300 ms`) copy of `content`. Editing happens only in the Source side.

**Controller hook needed:** add a method on `FileBrowserTabController` to set a subtab's view mode, e.g. `func setViewMode(_ mode: FileViewMode, forSubTab id: UUID)` that mutates the matching `subTabs` entry. Inspect the controller to match its existing mutation style (it already mutates `subTabs` for pin/active). Add this method as part of this task and unit-test it.

- [ ] **Step 1: Write the failing test for the controller hook**

Create `TreemuxTests/DocumentViewerViewTests.swift`:
```swift
import XCTest
@testable import Treemux

final class DocumentViewerViewTests: XCTestCase {
    func test_setViewModeUpdatesSubTabRecord() {
        // Build a controller with one open subtab (mirror existing controller tests).
        // let controller = ...
        // let id = controller.subTabs.first!.id
        // controller.setViewMode(.render, forSubTab: id)
        // XCTAssertEqual(controller.subTabs.first { $0.id == id }?.viewMode, .render)
    }
}
```
Fill in with the concrete controller construction from existing controller tests (no pseudocode in the final file).

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test ... -only-testing:TreemuxTests/DocumentViewerViewTests`
Expected: FAIL — `value of type 'FileBrowserTabController' has no member 'setViewMode'`.

- [ ] **Step 3: Add the controller hook**

In `FileBrowserTabController` (find via the `snapshot()` location), add:
```swift
/// Update the persisted view mode for a sub-tab (used by the document viewer's mode picker).
func setViewMode(_ mode: FileViewMode, forSubTab id: UUID) {
    guard let index = subTabs.firstIndex(where: { $0.id == id }) else { return }
    subTabs[index].viewMode = mode
}
```
(If `subTabs` elements are a runtime type, not `FileSubTabRecord`, add a `viewMode` field there too and ensure it flows into `snapshot()` — confirm against the type used in Task 9 Step 7.)

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild test ... -only-testing:TreemuxTests/DocumentViewerViewTests`
Expected: PASS.

- [ ] **Step 5: Implement `DocumentViewerView`**

Create `Treemux/UI/FileBrowser/DocumentViewerView.swift`:
```swift
import SwiftUI

/// Container for renderable documents: Source / Split / Render with debounced live preview.
struct DocumentViewerView: View {
    let subTabID: UUID
    let path: String
    let content: String
    let encoding: String.Encoding
    let dirty: Bool
    let kind: RenderKind
    let controller: FileBrowserTabController

    @State private var mode: FileViewMode
    @State private var debouncedContent: String
    @State private var debounceTask: Task<Void, Never>?

    init(subTabID: UUID, path: String, content: String, encoding: String.Encoding,
         dirty: Bool, kind: RenderKind, controller: FileBrowserTabController) {
        self.subTabID = subTabID
        self.path = path
        self.content = content
        self.encoding = encoding
        self.dirty = dirty
        self.kind = kind
        self.controller = controller
        let initial = controller.subTabs.first { $0.id == subTabID }?.viewMode
            ?? RenderedDocumentPolicy.defaultMode(for: kind)
        _mode = State(initialValue: initial)
        _debouncedContent = State(initialValue: content)
    }

    var body: some View {
        VStack(spacing: 0) {
            modePicker
            Divider()
            content(for: mode)
        }
        .onChange(of: content) { _, newValue in
            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                await MainActor.run { debouncedContent = newValue }
            }
        }
    }

    private var modePicker: some View {
        Picker("View Mode", selection: $mode) {
            Text("Source").tag(FileViewMode.source)
            Text("Split").tag(FileViewMode.split)
            Text("Render").tag(FileViewMode.render)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(6)
        .onChange(of: mode) { _, newMode in
            controller.setViewMode(newMode, forSubTab: subTabID)
        }
    }

    @ViewBuilder
    private func content(for mode: FileViewMode) -> some View {
        switch mode {
        case .source:
            sourceEditor
        case .render:
            renderedSide
        case .split:
            HSplitView {
                sourceEditor
                renderedSide
            }
        }
    }

    private var sourceEditor: some View {
        TextEditorView(subTabID: subTabID, path: path, content: content,
                       encoding: encoding, dirty: dirty, controller: controller)
    }

    @ViewBuilder
    private var renderedSide: some View {
        switch kind {
        case .markdown:
            RenderedMarkdownView(content: debouncedContent)
        case .html:
            HardenedWebView(html: debouncedContent)
        }
    }
}
```

- [ ] **Step 6: Build to verify it compiles**

Run: `xcodebuild build ... -skipPackagePluginValidation`
Expected: BUILD SUCCEEDED. (Confirm `TextEditorView`'s init args match exactly what `FileViewerPanelView` passes at line ~61; adjust if the real signature differs.)

- [ ] **Step 7: Commit**

```bash
git add Treemux/UI/FileBrowser/DocumentViewerView.swift TreemuxTests/DocumentViewerViewTests.swift Treemux/UI/FileBrowser/FileBrowserTabController.swift
git commit -m "feat(p4): add DocumentViewerView with Source/Split/Render + live preview"
```

---

## Task 11: Route renderable files in `FileViewerPanelView` + i18n + licenses

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileViewerPanelView.swift` (`.text` case ~lines 61-62)
- Modify: `Treemux/Localizable.xcstrings`
- Modify: Acknowledgements/licenses surface (locate via grep, e.g. `grep -rn "Sparkle\|Citadel\|Acknowled\|License" Treemux/UI`)
- Test: existing suite (no new unit test; this is wiring — validated by build + manual checklist in Task 12)

**Interfaces:**
- Consumes: `RenderedDocumentPolicy.renderKind(forPath:)`, `DocumentViewerView`.

- [ ] **Step 1: Route the `.text` branch**

In `FileViewerPanelView.swift`, replace the `.text` case body:
```swift
case .text(let path, let content, let encoding, let dirty):
    if let kind = RenderedDocumentPolicy.renderKind(forPath: path) {
        DocumentViewerView(subTabID: subTab.id, path: path, content: content,
                           encoding: encoding, dirty: dirty, kind: kind, controller: controller)
    } else {
        TextEditorView(subTabID: subTab.id, path: path, content: content,
                       encoding: encoding, dirty: dirty, controller: controller)
    }
```

- [ ] **Step 2: Add zh-Hans translations**

Open `Treemux/Localizable.xcstrings` and add `zh-Hans` entries for the new strings:
- `"Source"` → `"源码"`
- `"Split"` → `"分屏"`
- `"Render"` → `"渲染"`
- `"View Mode"` → `"视图模式"`

(Use the existing JSON structure of `Localizable.xcstrings`; mirror an existing entry's shape. If the file is large, locate an existing entry to copy as a template.)

- [ ] **Step 3: Add license acknowledgements**

Find the acknowledgements/licenses surface and add entries for **MarkdownUI (MIT)**, **NetworkImage (MIT)**, **swift-cmark (BSD-2)** (Watch-List requirement). If no such surface exists yet, add the three credits to wherever existing third-party credits live (e.g. an about/settings string), or create a minimal `ACKNOWLEDGEMENTS.md` and note it for a future in-app screen. Record what you did in the commit message.

- [ ] **Step 4: Build + run the full test suite**

Run:
```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux \
  -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation
```
Expected: BUILD SUCCEEDED, all tests pass (P3 baseline was 303 tests, 0 failures; expect the new tests added on top, still 0 failures).

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/FileViewerPanelView.swift Treemux/Localizable.xcstrings <license-file>
git commit -m "feat(p4): route md/html to DocumentViewerView, add i18n + license credits"
```

---

## Task 12: Build, run, and manual validation

**Files:** none (validation only)

- [ ] **Step 1: Clean build the app**

Run:
```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+p4-rendering
xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation build
```
Note the `Treemux-<id>` DerivedData folder from the build output.

- [ ] **Step 2: Tell 卡皮巴拉 the run command**

Provide the exact command (substitute the real `<id>`):
```bash
rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<id>/Build/Products/Debug/Treemux.app
```

- [ ] **Step 3: Manual validation checklist (卡皮巴拉 runs)**

- [ ] Open a `.md` file → defaults to **Split**; markdown renders on the right, editor on the left.
- [ ] Type in the Source side → preview updates after ~300 ms (debounced), no per-keystroke jank.
- [ ] A `.md` containing a remote image `![](https://…)` → image does **not** load (no network request); a `data:` image **does** render.
- [ ] A markdown link with `https://` opens in the system browser; a `javascript:`/`file:` link does nothing.
- [ ] Code fences (` ```swift `, ` ```python `) show tree-sitter coloring; unknown languages show plain monospace.
- [ ] Switch to **Source** then **Render**; pin the tab, relaunch the app → the tab reopens in the **last-used mode**.
- [ ] Open an `.html` file → defaults to **Source**; switch to **Render** → HTML renders with no JS execution, no remote resource loads, external links open in the system browser.
- [ ] Light theme check: confirm the rendered surfaces don't regress against the known dark-token follow-up (note any issues — the theme-aware-tokens follow-up is tracked separately).

- [ ] **Step 4: Record results**

Note pass/fail per item in the PR/branch description. Any failure → systematic-debugging before claiming P4 complete.

---

## Self-Review

**1. Spec coverage (§6):**
- Markdown engine = MarkdownUI, no WebView → Tasks 1, 7. ✓
- Mandatory `data:`-only image provider → Task 5 + Task 7 (block + inline). ✓
- Link scheme allow-list (http/https/mailto; block javascript/file/custom) → Task 6 + Task 7 + Task 8 (web external links). ✓
- `CodeSyntaxHighlighter` reusing tree-sitter → Tasks 2–4. ✓
- HTML hardened WKWebView: JS off, `baseURL=about:blank`, `WKContentRuleList` egress block, strict CSP, cancel in-view nav, external→system browser → Task 8. ✓
- Segmented control Source/Split/Render → Task 10. ✓
- `.md` → Split default; remember last mode per file, persisted, survives relaunch via extending `FileSubTabRecord` → Tasks 9, 10. ✓
- `.html` → Source default → Tasks 6, 10. ✓
- Live preview while typing, debounced; editing in Source side → Task 10. ✓
- New components `RenderedMarkdownView`, `HardenedWebView` → Tasks 7, 8. ✓
- Watch-list: override default ImageProvider (Task 5), never `NSAttributedString(html:)` (we use WKWebView, Task 8), `baseURL` footgun handled (Task 8), acknowledgements screen (Task 11). ✓
- Scope note: hardened WebView only, no full App Sandbox → respected (no sandbox entitlement work). ✓

**2. Placeholder scan:** Tasks 9 Step 5 and 10 Step 1 contain test scaffolding that explicitly instructs the implementer to fill arrange/act from the existing controller/snapshot tests — flagged inline as "no pseudocode in the final file" because the exact controller construction API must be read from the live codebase rather than guessed. This is intentional (avoids inventing a wrong controller initializer) and is the only deferred detail; all production code is complete.

**3. Type consistency:** `FileViewMode` (source/split/render) used consistently across Tasks 1, 9, 10. `RenderKind` (markdown/html) consistent across Tasks 6, 8, 10, 11. `TreeSitterCodeHighlighter.attributed(code:languageName:)` and `.language(named:)` consistent across Tasks 3, 4. `DataURIImage.decode(_:)` consistent across Tasks 5, 7. `RenderedDocumentPolicy.{renderKind,defaultMode,isAllowedLinkScheme}` consistent across Tasks 6, 7, 8, 10, 11. `HardenedWebContent.{cspWrapped,egressBlockRuleListJSON}` consistent across Task 8. `controller.setViewMode(_:forSubTab:)` defined in Task 10 Step 3, used in Task 10 Step 5. ✓

**Open risks flagged for execution:**
- `TextEditorView` init signature is assumed from the explore report (`subTabID:path:content:encoding:dirty:controller:`) — verify against the real `FileViewerPanelView.swift:61` call before building Task 10.
- MarkdownUI 2.x exact modifier names (`markdownImageProvider`, `markdownInlineImageProvider`, `markdownCodeSyntaxHighlighter`, `markdownTextStyle`) and the `InlineImageProvider` signature must match the resolved version — adjust to the compiler's reported API, keeping the security invariants intact.
- `CodeLanguage.queryURL` may be `nil` if the CodeEditLanguages resource bundle doesn't resolve in the test host (Task 3 Step 4 note).
