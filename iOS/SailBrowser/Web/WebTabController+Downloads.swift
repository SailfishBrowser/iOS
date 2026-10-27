import WebKit

extension WebTabController {
    // No page of its own: a new window, or a new tab still on the pool's prewarmed blank page.
    var showsNoPage: Bool {
        let list = webView.backForwardList
        return list.backItem == nil && (list.currentItem == nil || list.currentItem?.url.absoluteString == "about:blank")
    }

    // WebKit cannot show it, or the server asks for it to be saved: either way it becomes a download.
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")
        let isAttachment = disposition?.lowercased().hasPrefix("attachment") == true
        return !navigationResponse.canShowMIMEType || isAttachment ? .download : .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        onDownload?(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        onDownload?(download)
    }
}
