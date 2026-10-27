import Foundation
import Testing
import UIKit
import WebKit
@testable import SailBrowser

struct WebViewPoolTests {
    private let sessions = SessionStore(directories: .temporary())
    private let blocker = ContentBlocker(categories: Set(BlockingCategory.allCases))

    private func makeTab(desktop: Bool = false) -> Tab {
        Tab(
            id: UUID(), url: URL(string: "about:blank")!, title: "", isPinned: false, prefersDesktop: desktop,
            createdAt: .now, lastActiveAt: .now, tint: nil)
    }

    private func settledController(_ pool: WebViewPool, _ tab: Tab) async throws -> WebTabController {
        let controller = pool.controller(for: tab)
        try await waitUntil { controller.hasSettled }
        return controller
    }

    private func simulateAndFinish(_ controller: WebTabController, html: String, url: String) async {
        await confirmation { finished in
            await withCheckedContinuation { continuation in
                controller.onFinish = { _, _ in
                    controller.onFinish = nil
                    finished()
                    continuation.resume()
                }
                controller.webView.loadSimulatedRequest(URLRequest(url: URL(string: url)!), responseHTML: html)
            }
        }
    }

    @Test func discardedTabNeverRunsItsPendingFinish() async throws {
        let pool = WebViewPool(capacity: 2, blocker: blocker, sessions: sessions, haptics: recordingHaptics())
        let tab = makeTab()
        let controller = try await settledController(pool, tab)
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        controller.webView.frame = window.bounds
        window.addSubview(controller.webView)
        window.makeKeyAndVisible()

        var finishes = 0
        controller.onFinish = { _, _ in finishes += 1 }
        let discarded = DiscardFlag()
        let observation = controller.webView.observe(\.isLoading, options: .new) { webView, _ in
            MainActor.assumeIsolated {
                guard !webView.isLoading else { return }
                Task {
                    pool.discard(tab.id)
                    discarded.value = true
                }
            }
        }
        defer { observation.invalidate() }
        controller.webView.loadSimulatedRequest(
            URLRequest(url: URL(string: "https://example.test/discard")!), responseHTML: "<p>discard</p>")

        try await waitUntil { discarded.value }
        try await Task.sleep(for: .seconds(1))
        #expect(finishes == 0)
        #expect(!controller.hasSettled)
    }

    // A warning evicts through the normal path: the evicted tab's pending finish is cancelled and the spare web view
    // goes. The negative is proved by ordering: the eviction lands, two frames pass, and no finish has run.
    @Test func aMemoryWarningStopsTheEvictedTabsPendingFinishAndDropsThePrewarm() async throws {
        let pool = WebViewPool(blocker: blocker, sessions: sessions, haptics: recordingHaptics())
        let loading = makeTab()
        let controller = try await settledController(pool, loading)
        let last = makeTab()
        _ = try await settledController(pool, makeTab())
        _ = try await settledController(pool, last)
        pool.prewarm()
        #expect(pool.prewarmed != nil)
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        controller.webView.frame = window.bounds
        window.addSubview(controller.webView)
        window.makeKeyAndVisible()

        var finishes = 0
        controller.onFinish = { _, _ in finishes += 1 }
        let observation = controller.webView.observe(\.isLoading, options: .new) { webView, _ in
            MainActor.assumeIsolated {
                guard !webView.isLoading else { return }
                Task { pool.handleMemoryWarning(keeping: last.id) }
            }
        }
        defer { observation.invalidate() }
        controller.webView.loadSimulatedRequest(
            URLRequest(url: URL(string: "https://example.test/warned")!), responseHTML: "<p>warned</p>")

        try await waitUntil { pool.liveController(for: loading.id) == nil && pool.prewarmed == nil }
        #expect(pool.isUnderPressure)
        await nextDisplayFrame()
        await nextDisplayFrame()
        #expect(finishes == 0)
        #expect(!controller.hasSettled)
    }

    // After a warning the next new tab's first reveal ends the pressure and builds the spare; with no new tab, the
    // pressure ending builds it at once.
    @Test func afterAWarningTheFirstRevealEndsPressure() async throws {
        let pool = WebViewPool(blocker: blocker, sessions: sessions, haptics: recordingHaptics())
        let handler = StalledSchemeHandler()
        pool.configuration.setURLSchemeHandler(handler, forURLScheme: "stall")
        pool.handleMemoryWarning(keeping: nil)
        var tab = makeTab()
        tab.url = URL(string: "stall://page/hangs")!
        let controller = pool.controller(for: tab)
        try await waitUntil { handler.startedURLs == [tab.url] }
        #expect(pool.prewarmed == nil)
        #expect(pool.isUnderPressure)

        controller.webView.stopLoading()
        try await waitUntil { controller.hasSettled }
        try await waitUntil { pool.prewarmed != nil }
        #expect(!pool.isUnderPressure)

        let idle = WebViewPool(blocker: blocker, sessions: sessions, haptics: recordingHaptics())
        idle.handleMemoryWarning(keeping: nil)
        idle.prewarm()
        #expect(idle.prewarmed == nil)
        idle.pressureEnded()
        #expect(idle.prewarmed != nil)
    }

    @Test func prewarmObeysItsGate() {
        var allowed = false
        let pool = WebViewPool(blocker: blocker, sessions: sessions, haptics: recordingHaptics(), prewarms: { allowed })
        pool.prewarm()
        #expect(pool.prewarmed == nil)
        allowed = true
        pool.prewarm()
        #expect(pool.prewarmed != nil)
        pool.handleMemoryWarning(keeping: nil)
        pool.prewarm()
        #expect(pool.prewarmed == nil)
    }

    @Test func poolEvictsLeastRecentAndSavesSession() async throws {
        let pool = WebViewPool(capacity: 2, blocker: blocker, sessions: sessions, haptics: recordingHaptics())
        let tabs = [makeTab(), makeTab(), makeTab()]
        for tab in tabs {
            _ = try await settledController(pool, tab)
        }

        #expect(pool.liveController(for: tabs[0].id) == nil)
        #expect(pool.liveController(for: tabs[1].id) != nil)
        #expect(pool.liveController(for: tabs[2].id) != nil)
        #expect(sessions.load(tabs[0].id) != nil)
        #expect(sessions.load(tabs[1].id) == nil)
    }

    @Test func evictedTabRecreatesWithBackList() async throws {
        let pool = WebViewPool(capacity: 1, blocker: blocker, sessions: sessions, haptics: recordingHaptics())
        let tab = makeTab()
        let first = try await settledController(pool, tab)
        await simulateAndFinish(first, html: "<p>a</p>", url: "https://example.test/a")
        await simulateAndFinish(first, html: "<p>b</p>", url: "https://example.test/b")
        #expect(first.canGoBack)

        _ = try await settledController(pool, makeTab())
        #expect(pool.liveController(for: tab.id) == nil)

        var created: [Tab.ID] = []
        pool.onControllerCreated = { created.append($0.tabID) }
        let restored = pool.controller(for: tab)
        #expect(restored !== first)
        #expect(created == [tab.id])
        #expect(!restored.isRevealable)
        try await waitUntil(timeout: .seconds(10)) { restored.hasSettled }
        #expect(restored.canGoBack)
        #expect(restored.webView.backForwardList.currentItem?.url == URL(string: "https://example.test/b"))
    }

    // A page brought back from its session paints a blank document before its content: on the phone a cold tab landed
    // by a swipe showed white for 40 frames. It stays covered by its snapshot until it
    // finishes, or until the reveal delay.
    @Test func aRestoredPageStaysCoveredUntilItFinishes() async throws {
        let pool = WebViewPool(blocker: blocker, sessions: sessions, haptics: recordingHaptics())
        pool.configuration.setURLSchemeHandler(HangingSchemeHandler(), forURLScheme: "hang")
        var tab = makeTab()
        tab.url = URL(string: "hang://page/a")!
        let first = pool.controller(for: tab)
        try await waitUntil { first.webView.backForwardList.currentItem?.url == tab.url }
        var latest = tab
        for _ in 0..<3 {
            latest = makeTab()
            _ = try await settledController(pool, latest)
        }
        pool.handleMemoryWarning(keeping: latest.id)
        #expect(pool.liveController(for: tab.id) == nil)

        let restored = pool.controller(for: tab)
        defer { restored.webView.stopLoading() }
        let window = showInWindow(restored)
        defer { window.isHidden = true }
        try await waitUntil { restored.webView.backForwardList.currentItem?.url == tab.url }
        try await Task.sleep(for: .milliseconds(400))
        #expect(!restored.isRevealable)
        try await waitUntil(timeout: .seconds(2)) { restored.isRevealable }
    }

    @Test func memoryWarningKeepsActivePlusOneAndSavesSessions() async throws {
        let pool = WebViewPool(blocker: blocker, sessions: sessions, haptics: recordingHaptics())
        let tabs = (0..<4).map { _ in makeTab() }
        for tab in tabs {
            _ = try await settledController(pool, tab)
        }

        pool.handleMemoryWarning(keeping: tabs[0].id)

        #expect(pool.liveController(for: tabs[0].id) != nil)
        #expect(pool.liveController(for: tabs[1].id) == nil)
        #expect(pool.liveController(for: tabs[2].id) == nil)
        #expect(pool.liveController(for: tabs[3].id) != nil)
        for tab in tabs {
            #expect(sessions.load(tab.id) != nil)
        }
    }

    @Test func prewarmedTabHasNoBackItem() async throws {
        let pool = WebViewPool(blocker: blocker, sessions: sessions, haptics: recordingHaptics())
        pool.prewarm()
        try await Task.sleep(for: .milliseconds(500))
        var tab = makeTab()
        tab.url = URL(string: "data:text/html,<p>local</p>")!
        let controller = pool.controller(for: tab)
        try await waitUntil { controller.hasSettled }

        #expect(controller.url == tab.url)
        #expect(!controller.canGoBack)
        #expect(controller.webView.backForwardList.backList.isEmpty)
    }

    @Test func prewarmLoadInFlightNeverRevealsAdoptingTab() async throws {
        let pool = WebViewPool(blocker: blocker, sessions: sessions, haptics: recordingHaptics())
        let handler = StalledSchemeHandler()
        pool.configuration.setURLSchemeHandler(handler, forURLScheme: "stall")
        pool.prewarm()
        var tab = makeTab()
        tab.url = URL(string: "stall://page/hangs")!
        let controller = pool.controller(for: tab)
        defer { controller.webView.stopLoading() }
        try await waitUntil { handler.startedURLs == [tab.url] }

        #expect(controller.isLoading)
        #expect(!controller.hasSettled)
        #expect(!controller.isRevealable)
    }

    @Test func replacementPrewarmWaitsForTheTabsFirstCommit() async throws {
        let pool = WebViewPool(blocker: blocker, sessions: sessions, haptics: recordingHaptics())
        let handler = StalledSchemeHandler()
        pool.configuration.setURLSchemeHandler(handler, forURLScheme: "stall")
        pool.prewarm()
        var tab = makeTab()
        tab.url = URL(string: "stall://page/hangs")!
        let controller = pool.controller(for: tab)
        try await waitUntil { handler.startedURLs == [tab.url] }
        try await Task.sleep(for: .milliseconds(200))
        #expect(pool.prewarmed == nil)

        controller.webView.stopLoading()
        try await waitUntil { controller.hasSettled }
        #expect(pool.prewarmed != nil)
    }

    @Test func pendingWebViewIsSizedAndInsetForThePageBeforeAttach() {
        let page = PageGeometry(bounds: CGRect(x: 0, y: 0, width: 440, height: 956), safeTop: 62)
        let pool = WebViewPool(blocker: blocker, sessions: sessions, haptics: recordingHaptics())
        pool.page = page
        pool.prewarm()
        let controllers = [pool.controller(for: makeTab()), pool.controller(for: makeTab())]
        for controller in controllers {
            defer { controller.webView.stopLoading() }
            #expect(controller.webView.window == nil)
            #expect(controller.webView.frame == page.bounds)
            #expect(controller.webView.obscuredContentInsets.top == 62)
            #expect(controller.webView.obscuredContentInsets.bottom == Theme.Metrics.barTotalHeight)
        }
    }

    @Test func offWindowFinishDoesNotPrewarmUntilTheReveal() async throws {
        let pool = WebViewPool(blocker: blocker, sessions: sessions, haptics: recordingHaptics())
        pool.prewarm()
        var tab = makeTab()
        tab.url = URL(string: "data:text/html,<p>done</p>")!
        let controller = pool.controller(for: tab)
        try await waitUntil { controller.hasSettled }
        try await Task.sleep(for: .milliseconds(200))
        #expect(pool.prewarmed == nil)

        let window = showInWindow(controller)
        defer { window.isHidden = true }
        try await waitUntil { controller.isRevealable }
        #expect(pool.prewarmed != nil)
    }

    @Test func replacementPrewarmWaitsForTheRevealNotTheCommit() async throws {
        let pool = WebViewPool(blocker: blocker, sessions: sessions, haptics: recordingHaptics())
        pool.configuration.setURLSchemeHandler(HangingSchemeHandler(), forURLScheme: "hang")
        pool.prewarm()
        var tab = makeTab()
        tab.url = URL(string: "hang://page/a")!
        let controller = pool.controller(for: tab)
        defer { controller.webView.stopLoading() }
        try await waitUntil { controller.webView.backForwardList.currentItem?.url == tab.url }
        try await Task.sleep(for: .milliseconds(200))
        #expect(pool.prewarmed == nil)

        let window = showInWindow(controller)
        defer { window.isHidden = true }
        try await waitUntil { controller.isRevealable }
        #expect(pool.prewarmed != nil)
    }

    @Test func discardingATabBeforeItsFirstCommitStillPrewarms() async throws {
        let pool = WebViewPool(blocker: blocker, sessions: sessions, haptics: recordingHaptics())
        let handler = StalledSchemeHandler()
        pool.configuration.setURLSchemeHandler(handler, forURLScheme: "stall")
        pool.prewarm()
        var tab = makeTab()
        tab.url = URL(string: "stall://page/hangs")!
        let controller = pool.controller(for: tab)
        defer { controller.webView.stopLoading() }
        try await waitUntil { handler.startedURLs == [tab.url] }
        #expect(pool.prewarmed == nil)

        pool.discard(tab.id)
        #expect(pool.prewarmed != nil)
    }

    @Test func tabsOnDifferentSitesGetTheirOwnListsFromTheirHostsSetting() async throws {
        let blocker = ContentBlocker(categories: Set(BlockingCategory.allCases), store: temporaryRuleStore(), bundle: try adRuleBundle())
        await blocker.prepare()
        let pool = WebViewPool(blocker: blocker, sessions: sessions, haptics: recordingHaptics())
        pool.siteSettings = { host, _ in SiteSettings(blocksTrackers: host != "localhost") }
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        var allowedTab = makeTab(), blockedTab = makeTab()
        blockedTab.url = server.url("/page")
        allowedTab.url = URL(string: blockedTab.url.absoluteString.replacing("127.0.0.1", with: "localhost"))!
        let allowed = pool.controller(for: allowedTab), blocked = pool.controller(for: blockedTab)
        let finished = FinishedURLs()
        allowed.onFinish = { url, _ in finished.urls.append(url) }
        blocked.onFinish = { url, _ in finished.urls.append(url) }
        try await waitUntil(timeout: .seconds(10)) { Set(finished.urls) == [allowedTab.url, blockedTab.url] }

        let allowedLists = allowed.webView.configuration.userContentController
        let blockedLists = blocked.webView.configuration.userContentController
        #expect(allowedLists !== blockedLists)
        #expect(!blocker.isBlocking(allowedLists))
        #expect(blocker.isBlocking(blockedLists))
    }

    @Test func liveControllerIsReusedAndProtectedFromEviction() async throws {
        let pool = WebViewPool(capacity: 2, blocker: blocker, sessions: sessions, haptics: recordingHaptics())
        let tabs = [makeTab(), makeTab(), makeTab()]
        let first = try await settledController(pool, tabs[0])
        _ = try await settledController(pool, tabs[1])
        #expect(pool.controller(for: tabs[0]) === first)
        _ = try await settledController(pool, tabs[2])

        #expect(pool.liveController(for: tabs[0].id) === first)
        #expect(pool.liveController(for: tabs[1].id) == nil)
    }

    // A controller can outlive its pool; its site and popup hooks then leave the freed pool alone.
    @Test func aControllerThatOutlivesItsPoolStillNavigates() async throws {
        weak var freed: WebViewPool?
        let controller: WebTabController
        do {
            let pool = WebViewPool(blocker: blocker, sessions: sessions, haptics: recordingHaptics())
            freed = pool
            controller = try await settledController(pool, makeTab())
        }
        #expect(freed == nil)
        controller.preparePopup(WKWebViewConfiguration())
        await simulateAndFinish(controller, html: "<p>after</p>", url: "https://example.test/after")
        #expect(controller.url == URL(string: "https://example.test/after"))
    }

    private func userAgent(desktop: Bool) async throws -> String {
        let pool = WebViewPool(blocker: blocker, sessions: sessions, haptics: recordingHaptics())
        let controller = try await settledController(pool, makeTab(desktop: desktop))
        await simulateAndFinish(controller, html: "<p>ua</p>", url: "https://example.test/ua")
        return try #require(try await controller.webView.evaluateJavaScript("navigator.userAgent") as? String)
    }

    private var safariVersion: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Version/\(os.majorVersion).\(os.minorVersion)"
    }

    @Test func mobileUserAgentCarriesSafarisSuffixForTheRunningIOS() async throws {
        let agent = try await userAgent(desktop: false)
        #expect(agent.hasPrefix("Mozilla/5.0 (iPhone; CPU iPhone OS "))
        #expect(agent.hasSuffix(") AppleWebKit/605.1.15 (KHTML, like Gecko) \(safariVersion) Mobile/15E148 Safari/604.1"))
    }

    @Test func desktopUserAgentLooksLikeMacSafari() async throws {
        let agent = try await userAgent(desktop: true)
        #expect(agent.hasPrefix("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "))
        #expect(agent.hasSuffix(" \(safariVersion) Safari/605.1.15"))
    }

    @Test func poolWebViewsAllowElementFullscreen() async throws {
        let pool = WebViewPool(blocker: blocker, sessions: sessions, haptics: recordingHaptics())
        let controller = try await settledController(pool, makeTab())
        #expect(controller.webView.configuration.preferences.isElementFullscreenEnabled)
    }
}

private final class DiscardFlag { var value = false }
