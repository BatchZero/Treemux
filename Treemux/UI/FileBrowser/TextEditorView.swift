//
//  TextEditorView.swift
//  Treemux

import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import CodeEditLanguages
import Combine
import SwiftUI

struct TextEditorView: View {
    let subTabID: UUID
    let path: String
    let content: String
    let encoding: String.Encoding
    let dirty: Bool
    @ObservedObject var controller: FileBrowserTabController
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        VStack(spacing: 0) {
            CodeEditorRepresentable(
                path: path,
                content: content,
                hunks: controller.diffHunksByPath[path] ?? [],
                bufferID: subTabID,
                wordIndex: controller.wordIndex,
                isCompletionEnabled: { store.settings.enableCodeCompletion },
                editorTheme: TreemuxEditorTheme.from(uiColors: themeManager.activeTheme.ui),
                onChange: { controller.updateBuffer(content: $0, forSubTab: subTabID) }
            )
            Divider()
            statusBar
        }
    }

    private var statusBar: some View {
        HStack {
            Text(URL(fileURLWithPath: path).lastPathComponent)
            if dirty {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            }
            Spacer()
            Text(encodingDisplay).foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.thinMaterial)
    }

    private var encodingDisplay: String {
        switch encoding {
        case .utf8: return "UTF-8"
        case .isoLatin1: return "Latin-1"
        default: return "Encoding"
        }
    }
}

/// Bridges the file-browser viewer state to ``CodeEditSourceEditor.SourceEditor``.
///
/// The wrapper owns a local `String` mirror of the controller's buffer so
/// `SourceEditor` can take a `Binding<String>`. Outgoing edits are forwarded
/// to the controller via `onChange`; incoming buffer swaps (e.g. switching
/// sub-tabs, reverting on save) are detected by comparing `path` / `content`
/// against the cached values inside the SwiftUI view's `Coordinator`.
private struct CodeEditorRepresentable: View {
    let path: String
    let content: String
    let hunks: [DiffHunk]
    let bufferID: UUID
    let wordIndex: BufferWordIndex
    let isCompletionEnabled: () -> Bool
    let editorTheme: EditorTheme
    let onChange: (String) -> Void

    @State private var text: String
    @State private var editorState: SourceEditorState = .init()
    /// Persisted across view updates so we can push fresh hunks into the
    /// existing overlay without forcing CodeEditSourceEditor to rebuild.
    @StateObject private var stripeCoordinator = DiffStripeCoordinator()
    /// Owns the `WordCompletionDelegate` and re-indexes the buffer on edits.
    /// Held as `@StateObject` so a single instance survives view updates and
    /// can keep its weak `controller` reference connected.
    @StateObject private var completionCoordinator: WordCompletionCoordinator

    init(
        path: String,
        content: String,
        hunks: [DiffHunk],
        bufferID: UUID,
        wordIndex: BufferWordIndex,
        isCompletionEnabled: @escaping () -> Bool,
        editorTheme: EditorTheme,
        onChange: @escaping (String) -> Void
    ) {
        self.path = path
        self.content = content
        self.hunks = hunks
        self.bufferID = bufferID
        self.wordIndex = wordIndex
        self.isCompletionEnabled = isCompletionEnabled
        self.editorTheme = editorTheme
        self.onChange = onChange
        self._text = State(initialValue: content)
        let delegate = WordCompletionDelegate(wordIndex: wordIndex, isEnabled: isCompletionEnabled)
        self._completionCoordinator = StateObject(
            wrappedValue: WordCompletionCoordinator(
                bufferID: bufferID,
                wordIndex: wordIndex,
                delegate: delegate
            )
        )
    }

    var body: some View {
        SourceEditor(
            Binding<String>(
                get: { text },
                set: { newValue in
                    text = newValue
                    onChange(newValue)
                }
            ),
            language: language,
            configuration: configuration,
            state: $editorState,
            coordinators: [stripeCoordinator, completionCoordinator],
            completionDelegate: completionCoordinator.delegate
        )
        // When the sub-tab swaps the underlying file or content (e.g. activating
        // a different sub-tab, or saving / reloading), refresh the editor's
        // buffer without re-emitting onChange.
        .onChange(of: path) { _, _ in
            if text != content { text = content }
        }
        .onChange(of: content) { _, newValue in
            if text != newValue { text = newValue }
        }
        .onChange(of: hunks) { _, newValue in
            stripeCoordinator.updateHunks(newValue)
        }
        .onAppear {
            stripeCoordinator.updateHunks(hunks)
        }
    }

    // MARK: - Language / size guard

    private var language: CodeLanguage {
        // Use the in-memory buffer size — never stat the file on the render
        // path. `content` is the text actually loaded into the editor.
        guard EditorHighlightPolicy.shouldHighlight(path: path, byteCount: content.utf8.count),
              let lang = FileTypeClassifier.language(forPath: path) else {
            return .default
        }
        switch lang {
        case .swift: return .swift
        case .javascript: return .javascript
        case .typescript: return .typescript
        case .tsx: return .tsx
        case .python: return .python
        case .go: return .go
        case .rust: return .rust
        case .json: return .json
        case .yaml: return .yaml
        case .markdown: return .markdown
        case .html: return .html
        case .css: return .css
        case .bash: return .bash
        }
    }

    // MARK: - Editor configuration

    private var configuration: SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: editorTheme,
                useThemeBackground: true,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                wrapLines: true,
                tabWidth: 4
            ),
            behavior: .init(),
            layout: .init(),
            peripherals: .init(
                showGutter: true,
                showMinimap: false,
                showFoldingRibbon: false,
                // Non-empty trigger set wires up CodeEditSourceEditor's
                // `SuggestionTriggerCharacterModel`, which fires the
                // completion delegate on every typed letter / digit in
                // addition to the explicit trigger characters listed here.
                codeSuggestionTriggerCharacters: [".", "_"]
            )
        )
    }
}

/// Builds the syntax-highlighting `EditorTheme` from Treemux's in-app theme.
///
/// Why this exists instead of leaning on `NSColor.textBackgroundColor` etc.:
/// CodeEditSourceEditor pushes `theme.background` into layer-backed
/// `NSScrollView`/`NSTextView` `backgroundColor`. macOS converts that NSColor
/// into a CGColor for the layer using whatever `NSAppearance.current` is
/// effective at assignment time, then *caches* it on the layer — so dynamic
/// system colors freeze on first paint and never follow the window's
/// `effectiveAppearance`. By feeding concrete RGB colors derived from the
/// active theme, the editor background tracks the in-app theme
/// directly and re-renders correctly when the user switches themes (the
/// editor's `Equatable` config diff fires because the NSColor values differ).
private enum TreemuxEditorTheme {
    static func from(uiColors ui: ThemeUIColors) -> EditorTheme {
        let textPrimary = NSColor(Color(hex: ui.textPrimary)).editorThemeColor
        let textSecondary = NSColor(Color(hex: ui.textSecondary)).editorThemeColor
        let textMuted = NSColor(Color(hex: ui.textMuted)).editorThemeColor
        let background = NSColor(Color(hex: ui.pane)).editorThemeColor
        let lineHighlight = NSColor(Color(hex: ui.paneHeader)).editorThemeColor
        let selection = NSColor.sRGBSelection(fromHex: ui.accent, alpha: 0.45)

        return EditorTheme(
            text: .init(color: textPrimary),
            insertionPoint: textPrimary,
            invisibles: .init(color: textMuted),
            background: background,
            lineHighlight: lineHighlight,
            selection: selection,
            keywords: .init(color: NSColor.systemPink.editorThemeColor, bold: true),
            commands: .init(color: NSColor.systemBlue.editorThemeColor),
            types: .init(color: NSColor.systemTeal.editorThemeColor),
            attributes: .init(color: NSColor.systemTeal.editorThemeColor),
            variables: .init(color: textPrimary),
            values: .init(color: NSColor.systemOrange.editorThemeColor),
            numbers: .init(color: NSColor.systemOrange.editorThemeColor),
            strings: .init(color: NSColor.systemRed.editorThemeColor),
            characters: .init(color: NSColor.systemRed.editorThemeColor),
            comments: .init(color: textSecondary, italic: true)
        )
    }
}

private extension NSColor {
    /// CodeEditSourceEditor's MinimapView calls `-brightnessComponent` on
    /// theme colors, which throws `NSInvalidArgumentException` for NSColor
    /// catalog (dynamic) values like `.textBackgroundColor`. Resolve to sRGB
    /// before handing the color off so the third-party component sees a
    /// concrete component-bearing color.
    var editorThemeColor: NSColor {
        usingColorSpace(.sRGB) ?? self
    }

    /// Builds a selection-highlight color directly in sRGB from a hex string,
    /// bypassing the SwiftUI `Color(hex:)` → `NSColor(_:)` → `withAlphaComponent`
    /// bridge. That bridge is unreliable across macOS versions: the resulting
    /// NSColor can be tagged with display-P3 or a dynamic catalog space, and
    /// alpha adjustments on it are sometimes silently dropped or muted, which
    /// is what made the existing 30%-alpha selection nearly invisible.
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
}


// MARK: - Git diff stripe overlay

/// Coordinator that installs a thin overlay alongside the gutter to render
/// 2pt-wide stripes for lines covered by a `DiffHunk`. CodeEditSourceEditor
/// 0.15.x doesn't expose a public hook on its `GutterView`, so we piggy-back
/// on `TextViewCoordinator` to grab the controller and inject our own
/// floating subview using only the public `textView`/`scrollView` surface.
private final class DiffStripeCoordinator: ObservableObject, TextViewCoordinator {
    private weak var controller: TextViewController?
    private weak var stripeView: DiffStripeView?
    private var hunks: [DiffHunk] = []

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
        installStripeView(into: controller)
    }

    func controllerDidAppear(controller: TextViewController) {
        // Re-install if the view tree was torn down between appearances.
        if stripeView?.window == nil {
            installStripeView(into: controller)
        }
        stripeView?.setHunks(hunks)
        stripeView?.repositionToMatchGutter()
    }

    func destroy() {
        stripeView?.removeFromSuperview()
        stripeView = nil
        controller = nil
    }

    /// Push fresh hunks down to the overlay; safe to call from SwiftUI's
    /// `onChange` callback before the editor has finished loading (it will
    /// pick up the cached value in `controllerDidAppear`).
    func updateHunks(_ newHunks: [DiffHunk]) {
        hunks = newHunks
        stripeView?.setHunks(newHunks)
    }

    private func installStripeView(into controller: TextViewController) {
        guard let scrollView = controller.scrollView,
              let textView = controller.textView,
              stripeView?.superview !== scrollView else { return }

        let stripe = DiffStripeView(textView: textView, scrollView: scrollView)
        stripe.setHunks(hunks)
        // Add as a floating subview pinned to the horizontal axis so the
        // stripe stays put when the user scrolls horizontally and rides
        // along with the document on vertical scroll (matching the gutter).
        scrollView.addFloatingSubview(stripe, for: .horizontal)
        stripe.repositionToMatchGutter()
        stripeView = stripe
    }
}

/// Thin floating view that lives alongside CodeEditSourceEditor's gutter and
/// paints orange stripes for the lines covered by `[DiffHunk]`.
///
/// Y-positioning mirrors the technique used by CodeEditSourceEditor's own
/// `GutterView`: the view is flipped, and its `frame.origin.y` tracks
/// `textView.frame.origin.y - scrollView.contentInsets.top` so that
/// document-y values returned by `textLineForIndex` map directly to local
/// drawing coordinates.
private final class DiffStripeView: NSView {
    private weak var textView: TextView?
    private weak var scrollView: NSScrollView?
    private var hunks: [DiffHunk] = []

    /// Width of the stripe in points. Sized to be obvious without crowding
    /// the line numbers; matches the visual weight used in similar editors.
    private static let stripeWidth: CGFloat = 2.0

    init(textView: TextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = []

        // Stay in sync with the document scroll/layout the same way the
        // gutter does — see TextViewController+Lifecycle.swift.
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.needsDisplay = true
        }
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in
            self?.repositionToMatchGutter()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }

    func setHunks(_ newHunks: [DiffHunk]) {
        guard hunks != newHunks else { return }
        hunks = newHunks
        needsDisplay = true
    }

    /// Aligns the stripe view's frame to the gutter geometry. Width matches
    /// `stripeWidth` (we sit at the very leading edge of the gutter); height
    /// tracks the textView the same way the gutter does.
    func repositionToMatchGutter() {
        guard let textView, let scrollView else { return }
        let topInset = scrollView.contentInsets.top
        let height = textView.frame.height + 10
        // Pin x=0 (leading edge of the scroll view) and width to our stripe.
        // The gutter's leading edge is also at x=0, so we share the same
        // column; floating subviews added later draw above earlier ones, so
        // our stripe ends up in front of the gutter's background fill.
        frame = NSRect(
            x: 0,
            y: textView.frame.origin.y - topInset,
            width: Self.stripeWidth,
            height: height
        )
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !hunks.isEmpty,
              let textView,
              let layoutManager = textView.layoutManager else {
            return
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Convert local (gutter-aligned) y to document y. The stripe view's
        // frame.origin.y mirrors gutterView.frame.origin.y, so dirtyRect.minY
        // already lines up with the document's y axis after we account for
        // the contentInsets.top offset baked into our own frame placement.
        // i.e. our local y == textLine.yPos directly.

        context.saveGState()
        context.setFillColor(NSColor.systemOrange.cgColor)

        for hunk in hunks {
            // DiffHunk.newLineRange is 1-based (matching the `+a,b` field of
            // a unified diff hunk header). textLineForIndex is 0-based.
            for lineNumber in hunk.newLineRange {
                let zeroBasedIndex = lineNumber - 1
                guard zeroBasedIndex >= 0,
                      let position = layoutManager.textLineForIndex(zeroBasedIndex) else {
                    continue
                }
                let rect = NSRect(
                    x: 0,
                    y: position.yPos,
                    width: Self.stripeWidth,
                    height: position.height
                )
                // Skip rows that are entirely outside the dirty region —
                // big diffs would otherwise hammer the layout manager.
                guard rect.intersects(dirtyRect) else { continue }
                context.fill(rect)
            }
        }

        context.restoreGState()
    }
}
