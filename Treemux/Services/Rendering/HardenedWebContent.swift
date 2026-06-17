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
