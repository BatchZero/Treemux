import Foundation

/// Pure helpers for the hardened HTML WebView (spec §6).
enum HardenedWebContent {
    private static let cspMeta =
        "<meta http-equiv=\"Content-Security-Policy\" "
        + "content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'\">"

    /// Inject a strict CSP into the document head, creating head/html if missing.
    /// Uses regex so tags with attributes/whitespace (<head data-x="y">, <head >, <HEAD>) are matched.
    static func cspWrapped(_ html: String) -> String {
        // Match <head> with optional attributes/whitespace (case-insensitive)
        if let headRange = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            // Insert CSP meta immediately after the matched opening tag
            let afterHead = headRange.upperBound
            return html[..<afterHead] + cspMeta + html[afterHead...]
        }
        // Fall back: match <html> with optional attributes/whitespace
        if let htmlRange = html.range(of: "<html[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            let afterHtml = htmlRange.upperBound
            return html[..<afterHtml] + "<head>\(cspMeta)</head>" + html[afterHtml...]
        }
        // No html/head at all: wrap entirely
        return "<html><head>\(cspMeta)</head><body>\(html)</body></html>"
    }

    /// WKContentRuleList JSON: block every URL load from the rendering WebView.
    static let egressBlockRuleListJSON = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]
    """
}
