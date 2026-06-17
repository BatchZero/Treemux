import SwiftUI
import WebKit
import os

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

        // Store the initial html so the completion handler can load it once the rule list is ready.
        context.coordinator.pendingHTML = html

        // Compile the egress block rule list BEFORE loading any content.
        // The completion handler attaches the rule list then triggers the first load,
        // ensuring no content is rendered without the egress block in place.
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "treemux-egress-block",
            encodedContentRuleList: HardenedWebContent.egressBlockRuleListJSON
        ) { [weak webView] list, error in
            // Fix 3: log compile errors instead of silently swallowing them.
            if let error {
                print("treemux.hardened-web-view: content rule list compile error: \(error)")
            }
            if let list, let webView {
                webView.configuration.userContentController.add(list)
            }
            // Mark rule list as ready and load pending HTML (CSP is the primary defense
            // if the rule list failed; do NOT leave the view blank forever).
            context.coordinator.ruleListReady = true
            if let webView, let pendingHTML = context.coordinator.pendingHTML {
                load(pendingHTML, into: webView)
            }
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.pendingHTML = html
        // Only load immediately if the rule list is already attached;
        // otherwise the completion handler will load pendingHTML when ready.
        if context.coordinator.ruleListReady {
            load(html, into: webView)
        }
    }

    private func load(_ html: String, into webView: WKWebView) {
        webView.loadHTMLString(
            HardenedWebContent.cspWrapped(html),
            baseURL: URL(string: "about:blank")
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// Set to true once the WKContentRuleList has been compiled and attached.
        var ruleListReady = false
        /// HTML waiting to be loaded after the rule list is ready.
        var pendingHTML: String?

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
