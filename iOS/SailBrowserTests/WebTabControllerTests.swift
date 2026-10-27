import SwiftUI
import Testing
import UIKit
import WebKit
@testable import SailBrowser

@Suite(.serialized)
struct WebTabControllerTests {
    // The reader's link policy task keeps the reader past its tab; a link it opens then leaves the freed tab alone.
    @Test func aReaderLinkAfterItsTabIsFreedOpensNothing() {
        weak var freed: WebTabController?
        let reader: ReaderController
        do {
            let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
            freed = controller
            reader = controller.reader
        }
        #expect(freed == nil)
        reader.onOpen?(URL(string: "https://example.test/linked")!)
    }

    @Test func failedProvisionalLoadSettlesController() async throws {
        let handler = FailingSchemeHandler()
        let url = URL(string: "fail://page/a")!
        handler.failures[url] = .cannotFindHost
        let controller = failingController(handler)
        let window = showInWindow(controller)
        defer { window.isHidden = true }
        controller.load(url)

        try await waitUntil { controller.hasSettled && controller.isRevealable }
    }

    @Test func supersededFirstNavigationDoesNotReveal() async throws {
        let handler = StalledSchemeHandler()
        let controller = stalledController(handler)
        defer { controller.webView.stopLoading() }
        let first = URL(string: "stall://page/first")!
        let second = URL(string: "stall://page/second")!
        controller.load(first)
        try await waitUntil { handler.startedURLs == [first] }
        controller.load(second)
        try await waitUntil { handler.startedURLs == [first, second] }

        #expect(controller.isLoading)
        #expect(!controller.hasSettled)
        #expect(!controller.isRevealable)
    }

    @Test func supersededCommittedNavigationDoesNotSettle() async throws {
        let handler = StalledSchemeHandler()
        let controller = hangingController(stalling: handler)
        defer { controller.webView.stopLoading() }
        controller.load(URL(string: "hang://page/a")!)
        try await waitUntil { controller.webView.backForwardList.currentItem?.url == URL(string: "hang://page/a") }

        let second = URL(string: "stall://page/second")!
        controller.load(second)
        try await waitUntil { handler.startedURLs == [second] }

        #expect(controller.isLoading)
        #expect(!controller.hasSettled)
        #expect(!controller.isRevealable)
    }

    @Test func stoppedCommittedNavigationSettlesAndReveals() async throws {
        let controller = hangingController()
        let window = showInWindow(controller)
        defer { window.isHidden = true }
        controller.load(URL(string: "hang://page/a")!)
        try await waitUntil { controller.webView.backForwardList.currentItem?.url == URL(string: "hang://page/a") }

        controller.webView.stopLoading()
        try await waitUntil { controller.hasSettled }
        await controller.paintTask?.value
        #expect(controller.isRevealable)
    }

    @Test func stoppedOnlyNavigationSettlesAndReveals() async throws {
        let handler = StalledSchemeHandler()
        let controller = stalledController(handler)
        let window = showInWindow(controller)
        defer { window.isHidden = true }
        let only = URL(string: "stall://page/only")!
        controller.load(only)
        try await waitUntil { handler.startedURLs == [only] }

        controller.webView.stopLoading()
        try await waitUntil { controller.hasSettled }
        await controller.paintTask?.value
        #expect(controller.isRevealable)
    }

    @Test func revealableNeverResetsOnLaterNavigation() async throws {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        let window = showInWindow(controller)
        defer { window.isHidden = true }
        #expect(!controller.isRevealable)

        await loadAndFinish(controller, html: "<p>a</p>", base: "https://example.test/a")
        #expect(controller.isRevealable)
        #expect(controller.hasSettled)

        let slowPage = "<p>b</p><script>const start = Date.now(); while (Date.now() - start < 300) {}</script>"
        controller.webView.loadHTMLString(slowPage, baseURL: URL(string: "https://other.test/b"))
        try await waitUntil { !controller.hasSettled }
        #expect(controller.isRevealable)
        try await waitUntil { controller.hasSettled }
        #expect(controller.isRevealable)
    }

    // Every icon the page offers, largest first, then /favicon.ico, so one the store cannot decode (an SVG) has a next.
    @Test func faviconDiscoveryListsIconsLargestFirstThenFaviconIco() async throws {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        var found: [String: [URL]] = [:]
        controller.onFavicon = { host, urls in found[host] = urls }

        let icons = """
            <link rel="icon" href="/small.png" sizes="16x16">
            <link rel="apple-touch-icon" href="/touch.png">
            <link rel="shortcut icon" href="/large.png" sizes="256x256">
            """
        controller.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://icons.test/page")!), responseHTML: icons)
        try await waitUntil { found["icons.test"] != nil }
        #expect(found["icons.test"] == ["large.png", "touch.png", "small.png", "favicon.ico"].map {
            URL(string: "https://icons.test/\($0)")!
        })

        let svg = #"<link rel="icon" href="y18.svg">"#
        controller.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://svg.test/news")!), responseHTML: svg)
        try await waitUntil { found["svg.test"] != nil }
        #expect(found["svg.test"] == [URL(string: "https://svg.test/y18.svg")!, URL(string: "https://svg.test/favicon.ico")!])

        controller.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://plain.test/a/b")!), responseHTML: "<p>x</p>")
        try await waitUntil { found["plain.test"] != nil }
        #expect(found["plain.test"] == [URL(string: "https://plain.test/favicon.ico")!])
    }

    // The discovery script runs apart from the page's globals, so a page that replaces them cannot change its answer.
    @Test func aPageThatReplacesItsGlobalsStillReportsItsIcons() async throws {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        var found: [String: [URL]] = [:]
        controller.onFavicon = { host, urls in found[host] = urls }

        let page = """
            <link rel="icon" href="/icon.png">
            <script>window.Set = function () { return [1] }; window.URL = function () { return {} }</script>
            """
        controller.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://globals.test/")!), responseHTML: page)
        try await waitUntil { found["globals.test"] != nil }

        #expect(found["globals.test"] == [
            URL(string: "https://globals.test/icon.png")!, URL(string: "https://globals.test/favicon.ico")!,
        ])
    }

    @Test func findNavigatorVisibilityTracksPresentAndDismiss() async throws {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        let window = showInKeyWindow(controller)
        defer { window.isHidden = true }
        await loadAndFinish(controller, html: "<p>find me</p>", base: "https://example.test/find")
        #expect(!controller.isFindNavigatorVisible)

        controller.presentFind()
        #expect(controller.isFindNavigatorVisible)

        controller.webView.findInteraction?.dismissFindNavigator()
        try await waitUntil { !controller.isFindNavigatorVisible }
    }

    @Test func onScreenFinishWaitsForThePaintedBackground() async throws {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        let window = showInKeyWindow(controller)
        defer { window.isHidden = true }
        let traits = UITraitCollection(userInterfaceStyle: .light)

        var tintAtFinish: UIColor?
        await withCheckedContinuation { continuation in
            controller.onFinish = { _, _ in
                controller.onFinish = nil
                tintAtFinish = controller.barTint
                continuation.resume()
            }
            controller.webView.loadHTMLString(
                "<body style='background:#261d33'><p>dark</p></body>", baseURL: URL(string: "https://example.test/dark"))
        }

        #expect(controller.isRevealable)
        #expect(!Theme.Palette.isLight(try #require(tintAtFinish), in: traits))
    }

    @Test func pullReleaseMarksRefreshingUntilCommit() async throws {
        let controller = hangingController()
        defer { controller.webView.stopLoading() }
        controller.load(URL(string: "hang://page/a")!)
        try await waitUntil { controller.webView.backForwardList.currentItem?.url == URL(string: "hang://page/a") }
        controller.webView.stopLoading()
        try await waitUntil { controller.hasSettled }
        #expect(!controller.isPullRefreshing)

        pullAndRelease(controller)
        #expect(controller.isPullRefreshing)

        try await waitUntil { !controller.isPullRefreshing }
        #expect(controller.isLoading)
    }

    @Test func pullOnAnEmptyWebViewDoesNotStayRefreshing() async throws {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        pullAndRelease(controller)
        try await waitUntil(timeout: .seconds(1)) { !controller.isPullRefreshing }
    }

    @Test func pullWhoseReloadFailsBeforeCommitClearsWhenItSettles() async throws {
        let handler = FailingReloadSchemeHandler()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: "once")
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(frame: .zero, configuration: configuration), haptics: recordingHaptics())
        controller.load(URL(string: "once://page/a")!)
        try await waitUntil { controller.hasSettled }

        pullAndRelease(controller)
        #expect(controller.isPullRefreshing)
        try await waitUntil { !controller.isPullRefreshing }
        #expect(handler.requestCount == 2)
        #expect(controller.hasSettled)
    }

    @Test func insetsFollowTheSafeTopAndTheBar() {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        let scrollView = controller.webView.scrollView
        controller.apply(safeTop: 62)
        let launch = UIEdgeInsets(top: 62, left: 0, bottom: Theme.Metrics.barTotalHeight, right: 0)
        #expect(controller.webView.obscuredContentInsets == launch)
        #expect(scrollView.verticalScrollIndicatorInsets == launch)
        #expect(scrollView.horizontalScrollIndicatorInsets == launch)

        controller.apply(safeTop: 82)
        let banner = UIEdgeInsets(top: 82, left: 0, bottom: Theme.Metrics.barTotalHeight, right: 0)
        #expect(controller.webView.obscuredContentInsets == banner)
        #expect(scrollView.verticalScrollIndicatorInsets == banner)
    }

    @Test func pageAtItsTopStaysBelowTheSafeTopWhenItChanges() async throws {
        let (window, controller, scrollView) = await tallPage()
        defer { window.isHidden = true }
        #expect(scrollView.contentOffset.y == -62)

        controller.apply(safeTop: 82)
        #expect(scrollView.contentOffset.y == -82)

        scrollView.contentOffset.y = 500
        controller.apply(safeTop: 62)
        #expect(scrollView.contentOffset.y == 500)
    }

    @Test func pullCountsOverscrollFromTheObscuredTop() {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        controller.apply(safeTop: 62)
        let scrollView = TrackingScrollView()

        scrollView.contentOffset.y = -62
        controller.scrollViewDidScroll(scrollView)
        #expect(controller.pullProgress == 0)
        #expect(controller.refreshGap == 0)

        scrollView.contentOffset.y = -62 - Theme.Refresh.armDistance / 2
        controller.scrollViewDidScroll(scrollView)
        #expect(controller.pullProgress == 0.5)
        #expect(controller.refreshGap == Theme.Metrics.refreshHold)
    }

    @Test func refreshGapFollowsTheSpaceAboveThePageUpToTheHold() {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        controller.apply(safeTop: 62)
        let scrollView = UIScrollView()
        let hold = Theme.Metrics.refreshHold
        for (offset, gap) in [(-62, 0), (-82, 20), (-62 - hold, hold), (-300, hold), (400, 0)] as [(CGFloat, CGFloat)] {
            scrollView.contentOffset.y = offset
            controller.scrollViewDidScroll(scrollView)
            #expect(controller.refreshGap == gap)
        }
    }

    @Test func refreshHoldsThePageDownByTheRingUntilCommit() async throws {
        let (window, controller, top) = try await pulledHangingPage()
        defer { window.isHidden = true }
        defer { controller.webView.stopLoading() }
        let hold = Theme.Metrics.refreshHold
        let pageScroll = controller.webView.scrollView

        let target = pullAndRelease(controller)
        #expect(controller.isPullRefreshing)
        #expect(controller.webView.obscuredContentInsets.top == top + hold)
        #expect(pageScroll.contentOffset.y == -top - 2 * Theme.Refresh.armDistance)
        #expect(target == .zero)

        pageScroll.contentOffset.y = -top - hold
        try await waitUntil { !controller.isPullRefreshing }
        #expect(controller.webView.obscuredContentInsets.top == top)
        #expect(pageScroll.contentOffset.y == -top)
        try await Task.sleep(for: .milliseconds(300))
        #expect(pageScroll.contentOffset.y == -top)
    }

    @Test func refreshCommittingMidBounceSpringsFromTheBounceNotTheHeldTop() async throws {
        let (window, controller, top) = try await pulledHangingPage()
        defer { window.isHidden = true }
        defer { controller.webView.stopLoading() }
        let hold = Theme.Metrics.refreshHold
        let pageScroll = controller.webView.scrollView

        pullAndRelease(controller)
        let midBounce = -top - hold - 30
        pageScroll.contentOffset.y = midBounce
        var offsets: [CGFloat] = []
        let observation = pageScroll.observe(\.contentOffset, options: .new) { scrollView, _ in
            MainActor.assumeIsolated { offsets.append(scrollView.contentOffset.y) }
        }
        try await waitUntil { !controller.isPullRefreshing }
        observation.invalidate()

        #expect(pageScroll.contentOffset.y == -top)
        #expect(offsets.last == -top)
        let releaseStart = try #require(offsets.lastIndex(of: midBounce))
        #expect(offsets[(releaseStart + 1)...].allSatisfy { $0 >= midBounce && $0 <= -top })
    }

    @Test func cancellingPendingWorkStopsAPendingReveal() async throws {
        let controller = hangingController()
        defer { controller.webView.stopLoading() }
        controller.load(URL(string: "hang://page/a")!)
        try await waitUntil { controller.webView.backForwardList.currentItem?.url == URL(string: "hang://page/a") }
        try await Task.sleep(for: .milliseconds(300))

        let window = showInWindow(controller)
        defer { window.isHidden = true }
        controller.cancelPendingWork()
        try await Task.sleep(for: Theme.Network.revealDelay + Theme.Latency.frame)
        #expect(!controller.isRevealable)
    }

    @Test func refreshCommittingDuringUIKitsOwnScrollStopsItAndRestsAtTheSafeTop() async throws {
        let (window, controller, top) = try await pulledHangingPage()
        defer { window.isHidden = true }
        defer { controller.webView.stopLoading() }
        let pageScroll = controller.webView.scrollView

        pullAndRelease(controller)
        pageScroll.setContentOffset(CGPoint(x: 0, y: -top - 3 * Theme.Refresh.armDistance), animated: true)
        var offsets: [CGFloat] = []
        let observation = pageScroll.observe(\.contentOffset, options: .new) { scrollView, _ in
            MainActor.assumeIsolated { offsets.append(scrollView.contentOffset.y) }
        }
        try await waitUntil { !controller.isPullRefreshing }
        try await Task.sleep(for: .milliseconds(600))
        observation.invalidate()

        #expect(pageScroll.contentOffset.y == -top)
        #expect(offsets.allSatisfy { $0 <= -top })
    }

    @Test func pageReleaseSpringMatchesTheRingSpring() throws {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        window.addSubview(view)
        window.isHidden = false
        let distance: CGFloat = 100
        let velocity: CGFloat = 1.5

        WebTabController.springScroll(velocity: velocity) { view.center.y += distance }
        let key = try #require(view.layer.animationKeys()?.first)
        let animation = try #require(view.layer.animation(forKey: key) as? CASpringAnimation)
        let page = Spring(mass: animation.mass, stiffness: animation.stiffness, damping: animation.damping)
        let ring = Theme.Motion.refreshRelease.spring

        for frame in 0...60 {
            let time = Double(frame) / 60
            let pageValue = page.value(target: distance, initialVelocity: velocity * distance, time: time)
            let ringValue = ring.value(target: distance, initialVelocity: velocity * distance, time: time)
            #expect(abs(pageValue - ringValue) < 1)
        }
    }

    @Test func refreshEndingAfterTheUserScrolledKeepsTheOffset() async throws {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        let window = showInWindow(controller)
        defer { window.isHidden = true }
        controller.apply(safeTop: 62)
        await loadAndFinish(controller, html: "<body style='height:4000px'>a</body>", base: "https://example.test/a")

        pullAndRelease(controller)
        #expect(controller.isPullRefreshing)
        controller.scrollViewWillBeginDragging(controller.webView.scrollView)
        controller.webView.scrollView.contentOffset.y = 500
        try await waitUntil { !controller.isPullRefreshing }
        #expect(controller.webView.obscuredContentInsets.top == 62)
        #expect(controller.webView.scrollView.contentOffset.y == 500)
    }

    @Test(.timeLimit(.minutes(1))) func committedPageInAWindowRevealsAtFirstPaintBeforeTheCap() async throws {
        let controller = hangingController()
        let window = showInWindow(controller)
        defer { window.isHidden = true }
        defer { controller.webView.stopLoading() }
        controller.load(URL(string: "hang://page/a")!)
        await withCheckedContinuation { revealed in controller.onFirstRevealOrFailure = { revealed.resume() } }

        #expect(controller.revealedAtPaint)
        #expect(controller.isRevealable)
        #expect(!controller.hasSettled)
        #expect(controller.isLoading)
    }

    @Test func offWindowCommitRevealsOnlyOnceShownInAWindow() async throws {
        let controller = hangingController()
        defer { controller.webView.stopLoading() }
        controller.load(URL(string: "hang://page/a")!)
        try await waitUntil { controller.webView.backForwardList.currentItem?.url == URL(string: "hang://page/a") }

        try await expectRevealOnlyOnceShown(controller)
        #expect(!controller.hasSettled)
    }

    @Test func offWindowFinishRevealsOnlyOnceShownInAWindow() async throws {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        await loadAndFinish(controller, html: "<p>a</p>", base: "https://example.test/a")
        #expect(controller.hasSettled)

        try await expectRevealOnlyOnceShown(controller)
    }

    @Test func scrollLimitsKeepThePageBetweenTheSafeTopAndTheBar() async throws {
        let (window, controller, scrollView) = await tallPage()
        defer { window.isHidden = true }

        _ = try await controller.webView.evaluateJavaScript("scrollTo(0, 99999); 0")
        try await waitUntil { scrollView.contentOffset.y > 0 }
        #expect(scrollView.contentOffset.y == scrollView.contentSize.height - scrollView.bounds.height + Theme.Metrics.barTotalHeight)

        #expect(scrollView.adjustedContentInset.top == 62)
        #expect(scrollView.adjustedContentInset.bottom == Theme.Metrics.barTotalHeight)
    }

    @Test func barEdgesRecordOncePerFlip() {
        let haptics = recordingHaptics()
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: haptics)
        for offset in [0, 100, 150, 200, 160, 120, 100] as [CGFloat] {
            controller.scrolled(offsetY: offset, maxOffsetY: 1000, tracking: true, decelerating: false)
        }
        let edges = haptics.records.map(\.interaction).filter { $0 == .barHide || $0 == .barShow }
        #expect(edges == [.barHide, .barShow])
        #expect(!controller.isBarHidden)
    }

    @Test func armedReleaseRecordsTheArmOnceAndTheRelease() {
        let sink = RecordingHapticSink(start: .now)
        let haptics = HapticsEngine(sink: sink)
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: haptics)
        for offset in [-100, -150, -148, -170, -146] as [CGFloat] {
            controller.scrolled(offsetY: offset, maxOffsetY: 1000, tracking: true, decelerating: false)
            sink.advance(by: Theme.Latency.frame)
        }
        #expect(controller.released())
        #expect(!controller.released())
        let pulls = haptics.records.filter { $0.interaction == .pullArm || $0.interaction == .pullRelease }
        #expect(pulls.map(\.interaction) == [.pullArm, .pullRelease])
        // The release is silent: the arm already promised the refresh.
        #expect(pulls.map(\.played) == [true, false])
        #expect(controller.pullProgress == 0)
    }

    @Test func aPullPreparesItsArmPastTheTopAndAgainOnceItGoesCold() {
        let sink = RecordingHapticSink(start: .now)
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: HapticsEngine(sink: sink))
        controller.scrolled(offsetY: 0, maxOffsetY: 1000, tracking: true, decelerating: false)
        controller.scrolled(offsetY: -5, maxOffsetY: 1000, tracking: false, decelerating: true)
        #expect(sink.calls.isEmpty)
        controller.scrolled(offsetY: -5, maxOffsetY: 1000, tracking: true, decelerating: false)
        controller.scrolled(offsetY: -8, maxOffsetY: 1000, tracking: true, decelerating: false)
        sink.advance(by: Theme.Haptic.preparedFor)
        controller.scrolled(offsetY: -9, maxOffsetY: 1000, tracking: true, decelerating: false)
        sink.advance(by: Theme.Latency.frame)
        controller.scrolled(offsetY: -150, maxOffsetY: 1000, tracking: true, decelerating: false)
        let h = Theme.Haptic.self
        let tick = h.refreshTicks[0]
        #expect(sink.calls == [.prepare(tick), .prepare(tick), .play(h.refreshArm)])
    }

    // A slow pull ticks at every step, each stronger than the last, and thocks once at the line.
    @Test func aSlowPullTicksEveryStepThenThocksOnce() {
        let sink = RecordingHapticSink(start: .now)
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: HapticsEngine(sink: sink))
        let step = Theme.Refresh.tickStep
        for overscroll in stride(from: step, through: Theme.Refresh.armDistance, by: step) {
            controller.scrolled(offsetY: -overscroll, maxOffsetY: 1000, tracking: true, decelerating: false)
            sink.advance(by: Theme.Haptic.pullTickGap)
        }
        #expect(sink.played == Theme.Haptic.refreshTicks + [Theme.Haptic.refreshArm])
    }

    // A fast pull crosses a step a frame apart; a tick inside the gap after the last records silently, so the ratchet
    // never smears into a buzz.
    @Test func aFastPullSkipsTicksInsideTheGap() {
        let sink = RecordingHapticSink(start: .now)
        let haptics = HapticsEngine(sink: sink)
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: haptics)
        let step = Theme.Refresh.tickStep
        for overscroll in stride(from: step, through: 3 * step, by: step) {
            controller.scrolled(offsetY: -overscroll, maxOffsetY: 1000, tracking: true, decelerating: false)
            sink.advance(by: Theme.Latency.frame)
        }
        #expect(sink.played == [Theme.Haptic.refreshTicks[0]])
        let ticks = haptics.records.filter { $0.interaction == .pullTick }
        #expect(ticks.map(\.played) == [true, false, false])
    }

    // The texture under the finger runs from the pull's first frame: each frame's level is that frame's movement, so
    // a resting finger is silent, and the release stops it once. A drag that never leaves the top runs none.
    @Test func thePullTextureFollowsTheFingerAndStopsAtTheRelease() {
        let sink = RecordingHapticSink(start: .now)
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: HapticsEngine(sink: sink))
        let texture = Theme.Haptic.pullTexture
        let frame = Theme.Latency.frame
        let full = Theme.Haptic.pullTextureSpeed * CGFloat(frame / .seconds(1))
        controller.scrolled(offsetY: 50, maxOffsetY: 1000, tracking: true, decelerating: false)
        #expect(!controller.released())
        #expect(sink.levels.isEmpty)
        #expect(!sink.calls.contains(.stop(texture)))

        controller.scrolled(offsetY: -5, maxOffsetY: 1000, tracking: true, decelerating: false)
        controller.pullFrame()
        sink.advance(by: frame)
        controller.scrolled(offsetY: -(5 + full), maxOffsetY: 1000, tracking: true, decelerating: false)
        controller.pullFrame()
        sink.advance(by: frame)
        controller.pullFrame()
        sink.advance(by: frame)
        controller.scrolled(offsetY: -(5 + full + full / 4), maxOffsetY: 1000, tracking: true, decelerating: false)
        controller.pullFrame()
        let intensities = sink.levels.map(\.intensity)
        #expect(intensities.count == 4)
        for (intensity, expected) in zip(intensities, [0, 1, 0, 0.25] as [Float]) {
            #expect(abs(intensity - expected) < 1e-5)
        }
        #expect(sink.levels.map(\.sharpness) == sink.levels.map(\.sharpness).sorted())
        #expect(sink.levels.last?.sharpness == Float(controller.pullProgress))

        #expect(!controller.released())
        #expect(sink.calls.last == .stop(texture))
        #expect(controller.pullProgress == 0)
        controller.released()
        #expect(sink.calls.filter { $0 == .stop(texture) }.count == 1)
    }

    @Test func halfAPullTicksWithoutArming() {
        let haptics = recordingHaptics()
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: haptics)
        controller.scrolled(offsetY: -Theme.Refresh.armDistance / 2, maxOffsetY: 1000, tracking: true, decelerating: false)
        #expect(!controller.isPullArmed)
        let pulls = haptics.records.map(\.interaction).filter { $0 != .barShow && $0 != .barHide }
        #expect(pulls == [.pullTick])
        #expect(!controller.released())
        #expect(!haptics.records.contains { $0.interaction == .pullRelease })
    }

    // A frame that jumps several steps ticks the one it reached; the arm plays once, and chatter round the line after
    // it is silent.
    @Test func aJumpingPullTicksTheStepItReachedThenArmsOnce() {
        let sink = RecordingHapticSink(start: .now)
        let haptics = HapticsEngine(sink: sink)
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: haptics)
        for offset in [-40, -61, -91, -121, -150, -140, -152] as [CGFloat] {
            controller.scrolled(offsetY: offset, maxOffsetY: 1000, tracking: true, decelerating: false)
            sink.advance(by: Theme.Haptic.pullTickGap)
        }
        let pulls = haptics.records.filter { $0.interaction == .pullTick || $0.interaction == .pullArm }
        #expect(pulls.map(\.interaction) == [.pullTick, .pullTick, .pullTick, .pullTick, .pullArm])
        let played = pulls.map(\.played)
        #expect(played == [true, true, true, true, true])
        let ticks = Theme.Haptic.refreshTicks
        #expect(sink.played == [ticks[3], ticks[5], ticks[8], ticks[11], Theme.Haptic.refreshArm])
    }

    // The reload's first paint lands the refresh; a reload whose load never finishes still lands.
    @Test func aRefreshLandsWhenTheReloadPaintsNotWhenItFinishes() async throws {
        let (window, controller, handler, haptics) = try await heldReload()
        defer { window.isHidden = true }
        defer { controller.webView.stopLoading() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!haptics.records.contains { $0.interaction == .refreshLand })

        handler.respondToHeld()
        try await waitUntil { haptics.records.contains { $0.interaction == .refreshLand } }
        #expect(!controller.hasSettled)
        let refresh: Set<Interaction> = [.pullArm, .pullRelease, .refreshLand]
        let recorded = haptics.records.map(\.interaction).filter { refresh.contains($0) }
        #expect(recorded == [.pullArm, .pullRelease, .refreshLand])
    }

    // A fast pull crosses the steps a couple of frames apart: only the first tick plays, the rest record silently,
    // and the arm always plays. A slow pull plays every tick.
    @Test(arguments: [(2, [true, false, false]), (10, [true, true, true])])
    func pullTicksKeepTheirGap(framesApart: Int, played: [Bool]) {
        let sink = RecordingHapticSink(start: .now)
        let haptics = HapticsEngine(sink: sink)
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: haptics)
        for offset in [-61, -91, -121, -150] as [CGFloat] {
            controller.scrolled(offsetY: offset, maxOffsetY: 1000, tracking: true, decelerating: false)
            sink.advance(by: Theme.Latency.frame * framesApart)
        }
        let ticks = haptics.records.filter { $0.interaction == .pullTick }
        #expect(ticks.map(\.played) == played)
        let arms = haptics.records.filter { $0.interaction == .pullArm }
        #expect(arms.map(\.played) == [true])
    }

    // Searching away during a slow reload replaces it: the new page's commit does not land the refresh.
    @Test func aReloadReplacedByAnotherLoadDoesNotLand() async throws {
        let (window, controller, handler, haptics) = try await heldReload()
        defer { window.isHidden = true }
        defer { controller.webView.stopLoading() }
        let other = URL(string: "hang://page/other")!
        controller.load(other)
        // The new load cancels the held reload before anything answers it.
        try await Task.sleep(for: .milliseconds(200))
        handler.respondToHeld()
        try await waitUntil { controller.url == other }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!haptics.records.contains { $0.interaction == .refreshLand })
    }

    @Test func aFailedReloadDoesNotLand() async throws {
        let (window, controller, handler, haptics) = try await heldReload()
        defer { window.isHidden = true }
        handler.failHeld()
        try await waitUntil { controller.hasSettled }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!haptics.records.contains { $0.interaction == .refreshLand })
    }

    @Test func aWobbleRoundTheArmLinePlaysOneTap() {
        let haptics = recordingHaptics()
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: haptics)
        for offset in [-150, -130, -155, -120, -160] as [CGFloat] {
            controller.scrolled(offsetY: offset, maxOffsetY: 1000, tracking: true, decelerating: false)
        }
        #expect(controller.isPullArmed)
        #expect(haptics.records.filter { $0.interaction == .pullArm }.count == 1)
    }

    @Test func pullArmedFollowsTheDetentNotTheProgress() {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        var armed: [Bool] = []
        for overscroll in [0, 150, 148, 151, 140, 152] as [CGFloat] {
            controller.scrolled(offsetY: -overscroll, maxOffsetY: 1000, tracking: true, decelerating: false)
            armed.append(controller.isPullArmed)
        }
        #expect(armed == [false, true, true, true, false, true])

        controller.released()
        #expect(!controller.isPullArmed)
    }

    @Test(arguments: [false, true])
    func barShowDriverShowsTheBarFromEitherState(startsHidden: Bool) {
        let haptics = recordingHaptics()
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: haptics)
        controller.webView.scrollView.contentSize = CGSize(width: 0, height: 4000)
        if startsHidden {
            for offset in [0, 100] as [CGFloat] {
                controller.scrolled(offsetY: offset, maxOffsetY: 4000, tracking: true, decelerating: false)
            }
        }
        #expect(controller.isBarHidden == startsHidden)
        let recorded = haptics.records.count

        let path = WebDrivers.barShowPath
        for (index, height) in path.enumerated() {
            let sample = DragSample(
                startLocation: .zero, location: .zero, translation: CGSize(width: 0, height: height), velocity: .zero,
                time: .now)
            controller.debugScroll(index == 0 ? .began : .changed, sample)
        }
        controller.debugScroll(.ended, DragSample(
            startLocation: .zero, location: .zero, translation: CGSize(width: 0, height: path.last!), velocity: .zero,
            time: .now))

        let edges = haptics.records[recorded...].map(\.interaction)
        #expect(edges.suffix(2) == [.barHide, .barShow])
        #expect(!controller.isBarHidden)
    }

    // The ring applies a sample before a probe started on that sample first runs; reading the baseline before the
    // sample keeps the arm's span to its next frame, and lets the release finish once the ring settles at 1.
    @Test(.timeLimit(.minutes(1))) func pullDriversProbeTheRingFromBeforeTheSample() async throws {
        // The live sink's clock is real, so records carry the instant the write latency is measured from.
        let env = makeEnvironment(hapticSink: LiveHapticSink())
        let controller = hangingController(haptics: env.haptics)
        defer { controller.webView.stopLoading() }
        let window = showInWindow(controller)
        defer { window.isHidden = true }
        let host = UIHostingController(rootView: LoadingRing(controller: controller).environment(env))
        host.view.frame = window.bounds
        window.addSubview(host.view)
        controller.load(URL(string: "hang://page/a")!)
        try await waitUntil { controller.webView.backForwardList.currentItem?.url == URL(string: "hang://page/a") }
        controller.webView.stopLoading()
        try await waitUntil { controller.hasSettled }
        env.publishDebugSurface(.webScroll, owner: UUID(), controller.debugScroll)
        #expect(env.debugWatches[.webScroll] != nil)

        let arm = await WebDrivers.probedScroll(
            env, WebDrivers.pullArmPath, over: WebDrivers.pullArmDuration, watching: .pullArm)
        #expect(arm < .milliseconds(100))
        #expect(!controller.isPullRefreshing)

        try await Task.sleep(for: .seconds(Theme.Refresh.armPulseDuration))
        let release = await WebDrivers.probedScroll(
            env, WebDrivers.pullReleasePath, over: WebDrivers.pullReleaseDuration, watching: .pullRelease)
        #expect(release < .milliseconds(100))
        let pulls: [Interaction] = env.haptics.records.map(\.interaction).filter { $0 == .pullArm || $0 == .pullRelease }
        #expect(pulls == [.pullArm, .pullArm, .pullRelease])
    }

    @Test func aReadablePageIsReaderableOnceFinishedUntilTheNextPageCommits() async throws {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        #expect(!controller.isReaderable)
        await loadAndFinish(controller, html: try ReaderFixtures.html("readability-001"), base: "https://example.test/a")
        try await waitUntil { controller.isReaderable }

        await loadAndFinish(controller, html: try ReaderFixtures.html("app-form"), base: "https://example.test/b")
        try await Task.sleep(for: .milliseconds(200))
        #expect(!controller.isReaderable)
    }

    @Test func theReaderShowsTheArticleOverThePageAndAnyNavigationClosesIt() async throws {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        await loadAndFinish(controller, html: try ReaderFixtures.html("readability-001"), base: "https://example.test/a")

        await controller.openReader(ruleLists: [])
        #expect(controller.readerArticle?.title == "Get your Frontend JavaScript Code Covered | Code")
        #expect(controller.reader.isOpen)
        #expect(controller.reader.page?.url?.absoluteString == "https://example.test/a")

        controller.load(page("b"))
        try await waitUntil { controller.readerArticle == nil }
        #expect(!controller.reader.isOpen)
    }

    // A navigation within the page changes the URL with no provisional start; it closes the reader all the same.
    @Test(arguments: ["history.pushState({}, '', '/b')", "location.hash = 'part-2'"])
    func aNavigationWithinThePageClosesTheReader(_ script: String) async throws {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        await loadAndFinish(controller, html: try ReaderFixtures.html("readability-001"), base: "https://example.test/a")
        await controller.openReader(ruleLists: [])
        #expect(controller.reader.isOpen)

        _ = try await controller.webView.evaluateJavaScript(script)
        try await waitUntil { controller.readerArticle == nil }
        #expect(!controller.reader.isOpen)
        #expect(controller.url != URL(string: "https://example.test/a"))
    }

    // An article extracted while its page navigated away is dropped, not shown over the next page.
    @Test func anArticleWhosePageNavigatedAwayIsDropped() async throws {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        await loadAndFinish(controller, html: try ReaderFixtures.html("readability-001"), base: "https://example.test/a")
        let opening = Task { await controller.openReader(ruleLists: []) }
        controller.load(page("b"))
        await opening.value
        #expect(controller.readerArticle == nil)
        #expect(!controller.reader.isOpen)
    }

    // The readable check of a page that has gone never marks the next one.
    @Test func aStaleReadableCheckNeverMarksTheNextPage() async throws {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        await loadAndFinish(controller, html: try ReaderFixtures.html("readability-001"), base: "https://example.test/a")
        await loadAndFinish(controller, html: try ReaderFixtures.html("app-form"), base: "https://example.test/b")
        try await Task.sleep(for: .milliseconds(300))
        #expect(!controller.isReaderable)
    }

    @Test func closingTheReaderRemovesIt() async throws {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        await loadAndFinish(controller, html: try ReaderFixtures.html("readability-001"), base: "https://example.test/a")
        await controller.openReader(ruleLists: [])

        controller.closeReader()
        #expect(controller.readerArticle == nil)
        #expect(!controller.reader.isOpen)
    }

    @Test func aLinkInTheReaderLoadsInTheTab() async throws {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        await loadAndFinish(controller, html: try ReaderFixtures.html("readability-001"), base: "https://example.test/a")
        await controller.openReader(ruleLists: [])
        let link = URL(string: "https://example.test/next")!

        controller.reader.onOpen?(link)
        try await waitUntil { controller.readerArticle == nil }
        #expect(!controller.reader.isOpen)
    }

    @Test func theReaderFollowsThePageZoomAndTheTabsInsets() async throws {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        controller.apply(safeTop: 62)
        controller.setPageZoom(1.25)
        await loadAndFinish(controller, html: try ReaderFixtures.html("readability-001"), base: "https://example.test/a")
        await controller.openReader(ruleLists: [])
        let page = try #require(controller.reader.page)
        #expect(page.pageZoom == 1.25)
        #expect(page.obscuredContentInsets == controller.webView.obscuredContentInsets)

        controller.setPageZoom(0.9)
        #expect(page.pageZoom == 0.9)
    }

    // A drag that closes the reader, or keeps it during its close, is the controller's state too.
    @Test func aDragOnTheReaderIsTheControllersState() async throws {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        await loadAndFinish(controller, html: try ReaderFixtures.html("readability-001"), base: "https://example.test/a")
        await controller.openReader(ruleLists: [])
        let article = controller.readerArticle

        controller.reader.onShown?(nil)
        #expect(controller.readerArticle == nil)
        controller.reader.onShown?(article)
        #expect(controller.readerArticle == article)
    }

    @Test func aDragDuringTheReleaseSpringStartsFromTheDrawnOffset() async throws {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let handler = HeldReloadSchemeHandler()
        let (controller, top) = try await settledHangingController(in: window, hanging: handler)
        defer { controller.webView.stopLoading() }
        let hold = Theme.Metrics.refreshHold
        let pageScroll = controller.webView.scrollView
        pageScroll.contentOffset.y = -top - hold
        pullAndRelease(controller)
        #expect(controller.isPullRefreshing)

        try await waitUntil { handler.holdsReload }
        handler.respondToHeld()
        try await waitUntilDrawn(pageScroll, from: -top - hold, to: -top)
        let drawn = drawnOffsetY(pageScroll)
        controller.scrollViewWillBeginDragging(pageScroll)

        #expect(abs(pageScroll.contentOffset.y - drawn) < 0.5, "model \(pageScroll.contentOffset.y), drawn \(drawn)")
        #expect(offsetAnimationKeys(pageScroll).isEmpty, "\(offsetAnimationKeys(pageScroll))")
    }

    @Test func aDragDuringTheHoldSettleStartsFromTheDrawnOffset() async throws {
        let (window, controller, top) = try await pulledHangingPage(hanging: HeldReloadSchemeHandler())
        defer { window.isHidden = true }
        defer { controller.webView.stopLoading() }
        let hold = Theme.Metrics.refreshHold
        let pageScroll = controller.webView.scrollView
        let pulled = -top - 2 * Theme.Refresh.armDistance
        pullAndRelease(controller)

        pageScroll.contentOffset.y = -top - hold
        try await waitUntilDrawn(pageScroll, from: pulled, to: -top - hold)
        let drawn = drawnOffsetY(pageScroll)
        controller.scrollViewWillBeginDragging(pageScroll)

        #expect(abs(pageScroll.contentOffset.y - drawn) < 0.5, "model \(pageScroll.contentOffset.y), drawn \(drawn)")
        #expect(offsetAnimationKeys(pageScroll).isEmpty, "\(offsetAnimationKeys(pageScroll))")
        #expect(!controller.isSettlingHold)
    }

    @Test func beginDraggingIncrementsUserScrollCount() {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        #expect(controller.userScrollCount == 0)

        controller.scrollViewWillBeginDragging(controller.webView.scrollView)
        controller.scrollViewWillBeginDragging(controller.webView.scrollView)
        #expect(controller.userScrollCount == 2)
    }

    // Unlike showInWindow: the window is made key and no reveal is requested.
    private func showInKeyWindow(_ controller: WebTabController) -> UIWindow {
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.first as! UIWindowScene)
        controller.webView.frame = window.bounds
        window.addSubview(controller.webView)
        window.makeKeyAndVisible()
        return window
    }

    // A PageWebView shown under a 62 pt safe top with a page tall enough to scroll.
    private func tallPage() async -> (window: UIWindow, controller: WebTabController, scrollView: UIScrollView) {
        let controller = WebTabController(
            tabID: UUID(), webView: PageWebView(frame: .zero, configuration: WKWebViewConfiguration()),
            haptics: recordingHaptics())
        let window = showInWindow(controller)
        controller.apply(safeTop: 62)
        await loadAndFinish(controller, html: "<body style='margin:0;height:4000px'>a</body>", base: "https://example.test/a")
        return (window, controller, controller.webView.scrollView)
    }

    // A settled hanging page in a new window, pulled two arm distances past its top and ready to release.
    private func pulledHangingPage(
        hanging: any WKURLSchemeHandler = HangingSchemeHandler()
    ) async throws -> (window: UIWindow, controller: WebTabController, top: CGFloat) {
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.first as! UIWindowScene)
        let (controller, top) = try await settledHangingController(in: window, hanging: hanging)
        controller.webView.scrollView.contentOffset.y = -top - 2 * Theme.Refresh.armDistance
        return (window, controller, top)
    }

    // A settled page whose pull has released into a reload the handler is holding.
    private func heldReload() async throws -> (
        window: UIWindow, controller: WebTabController, handler: HeldReloadSchemeHandler, haptics: HapticsEngine
    ) {
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.first as! UIWindowScene)
        let handler = HeldReloadSchemeHandler()
        let haptics = recordingHaptics()
        let (controller, _) = try await settledHangingController(in: window, hanging: handler, haptics: haptics)
        pullAndRelease(controller)
        try await waitUntil { handler.holdsReload }
        return (window, controller, handler, haptics)
    }

    // Past the reveal cap the page is still not revealable off window; shown, its paint reveals it.
    private func expectRevealOnlyOnceShown(
        _ controller: WebTabController, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await Task.sleep(for: Theme.Network.revealDelay + Theme.Latency.frame)
        #expect(!controller.isRevealable, sourceLocation: sourceLocation)
        let window = showInWindow(controller)
        defer { window.isHidden = true }
        await controller.paintTask?.value
        #expect(controller.isRevealable, sourceLocation: sourceLocation)
    }
}

@Suite(.serialized)
struct SiteNavigationTests {
    @Test func navigatingToABlockedSiteSwitchesListsBeforeItsFirstTracker() async throws {
        let rule = ##"[{"trigger":{"url-filter":"tracker\\.gif"},"action":{"type":"block"}}]"##
        let blocker = ContentBlocker(categories: Set(BlockingCategory.allCases), store: temporaryRuleStore(), bundle: try ruleBundle(rule))
        await blocker.prepare()
        let pool = WebViewPool(blocker: blocker, sessions: SessionStore(directories: .temporary()), haptics: recordingHaptics())
        pool.siteSettings = { host, _ in SiteSettings(blocksTrackers: host != "localhost") }
        let server = try await LocalPageServer { path in #"<img src="/tracker.gif?\#(path.split(separator: "?")[1])">"# }
        let allowed = URL(string: server.url("/page?allowed").absoluteString.replacing("127.0.0.1", with: "localhost"))!
        let blocked = server.url("/page?blocked")
        let tab = Tab(
            id: UUID(), url: allowed, title: "", isPinned: false, prefersDesktop: false, createdAt: .now,
            lastActiveAt: .now, tint: nil)
        let controller = pool.controller(for: tab)
        let finished = FinishedURLs()
        controller.onFinish = { url, _ in finished.urls.append(url) }
        try await waitUntil(timeout: .seconds(10)) { finished.urls == [allowed] }
        #expect(server.requestedPaths.contains("/tracker.gif?allowed"))

        controller.load(blocked)
        try await waitUntil(timeout: .seconds(10)) { finished.urls == [allowed, blocked] }
        #expect(server.requestedPaths.contains("/page?blocked"))
        #expect(!server.requestedPaths.contains("/tracker.gif?blocked"))
    }

    // A popup gets its own content controller, so the site it opens never switches its opener's blocking.
    @Test func aPopupsSiteLeavesItsOpenersListsAlone() async throws {
        let blocker = ContentBlocker(categories: Set(BlockingCategory.allCases), store: temporaryRuleStore(), bundle: try adRuleBundle())
        await blocker.prepare()
        let pool = WebViewPool(blocker: blocker, sessions: SessionStore(directories: .temporary()), haptics: recordingHaptics())
        pool.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        pool.siteSettings = { host, _ in SiteSettings(blocksTrackers: host != "localhost") }
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        let shown = server.url("/page-opener")
        let popupURL = URL(string: server.url("/page-popup").absoluteString.replacing("127.0.0.1", with: "localhost"))!
        let opener = pool.controller(for: Tab(
            id: UUID(), url: shown, title: "", isPinned: false, prefersDesktop: false, createdAt: .now,
            lastActiveAt: .now, tint: nil))
        let finished = FinishedURLs()
        opener.onFinish = { url, _ in finished.urls.append(url) }
        try await waitUntil(timeout: .seconds(10)) { finished.urls == [shown] }
        let opened = PopupBox()
        opener.onOpenWindow = { webView, _ in
            let popup = pool.adopt(webView, as: UUID())
            popup.onFinish = { url, _ in finished.urls.append(url) }
            opened.controller = popup
        }
        _ = try await opener.webView.evaluateJavaScript("window.open('\(popupURL.absoluteString)'); 1")
        try await waitUntil(timeout: .seconds(10)) { finished.urls == [shown, popupURL] }

        let popup = try #require(opened.controller)
        let openerLists = opener.webView.configuration.userContentController
        let popupLists = popup.webView.configuration.userContentController
        #expect(popupLists !== openerLists)
        #expect(!blocker.isBlocking(popupLists))
        #expect(blocker.isBlocking(openerLists))
    }

    // A navigation decided for another site that never commits puts the shown page's settings back. WebKit leaves either
    // the old page or its own blank page, both blocked here.
    @Test func aDecidedNavigationThatFailsRestoresTheShownSitesSettings() async throws {
        let blocker = ContentBlocker(categories: Set(BlockingCategory.allCases), store: temporaryRuleStore(), bundle: try adRuleBundle())
        await blocker.prepare()
        let pool = WebViewPool(blocker: blocker, sessions: SessionStore(directories: .temporary()), haptics: recordingHaptics())
        let asked = AskedHosts()
        pool.siteSettings = { host, _ in
            asked.hosts.append(host)
            return SiteSettings(blocksTrackers: host != "localhost")
        }
        let server = try await LocalPageServer { _ in "<p>shown</p>" }
        let shown = server.url("/page")
        let controller = pool.controller(for: Tab(
            id: UUID(), url: shown, title: "", isPinned: false, prefersDesktop: false, createdAt: .now,
            lastActiveAt: .now, tint: nil))
        let finished = FinishedURLs()
        controller.onFinish = { url, _ in finished.urls.append(url) }
        try await waitUntil(timeout: .seconds(10)) { finished.urls == [shown] }
        let lists = controller.webView.configuration.userContentController
        #expect(blocker.isBlocking(lists))

        controller.load(URL(string: "http://localhost:1/refused")!)
        try await waitUntil(timeout: .seconds(10)) {
            asked.hosts.contains("localhost") && !controller.webView.isLoading
                && controller.webView.url?.host() != "localhost"
        }
        #expect(blocker.isBlocking(lists))
    }

    @Test func aSiteWithJavaScriptOffRunsNoPageScript() async throws {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        controller.applySite = { SiteSettings(allowsJavaScript: $0 != "off.test") }
        let html = "<title>static</title><script>document.title = 'ran'</script>"

        for (host, title) in [("off.test", "static"), ("on.test", "ran")] {
            await loadAndFinish(controller, html: html, base: "https://\(host)/")
            try await waitUntil { controller.webView.title?.isEmpty == false }
            #expect(controller.webView.title == title, "\(host)")
        }
    }

    // A download ends its navigation with WebKitErrorDomain 102, a superseding load with a cancellation: no page.
    @Test func aPolicyChangeFailureShowsNoErrorPage() {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        controller.webView(
            controller.webView, didFailProvisionalNavigation: nil, withError: NSError(domain: "WebKitErrorDomain", code: 102))
        #expect(controller.loadError == nil)
        #expect(controller.errorView == nil)
        #expect(controller.hasSettled)
    }

    @Test func aDownloadAndASupersededLoadShowNoErrorPage() async throws {
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        server.routes["/a.zip"] = { _ in
            LocalPageServer.Reply(
                headers: ["Content-Type": "application/zip", "Content-Disposition": "attachment; filename=a.zip"],
                body: Data([1, 2, 3]))
        }
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        let downloads = Counter()
        controller.onDownload = { _ in downloads.count += 1 }
        controller.load(server.url("/a.zip"))
        try await waitUntil(timeout: .seconds(10)) { downloads.count == 1 && controller.hasSettled }
        #expect(controller.loadError == nil)

        let handler = StalledSchemeHandler()
        let stalled = stalledController(handler)
        defer { stalled.webView.stopLoading() }
        stalled.load(URL(string: "stall://page/x")!)
        try await waitUntil { handler.startedURLs.count == 1 }
        stalled.load(URL(string: "stall://page/y")!)
        try await waitUntil { handler.startedURLs.count == 2 }
        #expect(stalled.loadError == nil)
    }

    // A session-restored tab whose load fails sits on a blank document: the page is in place before the cover fades.
    @Test(arguments: [false, true])
    func aFailedColdLoadInstallsTheErrorBeforeItReveals(isPrivate: Bool) async throws {
        let controller = failingController(FailingSchemeHandler(), isPrivate: isPrivate)
        let window = showInWindow(controller)
        defer { window.isHidden = true }
        controller.revealsAtFinish = true
        let url = URL(string: "fail://page/cold")!
        let background = isPrivate ? Theme.Network.errorBackgroundPrivate : Theme.Network.errorBackground

        controller.webView(
            controller.webView, didFailProvisionalNavigation: nil, withError: failingError(.notConnectedToInternet, url: url))

        #expect(controller.errorView?.superview === controller.webView)
        #expect(controller.loadError?.reason == .offline)
        #expect(controller.loadError?.url == url)
        #expect(!controller.isRevealable)
        #expect(controller.hasSettled)
        #expect(controller.barTint == background)
        #expect(controller.errorView?.backgroundColor == background)
        await controller.paintTask?.value
        #expect(controller.isRevealable)
    }

    @Test func realFailuresReachTheirReasons() async throws {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        let window = showInWindow(controller)
        defer { window.isHidden = true }
        // A connection accepted and closed with no reply is lost (-1005), in process; a dead port can take longer
        // than the wait inside a loaded simulator.
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        server.routes["/lost"] = { _ in nil }
        controller.load(server.url("/lost"))
        try await waitUntil(timeout: .seconds(10)) { controller.loadError != nil }
        #expect(controller.loadError?.reason == .cannotConnect)
        #expect(controller.loadError?.url == server.url("/lost"))

        server.routes["/loop-a"] = { _ in LocalPageServer.Reply(status: "302 Found", headers: ["Location": "/loop-b"], body: Data()) }
        server.routes["/loop-b"] = { _ in LocalPageServer.Reply(status: "302 Found", headers: ["Location": "/loop-a"], body: Data()) }
        controller.load(server.url("/loop-a"))
        try await waitUntil(timeout: .seconds(10)) { controller.loadError?.reason == .tooManyRedirects }
        #expect(controller.loadError?.url == server.url("/loop-a"))
    }

    @Test func aFailedLinkTapRetriesTheFailedURLNotThePage() async throws {
        let handler = FailingSchemeHandler()
        let haptics = recordingHaptics()
        let controller = failingController(handler, haptics: haptics)
        let a = URL(string: "fail://page/a")!
        let b = URL(string: "fail://page/b")!
        await finishLoading(controller, a)
        handler.failures[b] = .cannotFindHost
        controller.load(b)
        try await waitUntil { controller.loadError != nil }
        #expect(controller.loadError?.reason == .cannotFindHost)
        #expect(controller.loadError?.url == b)
        #expect(menuNavs(haptics) == 0)

        controller.retry()

        try await waitUntil { handler.startedURLs.count == 3 }
        #expect(handler.startedURLs.last == b)
        #expect(handler.startedURLs.filter { $0 == a }.count == 1)
        #expect(menuNavs(haptics) == 1)
    }

    @Test func aFailedLinkTapGoesBackToThePageUnderIt() async throws {
        let handler = FailingSchemeHandler()
        let controller = failingController(handler)
        let window = showInWindow(controller)
        defer { window.isHidden = true }
        let a = URL(string: "fail://page/a")!
        let b = URL(string: "fail://page/b")!
        await finishLoading(controller, a)
        #expect(!controller.webView.canGoBack)
        let dismissals: [() -> Void] = [
            { controller.goBack() }, { controller.errorView!.dismissButton.sendActions(for: .touchUpInside) },
        ]
        for dismiss in dismissals {
            controller.webView(
                controller.webView, didFailProvisionalNavigation: nil, withError: failingError(.cannotFindHost, url: b))
            #expect(controller.canGoBack)
            #expect(controller.coversCommittedPage)
            let view = try #require(controller.errorView)
            #expect(!view.dismissButton.isHidden)
            let started = handler.startedURLs

            dismiss()

            #expect(controller.loadError == nil)
            #expect(controller.errorView == nil)
            #expect(view.layer.animationKeys()?.contains("opacity") == true)
            #expect(view.superview != nil)
            #expect(controller.webView.backForwardList.currentItem?.url == a)
            #expect(handler.startedURLs == started)
            #expect(!controller.canGoBack)
        }
    }

    // The real gesture is a phone-pass item; WebKit's own history move is what the policy step turns into a dismissal.
    @Test func aBackForwardActionOverACommittedPageIsADismissal() async throws {
        let handler = FailingSchemeHandler()
        let controller = failingController(handler)
        let a = URL(string: "fail://page/a")!
        let b = URL(string: "fail://page/b")!
        let c = URL(string: "fail://page/c")!
        await finishLoading(controller, a)
        await finishLoading(controller, c)
        controller.webView(
            controller.webView, didFailProvisionalNavigation: nil, withError: failingError(.cannotFindHost, url: b))
        #expect(controller.coversCommittedPage)
        #expect(!controller.dismissesHistoryMove(type: .linkActivated, isMainFrame: true))
        // An iframe under the error page moving through its own history is not a touch on the page.
        #expect(!controller.dismissesHistoryMove(type: .backForward, isMainFrame: false))
        #expect(controller.dismissesHistoryMove(type: .backForward, isMainFrame: true))

        controller.webView.goBack()
        try await waitUntil { controller.loadError == nil }
        // WebKit moves the cursor before it asks and puts it back after the cancel; both are its own messages.
        try await waitUntil { controller.webView.backForwardList.currentItem?.url == c }
        #expect(handler.startedURLs == [a, c])
    }

    @Test func aFailedReloadOfTheCommittedPageReloadsIt() async throws {
        let handler = FailingSchemeHandler()
        let controller = failingController(handler)
        let a = URL(string: "fail://page/a")!
        await finishLoading(controller, a)
        controller.webView(controller.webView, didFailProvisionalNavigation: nil, withError: failingError(.timedOut, url: a))
        #expect(!controller.coversCommittedPage)
        #expect(controller.canGoBack == controller.webView.canGoBack)
        #expect(controller.errorView?.dismissButton.isHidden == true)

        controller.retry()

        try await waitUntil { handler.startedURLs.count == 2 }
        #expect(handler.startedURLs.last == a)
        try await waitUntil { controller.loadError == nil }
        #expect(controller.webView.backForwardList.backList.isEmpty)
    }

    @Test func reloadOnATabWithNoCommittedPageRequestsTheFailedURL() async throws {
        let handler = StalledSchemeHandler()
        let haptics = recordingHaptics()
        let controller = stalledController(handler, haptics: haptics)
        defer { controller.webView.stopLoading() }
        let new = URL(string: "stall://page/new")!
        controller.load(new)
        // The handler's start and didStartProvisionalNavigation both arrive after load; without this wait the error's
        // own failing URL alone would make the test pass.
        try await waitUntil { handler.startedURLs.count == 1 }
        controller.webView(controller.webView, didFailProvisionalNavigation: nil, withError: failingError(.cannotFindHost, url: new))
        #expect(controller.webView.backForwardList.currentItem == nil)

        controller.reload()

        try await waitUntil { handler.startedURLs == [new, new] }
        #expect(menuNavs(haptics) == 0)
    }

    @Test func theErrorClearsWhenTheNewPageFinishesNotWhenItCommits() async throws {
        let handler = FailingSchemeHandler()
        let controller = hangingController(stalling: StalledSchemeHandler(), failing: handler)
        defer { controller.webView.stopLoading() }
        let a = URL(string: "fail://page/a")!
        controller.webView(controller.webView, didFailProvisionalNavigation: nil, withError: failingError(.cannotFindHost, url: a))
        controller.retry()
        try await waitUntil { controller.loadError == nil }
        #expect(controller.errorView == nil)
        #expect(controller.barTint != Theme.Network.errorBackground)
        #expect(handler.startedURLs.last == a)

        let b = URL(string: "hang://page/b")!
        controller.webView(controller.webView, didFailProvisionalNavigation: nil, withError: failingError(.timedOut, url: b))
        controller.retry()
        try await waitUntil { controller.webView.backForwardList.currentItem?.url == b }
        #expect(controller.loadError != nil)
        #expect(controller.errorClearTask != nil)
        try await waitUntil(timeout: .seconds(2)) { controller.loadError == nil }
        #expect(controller.errorView == nil)
    }

    @Test func aCommitWithoutAStartLeavesTheErrorAlone() {
        let controller = failingController(FailingSchemeHandler())
        controller.webView(
            controller.webView, didFailProvisionalNavigation: nil,
            withError: failingError(.cannotFindHost, url: URL(string: "fail://page/a")!))
        controller.webView(controller.webView, didCommit: nil)
        #expect(controller.loadError != nil)
        #expect(controller.errorClearTask == nil)
    }

    @Test func anErrorWhileTheBarIsHiddenShowsTheBar() {
        let controller = failingController(FailingSchemeHandler())
        for offset in [0, 100, 150, 200] as [CGFloat] {
            controller.scrolled(offsetY: offset, maxOffsetY: 1000, tracking: true, decelerating: false)
        }
        #expect(controller.isBarHidden)
        controller.webView(
            controller.webView, didFailProvisionalNavigation: nil,
            withError: failingError(.notConnectedToInternet, url: URL(string: "fail://page/a")!))
        #expect(!controller.isBarHidden)
    }

    // The capture is the error page; the page's backdrop is the earlier real picture, read once.
    @Test func aTabThatFailedOfflineKeepsItsPictureInTheDeck() async throws {
        let controller = failingController(FailingSchemeHandler())
        let window = showInWindow(controller)
        defer { window.isHidden = true }
        let red = solidImage(.red, side: 10)
        let reads = Counter()
        controller.lastSnapshot = {
            reads.count += 1
            return red
        }
        let a = URL(string: "fail://page/a")!
        controller.webView(
            controller.webView, didFailProvisionalNavigation: nil, withError: failingError(.notConnectedToInternet, url: a))

        let image = try #require(await controller.snapshot(width: 300))
        #expect(image.size.width == 300)
        #expect(pixel(image, at: CGPoint(x: 0.01, y: 0.99)) == components(Theme.Network.errorBackground))
        let dimmed = pixel(image, at: CGPoint(x: 0.5, y: 0.3))
        #expect(dimmed[0] > dimmed[1] + 40 && dimmed[0] < 255)
        #expect(controller.errorView?.backdropView?.image === red)
        #expect(controller.barTint == Theme.Network.errorBackground)

        let view = controller.errorView
        controller.webView(controller.webView, didFailProvisionalNavigation: nil, withError: failingError(.timedOut, url: a))
        #expect(controller.errorView === view)
        #expect(controller.errorView?.backdropView?.image === red)
        #expect(reads.count == 1)
        #expect(controller.loadError?.reason == .timedOut)
    }

    // A new tab sits on about:blank until its first page; a failed submit there covers nothing worth going back to.
    @Test func aFailedFirstLoadOverAboutBlankHasNoPageToGoBackTo() async throws {
        let controller = failingController(FailingSchemeHandler())
        await finishLoading(controller, URL(string: "about:blank")!)
        #expect(controller.webView.backForwardList.currentItem?.url.absoluteString == "about:blank")

        controller.webView(
            controller.webView, didFailProvisionalNavigation: nil,
            withError: failingError(.cannotFindHost, url: URL(string: "fail://page/b")!))

        #expect(controller.loadError != nil)
        #expect(!controller.coversCommittedPage)
        #expect(!controller.canGoBack)
        #expect(controller.errorView?.dismissButton.isHidden == true)
    }

    @Test func provisionalURLIsConsumed() async throws {
        let handler = StalledSchemeHandler()
        let controller = stalledController(handler)
        defer { controller.webView.stopLoading() }
        controller.load(URL(string: "stall://page/one")!)
        try await waitUntil { handler.startedURLs.count == 1 }
        controller.webView(controller.webView, didCommit: nil)
        controller.webView(controller.webView, didFailProvisionalNavigation: nil, withError: URLError(.timedOut))
        #expect(controller.loadError == nil)
    }
}

final class Counter { var count = 0 }

func failingError(_ code: URLError.Code, url: URL) -> NSError {
    NSError(domain: NSURLErrorDomain, code: code.rawValue, userInfo: [NSURLErrorFailingURLErrorKey: url])
}

func menuNavs(_ haptics: HapticsEngine) -> Int {
    haptics.records.filter { $0.interaction == .menuNav && $0.played }.count
}

func solidImage(_ color: UIColor, side: CGFloat) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
        color.setFill()
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    }
}

func pixel(_ image: UIImage, at unit: CGPoint) -> [Int] {
    let cg = image.cgImage!
    let x = Int(unit.x * CGFloat(cg.width)), y = Int(unit.y * CGFloat(cg.height))
    var data = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
        data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(cg, in: CGRect(x: -x, y: y - cg.height + 1, width: cg.width, height: cg.height))
    return data[0..<3].map(Int.init)
}

func components(_ color: UIColor) -> [Int] {
    color.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)!
        .components!.prefix(3).map { Int(($0 * 255).rounded()) }
}

// Loads a URL and waits for its finish.
func finishLoading(_ controller: WebTabController, _ url: URL) async {
    await finishing(controller) { controller.load(url) }
}

// Runs the action and waits for the finish it leads to.
func finishing(_ controller: WebTabController, _ action: () -> Void) async {
    await withCheckedContinuation { continuation in
        controller.onFinish = { _, _ in
            controller.onFinish = nil
            continuation.resume()
        }
        action()
    }
}

// Fails the URLs in `failures` as WebKit reports a failed request, with the failing URL set; answers every other
// request with a finished page. With an empty map it counts requests.
final class FailingSchemeHandler: NSObject, WKURLSchemeHandler {
    var failures: [URL: URLError.Code] = [:]
    // With holdsFailures, a failing request waits until failHeld(), so a test can order the failure against a flap.
    var holdsFailures = false
    private var held: [(task: any WKURLSchemeTask, code: URLError.Code)] = []
    private(set) var startedURLs: [URL] = []

    func failHeld() {
        held.forEach { $0.task.didFailWithError(failingError($0.code, url: $0.task.request.url!)) }
        held = []
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let url = urlSchemeTask.request.url!
        startedURLs.append(url)
        if let code = failures[url] {
            if holdsFailures {
                held.append((urlSchemeTask, code))
            } else {
                urlSchemeTask.didFailWithError(failingError(code, url: url))
            }
            return
        }
        urlSchemeTask.didReceive(
            URLResponse(url: url, mimeType: "text/html", expectedContentLength: -1, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(Data("<p>\(url.lastPathComponent)</p>".utf8))
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        held.removeAll { $0.task === urlSchemeTask }
    }
}

func failingController(
    _ handler: FailingSchemeHandler, haptics: HapticsEngine = recordingHaptics(), isPrivate: Bool = false,
    connectivity: Connectivity = Connectivity(monitor: nil)
) -> WebTabController {
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(handler, forURLScheme: "fail")
    if isPrivate {
        configuration.websiteDataStore = .nonPersistent()
    }
    return WebTabController(
        tabID: UUID(), webView: WKWebView(frame: .zero, configuration: configuration), haptics: haptics,
        connectivity: connectivity)
}

final class FinishedURLs { var urls: [URL] = [] }

private final class PopupBox { var controller: WebTabController? }

private final class AskedHosts { var hosts: [String] = [] }

final class FailingReloadSchemeHandler: NSObject, WKURLSchemeHandler {
    private(set) var requestCount = 0

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        requestCount += 1
        guard requestCount == 1 else {
            urlSchemeTask.didFailWithError(URLError(.notConnectedToInternet))
            return
        }
        urlSchemeTask.didReceive(
            URLResponse(
                url: urlSchemeTask.request.url!, mimeType: "text/html", expectedContentLength: -1,
                textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(Data("<p>a</p>".utf8))
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

final class TrackingScrollView: UIScrollView {
    override var isTracking: Bool { true }
}

@discardableResult
func pullAndRelease(_ controller: WebTabController) -> CGPoint {
    let scrollView = TrackingScrollView()
    scrollView.contentOffset.y = -controller.webView.obscuredContentInsets.top - 2 * Theme.Refresh.armDistance
    controller.scrollViewDidScroll(scrollView)
    var target = CGPoint.zero
    controller.scrollViewWillEndDragging(scrollView, withVelocity: .zero, targetContentOffset: &target)
    return target
}

func loadAndFinish(_ controller: WebTabController, html: String, base: String) async {
    await confirmation { finished in
        await withCheckedContinuation { continuation in
            controller.onFinish = { _, _ in
                controller.onFinish = nil
                finished()
                continuation.resume()
            }
            controller.webView.loadHTMLString(html, baseURL: URL(string: base))
        }
    }
}

final class StalledSchemeHandler: NSObject, WKURLSchemeHandler {
    private(set) var startedURLs: [URL] = []

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        startedURLs.append(urlSchemeTask.request.url!)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

final class HangingSchemeHandler: NSObject, WKURLSchemeHandler {
    private var tasks: [any WKURLSchemeTask] = []

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        tasks.append(urlSchemeTask)
        respondPartially(urlSchemeTask)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

// Answers the first load at once and holds every later one (a pull's reload) until the test commits it.
final class HeldReloadSchemeHandler: NSObject, WKURLSchemeHandler {
    private var tasks: [any WKURLSchemeTask] = []
    private var held: [any WKURLSchemeTask] = []

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        tasks.append(urlSchemeTask)
        if tasks.count == 1 {
            respondPartially(urlSchemeTask)
        } else {
            held.append(urlSchemeTask)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        held.removeAll { $0 === urlSchemeTask }
    }

    var holdsReload: Bool { !held.isEmpty }

    func respondToHeld() {
        held.forEach(respondPartially)
        held = []
    }

    func failHeld() {
        held.forEach { $0.didFailWithError(URLError(.notConnectedToInternet)) }
        held = []
    }
}

func respondPartially(_ urlSchemeTask: any WKURLSchemeTask) {
    urlSchemeTask.didReceive(
        URLResponse(
            url: urlSchemeTask.request.url!, mimeType: "text/html", expectedContentLength: -1,
            textEncodingName: "utf-8"))
    urlSchemeTask.didReceive(Data(String(repeating: "<p>partial</p>", count: 200).utf8))
}

func drawnOffsetY(_ scrollView: UIScrollView) -> CGFloat {
    scrollView.layer.presentation()!.bounds.origin.y
}

func offsetAnimationKeys(_ scrollView: UIScrollView) -> [String] {
    (scrollView.layer.animationKeys() ?? []).filter {
        (scrollView.layer.animation(forKey: $0) as? CAPropertyAnimation)?.keyPath == "bounds.origin"
    }
}

// Waits until the scroll view is drawn between 20% and 80% of a spring's travel.
func waitUntilDrawn(_ scrollView: UIScrollView, from start: CGFloat, to end: CGFloat) async throws {
    try await waitUntil(every: .milliseconds(4)) {
        let fraction = (drawnOffsetY(scrollView) - start) / (end - start)
        return fraction > 0.2 && fraction < 0.8 && !offsetAnimationKeys(scrollView).isEmpty
    }
}

func hangingController(
    hanging: any WKURLSchemeHandler = HangingSchemeHandler(), stalling stalled: StalledSchemeHandler = StalledSchemeHandler(),
    failing: FailingSchemeHandler? = nil, haptics: HapticsEngine = recordingHaptics()
) -> WebTabController {
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(hanging, forURLScheme: "hang")
    configuration.setURLSchemeHandler(stalled, forURLScheme: "stall")
    if let failing {
        configuration.setURLSchemeHandler(failing, forURLScheme: "fail")
    }
    return WebTabController(
        tabID: UUID(), webView: WKWebView(frame: .zero, configuration: configuration), haptics: haptics,
        connectivity: Connectivity(monitor: nil))
}

func stalledController(_ handler: StalledSchemeHandler, haptics: HapticsEngine = recordingHaptics()) -> WebTabController {
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(handler, forURLScheme: "stall")
    return WebTabController(
        tabID: UUID(), webView: WKWebView(frame: .zero, configuration: configuration), haptics: haptics,
        connectivity: Connectivity(monitor: nil))
}

func showInWindow(_ controller: WebTabController) -> UIWindow {
    let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
    let window = UIWindow(windowScene: scene)
    show(controller, in: window)
    controller.revealWhenPainted()
    return window
}

func show(_ controller: WebTabController, in window: UIWindow) {
    controller.webView.frame = window.bounds
    window.addSubview(controller.webView)
    window.isHidden = false
}

func settledHangingController(
    in window: UIWindow, hanging: any WKURLSchemeHandler = HangingSchemeHandler(),
    haptics: HapticsEngine = recordingHaptics()
) async throws -> (controller: WebTabController, safeTop: CGFloat) {
    let controller = hangingController(hanging: hanging, haptics: haptics)
    show(controller, in: window)
    let top = window.safeAreaInsets.top
    controller.apply(safeTop: top)
    controller.load(URL(string: "hang://page/a")!)
    try await waitUntil { controller.webView.backForwardList.currentItem?.url == URL(string: "hang://page/a") }
    controller.webView.stopLoading()
    try await waitUntil { controller.hasSettled }
    return (controller, top)
}

struct WaitTimedOut: Error {}

func waitUntil(
    timeout: Duration = .seconds(5), every interval: Duration = .milliseconds(20), _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw WaitTimedOut() }
        try await Task.sleep(for: interval)
    }
}

// The one automatic retry: fired by the first return to online after a network failure, silent, never a loop.
@Suite(.serialized)
struct ReconnectTests {
    private let a = URL(string: "fail://page/a")!

    private func flap(_ connectivity: Connectivity) {
        connectivity.apply(online: false, constrained: false, expensive: false)
        connectivity.apply(online: true, constrained: false, expensive: false)
    }

    private func failedController(
        _ handler: FailingSchemeHandler, code: URLError.Code, connectivity: Connectivity,
        haptics: HapticsEngine = recordingHaptics()
    ) async throws -> WebTabController {
        handler.failures[a] = code
        let controller = failingController(handler, haptics: haptics, connectivity: connectivity)
        controller.load(a)
        try await waitUntil { controller.loadError != nil }
        return controller
    }

    @Test func threeFlapsCostOneLoadPerShownError() async throws {
        let handler = FailingSchemeHandler()
        let connectivity = Connectivity(monitor: nil)
        let haptics = recordingHaptics()
        let controller = try await failedController(
            handler, code: .notConnectedToInternet, connectivity: connectivity, haptics: haptics)
        let window = showInWindow(controller)
        defer { window.isHidden = true }
        #expect(handler.startedURLs.count == 1)
        handler.holdsFailures = true

        for count in 2...4 {
            flap(connectivity)
            try await waitUntil { handler.startedURLs.count == count }
            #expect(!controller.hasSettled)
            handler.failHeld()
            try await waitUntil { controller.hasSettled }
            #expect(controller.loadError?.reason == .offline)
        }
        connectivity.apply(online: true, constrained: false, expensive: false)
        #expect(connectivity.reconnects == 3)
        controller.retry()
        try await waitUntil { handler.startedURLs.count == 5 }
        #expect(menuNavs(haptics) == 1)
    }

    @Test func aFailureWhileOnlineNeverAutoRetries() async throws {
        let handler = FailingSchemeHandler()
        let connectivity = Connectivity(monitor: nil)
        let controller = try await failedController(handler, code: .cannotFindHost, connectivity: connectivity)
        let window = showInWindow(controller)
        defer { window.isHidden = true }
        flap(connectivity)
        try await waitUntil { handler.startedURLs.count == 2 }

        // Each negative holds the manual retry's failure: had the flap retried too, a third request would have started.
        let untrusted = FailingSchemeHandler()
        let secure = try await failedController(untrusted, code: .serverCertificateUntrusted, connectivity: connectivity)
        show(secure, in: window)
        untrusted.holdsFailures = true
        flap(connectivity)
        secure.retry()
        try await waitUntil { untrusted.startedURLs.count == 2 }
        untrusted.failHeld()
        try await waitUntil { secure.hasSettled }
        #expect(untrusted.startedURLs.count == 2)

        let steady = FailingSchemeHandler()
        let online = Connectivity(monitor: nil)
        let offline = try await failedController(steady, code: .notConnectedToInternet, connectivity: online)
        show(offline, in: window)
        steady.holdsFailures = true
        online.apply(online: true, constrained: false, expensive: false)
        online.apply(online: true, constrained: false, expensive: false)
        #expect(online.reconnects == 0)
        offline.retry()
        try await waitUntil { steady.startedURLs.count == 2 }
        steady.failHeld()
        try await waitUntil { offline.hasSettled }
        #expect(steady.startedURLs.count == 2)
    }

    @Test func aFailureWhileOfflineRetriesOnTheFirstOnline() async throws {
        let handler = FailingSchemeHandler()
        let connectivity = Connectivity(monitor: nil)
        connectivity.apply(online: false, constrained: false, expensive: false)
        let controller = try await failedController(handler, code: .notConnectedToInternet, connectivity: connectivity)
        let window = showInWindow(controller)
        defer { window.isHidden = true }

        connectivity.apply(online: true, constrained: false, expensive: false)

        try await waitUntil { handler.startedURLs.count == 2 }
    }

    @Test func anOffScreenReconnectMarksNeedsReload() async throws {
        let handler = FailingSchemeHandler()
        let connectivity = Connectivity(monitor: nil)
        let controller = try await failedController(handler, code: .notConnectedToInternet, connectivity: connectivity)
        #expect(!controller.needsReload)

        flap(connectivity)

        try await waitUntil { controller.needsReload }
        #expect(handler.startedURLs.count == 1)
    }

    @Test func evictionCancelsTheReconnectRetry() async throws {
        let handler = FailingSchemeHandler()
        let connectivity = Connectivity(monitor: nil)
        let controller = try await failedController(handler, code: .notConnectedToInternet, connectivity: connectivity)
        let window = showInWindow(controller)
        defer { window.isHidden = true }

        controller.cancelPendingWork()
        flap(connectivity)
        controller.webView(
            controller.webView, didFailProvisionalNavigation: nil, withError: failingError(.notConnectedToInternet, url: a))
        handler.holdsFailures = true
        flap(connectivity)

        try await waitUntil { handler.startedURLs.count == 2 }
        handler.failHeld()
        try await waitUntil { controller.hasSettled }
        #expect(handler.startedURLs.count == 2)
    }
}

// The termination cap: the delegate is called directly, in a window, on the counting handler.
@Suite(.serialized)
struct TerminationTests {
    private let a = URL(string: "fail://page/a")!

    private func crashingController(
        _ handler: FailingSchemeHandler, sink: RecordingHapticSink
    ) async -> (WebTabController, UIWindow, HapticsEngine) {
        let haptics = HapticsEngine(sink: sink)
        let controller = failingController(handler, haptics: haptics)
        let window = showInWindow(controller)
        await finishLoading(controller, a)
        return (controller, window, haptics)
    }

    private func terminate(_ controller: WebTabController) {
        controller.webViewWebContentProcessDidTerminate(controller.webView)
    }

    @Test func aPageThatFinishesThenCrashesTwiceReloadsOnce() async throws {
        let handler = FailingSchemeHandler()
        let sink = RecordingHapticSink(start: .now)
        let (controller, window, haptics) = await crashingController(handler, sink: sink)
        defer { window.isHidden = true }

        await finishing(controller) { terminate(controller) }
        #expect(handler.startedURLs.count == 2)
        #expect(controller.loadError == nil)
        #expect(controller.lastTermination?.url == a)

        terminate(controller)
        #expect(handler.startedURLs.count == 2)
        #expect(controller.loadError?.reason == .crashed)
        #expect(controller.loadError?.url == a)
        #expect(controller.hasSettled)
        #expect(!controller.coversCommittedPage)
        await controller.paintTask?.value
        #expect(controller.isRevealable)

        await finishing(controller) { controller.retry() }
        #expect(handler.startedURLs.count == 3)
        #expect(controller.webView.backForwardList.currentItem?.url == a)
        #expect(controller.webView.backForwardList.backList.isEmpty)
        #expect(menuNavs(haptics) == 1)
        #expect(controller.loadError == nil)

        await finishing(controller) { terminate(controller) }
        #expect(handler.startedURLs.count == 4)
        #expect(controller.loadError == nil)
        terminate(controller)
        #expect(handler.startedURLs.count == 4)
        #expect(controller.loadError?.reason == .crashed)
    }

    @Test func thePageMenuReloadOnACrashPageGrantsOneMoreReload() async throws {
        let handler = FailingSchemeHandler()
        let sink = RecordingHapticSink(start: .now)
        let (controller, window, _) = await crashingController(handler, sink: sink)
        defer { window.isHidden = true }
        await finishing(controller) { terminate(controller) }
        terminate(controller)
        #expect(controller.loadError?.reason == .crashed)
        let playedBefore = sink.played.count

        await finishing(controller) { controller.reload() }

        #expect(controller.lastTermination == nil)
        #expect(handler.startedURLs.count == 3)
        #expect(sink.played.count == playedBefore)
        await finishing(controller) { terminate(controller) }
        #expect(handler.startedURLs.count == 4)
        #expect(controller.loadError == nil)
    }

    @Test func aTerminationAfterTheWindowReloadsAgain() async throws {
        let handler = FailingSchemeHandler()
        let sink = RecordingHapticSink(start: .now)
        let (controller, window, _) = await crashingController(handler, sink: sink)
        defer { window.isHidden = true }
        await finishing(controller) { terminate(controller) }
        sink.advance(by: Theme.Network.terminationWindow)

        await finishing(controller) { terminate(controller) }
        #expect(handler.startedURLs.count == 3)
        #expect(controller.loadError == nil)

        sink.advance(by: Theme.Network.terminationWindow - .seconds(1))
        terminate(controller)
        #expect(handler.startedURLs.count == 3)
        #expect(controller.loadError?.reason == .crashed)
    }

    @Test func aCommitOfADifferentURLResetsTheRecord() async throws {
        let handler = FailingSchemeHandler()
        let sink = RecordingHapticSink(start: .now)
        let (controller, window, _) = await crashingController(handler, sink: sink)
        defer { window.isHidden = true }
        await finishing(controller) { terminate(controller) }
        #expect(controller.lastTermination != nil)

        await finishLoading(controller, URL(string: "fail://page/b")!)
        #expect(controller.lastTermination == nil)

        await finishing(controller) { terminate(controller) }
        #expect(handler.startedURLs.count == 4)
        #expect(controller.loadError == nil)
    }

    @Test func anOffScreenTerminationIsNotRecorded() async throws {
        let handler = FailingSchemeHandler()
        let controller = failingController(handler)
        await finishLoading(controller, a)

        terminate(controller)
        terminate(controller)

        #expect(controller.needsReload)
        #expect(controller.lastTermination == nil)
        #expect(controller.loadError == nil)
        #expect(handler.startedURLs.count == 1)
    }
}
