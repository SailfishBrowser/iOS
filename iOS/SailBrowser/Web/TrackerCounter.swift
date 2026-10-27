import WebKit

// Counts element loads the lists blocked on domains they always block. WebKit reports no rule list matches, so this
// misses blocked fetches, beacons and frames, and the count is a floor.
final class TrackerCounter: NSObject, WKScriptMessageHandler {
    static let handlerName = "sailBlocked"

    // Posts each element load that failed, once per URL per document. Loads a rule list blocked fail this way.
    static let script = WKUserScript(
        source: """
            (() => {
              const seen = new Set();
              window.addEventListener('error', event => {
                const target = event.target;
                if (!(target instanceof Element)) return;
                const url = target.currentSrc || target.src || target.href;
                if (!url || seen.has(url)) return;
                seen.add(url);
                window.webkit.messageHandlers.\(handlerName).postMessage(url);
              }, true);
            })();
            """,
        injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)

    var domains: TrackerDomains?
    private let controllers = NSMapTable<WKWebView, WebTabController>.weakToWeakObjects()

    func install(on userContent: WKUserContentController) {
        userContent.addUserScript(Self.script)
        userContent.add(self, contentWorld: .defaultClient, name: Self.handlerName)
    }

    func route(_ controller: WebTabController) {
        controllers.setObject(controller, forKey: controller.webView)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let domains, let webView = message.webView, let controller = controllers.object(forKey: webView),
            let url = URL(string: message.body as! String), let host = url.host(), domains.contains(host: host)
        else { return }
        controller.countBlocked(url)
    }
}
