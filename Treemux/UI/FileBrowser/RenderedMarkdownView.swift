import SwiftUI
import MarkdownUI

/// Inline-image counterpart of DataURIImageProvider — also `data:`-only.
/// Conforms to MarkdownUI's `InlineImageProvider` protocol.
/// The `throws` in the signature means non-data: URLs throw and are silently
/// suppressed by MarkdownUI — no network request is ever made.
struct DataURIInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image {
        if let nsImage = DataURIImage.decode(url) {
            return Image(nsImage: nsImage)
        }
        // Non-data: URLs: throw to signal failure — MarkdownUI renders nothing.
        // This is the mandatory no-network guarantee for inline images.
        // NOTE: throwing here causes MarkdownUI's inline-image task group to drop ALL inline
        // images in the same paragraph (not just the offending one). This is acceptable because
        // it only ever removes images (no security impact), and is a MarkdownUI task-group
        // behavior — not something fixable inside this provider.
        throw URLError(.unsupportedURL)
    }
}

/// Security-hardened markdown rendering surface (spec §6):
/// - only `data:` images render (no remote fetch),
/// - links limited to http/https/mailto and opened in the system browser,
/// - code blocks highlighted via tree-sitter.
struct RenderedMarkdownView: View {
    @Environment(ThemeManager.self) private var theme
    let content: String
    var scrollSync: ScrollSync? = nil
    @State private var scrollPosition = ScrollPosition()
    @State private var renderMaxY: CGFloat = 0
    @State private var liveRenderY: CGFloat = 0
    @State private var suppressNextPublication = false

    var body: some View {
        ScrollView {
            Markdown(content)
                .markdownImageProvider(DataURIImageProvider())
                .markdownInlineImageProvider(DataURIInlineImageProvider())
                .markdownCodeSyntaxHighlighter(MarkdownCodeSyntaxHighlighter(
                    captureColors: CodeHighlightTheme.table(
                        ansi: theme.activeTheme.terminal.ansi,
                        ui: theme.activeTheme.ui),
                    font: DesignFonts.dataLayer(size: 12)))
                .markdownTextStyle {
                    ForegroundColor(theme.textPrimary)
                }
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: RenderScrollGeometry.self) { geometry in
            RenderScrollGeometry(
                offsetY: geometry.contentOffset.y,
                contentHeight: geometry.contentSize.height,
                viewportHeight: geometry.containerSize.height
            )
        } action: { _, geometry in
            liveRenderY = geometry.offsetY
            renderMaxY = geometry.maxY
            if suppressNextPublication {
                suppressNextPublication = false
                return
            }
            guard let scrollSync else { return }
            scrollSync.publish(
                fraction: ScrollSyncMetrics.fraction(
                    offsetY: geometry.offsetY,
                    contentHeight: geometry.contentHeight,
                    viewportHeight: geometry.viewportHeight
                ),
                from: .render
            )
        }
        .onChange(of: scrollSync?.revision) { _, _ in
            guard let scrollSync, scrollSync.driver == .source else { return }
            let targetY = min(max(scrollSync.fraction, 0), 1) * renderMaxY
            guard abs(liveRenderY - targetY) > 0.5 else {
                scrollSync.finish(.source)
                return
            }
            suppressNextPublication = true
            scrollPosition.scrollTo(y: targetY)
            scrollSync.finish(.source)
        }
        .background(theme.paneBackground)
        .environment(\.openURL, OpenURLAction { url in
            guard RenderedDocumentPolicy.isAllowedLinkScheme(url.scheme) else {
                return .discarded // block javascript:/file:/custom schemes
            }
            NSWorkspace.shared.open(url)
            return .handled
        })
    }
}

private struct RenderScrollGeometry: Equatable {
    let offsetY: CGFloat
    let contentHeight: CGFloat
    let viewportHeight: CGFloat

    var maxY: CGFloat {
        max(0, contentHeight - viewportHeight)
    }
}
