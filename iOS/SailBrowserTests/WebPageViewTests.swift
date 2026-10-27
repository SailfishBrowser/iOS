import SwiftUI
import Testing
import UIKit
import WebKit
@testable import SailBrowser

struct WebPageViewTests {
    final class RecordingWebView: WKWebView {
        var laidOutSizes: [CGSize] = []

        override func layoutSubviews() {
            super.layoutSubviews()
            laidOutSizes.append(bounds.size)
        }
    }

    @Test func movingBetweenContainersNeverLaysOutAtZeroSize() {
        let size = CGSize(width: 402, height: 874)
        let webView = RecordingWebView()
        let first = WebPageView.Container(frame: CGRect(origin: .zero, size: size))
        first.host(webView, reader: ReaderController(haptics: recordingHaptics()).view)
        first.layoutIfNeeded()
        #expect(webView.bounds.size == size)

        let second = WebPageView.Container(frame: .zero)
        second.host(webView, reader: ReaderController(haptics: recordingHaptics()).view)
        #expect(webView.bounds.size == size)
        second.frame = CGRect(origin: .zero, size: size)
        second.layoutIfNeeded()

        #expect(webView.superview?.superview === second)
        #expect(webView.bounds == second.bounds)
        #expect(!webView.laidOutSizes.contains(.zero))

        second.frame = CGRect(origin: .zero, size: CGSize(width: 300, height: 600))
        second.layoutIfNeeded()
        #expect(webView.bounds == second.bounds)
    }

    // The reader sits over the page in the card's stage, so it takes the card's place, corner and crop; the safe top's
    // band stays over both.
    @Test func theReaderSitsOverThePageInTheCard() {
        let container = WebPageView.Container(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let webView = WKWebView()
        let reader = ReaderController(haptics: recordingHaptics()).view!
        container.host(webView, reader: reader)
        container.layoutIfNeeded()
        #expect(reader.superview === webView.superview)
        let stage = reader.superview!
        #expect(stage.subviews.firstIndex(of: reader)! > stage.subviews.firstIndex(of: webView)!)
        #expect(stage.subviews.last === container.band)
        #expect(reader.bounds == webView.bounds)
    }

    @Test func scalingAncestorKeepsSafeAreaAndTopScrollOffset() async throws {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let zoom = UIView(frame: window.bounds)
        let container = WebPageView.Container(frame: zoom.bounds)
        zoom.addSubview(container)
        window.addSubview(zoom)
        window.isHidden = false
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let controller = WebTabController(tabID: UUID(), webView: webView, haptics: recordingHaptics())
        container.host(webView, reader: ReaderController(haptics: recordingHaptics()).view)
        controller.apply(safeTop: window.safeAreaInsets.top)
        window.layoutIfNeeded()
        let top = window.safeAreaInsets.top
        #expect(top > 0)
        #expect(webView.obscuredContentInsets.top == top)

        webView.loadHTMLString("<body style='margin:0;height:4000px'>a</body>", baseURL: URL(string: "https://example.test/"))
        try await waitUntil { !webView.isLoading && webView.scrollView.contentSize.height > window.bounds.height }
        webView.scrollView.contentOffset.y = -top
        let safeArea = webView.safeAreaInsets

        for scale in [0.9, 0.5, 0.3, 0.72, 1] as [CGFloat] {
            zoom.transform = CGAffineTransform(scaleX: scale, y: scale)
            window.layoutIfNeeded()
            #expect(webView.safeAreaInsets == safeArea)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(webView.scrollView.contentOffset.y == -top)
    }

    @Test func leavingAndRejoiningWindowKeepsTopInsetOffset() async throws {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let first = WebPageView.Container(frame: window.bounds)
        let second = WebPageView.Container(frame: window.bounds)
        window.addSubview(first)
        window.addSubview(second)
        window.isHidden = false
        let webView = PageWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let controller = WebTabController(tabID: UUID(), webView: webView, haptics: recordingHaptics())
        first.host(webView, reader: ReaderController(haptics: recordingHaptics()).view)
        controller.apply(safeTop: window.safeAreaInsets.top)
        window.layoutIfNeeded()
        webView.loadHTMLString("<body style='margin:0;height:4000px'>a</body>", baseURL: URL(string: "https://example.test/"))
        try await waitUntil { !webView.isLoading && webView.scrollView.contentSize.height > window.bounds.height }
        let top = -window.safeAreaInsets.top
        webView.scrollView.contentOffset.y = top

        webView.removeFromSuperview()
        second.host(webView, reader: ReaderController(haptics: recordingHaptics()).view)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))

        #expect(webView.scrollView.contentOffset.y == top)
    }

    @Test func pageViewFeedsTheLiveSafeTopToEveryTabItShows() {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let first = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        let prewarmed = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        func page(_ controller: WebTabController, top: CGFloat) -> some View {
            WebPageView(controller: controller, geometry: .identity(height: window.bounds.height), isInteractive: true, isPrivate: false)
                .environment(\.screenInsets, EdgeInsets(top: top, leading: 0, bottom: 34, trailing: 0))
        }
        let host = UIHostingController(rootView: page(first, top: 62))
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        #expect(first.webView.obscuredContentInsets == UIEdgeInsets(top: 62, left: 0, bottom: Theme.Metrics.barTotalHeight, right: 0))

        host.rootView = page(first, top: 68)
        host.view.layoutIfNeeded()
        #expect(first.webView.obscuredContentInsets.top == 68)

        host.rootView = page(prewarmed, top: 68)
        host.view.layoutIfNeeded()
        #expect(prewarmed.webView.obscuredContentInsets == UIEdgeInsets(top: 68, left: 0, bottom: Theme.Metrics.barTotalHeight, right: 0))
    }

    @Test func pageViewRevealsATabThatFinishedOffWindowOnceShown() async throws {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        await loadAndFinish(controller, html: "<p>a</p>", base: "https://example.test/a")
        #expect(!controller.isRevealable)

        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        window.rootViewController = UIHostingController(
            rootView: WebPageView(controller: controller, geometry: .identity(height: window.bounds.height), isInteractive: true, isPrivate: false))
        window.isHidden = false
        try await waitUntil(timeout: .milliseconds(500)) { controller.isRevealable }
    }

    @Test func containerAppliesCardGeometryToItsStage() {
        let container = WebPageView.Container(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        let webView = WKWebView()
        container.host(webView, reader: ReaderController(haptics: recordingHaptics()).view)
        let stage = webView.superview!
        #expect(stage !== container)

        container.apply(
            CardGeometry(scale: 0.72, offset: CGSize(width: 10, height: 20), corner: 24, opacity: 0.5, clipHeight: 600))
        #expect(stage.transform == CGAffineTransform(translationX: 10, y: 20).scaledBy(x: 0.72, y: 0.72))
        #expect(abs(stage.layer.cornerRadius - 24 / 0.72) < 1e-9)
        #expect(stage.alpha == 0.5)

        container.apply(.identity(height: 956))
        #expect(stage.transform == .identity)
        #expect(stage.layer.cornerRadius == 0)
        #expect(stage.alpha == 1)
        #expect(webView.superview === stage)
    }

    @Test func cropMaskIsNilAtIdentityAndWebViewBoundsNeverChange() throws {
        let screen = CGSize(width: 440, height: 956)
        let container = WebPageView.Container(frame: CGRect(origin: .zero, size: screen))
        let webView = WKWebView()
        container.host(webView, reader: ReaderController(haptics: recordingHaptics()).view)
        container.layoutIfNeeded()
        let stage = webView.superview!

        container.apply(.identity(height: screen.height))
        container.layoutIfNeeded()
        #expect(stage.layer.mask == nil)
        #expect(webView.bounds.size == screen)

        let layout = CardLayout(screen: screen)
        let rest = layout.transform(slot: 1, isActive: true, activeIndex: 1, position: 1, progress: 1)
        container.apply(
            CardGeometry(
                scale: rest.scale, offset: rest.offset, corner: rest.corner, opacity: rest.opacity,
                clipHeight: rest.clipHeight))
        container.layoutIfNeeded()
        let mask = try #require(stage.layer.mask)
        #expect(mask.frame.origin == .zero)
        #expect(mask.frame.width == screen.width)
        #expect(abs(mask.frame.height - rest.clipHeight / rest.scale) < 1e-9)
        #expect(abs(mask.cornerRadius - rest.corner / rest.scale) < 1e-9)
        #expect(stage.bounds.size == screen)
        #expect(webView.bounds.size == screen)

        container.apply(.identity(height: screen.height))
        #expect(stage.layer.mask == nil)
        #expect(webView.bounds.size == screen)
    }

    // WebKit moves the page into its own window for element fullscreen; a SwiftUI update meanwhile must not pull it
    // back into the card.
    @Test func aPageInFullscreenIsLeftWhereWebKitPutIt() {
        let container = WebPageView.Container(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        container.orientation = OrientationPolicy()
        let webView = FullscreenWebView()
        let reader = ReaderController(haptics: recordingHaptics()).view!
        container.host(webView, reader: reader)
        let webKitWindow = UIView()
        for state in [WKWebView.FullscreenState.enteringFullscreen, .inFullscreen] {
            webView.state = state
            webKitWindow.addSubview(webView)
            container.hostIfNeeded(webView, reader: reader)
            #expect(webView.superview === webKitWindow)
            #expect(container.isHoldingFullscreen)
        }
    }

    @Test func aPageHandedBackIsPinnedToTheStageAgainAndThePlaceholderSurvives() {
        let container = WebPageView.Container(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        container.orientation = OrientationPolicy()
        let webView = FullscreenWebView()
        let reader = ReaderController(haptics: recordingHaptics()).view!
        container.host(webView, reader: reader)
        container.layoutIfNeeded()
        let stage = reader.superview!
        webView.state = .inFullscreen
        let placeholder = UIView()
        stage.insertSubview(placeholder, aboveSubview: webView)
        UIView().addSubview(webView)

        // As WebKit returns it: under the placeholder, a fixed frame, no constraints, TAMIC untouched.
        stage.insertSubview(webView, belowSubview: placeholder)
        webView.frame = CGRect(x: 0, y: 0, width: 300, height: 500)
        webView.state = .exitingFullscreen
        #expect(container.isHoldingFullscreen)
        webView.state = .notInFullscreen
        #expect(!container.isHoldingFullscreen)
        #expect(placeholder.superview === stage)
        container.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
        container.layoutIfNeeded()
        #expect(webView.bounds == container.bounds)
        #expect(webView.superview === stage)
    }

    @Test func aFreshCardLeavesAFullscreenPageAloneAndHostsItOnceItIsBack() {
        let container = WebPageView.Container(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        container.orientation = OrientationPolicy()
        let webView = FullscreenWebView()
        let readerController = ReaderController(haptics: recordingHaptics())
        let webKitWindow = UIView()
        webKitWindow.addSubview(webView)
        webView.state = .inFullscreen
        container.hostIfNeeded(webView, reader: readerController.view)
        #expect(webView.superview === webKitWindow)
        #expect(container.isHoldingFullscreen)

        webView.state = .notInFullscreen
        #expect(webView.superview?.superview === container)
        container.layoutIfNeeded()
        #expect(webView.bounds == container.bounds)
    }

    @Test func thePolicyHearsAHostedPageAndOutlivesTheCard() {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let container = WebPageView.Container(frame: window.bounds)
        window.addSubview(container)
        let policy = OrientationPolicy()
        var restores = 0
        policy.restorePortrait = { _ in restores += 1 }
        container.orientation = policy
        let webView = FullscreenWebView()
        let reader = ReaderController(haptics: recordingHaptics()).view!
        container.host(webView, reader: reader)

        webView.state = .enteringFullscreen
        #expect(policy.isElementFullscreen)
        #expect(restores == 0)
        webView.state = .exitingFullscreen
        #expect(policy.isElementFullscreen)
        #expect(restores == 1)
        webView.state = .notInFullscreen
        #expect(!policy.isElementFullscreen)
        #expect(restores == 2)
        let stage = webView.superview!
        #expect(stage.constraints.count(where: { $0.firstItem === webView }) == 4)

        webView.state = .inFullscreen
        let webKitWindow = UIView()
        webKitWindow.addSubview(webView)
        WebPageView.dismantleUIView(container, coordinator: ())
        #expect(policy.isElementFullscreen)
        webView.state = .notInFullscreen
        #expect(!policy.isElementFullscreen)
        #expect(webView.superview === webKitWindow)
    }

    @Test func theSafeTopWaitsWhileThePageIsInFullscreen() {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let webView = FullscreenWebView()
        let controller = WebTabController(tabID: UUID(), webView: webView, haptics: recordingHaptics())
        func page(top: CGFloat, isInteractive: Bool = true) -> some View {
            WebPageView(controller: controller, geometry: .identity(height: window.bounds.height), isInteractive: isInteractive, isPrivate: false)
                .environment(\.screenInsets, EdgeInsets(top: top, leading: 0, bottom: 34, trailing: 0))
        }
        let host = UIHostingController(rootView: page(top: 62))
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        #expect(webView.obscuredContentInsets.top == 62)

        // The safe top changes during the episode (the landscape layout); the page in WebKit's window keeps its own.
        webView.state = .inFullscreen
        host.rootView = page(top: 20)
        host.view.layoutIfNeeded()
        #expect(webView.obscuredContentInsets.top == 62)

        // The first update after the exit applies the safe top the episode changed, with no newer value to carry it.
        webView.state = .notInFullscreen
        host.rootView = page(top: 20, isInteractive: false)
        host.view.layoutIfNeeded()
        #expect(webView.obscuredContentInsets.top == 20)
        #expect(!webView.superview!.superview!.isUserInteractionEnabled)

        host.rootView = page(top: 68)
        host.view.layoutIfNeeded()
        #expect(webView.obscuredContentInsets.top == 68)
    }

    @Test func sidewaysScrollAtConstantProgressIssuesNoMaskUpdate() throws {
        let screen = CGSize(width: 440, height: 956)
        let container = WebPageView.Container(frame: CGRect(origin: .zero, size: screen))
        let webView = WKWebView()
        container.host(webView, reader: ReaderController(haptics: recordingHaptics()).view)
        container.layoutIfNeeded()
        let stage = webView.superview!
        let layout = CardLayout(screen: screen)
        func geometry(_ position: CGFloat) -> CardGeometry {
            let t = layout.transform(slot: 1, isActive: true, activeIndex: 1, position: position, progress: 1)
            return CardGeometry(
                scale: t.scale, offset: t.offset, corner: t.corner, opacity: t.opacity, clipHeight: t.clipHeight)
        }
        container.apply(geometry(1))
        let mask = try #require(stage.layer.mask as? WebPageView.CropLayer)
        let before = mask.updates
        for position in stride(from: CGFloat(1), through: 0.2, by: -0.1) {
            container.apply(geometry(position))
        }
        container.layoutIfNeeded()
        #expect(mask.updates == before)
        #expect(stage.layer.mask === mask)

        container.apply(geometry(1.5))
        #expect(mask.updates == before + 1)
    }
}
