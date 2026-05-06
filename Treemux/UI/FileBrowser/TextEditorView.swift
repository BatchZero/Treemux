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
                bufferID: controller.activeSubTabID ?? Self.fallbackBufferID,
                wordIndex: controller.wordIndex,
                isCompletionEnabled: { store.settings.enableCodeCompletion },
                editorTheme: TreemuxEditorTheme.from(uiColors: themeManager.activeTheme.ui),
                onChange: { controller.updateBuffer(content: $0) }
            )
            Divider()
            statusBar
        }
    }

    /// Stable UUID used when the controller has no active sub-tab — keeps the
    /// editor wiring uniform without inserting a phantom entry into the index.
    private static let fallbackBufferID = UUID()

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
    /// Tweaks NSScrollView so trackpad/wheel horizontal panning actually
    /// scrolls long unwrapped lines (overlay scrollbar stays unchanged).
    @StateObject private var scrollBehaviorCoordinator = ScrollBehaviorCoordinator()
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
            coordinators: [stripeCoordinator, scrollBehaviorCoordinator, completionCoordinator],
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

    /// Files larger than this open without tree-sitter highlighting.
    private static let highlightSizeLimit: Int = 2 * 1024 * 1024

    private var fileSizeBytes: Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? Int) ?? 0
    }

    private var shouldHighlight: Bool {
        guard FileTypeClassifier.language(forPath: path) != nil else { return false }
        return fileSizeBytes <= Self.highlightSizeLimit
    }

    private var language: CodeLanguage {
        guard shouldHighlight, let lang = FileTypeClassifier.language(forPath: path) else {
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
                wrapLines: false,
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
/// active `ThemeDefinition`, the editor background tracks the in-app theme
/// directly and re-renders correctly when the user switches themes (the
/// editor's `Equatable` config diff fires because the NSColor values differ).
private enum TreemuxEditorTheme {
    static func from(uiColors ui: UIColors) -> EditorTheme {
        let textPrimary = NSColor(Color(hex: ui.textPrimary)).editorThemeColor
        let textSecondary = NSColor(Color(hex: ui.textSecondary)).editorThemeColor
        let textMuted = NSColor(Color(hex: ui.textMuted)).editorThemeColor
        let background = NSColor(Color(hex: ui.paneBackground)).editorThemeColor
        let lineHighlight = NSColor(Color(hex: ui.paneHeaderBackground)).editorThemeColor
        let selection = NSColor.sRGBSelection(fromHex: ui.accentColor, alpha: 0.45)

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

// MARK: - Scroll behavior

/// Wraps `TextLayoutManagerDelegate` to keep `wrapLinesWidth` non-negative
/// even when `ScrollBehaviorCoordinator` has inflated `edgeInsets.right` to
/// preserve horizontal scrolling for unwrapped lines.
///
/// Why this exists:
/// `TextSelectionManager.getFillRects` clamps every selection rect to a
/// `validTextDrawingRect.width = max(layoutManager.maxLineWidth,
/// layoutManager.wrapLinesWidth)`. Because of an upstream inout-shadowing
/// bug (`TextLayoutManager+Layout.swift:190`, present in CodeEditTextView
/// main as of 2026-05) `maxLineWidth` stays at 0. `wrapLinesWidth` resolves
/// to `delegate?.textViewportSize().width − edgeInsets.horizontal`. The
/// scroll workaround inflates `edgeInsets.right` past the viewport width,
/// which makes `wrapLinesWidth` negative, which collapses every selection
/// rect to zero width — selection background becomes invisible everywhere
/// (mouse drag, ⌘A, shift-arrow all affected).
///
/// We can't subclass `TextLayoutManager` (`public class` without `open`),
/// can't write `maxLineWidth` (internal), can't fork the package without
/// owning a long-running fork. But `TextLayoutManager.delegate` is a
/// `public weak var`, so we can slot a wrapper in front of the textView.
/// We forward 4 of 5 protocol methods unchanged, and override
/// `textViewportSize()` to return `real_viewport + edgeInsets.horizontal`.
/// `wrapLinesWidth` then evaluates to `real_viewport`, regardless of how
/// much we inflate `edgeInsets.right`. Selection draws correctly; horizontal
/// scrolling continues to work.
///
/// Containment proof: `textViewportSize()` is consumed at exactly one site
/// in CodeEditTextView (the `wrapLinesWidth` getter) and `wrapLinesWidth`
/// itself only feeds `maxLineLayoutWidth` (only used when `wrapLines == true`,
/// which we never set) and `getFillRects`. So the inflation only affects
/// selection-rect width — exactly what we want — and nothing else.
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
        // Compensate for the inflated edge insets so wrapLinesWidth resolves
        // to the real viewport width. Reading edgeInsets at call time means
        // we always reflect the current inflation level.
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

/// Makes long unwrapped lines actually horizontally scrollable.
///
/// CodeEditTextView 0.x has a bug in `TextLayoutManager.layoutLine`:
/// `var maxFoundLineWidth = maxFoundLineWidth` shadows the inout parameter,
/// so per-line widths are never propagated back. `maxLineWidth` stays at 0
/// regardless of the actual document, `estimatedWidth()` is tiny, and
/// `updateFrameIfNeeded` shrinks `textView.frame.width` back to the
/// clip-view width — leaving NSScrollView with no horizontal range to scroll.
///
/// Workaround without forking the package:
/// * `usesPredominantAxisScrolling = false` so the trackpad's X delta
///   reaches the scroll view (overlay scrollbar is unchanged).
/// * Scan the buffer once to estimate the longest line's pixel width.
/// * Inflate `layoutManager.edgeInsets.right` so `estimatedWidth()`
///   reports the inflated total, making `updateFrameIfNeeded` keep the
///   frame at the desired size **on every call** — no shrink/expand
///   tug-of-war, no clip-view origin clamping, no scroll jitter.
///
/// **Important:** the comment above used to claim `wrapLinesWidth` is unused
/// while `wrapLines == false`. That's wrong: `TextSelectionManager.getFillRects`
/// reads `wrapLinesWidth` unconditionally, and clamps every selection rect
/// to `validTextDrawingRect.width = max(maxLineWidth, wrapLinesWidth)`. With
/// `wrapLinesWidth = viewport_width − edgeInsets.horizontal` going negative
/// after we inflate `edgeInsets.right`, the clamp collapses every selection
/// rect to zero width and the selection background becomes invisible.
///
/// The fix is `SelectionRectFixDelegate` below: a wrapper around the layout
/// manager's existing delegate (the textView) that lies about
/// `textViewportSize().width`, returning `real_viewport + edgeInsets.horizontal`.
/// That makes `wrapLinesWidth` evaluate to the real viewport width regardless
/// of how much we've inflated `edgeInsets.right`, restoring selection draw
/// without sacrificing horizontal scroll. `textViewportSize()` is *only*
/// consumed by `wrapLinesWidth` in the package, so the lie is contained.
private final class ScrollBehaviorCoordinator: ObservableObject, TextViewCoordinator {
    /// Skip the wide-frame workaround on very large files; the linear scan
    /// would block the main thread on open. Mirrors the highlight limit.
    private static let scanByteLimit: Int = 2 * 1024 * 1024
    /// Tab visual width in characters — must match
    /// `SourceEditorConfiguration.appearance.tabWidth` set on the editor.
    private static let tabVisualWidth: Int = 4

    private weak var textView: TextView?
    private var desiredWidth: CGFloat = 0
    private var frameObserver: NSObjectProtocol?
    private var isApplyingInsets = false
    /// Held strongly because `TextLayoutManager.delegate` is `weak`. Owns the
    /// reference to the textView (also weak) so the wrapper itself is safe
    /// to outlive the textView; if the textView is gone we no-op forwards.
    private let selectionFixDelegate = SelectionRectFixDelegate()
    /// Captured at install time so we can restore the original delegate when
    /// the coordinator is destroyed. Weak: the textView owns it.
    private weak var originalLayoutDelegate: TextLayoutManagerDelegate?

    func prepareCoordinator(controller: TextViewController) {
        configure(controller.scrollView)
    }

    func controllerDidAppear(controller: TextViewController) {
        configure(controller.scrollView)
        attach(to: controller.textView)
        installSelectionRectFix(on: controller.textView)
        recomputeDesiredWidth()
        applyDesiredWidth()
    }

    func controllerDidDisappear(controller: TextViewController) {
        detach()
    }

    func textViewDidChangeText(controller: TextViewController) {
        recomputeDesiredWidth()
        applyDesiredWidth()
    }

    func destroy() {
        detach()
        uninstallSelectionRectFix()
        textView = nil
    }

    /// Slot the wrapper delegate in front of the textView for the editor's
    /// layout manager. Idempotent — if our wrapper is already installed we
    /// just refresh its captured references in case the textView changed.
    private func installSelectionRectFix(on textView: TextView?) {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        // If our wrapper is already in place, just refresh references.
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

    /// Restore the textView's own delegate so the editor returns to upstream
    /// behavior cleanly when the coordinator is torn down.
    private func uninstallSelectionRectFix() {
        guard let layoutManager = textView?.layoutManager,
              layoutManager.delegate === selectionFixDelegate else { return }
        layoutManager.delegate = originalLayoutDelegate ?? textView
        originalLayoutDelegate = nil
        selectionFixDelegate.textView = nil
        selectionFixDelegate.layoutManager = nil
    }

    private func configure(_ scrollView: NSScrollView?) {
        guard let scrollView else { return }
        scrollView.usesPredominantAxisScrolling = false
        scrollView.horizontalScrollElasticity = .allowed
    }

    private func attach(to textView: TextView?) {
        if self.textView !== textView { detach() }
        self.textView = textView
        guard let textView, frameObserver == nil else { return }
        // `updateTextInsets` (e.g. when gutter width grows) resets
        // `layoutManager.edgeInsets`, which causes `updateFrameIfNeeded`
        // to shrink the frame. Re-applying on every frame change keeps
        // the inflation in place across those resets.
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in
            self?.applyDesiredWidth()
        }
    }

    private func detach() {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
    }

    private func recomputeDesiredWidth() {
        guard let textView, let layoutManager = textView.layoutManager else {
            desiredWidth = 0
            return
        }
        guard !layoutManager.wrapLines else { desiredWidth = 0; return }
        let string = textView.string
        guard string.utf16.count <= Self.scanByteLimit else { desiredWidth = 0; return }

        // Walk the buffer once, counting the visual columns of each line.
        // For a monospaced font the per-character advance is constant, so
        // this lines up with what the typesetter ultimately produces.
        var maxColumns = 0
        var current = 0
        for ch in string.unicodeScalars {
            if ch == "\n" {
                if current > maxColumns { maxColumns = current }
                current = 0
            } else if ch == "\t" {
                current += Self.tabVisualWidth
            } else {
                current += 1
            }
        }
        if current > maxColumns { maxColumns = current }

        let charWidth = (" " as NSString).size(withAttributes: [.font: textView.font]).width
        // Line fragment views render at `edgeInsets.left` (gutter offset),
        // so documentView needs to fit `left + line content + slack` to
        // let the user scroll the last column past the right edge. +4
        // columns of slack absorbs typesetter rounding / wider glyphs.
        let leftInset = layoutManager.edgeInsets.left
        desiredWidth = leftInset + CGFloat(maxColumns + 4) * charWidth
    }

    private func applyDesiredWidth() {
        guard !isApplyingInsets,
              let textView,
              let layoutManager = textView.layoutManager,
              desiredWidth > 0 else { return }

        let clipW = textView.enclosingScrollView?.contentSize.width ?? 0
        let target = max(desiredWidth, clipW)
        let currentEstimated = layoutManager.estimatedWidth()
        guard currentEstimated < target - 0.5 else { return }

        var insets = layoutManager.edgeInsets
        insets.right += target - currentEstimated
        // didSet on layoutManager.edgeInsets pings the delegate, which
        // calls updateFrameIfNeeded; that's how the frame grows. We set
        // the flag so the resulting frameDidChange notification doesn't
        // re-enter this method.
        isApplyingInsets = true
        layoutManager.edgeInsets = insets
        isApplyingInsets = false
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
