import Testing
import UIKit
import WebKit
@testable import SailBrowser

@MainActor
struct FullscreenTests {
    private static let base = URL(string: "https://example.test/")!

    // Shows the web view in its own window with a tall red page loaded.
    private func shownPage(_ webView: WKWebView) async throws -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        webView.frame = window.bounds
        window.addSubview(webView)
        window.isHidden = false
        webView.loadHTMLString("<body style='margin:0;height:4000px;background:red'></body>", baseURL: Self.base)
        try await waitUntil { !webView.isLoading }
        return window
    }

    // Opens a tab for the page as a popup does, so the environment's capture path runs over this web view.
    private func adopt(_ webView: WKWebView, in env: AppEnvironment) -> WebTabController {
        env.open(page("a"))
        env.activeController!.onOpenWindow!(webView, Self.base)
        return env.activeController!
    }

    @Test func noPictureIsTakenWhileThePageIsInFullscreen() async throws {
        let webView = FullscreenWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let window = try await shownPage(webView)
        defer { window.isHidden = true }
        let controller = WebTabController(tabID: UUID(), webView: webView, haptics: recordingHaptics())
        for state in [WKWebView.FullscreenState.enteringFullscreen, .inFullscreen, .exitingFullscreen] {
            webView.state = state
            #expect(await controller.snapshot(width: 300) == nil)
        }
        webView.state = .notInFullscreen
        let image = try #require(await controller.snapshot(width: 300))
        #expect(image.size.width == 300)
    }

    // A capture mid-film stores nothing, so the tab keeps its last picture instead of a landscape frame of the video.
    @Test func aCaptureMidFullscreenKeepsTheTabsLastPicture() async throws {
        let env = makeEnvironment()
        let webView = FullscreenWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let window = try await shownPage(webView)
        defer { window.isHidden = true }
        let controller = adopt(webView, in: env)
        #expect(controller.webView === webView)
        let id = controller.tabID
        let red = solidImage(.red, side: 10)
        env.snapshots.store(red, for: id)

        webView.state = .inFullscreen
        let held = try #require(env.captureSnapshot(of: id))
        await held.value
        #expect(env.snapshots.thumbnail(for: id).image === red)

        webView.state = .notInFullscreen
        let taken = try #require(env.captureSnapshot(of: id))
        await taken.value
        let after = try #require(env.snapshots.thumbnail(for: id).image)
        #expect(after !== red)
        #expect(after.size.width == window.bounds.width)
    }

    // Locking the phone during a film: the flush completes, the assertion ends once, and the capture asked for
    // resolves to nothing.
    @Test func aBackgroundEntryMidFullscreenFlushesAndCapturesNothing() async throws {
        let log = FlushLog()
        let env = makeEnvironment(assertion: log.assertion)
        let webView = FullscreenWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let window = try await shownPage(webView)
        defer { window.isHidden = true }
        let id = adopt(webView, in: env).tabID
        let red = solidImage(.red, side: 10)
        env.snapshots.store(red, for: id)
        var requested: [Tab.ID] = []
        env.onCaptureRequested = { requested.append($0) }
        webView.state = .inFullscreen

        env.sceneWillResignActive()
        env.sceneDidEnterBackground()
        try await waitUntil { log.count(.end) == 1 }
        #expect(log.events == [.begin, .end])
        #expect(requested.contains(id))
        #expect(env.snapshots.thumbnail(for: id).image === red)
    }

    // WebKit moves the page straight from the card into its own window and back; neither move is the move out of
    // every window that parks a top offset, so nothing is parked or put back.
    @Test func theMoveIntoWebKitsWindowParksNoOffset() async throws {
        let webView = PageWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let window = try await shownPage(webView)
        defer { window.isHidden = true }
        let controller = WebTabController(tabID: UUID(), webView: webView, haptics: recordingHaptics())
        controller.apply(safeTop: 62)
        try await waitUntil { webView.scrollView.contentSize.height > window.bounds.height }
        webView.scrollView.contentOffset.y = -62

        let webKitWindow = UIWindow(windowScene: window.windowScene!)
        webKitWindow.addSubview(webView)
        webView.scrollView.contentOffset.y = 0
        window.addSubview(webView)
        #expect(webView.window === window)
        #expect(webView.scrollView.contentOffset.y == 0)
    }

    @Test func theRevealDelayIsOneSecond() {
        #expect(Theme.Network.revealDelay == .seconds(1))
    }
}
