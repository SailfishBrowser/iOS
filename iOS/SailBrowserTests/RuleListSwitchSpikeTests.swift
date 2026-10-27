import Foundation
import Testing
import WebKit
@testable import SailBrowser

@Suite(.serialized)
struct RuleListSwitchSpikeTests {
    private static let iterations = 50
    private static let trackerRule = ##"[{"trigger":{"url-filter":"tracker\\.gif"},"action":{"type":"block"}}]"##

    @Test func removingListsWhileDecidingANavigationLetsThatPagesTrackerLoad() async throws {
        let failures = try await run(listsBefore: true)
        #expect(failures.switched.isEmpty, "tracker blocked after removal in iterations \(failures.switched)")
        #expect(failures.control.isEmpty, "control web view loaded the tracker in iterations \(failures.control)")
    }

    @Test func addingListsWhileDecidingANavigationBlocksThatPagesTracker() async throws {
        let failures = try await run(listsBefore: false)
        #expect(failures.switched.isEmpty, "tracker loaded after adding in iterations \(failures.switched)")
        #expect(failures.control.isEmpty, "control web view blocked the tracker in iterations \(failures.control)")
    }

    private func run(listsBefore: Bool) async throws -> (switched: [Int], control: [Int]) {
        let list = try #require(
            try await temporaryRuleStore().compileContentRuleList(forIdentifier: "tracker", encodedContentRuleList: Self.trackerRule))
        let server = try await LocalPageServer { path in #"<img src="/tracker.gif?\#(path.split(separator: "?")[1])">"# }
        let switched = SpikePage(), control = SpikePage()
        if listsBefore { control.webView.configuration.userContentController.add(list) }
        switched.onMainFrameDecision = { controller in
            if listsBefore { controller.removeAllContentRuleLists() } else { controller.add(list) }
        }

        var failures: (switched: [Int], control: [Int]) = ([], [])
        for iteration in 0..<Self.iterations {
            let switchedController = switched.webView.configuration.userContentController
            switchedController.removeAllContentRuleLists()
            if listsBefore { switchedController.add(list) }
            let tag = "\(listsBefore ? "remove" : "add")-\(iteration)"
            async let first: Void = switched.load(server.url("/page?s-\(tag)"))
            async let second: Void = control.load(server.url("/page?c-\(tag)"))
            _ = try await (first, second)
            if server.requestedPaths.contains("/tracker.gif?s-\(tag)") != listsBefore { failures.switched.append(iteration) }
            if server.requestedPaths.contains("/tracker.gif?c-\(tag)") == listsBefore { failures.control.append(iteration) }
        }
        return failures
    }
}

private final class SpikePage: NSObject, WKNavigationDelegate {
    let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    var onMainFrameDecision: ((WKUserContentController) -> Void)?
    private var ends = 0

    override init() {
        super.init()
        webView.navigationDelegate = self
    }

    func load(_ url: URL) async throws {
        let target = ends + 1
        webView.load(URLRequest(url: url))
        try await waitUntil(timeout: .seconds(10)) { ends == target }
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.targetFrame?.isMainFrame == true {
            onMainFrameDecision?(webView.configuration.userContentController)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ends += 1 }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { ends += 1 }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        ends += 1
    }
}
