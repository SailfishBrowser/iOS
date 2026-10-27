import Foundation
import Testing
import WebKit
@testable import SailBrowser

@Suite(.serialized)
struct TrackerCounterTests {
    @Test func blockedScriptAndImageLoadsArePostedOnce() async throws {
        let rule = ##"[{"trigger":{"url-filter":"tracker\\."},"action":{"type":"block"}}]"##
        let list = try #require(
            try await temporaryRuleStore().compileContentRuleList(forIdentifier: "tracker", encodedContentRuleList: rule))
        let handler = RecordingMessages()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(list)
        configuration.userContentController.addUserScript(TrackerCounter.script)
        configuration.userContentController.add(handler, contentWorld: .defaultClient, name: TrackerCounter.handlerName)
        let server = try await LocalPageServer { _ in
            #"<script src="/tracker.js"></script><img src="/tracker.gif"><img src="/tracker.gif"><img src="/fine.gif">"#
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: server.url("/page")))

        let expected = Set(["/tracker.js", "/tracker.gif"].map { server.url($0).absoluteString })
        try await waitUntil(timeout: .seconds(10)) { Set(handler.bodies) == expected }
        try await Task.sleep(for: .milliseconds(300))
        #expect(handler.bodies.count == 2)
        #expect(server.requestedPaths == ["/page", "/fine.gif"])
    }
}

@Suite(.serialized)
struct TrackerCountTests {
    // The page blocks one tracker twice, one in a frame, and one on a host outside the domain set.
    @Test func blockedLoadsOnListedHostsCountOncePerPageAndResetOnTheNextPage() async throws {
        let blocker = ContentBlocker(
            categories: Set(BlockingCategory.allCases), store: temporaryRuleStore(),
            bundle: try ruleBundle(##"[{"trigger":{"url-filter":"tracker\\."},"action":{"type":"block"}}]"##))
        await blocker.prepare()
        let pool = WebViewPool(blocker: blocker, sessions: SessionStore(directories: .temporary()), haptics: recordingHaptics())
        pool.trackers.domains = try trackerDomains(["127.0.0.1"])
        let port = PortBox()
        let server = try await LocalPageServer { path in
            switch path {
            case "/page-main":
                #"<img src="/tracker.gif"><img src="/tracker.gif?again"><script src="/tracker.js"></script>"#
                    + #"<img src="http://localhost:\#(port.value)/tracker.gif"><iframe src="/page-frame"></iframe>"#
            case "/page-frame": #"<img src="/tracker.gif"><img src="/tracker.gif?frame">"#
            default: "<p>clean</p>"
            }
        }
        port.value = server.url("/").port!
        let tab = Tab(
            id: UUID(), url: server.url("/page-main"), title: "", isPinned: false, prefersDesktop: false,
            createdAt: .now, lastActiveAt: .now, tint: nil)
        let controller = pool.controller(for: tab)

        try await waitUntil(timeout: .seconds(10)) { controller.blockedCount == 4 }
        try await Task.sleep(for: .milliseconds(500))
        #expect(controller.blockedCount == 4)

        let finished = FinishedURLs()
        controller.onFinish = { url, _ in finished.urls.append(url) }
        controller.load(server.url("/page-clean"))
        try await waitUntil(timeout: .seconds(10)) { finished.urls == [server.url("/page-clean")] }
        #expect(controller.blockedCount == 0)
    }

    @Test func nothingCountsBeforeTheDomainSetLoads() async throws {
        let blocker = ContentBlocker(
            categories: Set(BlockingCategory.allCases), store: temporaryRuleStore(),
            bundle: try ruleBundle(##"[{"trigger":{"url-filter":"tracker\\."},"action":{"type":"block"}}]"##))
        await blocker.prepare()
        let pool = WebViewPool(blocker: blocker, sessions: SessionStore(directories: .temporary()), haptics: recordingHaptics())
        let server = try await LocalPageServer { _ in #"<img src="/tracker.gif">"# }
        let tab = Tab(
            id: UUID(), url: server.url("/page"), title: "", isPinned: false, prefersDesktop: false,
            createdAt: .now, lastActiveAt: .now, tint: nil)
        let controller = pool.controller(for: tab)
        try await waitUntil(timeout: .seconds(10)) { controller.hasSettled }
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.blockedCount == 0)
    }
}

private final class PortBox { var value = 0 }

final class RecordingMessages: NSObject, WKScriptMessageHandler {
    private(set) var bodies: [String] = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        bodies.append(message.body as! String)
    }
}
