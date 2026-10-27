import SwiftUI
import Testing
import UIKit
import WebKit
@testable import SailBrowser

// The page's safe space: a band of the page tint over the status bar that no page content scrolls
// under, the bar's band over the bottom, and a floor of the bar's material over the home indicator while the bar is
// hidden.
@MainActor @Suite(.serialized)
struct SafeSpaceTests {
    private static let safeTop: CGFloat = 62
    private static let safeBottom: CGFloat = 34
    private static let longPage = "<meta name='theme-color' content='#ff0000'>"
        + "<body style='margin:0;height:4000px;background:#ffffff'>a</body>"
    private let insets = UIEdgeInsets(top: safeTop, left: 0, bottom: Theme.Metrics.barTotalHeight, right: 0)

    private func window() -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        return UIWindow(windowScene: scene)
    }

    private func page(_ controller: WebTabController, _ geometry: CardGeometry) -> AnyView {
        AnyView(
            WebPageView(controller: controller, geometry: geometry, isInteractive: true, isPrivate: false)
                .environment(
                    \.screenInsets, EdgeInsets(top: Self.safeTop, leading: 0, bottom: Self.safeBottom, trailing: 0)))
    }

    private func container(in view: UIView) -> WebPageView.Container? {
        view as? WebPageView.Container ?? view.subviews.lazy.compactMap(container(in:)).first
    }

    private func browsing(_ controller: WebTabController, in window: UIWindow)
        -> (UIHostingController<AnyView>, WebPageView.Container)
    {
        let host = UIHostingController(rootView: page(controller, .identity(height: window.bounds.height)))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        return (host, container(in: host.view)!)
    }

    private func loaded(in window: UIWindow) async throws -> (WebTabController, WebPageView.Container) {
        let controller = WebTabController(
            tabID: UUID(), webView: PageWebView(frame: .zero, configuration: WKWebViewConfiguration()),
            haptics: recordingHaptics())
        let (_, container) = browsing(controller, in: window)
        await loadAndFinish(controller, html: Self.longPage, base: "https://example.test/a")
        try await waitUntil {
            var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            controller.barTint.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return red == 1 && green == 0 && blue == 0
        }
        container.layoutIfNeeded()
        return (controller, container)
    }

    @Test func pageContentStartsAtTheSafeTopUnderABandOfThePageTint() async throws {
        let window = window()
        defer { window.isHidden = true }
        let (controller, container) = try await loaded(in: window)
        let scrollView = controller.webView.scrollView
        let band = container.band

        #expect(band.frame == CGRect(x: 0, y: 0, width: window.bounds.width, height: Self.safeTop))
        #expect(band.backgroundColor == controller.barTint)
        #expect(band.superview === controller.webView.superview)
        #expect(band.superview!.subviews.last === band)
        #expect(scrollView.contentOffset.y == -Self.safeTop)
        #expect(controller.webView.obscuredContentInsets == insets)
        #expect(scrollView.contentInset.bottom == Theme.Metrics.barTotalHeight)

        scrollView.contentOffset.y = 500
        container.layoutIfNeeded()
        #expect(band.frame.maxY == Self.safeTop)
        #expect(!band.isHidden && band.alpha == 1)
    }

    @Test func bandAndInsetsHoldThroughADeckZoomRoundTrip() async throws {
        let window = window()
        defer { window.isHidden = true }
        let controller = WebTabController(
            tabID: UUID(), webView: PageWebView(frame: .zero, configuration: WKWebViewConfiguration()),
            haptics: recordingHaptics())
        let (host, container) = browsing(controller, in: window)
        await loadAndFinish(controller, html: Self.longPage, base: "https://example.test/a")
        let scrollView = controller.webView.scrollView
        scrollView.contentOffset.y = 500

        let layout = CardLayout(screen: window.bounds.size)
        let rest = layout.transform(slot: 1, isActive: true, activeIndex: 1, position: 1, progress: 1)
        host.rootView = page(
            controller,
            CardGeometry(
                scale: rest.scale, offset: rest.offset, corner: rest.corner, opacity: rest.opacity,
                clipHeight: rest.clipHeight))
        host.view.layoutIfNeeded()
        #expect(container.band.frame.height == Self.safeTop)
        #expect(controller.webView.obscuredContentInsets == insets)

        host.rootView = page(controller, .identity(height: window.bounds.height))
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(container.band.frame == CGRect(x: 0, y: 0, width: window.bounds.width, height: Self.safeTop))
        #expect(controller.webView.obscuredContentInsets == insets)
        #expect(scrollView.contentInset == insets)
        #expect(scrollView.contentOffset.y == 500)
    }

    @Test(arguments: [false, true])
    func insetsHoldWhenTheKeyboardShowsAndHides(atTop: Bool) async throws {
        let window = window()
        defer { window.isHidden = true }
        let (controller, _) = try await loaded(in: window)
        let scrollView = controller.webView.scrollView
        let offset = atTop ? -Self.safeTop : 500
        scrollView.contentOffset.y = offset
        let bounds = window.bounds
        let down = CGRect(x: 0, y: bounds.height, width: bounds.width, height: 336)
        let up = down.offsetBy(dx: 0, dy: -336)
        func post(_ names: [Notification.Name], from: CGRect, to: CGRect) {
            let info: [AnyHashable: Any] = [
                UIResponder.keyboardFrameBeginUserInfoKey: NSValue(cgRect: from),
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: to),
                UIResponder.keyboardAnimationDurationUserInfoKey: 0.25,
                UIResponder.keyboardAnimationCurveUserInfoKey: 7,
                UIResponder.keyboardIsLocalUserInfoKey: true,
            ]
            for name in names {
                NotificationCenter.default.post(name: name, object: nil, userInfo: info)
            }
        }

        post(
            [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillShowNotification,
             UIResponder.keyboardDidChangeFrameNotification, UIResponder.keyboardDidShowNotification],
            from: down, to: up)
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.webView.obscuredContentInsets == insets)
        #expect(scrollView.contentInset == insets)
        #expect(scrollView.contentOffset.y == offset)

        post(
            [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification,
             UIResponder.keyboardDidChangeFrameNotification, UIResponder.keyboardDidHideNotification],
            from: up, to: down)
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.webView.obscuredContentInsets == insets)
        #expect(scrollView.contentInset == insets)
        #expect(scrollView.contentOffset.y == offset)
    }

    @Test func pullThresholdIsUnchangedUnderTheBand() async throws {
        let window = window()
        defer { window.isHidden = true }
        let (controller, _) = try await loaded(in: window)
        let scrollView = TrackingScrollView()

        scrollView.contentOffset.y = -Self.safeTop
        controller.scrollViewDidScroll(scrollView)
        #expect(controller.pullProgress == 0)

        scrollView.contentOffset.y = -Self.safeTop - Theme.Refresh.armDistance / 2
        controller.scrollViewDidScroll(scrollView)
        #expect(controller.pullProgress == 0.5)

        scrollView.contentOffset.y = -Self.safeTop - Theme.Refresh.armDistance
        controller.scrollViewDidScroll(scrollView)
        #expect(controller.pullProgress == 1)
        #expect(controller.isPullArmed)
    }

    @Test func snapshotCarriesTheBandOverTheSafeTop() async throws {
        let window = window()
        defer { window.isHidden = true }
        let (controller, _) = try await loaded(in: window)
        await controller.paintTask?.value
        let image = try #require(await controller.snapshot(width: window.bounds.width))

        func rgb(atPoint y: CGFloat) -> [UInt8] { pixel(of: image, atPoint: y) }
        #expect(rgb(atPoint: 1) == [255, 0, 0])
        #expect(rgb(atPoint: Self.safeTop - 1) == [255, 0, 0])
        #expect(rgb(atPoint: Self.safeTop + 1) == [255, 255, 255])
    }

    // The band stays over the reader, in the reader's own background, and the status bar reads on it.
    @Test(arguments: [UIUserInterfaceStyle.dark, .light])
    func theBandStaysOverTheReaderInTheReadersBackground(_ style: UIUserInterfaceStyle) async throws {
        let window = window()
        window.overrideUserInterfaceStyle = style
        defer { window.isHidden = true }
        let controller = WebTabController(
            tabID: UUID(), webView: PageWebView(frame: .zero, configuration: WKWebViewConfiguration()),
            haptics: recordingHaptics())
        let (host, container) = browsing(controller, in: window)
        await loadAndFinish(controller, html: try ReaderFixtures.html("readability-001"), base: "https://example.test/a")
        await controller.openReader(ruleLists: [])
        #expect(controller.readerArticle != nil)
        try await waitUntil { container.band.backgroundColor == Theme.Palette.readerBackground }

        let stage = try #require(container.band.superview)
        #expect(stage.subviews.last === container.band)
        #expect(stage.subviews.contains(controller.reader.view))
        #expect(container.band.frame == CGRect(x: 0, y: 0, width: window.bounds.width, height: Self.safeTop))
        let traits = UITraitCollection(userInterfaceStyle: style)
        #expect(
            StatusBarStyle.style(tint: controller.bandTint, deckProgress: 0, overlay: .none, traits: traits)
                == (style == .dark ? .lightContent : .darkContent))

        controller.closeReader()
        host.view.layoutIfNeeded()
        try await waitUntil { container.band.backgroundColor == controller.barTint }
    }

    private func bar(hidden: Bool, in window: UIWindow) -> BarSlideView {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        let bar = BarSlideView(BarContent(env: makeEnvironment(), controller: controller), hidden: hidden)
        bar.floorHeight = Self.safeBottom
        bar.frame = CGRect(
            x: 0, y: window.bounds.height - Theme.Metrics.barTotalHeight, width: window.bounds.width,
            height: Theme.Metrics.barTotalHeight)
        window.addSubview(bar)
        window.isHidden = false
        bar.layoutIfNeeded()
        return bar
    }

    // The floor's mask follows the bar's top, so the floor shows exactly the strip the bar has left.
    private func shownFloorHeight(_ bar: BarSlideView) -> CGFloat {
        let mask = bar.floor.view.layer.mask!
        let top = mask.position.y - mask.bounds.height / 2 + mask.transform.m42
        return min(max(top + mask.bounds.height, 0), Self.safeBottom) - min(max(top, 0), Self.safeBottom)
    }

    @Test func theFloorShowsOnlyTheStripTheBarHasLeft() {
        let window = window()
        defer { window.isHidden = true }
        let bar = bar(hidden: false, in: window)
        let floor = bar.floor.view!

        #expect(floor.frame == CGRect(
            x: 0, y: Theme.Metrics.barTotalHeight - Self.safeBottom, width: window.bounds.width,
            height: Self.safeBottom))
        #expect(bar.subviews.firstIndex(of: floor)! < bar.subviews.firstIndex(of: bar.host.view)!)
        #expect(!floor.isUserInteractionEnabled)
        #expect(floor.alpha == 1)
        #expect(shownFloorHeight(bar) == 0)

        bar.slide(hidden: true)
        #expect(shownFloorHeight(bar) == Self.safeBottom)
        #expect(floor.layer.mask!.animationKeys() == bar.host.view.layer.animationKeys())

        bar.slide(hidden: false)
        #expect(shownFloorHeight(bar) == 0)
        #expect(shownFloorHeight(self.bar(hidden: true, in: window)) == Self.safeBottom)
    }

    @Test func theFloorStaysOffForTheBarIntroAfterASubmitAndComesOnForAScrollHide() {
        let window = window()
        defer { window.isHidden = true }
        let env = makeEnvironment()
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        let bar = BarSlideView(BarContent(env: env, controller: controller), hidden: false)
        window.addSubview(bar)
        window.isHidden = false

        env.ui.submitSearch(onHidden: {}, onCancel: {})
        #expect(env.ui.isBarIntroPending)
        BarSlide.update(bar, controller, env.ui)
        #expect(bar.isSlidOut)
        #expect(bar.floor.view.isHidden)

        env.ui.endBarIntro()
        BarSlide.update(bar, controller, env.ui)
        #expect(!bar.isSlidOut)
        controller.scrolled(offsetY: 100, maxOffsetY: 2000, tracking: true, decelerating: false)
        controller.scrolled(offsetY: 200, maxOffsetY: 2000, tracking: true, decelerating: false)
        #expect(controller.isBarHidden)
        BarSlide.update(bar, controller, env.ui)
        #expect(bar.isSlidOut)
        #expect(!bar.floor.view.isHidden)
    }

    @Test func theFloorHidesWithTheBarUnderTheSearchSheet() {
        let window = window()
        defer { window.isHidden = true }
        let bar = bar(hidden: true, in: window)
        bar.cover(true)
        #expect(bar.floor.view.alpha == 0)
        bar.cover(false)
        #expect(bar.floor.view.alpha == 1)
    }

    @Test func aDragFromUnderTheClockReachesThePage() async throws {
        let window = window()
        defer { window.isHidden = true }
        let (controller, container) = try await loaded(in: window)
        let hit = try #require(container.hitTest(CGPoint(x: 200, y: 30), with: nil))
        #expect(hit.isDescendant(of: controller.webView))
    }

    // WebKit hands back its under-page colour already resolved, so a page with no theme colour in the dark app gets
    // the same band in its snapshot as live.
    @Test func snapshotBandMatchesTheLiveBandForAPageWithNoThemeColourInTheDark() async throws {
        let window = window()
        window.overrideUserInterfaceStyle = .dark
        defer { window.isHidden = true }
        let controller = WebTabController(
            tabID: UUID(), webView: PageWebView(frame: .zero, configuration: WKWebViewConfiguration()),
            haptics: recordingHaptics())
        let (_, container) = browsing(controller, in: window)
        await loadAndFinish(
            controller, html: "<body style='margin:0;height:4000px;background:#203040'>a</body>",
            base: "https://example.test/a")
        await controller.paintTask?.value
        #expect(controller.webView.themeColor == nil)
        var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        container.band.backgroundColor!.resolvedColor(with: container.band.traitCollection)
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let live = [red, green, blue].map { Int(($0 * 255).rounded()) }

        let image = try #require(await controller.snapshot(width: window.bounds.width))
        let banded = pixel(of: image, atPoint: 1).map(Int.init)
        #expect(zip(live, banded).allSatisfy { abs($0 - $1) <= 1 }, "live \(live) snapshot \(banded)")
    }
}

// RGB at the horizontal middle of a row given in points.
func pixel(of image: UIImage, atPoint y: CGFloat) -> [UInt8] {
    let cg = image.cgImage!
    let width = cg.width, height = cg.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    let row = Int(y * CGFloat(height) / image.size.height)
    let i = (row * width + width / 2) * 4
    return Array(pixels[i..<i + 3])
}

@MainActor
struct StatusBarStyleTests {
    private let dark = UITraitCollection(userInterfaceStyle: .dark)

    @Test func browsingFollowsTheBandAndEverythingElseIsLight() {
        let white = UIColor.white
        let theme = UIColor(red: 0x14 / 255, green: 0x21 / 255, blue: 0x67 / 255, alpha: 1)
        #expect(StatusBarStyle.style(tint: white, deckProgress: 0, overlay: .none, traits: dark) == .darkContent)
        #expect(StatusBarStyle.style(tint: white, deckProgress: 0, overlay: .menu, traits: dark) == .darkContent)
        #expect(StatusBarStyle.style(tint: theme, deckProgress: 0, overlay: .none, traits: dark) == .lightContent)
        #expect(StatusBarStyle.style(tint: white, deckProgress: 1, overlay: .none, traits: dark) == .lightContent)
        #expect(StatusBarStyle.style(tint: white, deckProgress: 0.3, overlay: .none, traits: dark) == .lightContent)
        #expect(StatusBarStyle.style(tint: white, deckProgress: 0, overlay: .search, traits: dark) == .lightContent)
        #expect(StatusBarStyle.style(tint: white, deckProgress: 0, overlay: .settings, traits: dark) == .lightContent)
        #expect(StatusBarStyle.style(tint: nil, deckProgress: 0, overlay: .none, traits: dark) == .lightContent)
    }

    @Test func theStatusBarWindowSetsTheScenesStyleAndTakesNoTouches() async throws {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = StatusBarWindow(windowScene: scene)
        defer { window.isHidden = true }
        window.style = .darkContent
        try await waitUntil { scene.statusBarManager?.statusBarStyle == .darkContent }
        window.style = .lightContent
        try await waitUntil { scene.statusBarManager?.statusBarStyle == .lightContent }
        #expect(window.hitTest(CGPoint(x: 100, y: 20), with: nil) == nil)
        #expect(!window.isKeyWindow)
    }
}
