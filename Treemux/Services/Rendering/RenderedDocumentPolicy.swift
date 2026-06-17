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
