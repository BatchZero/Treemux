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
