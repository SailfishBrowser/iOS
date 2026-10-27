import os
import SwiftUI
import UIKit
import WebKit

@Observable
final class WebTabController: NSObject, WKNavigationDelegate, WKUIDelegate, UIScrollViewDelegate,
    UIGestureRecognizerDelegate
{
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "web")
    private static let faviconScript = """
        (() => {
          const size = link => Math.max(link.relList.contains('apple-touch-icon') ? 180 : 0,
            ...[...link.sizes].map(value => parseInt(value) || 0));
          const links = [...document.querySelectorAll('link[rel~="icon"], link[rel~="apple-touch-icon"]')]
            .filter(link => link.href)
            .sort((a, b) => size(b) - size(a))
            .map(link => link.href);
          return [...new Set([...links, new URL('/favicon.ico', location.origin).href])];
        })()
        """

    let tabID: Tab.ID
    let webView: WKWebView
    let reader: ReaderController
    let translator: PageTranslator

    private(set) var title: String
    private(set) var url: URL?
    private(set) var isLoading: Bool
    private(set) var progress: Double
    private var webCanGoBack: Bool
    private(set) var canGoForward: Bool
    private var pageTint: UIColor
    // Non-nil while the error page shows inside the web view.
    private(set) var loadError: LoadError?
    private(set) var hasSettled = false
    private(set) var isRevealable = false
    private(set) var isBarHidden = false
    private(set) var pullProgress: CGFloat = 0
    private(set) var isPullArmed = false
    private(set) var isPullRefreshing = false
    private(set) var refreshGap: CGFloat = 0
    private(set) var userScrollCount = 0
    private(set) var isFindNavigatorVisible = false
    private(set) var isReaderable = false
    // Non-nil while the reader shows over the page.
    private(set) var readerArticle: ReaderArticle?
    private(set) var blockedCount = 0
    var needsReload = false
    // Desktop content mode drops the configuration's application name, so desktop sends the whole Safari string.
    var prefersDesktop = false {
        didSet { webView.customUserAgent = prefersDesktop ? SafariUserAgent.desktop : nil }
    }

    @ObservationIgnored var onFinish: ((URL, String) -> Void)?
    // A pinch in at the page's minimum zoom reached the threshold; the environment says whether it opened the switcher.
    @ObservationIgnored var onPinchToSwitcher: (() -> Bool)?
    // WebKit's zoom under a pinch that opened the switcher has ended, bounce included: the page is still for its picture.
    @ObservationIgnored var onPinchZoomEnded: (() -> Void)?
    @ObservationIgnored var onOpenWindow: ((WKWebView, URL) -> Void)?
    // A link menu's open: true leaves the new tab in the background.
    @ObservationIgnored var onOpenLink: ((URL, Bool) -> Void)?
    @ObservationIgnored var onCommit: ((URL, String) -> Void)?
    // The committed page's title: any title until it has one, then only titles set while its URL is still shown.
    @ObservationIgnored var onTitle: ((URL, String) -> Void)?
    // The page's icons, best first, ending with /favicon.ico.
    @ObservationIgnored var onFavicon: ((String, [URL]) -> Void)?
    @ObservationIgnored var onFirstRevealOrFailure: (() -> Void)?
    @ObservationIgnored var onBarHiddenChanged: (() -> Void)?
    @ObservationIgnored var onDownload: ((WKDownload) -> Void)?
    // The tab's last real picture, read once when an error page is made and held for the error's life.
    @ObservationIgnored var lastSnapshot: () -> UIImage? = { nil }
    // Applies a host's site settings to this web view for a main-frame navigation and returns them.
    @ObservationIgnored var applySite: (String) -> SiteSettings = { _ in SiteSettings() }
    // Readies the configuration WebKit hands over for a popup before its web view is made.
    @ObservationIgnored var preparePopup: (WKWebViewConfiguration) -> Void = { _ in }
    @ObservationIgnored var appOpener = AppOpener.none
    // Whether the page's host may use these, asking if it must.
    @ObservationIgnored var decideMedia: (_ host: String, _ kinds: [MediaKind]) async -> Bool = { _, _ in false }
    @ObservationIgnored let dialogs = PageDialogs()
    @ObservationIgnored private var site = SiteSettings()
    @ObservationIgnored private var blockedURLs: Set<URL> = []
    @ObservationIgnored private var committedURL: URL?
    @ObservationIgnored private var committedTitled = false

    @ObservationIgnored private let haptics: HapticsEngine
    @ObservationIgnored private var bars = BarVisibility()
    @ObservationIgnored private var pinchTracker = PinchToSwitcher.Tracker()
    @ObservationIgnored private var capturesAtZoomEnd = false
    @ObservationIgnored private var pull = PullToRefresh()
    @ObservationIgnored private var safeTop: CGFloat = 0
    @ObservationIgnored private var heldScrollCount: Int?
    @ObservationIgnored private var heldOffsetY: CGFloat = 0
    @ObservationIgnored private var heldOffsetTime: TimeInterval = 0
    @ObservationIgnored private var heldVelocity: CGFloat = 0
    @ObservationIgnored private(set) var isSettlingHold = false
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var revealTask: Task<Void, Error>?
    @ObservationIgnored private(set) var paintTask: Task<Void, Never>?
    @ObservationIgnored private var awaitsReveal = false
    // A page brought back cold, from its session or by a reload after its process ended, paints a blank white
    // document before its content (a swipe onto such a tab showed white for 40 frames on the phone).
    // It reveals once it finishes, or at the reveal delay, so its cover shows the
    // snapshot until then.
    @ObservationIgnored var revealsAtFinish = false
    #if DEBUG
    @ObservationIgnored private(set) var revealedAtPaint = false
    #endif
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored private var refreshNavigation: WKNavigation?
    @ObservationIgnored private var landingTask: Task<Void, Never>?
    @ObservationIgnored private var lastPullHaptic: ContinuousClock.Instant?
    @ObservationIgnored private var pullClock: FrameClock?
    @ObservationIgnored private var readerableTask: Task<Void, Never>?
    @ObservationIgnored private(set) var errorView: LoadErrorView?
    @ObservationIgnored private(set) var errorClearTask: Task<Void, Error>?
    // The error page drawn when it is shown, updated or re-inset, so a capture at a gesture's start reads a picture.
    @ObservationIgnored private var errorPicture: UIImage?
    // The URL a provisional navigation started with, consumed at its commit or failure.
    @ObservationIgnored private var provisionalURL: URL?
    @ObservationIgnored private var navigatedSinceError = false
    @ObservationIgnored private let connectivity: Connectivity
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    // The last content-process termination on screen, keyed on the back-forward list's current item: WebKit resets
    // the page's URL when the process exits, and the back-forward list is what the reload reloads.
    @ObservationIgnored private(set) var lastTermination: (url: URL, at: ContinuousClock.Instant)?

    init(
        tabID: Tab.ID, webView: WKWebView, haptics: HapticsEngine,
        isTranslationSupported: @escaping (Locale.Language, Locale.Language) async -> Bool = PageTranslator.isAvailable,
        connectivity: Connectivity = .shared
    ) {
        self.tabID = tabID
        self.webView = webView
        self.haptics = haptics
        self.connectivity = connectivity
        reader = ReaderController(haptics: haptics)
        translator = PageTranslator(
            webView: webView, target: Locale.current.language, isSupported: isTranslationSupported)
        title = webView.title ?? ""
        url = webView.url
        isLoading = webView.isLoading
        progress = webView.estimatedProgress
        webCanGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        pageTint = webView.themeColor ?? webView.underPageBackgroundColor
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.delegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isFindInteractionEnabled = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #if DEBUG
        webView.isInspectable = true
        #endif
        // The reader's link policy runs in its own task, which keeps the reader past this tab.
        reader.onOpen = { [weak self] in self?.load($0) }
        reader.onShown = { [unowned self] in readerArticle = $0 }
        reader.onPinch = { [unowned self] in pinched($0) }
        reader.onZoomEnded = { [unowned self] in pinchZoomEnded() }

        // Always installed, simultaneous with WebKit's own zoom pinch (never blocked); eligibility is decided at fire
        // time, so a real zoom out is never stolen.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
        pinch.delegate = self
        webView.addGestureRecognizer(pinch)

        observations = [
            webView.observe(\.title, options: .new) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.titleChanged(webView.title ?? "") }
            },
            webView.observe(\.url, options: .new) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.urlChanged(webView.url) }
            },
            webView.observe(\.isLoading, options: .new) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.loadingChanged(webView.isLoading) }
            },
            webView.observe(\.estimatedProgress, options: .new) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.progress = webView.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: .new) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.webCanGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward, options: .new) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoForward = webView.canGoForward }
            },
            webView.observe(\.themeColor, options: .new) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.pageTint = webView.themeColor ?? webView.underPageBackgroundColor }
            },
            webView.observe(\.underPageBackgroundColor, options: .new) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.pageTint = webView.themeColor ?? webView.underPageBackgroundColor }
            },
        ]

        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChangeFrame), name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil)
    }

    // The pool's memory-warning path drops a controller without stopWork; the clear must not outlive it.
    deinit {
        errorClearTask?.cancel()
        reconnectTask?.cancel()
    }

    // The page's pinch (and, forwarded, the reader's): arm at a begin from minimum zoom, fire once at the threshold
    // while still at minimum zoom, as a press of the tab stack button. WebKit's own pinch keeps rubber-banding the
    // page until the fingers lift and the bounce ends, past the deck's rest, so the page's picture for the deck waits
    // for that end (scrollViewDidEndZooming), or for the fingers on a page WebKit is not zooming. The scroll view read
    // is the page's own, or the reader's while it shows; a pinch still in progress as the reader's close releases its
    // page has nothing to read and does nothing.
    @objc func pinched(_ pinch: UIPinchGestureRecognizer) {
        guard let scrollView = pinch.view === webView ? webView.scrollView : reader.page?.scrollView else { return }
        let atMinimum = PinchToSwitcher.isAtMinimumZoom(
            zoomScale: scrollView.zoomScale, minimumZoomScale: scrollView.minimumZoomScale)
        switch pinch.state {
        case .began:
            pinchTracker.began(atMinimumZoom: atMinimum)
            if atMinimum { haptics.prepare(.pinchSwitcher) }
        case .changed:
            if pinchTracker.changed(scale: pinch.scale, atMinimumZoom: atMinimum), onPinchToSwitcher?() == true {
                capturesAtZoomEnd = true
            }
        case .ended, .cancelled, .failed:
            pinchTracker.ended()
            if !scrollView.isZooming, !scrollView.isZoomBouncing {
                pinchZoomEnded()
            }
        default:
            break
        }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        pinchZoomEnded()
    }

    private func pinchZoomEnded() {
        guard capturesAtZoomEnd else { return }
        capturesAtZoomEnd = false
        onPinchZoomEnded?()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func goBack() {
        if coversCommittedPage {
            clearError()
        } else {
            webView.goBack()
        }
    }

    func goForward() {
        webView.goForward()
    }

    // With an error page showing, every reload path retries the failed URL: a never-committed tab has nothing to
    // reload, and the nav pill fires its own haptic before calling here.
    func reload() {
        if loadError == nil {
            webView.reload()
        } else {
            performRetry()
        }
    }

    // The error page's button: the one user trigger, so the one haptic.
    func retry() {
        haptics.fire(.menuNav)
        performRetry()
    }

    var canGoBack: Bool {
        webCanGoBack || coversCommittedPage
    }

    // The error page sits over the page the person was reading: a failed link tap commits nothing, so the current item
    // is still that page. False for a failed reload of it, a failed first load (a new tab's about:blank is no page)
    // and the crash page.
    var coversCommittedPage: Bool {
        guard let loadError, loadError.reason != .crashed, !showsNoPage,
            let current = webView.backForwardList.currentItem
        else { return false }
        return loadError.url != current.url
    }

    // The bar, the band and the menu follow the error page's neutral while it shows.
    var barTint: UIColor {
        loadError == nil ? pageTint : errorBackground
    }

    private var errorBackground: UIColor {
        isPrivate ? Theme.Network.errorBackgroundPrivate : Theme.Network.errorBackground
    }

    func apply(safeTop: CGFloat) {
        self.safeTop = safeTop
        let top = obscuredTop
        guard webView.obscuredContentInsets != Self.obscuredInsets(top: top) else { return }
        let scrollView = webView.scrollView
        let offset = scrollView.contentOffset
        let isAtTop = offset.y <= -webView.obscuredContentInsets.top
        setObscuredInsets(top: top)
        scrollView.contentOffset = isAtTop ? CGPoint(x: offset.x, y: -top) : offset
    }

    private var obscuredTop: CGFloat {
        safeTop + (heldScrollCount == nil ? 0 : Theme.Metrics.refreshHold)
    }

    private static func obscuredInsets(top: CGFloat) -> UIEdgeInsets {
        UIEdgeInsets(top: top, left: 0, bottom: Theme.Metrics.barTotalHeight, right: 0)
    }

    private func setObscuredInsets(top: CGFloat) {
        let insets = Self.obscuredInsets(top: top)
        webView.setObscuredInsets(insets)
        reader.setInsets(insets)
        errorView?.apply(insets: insets)
        drawErrorPicture()
    }

    func setPageZoom(_ zoom: Double) {
        webView.pageZoom = zoom
        reader.setZoom(zoom)
    }

    // The page's article over it, under the same rule lists as the pages.
    // An article whose page has navigated away while it was extracted is dropped. A readable page the extraction finds
    // no article on (its text hidden, say) is not readerable until the next route or finish checks it again.
    func openReader(ruleLists: [WKContentRuleList]) async {
        let source = webView.url
        do {
            let article = try await ReaderExtractor.article(in: webView)
            guard webView.url == source, !webView.isLoading else { return }
            guard let article else {
                isReaderable = false
                return
            }
            readerArticle = article
            reader.present(
                article, baseURL: webView.url, zoom: webView.pageZoom, insets: webView.obscuredContentInsets,
                ruleLists: ruleLists)
        } catch {
            Self.logger.error("Article extraction failed: \(error, privacy: .public)")
        }
    }

    // A navigation within the page (pushState, a fragment, back or forward between its own entries) changes the URL
    // with no provisional start: the reader closes and the new route is checked again. A load's own URL change comes
    // while it is loading, and its finish checks it.
    private func urlChanged(_ url: URL?) {
        self.url = url
        if readerArticle != nil {
            closeReader()
        }
        readerableTask?.cancel()
        isReaderable = false
        if !webView.isLoading {
            checkReaderable()
        }
    }

    // One check at a time, superseded by the next page's commit or route.
    private func checkReaderable() {
        readerableTask?.cancel()
        readerableTask = Task { [weak self, webView] in
            let readerable = await ReaderExtractor.isReaderable(in: webView)
            guard !Task.isCancelled else { return }
            self?.isReaderable = readerable
        }
    }

    func closeReader() {
        readerArticle = nil
        reader.dismiss()
    }

    // The colour over the safe top: the reader's own background while it shows, else the page's tint.
    var bandTint: UIColor {
        readerArticle == nil ? barTint : Theme.Palette.readerBackground
    }

    // In element fullscreen the page is in WebKit's window at the landscape width and the picture would be the video,
    // so the tab keeps its last one.
    func snapshot(width: CGFloat) async -> UIImage? {
        guard webView.window != nil, webView.fullscreenState == .notInFullscreen else { return nil }
        let image: UIImage
        let size: CGSize
        if let errorPicture {
            // The error page is what the tab shows; its picture is the page's width, scaled to the width asked off main.
            image = errorPicture
            size = CGSize(width: width, height: errorPicture.size.height * width / errorPicture.size.width)
        } else {
            let configuration = WKSnapshotConfiguration()
            configuration.snapshotWidth = NSNumber(value: Double(width))
            configuration.afterScreenUpdates = false
            do {
                // A tab in reader mode is its reader, in the switcher too.
                let shown = readerArticle == nil ? webView : reader.page!
                image = try await shown.takeSnapshot(configuration: configuration)
            } catch {
                Self.logger.error("Snapshot failed: \(error, privacy: .public)")
                return nil
            }
            size = image.size
        }
        let band = safeTop * width / webView.bounds.width
        let tint = bandTint.resolvedColor(with: webView.traitCollection)
        // A private page's band is drawn in, as it shows over the page.
        let privateBand = isPrivate
            ? PrivateBandView.picture(width: webView.bounds.width, safeTop: safeTop - Theme.Metrics.privateBandExtra) : nil
        return await Task.detached { Self.banded(image, size: size, top: band, tint: tint, privateBand: privateBand) }.value
    }

    // A card and its cover show the page as browsing does, with the tint band over the safe top.
    nonisolated private static func banded(
        _ image: UIImage, size: CGSize, top: CGFloat, tint: UIColor, privateBand: UIImage?
    ) -> UIImage {
        UIGraphicsImageRenderer(size: size, format: image.imageRendererFormat).image { context in
            image.draw(in: CGRect(origin: .zero, size: size))
            tint.setFill()
            let band = CGRect(x: 0, y: 0, width: size.width, height: top)
            context.fill(band)
            privateBand?.draw(in: band)
        }
    }

    func interactionStateData() -> Data? {
        webView.interactionState as? Data
    }

    func presentFind() {
        webView.findInteraction?.presentFindNavigator(showingReplace: false)
        syncFindNavigator()
    }

    // The find interaction flips its visibility inside present and dismiss, but dismiss posts this notification before
    // the flip, so the read waits one main-actor turn instead of for the keyboard's animation to end.
    @objc private func keyboardWillChangeFrame() {
        Task { syncFindNavigator() }
    }

    private func syncFindNavigator() {
        let visible = webView.findInteraction?.isFindNavigatorVisible == true
        if visible != isFindNavigatorVisible {
            isFindNavigatorVisible = visible
        }
    }

    private func loadingChanged(_ loading: Bool) {
        isLoading = loading
        if !loading {
            endPullRefresh()
        }
    }

    private func holdForRefresh() {
        heldScrollCount = userScrollCount
        let offset = webView.scrollView.contentOffset
        heldOffsetY = offset.y
        heldOffsetTime = CACurrentMediaTime()
        heldVelocity = 0
        setObscuredInsets(top: obscuredTop)
        webView.scrollView.contentOffset = offset
    }

    private func endPullRefresh() {
        isPullRefreshing = false
        guard let heldScrollCount else { return }
        self.heldScrollCount = nil
        let scrollView = webView.scrollView
        guard userScrollCount == heldScrollCount else {
            let offset = scrollView.contentOffset
            setObscuredInsets(top: safeTop)
            scrollView.contentOffset = offset
            return
        }
        if !isSettlingHold, scrollView.isDecelerating {
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        }
        let start = scrollView.contentOffset.y
        let velocity = !isSettlingHold && start < -safeTop ? bounceVelocity / (-safeTop - start) : 0
        withAnimation(Theme.Motion.refreshRelease.animation(initialVelocity: Double(velocity))) {
            Self.springScroll(velocity: velocity) {
                self.setObscuredInsets(top: self.safeTop)
                scrollView.contentOffset.y = -self.safeTop
            }
        }
    }

    func revealWhenPainted() {
        guard awaitsReveal, !isRevealable, paintTask == nil, webView.window != nil else { return }
        if revealTask == nil {
            revealTask = Task { [weak self] in
                try await Task.sleep(for: Theme.Network.revealDelay)
                self?.revealIfInWindow()
            }
        }
        guard !revealsAtFinish || hasSettled else { return }
        paintTask = Task { [weak self] in
            await self?.nextPresentation()
            guard !Task.isCancelled else { return }
            #if DEBUG
            self?.revealedAtPaint = true
            #endif
            self?.revealIfInWindow()
        }
    }

    private func revealIfInWindow() {
        guard webView.window != nil else {
            cancelReveal()
            return
        }
        cancelReveal()
        awaitsReveal = false
        revealsAtFinish = false
        isRevealable = true
        firstRevealOrFailure()
    }

    private func cancelReveal() {
        revealTask?.cancel()
        revealTask = nil
        paintTask?.cancel()
        paintTask = nil
    }

    private func awaitReveal() {
        guard !isRevealable else { return }
        awaitsReveal = true
        revealWhenPainted()
    }

    private func firstRevealOrFailure() {
        onFirstRevealOrFailure?()
        onFirstRevealOrFailure = nil
    }

    private func settle() {
        hasSettled = true
        endPullRefresh()
        awaitReveal()
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        // A history move while the error page covers a committed page (the edge swipe) dismisses the page instead.
        if dismissesHistoryMove(
            type: navigationAction.navigationType, isMainFrame: navigationAction.targetFrame?.isMainFrame == true)
        {
            clearError()
            return (.cancel, preferences)
        }
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        if let link = LinkRequest(navigationAction), await leavesForApp(link) { return (.cancel, preferences) }
        preferences.preferredContentMode = prefersDesktop ? .desktop : .mobile
        if navigationAction.targetFrame?.isMainFrame == true {
            site = applySite(navigationAction.request.url?.host() ?? "")
        }
        preferences.allowsContentJavaScript = site.allowsJavaScript
        return (.allow, preferences)
    }

    func dismissesHistoryMove(type: WKNavigationType, isMainFrame: Bool) -> Bool {
        type == .backForward && isMainFrame && coversCommittedPage
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        finishTask?.cancel()
        hasSettled = false
        provisionalURL = webView.url
        if loadError != nil {
            navigatedSinceError = true
        }
        if readerArticle != nil {
            closeReader()
        }
    }

    func countBlocked(_ url: URL) {
        guard blockedURLs.insert(url).inserted else { return }
        blockedCount += 1
    }

    // WebKit reports navigation callbacks for the main frame only.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        provisionalURL = nil
        if webView.url != lastTermination?.url {
            lastTermination = nil
        }
        translator.reset()
        // What commits can differ from what was decided: a failed cross-site load can commit WebKit's own blank page.
        site = applySite(webView.url?.host() ?? "")
        committedURL = webView.url
        committedTitled = !(webView.title ?? "").isEmpty
        if let url = webView.url {
            onCommit?(url, webView.title ?? "")
        }
        dialogs.pageCommitted()
        blockedURLs = []
        if blockedCount != 0 {
            blockedCount = 0
        }
        readerableTask?.cancel()
        isReaderable = false
        endPullRefresh()
        awaitReveal()
        if loadError != nil, navigatedSinceError {
            scheduleErrorClear()
        }
        landRefresh(navigation)
    }

    // A page that commits and never finishes still uncovers, at the reveal delay; never at the commit itself, before
    // the committed document has painted. WebKit's own blank commit after a failed cross-site load has no start since
    // the error and leaves the page alone.
    private func scheduleErrorClear() {
        errorClearTask?.cancel()
        errorClearTask = Task { [weak self] in
            try await Task.sleep(for: Theme.Network.revealDelay)
            self?.clearError()
        }
    }

    // A pull's reload lands on its first presented paint, the same wait as the first reveal, not on didFinish. Only
    // that reload's commit lands, and only on screen: any other commit means the reload was replaced.
    private func landRefresh(_ navigation: WKNavigation?) {
        guard let refreshNavigation else { return }
        self.refreshNavigation = nil
        guard navigation === refreshNavigation, webView.window != nil else { return }
        landingTask = Task { [weak self] in
            await self?.nextPresentation()
            guard !Task.isCancelled else { return }
            self?.haptics.fire(.refreshLand)
        }
    }

    private func cancelLanding() {
        refreshNavigation = nil
        landingTask?.cancel()
        landingTask = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView.window != nil else {
            finish()
            return
        }
        finishTask = Task { [weak self] in
            await self?.nextPresentation()
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    // Until the committed page has a title, any title is its own, even after a replaceState rewrote the URL on load.
    // After that, only titles set while its URL is still shown count, so a pushState page's title stays off it.
    private func titleChanged(_ title: String) {
        self.title = title
        guard let committedURL, webView.url == committedURL || !committedTitled else { return }
        committedTitled = committedTitled || !title.isEmpty
        onTitle?(committedURL, title)
    }

    func cancelPendingWork() {
        finishTask?.cancel()
        cancelReveal()
        cancelLanding()
        errorClearTask?.cancel()
        reconnectTask?.cancel()
    }

    private func finish() {
        if navigatedSinceError { clearError() }
        settle()
        guard let url = webView.url else { return }
        onFinish?(url, webView.title ?? "")
        Task { [translator] in await translator.detect() }
        discoverFavicon(for: url)
        checkReaderable()
    }

    private func nextPresentation() async {
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 1
        configuration.afterScreenUpdates = true
        do {
            _ = try await webView.takeSnapshot(configuration: configuration)
        } catch {
            Self.logger.error("Presentation wait failed: \(error, privacy: .public)")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if (error as? URLError)?.code == .cancelled, webView.isLoading { return }
        cancelLanding()
        firstRevealOrFailure()
        settle()
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        if (error as? URLError)?.code == .cancelled, webView.isLoading { return }
        cancelLanding()
        // The failed navigation's site was applied when it was decided; the page still shown is the committed one.
        site = applySite(webView.url?.host() ?? "")
        let failedURL = provisionalURL
        provisionalURL = nil
        // Installed before the reveal's paint wait, so a cold tab's cover fades onto the error page, never onto white.
        if let loadError = LoadError(error, fallbackURL: failedURL) {
            showError(loadError)
        }
        firstRevealOrFailure()
        settle()
    }

    private func showError(_ error: LoadError) {
        loadError = error
        errorClearTask?.cancel()
        errorClearTask = nil
        navigatedSinceError = false
        let view = errorView ?? installErrorView(error)
        view.update(error: error, canDismiss: coversCommittedPage)
        drawErrorPicture()
        if isBarHidden {
            scrolled(offsetY: 0, maxOffsetY: 0, tracking: false, decelerating: false)
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        guard error.reason.retriesOnReconnect else { return }
        // One retry when the path returns to online after this failure. The counter, not the Bool: a flap inside one
        // transaction reaches an observer as one emission, and the transition itself is the value.
        let seen = connectivity.reconnects
        reconnectTask = Task { [weak self, connectivity] in
            for await count in Observations({ connectivity.reconnects }) where count > seen {
                self?.reconnect()
                return
            }
        }
    }

    private func installErrorView(_ error: LoadError) -> LoadErrorView {
        let view = LoadErrorView(
            error: error, backdrop: lastSnapshot(), background: errorBackground,
            onAction: { [unowned self] in retry() }, onDismiss: { [unowned self] in clearError() })
        view.frame = webView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.apply(insets: webView.obscuredContentInsets)
        webView.addSubview(view)
        errorView = view
        return view
    }

    // Drawn directly, laid out first: no screen and no live process needed. A view with no size has no picture (a
    // test's off-window controller); every live web view is sized by its host before it loads.
    private func drawErrorPicture() {
        guard let errorView, !errorView.bounds.isEmpty else { return }
        errorView.layoutIfNeeded()
        errorPicture = UIGraphicsImageRenderer(bounds: errorView.bounds).image { context in
            errorView.layer.render(in: context.cgContext)
        }
    }

    // Silent (never retry(): no touch, no haptic). Off screen, activation retries through reload().
    private func reconnect() {
        if webView.window != nil {
            performRetry()
        } else {
            needsReload = true
        }
    }

    // The bar and the band take the page's tint on the same frame; on screen the page fades out on the reveal fade.
    private func clearError() {
        guard let errorView else { return }
        loadError = nil
        self.errorView = nil
        errorPicture = nil
        errorClearTask?.cancel()
        errorClearTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        guard webView.window != nil else {
            errorView.removeFromSuperview()
            return
        }
        Theme.Network.errorClear.animate(initialVelocity: 0) {
            errorView.alpha = 0
        } completion: { _ in
            errorView.removeFromSuperview()
        }
    }

    // A failed reload of the committed page reloads it (no new history item); anything else loads the failed URL: a
    // never-committed tab has nothing to reload, and a failed link tap would reload the old page. No haptic.
    private func performRetry() {
        guard let loadError else { return }
        if loadError.reason == .crashed {
            lastTermination = nil
            webView.reload()
        } else if loadError.url == webView.backForwardList.currentItem?.url {
            webView.reload()
        } else {
            load(loadError.url)
        }
    }

    // One automatic reload per URL inside the termination window; a second termination of the same URL shows the
    // crash page, whose Reload grants one more. A background tab's process is killed by the system, not the page.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishTask?.cancel()
        cancelReveal()
        cancelLanding()
        awaitsReveal = false
        isRevealable = false
        revealsAtFinish = true
        guard webView.window != nil else {
            needsReload = true
            return
        }
        guard let url = webView.backForwardList.currentItem?.url else {
            webView.reload()
            return
        }
        if let lastTermination, lastTermination.url == url,
            haptics.now - lastTermination.at < Theme.Network.terminationWindow
        {
            showError(.crashed(url: url))
            revealsAtFinish = false
            firstRevealOrFailure()
            settle()
            return
        }
        lastTermination = (url, haptics.now)
        webView.reload()
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let link = LinkRequest(navigationAction), ExternalLinks.kind(of: link.url) == .external {
            Task { _ = await leavesForApp(link) }
            return nil
        }
        preparePopup(configuration)
        let newWebView = PageWebView(frame: .zero, configuration: configuration)
        onOpenWindow?(newWebView, navigationAction.request.url ?? URL(string: "about:blank")!)
        return newWebView
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        scrolled(
            offsetY: scrollView.contentOffset.y + webView.obscuredContentInsets.top,
            maxOffsetY: maxOffsetY(of: scrollView), tracking: scrollView.isTracking,
            decelerating: scrollView.isDecelerating)
        if heldScrollCount == userScrollCount, !isSettlingHold, !scrollView.isTracking {
            let y = scrollView.contentOffset.y
            if y < -obscuredTop {
                recordHeldOffset(y)
            } else if y == -obscuredTop, heldOffsetY < -obscuredTop {
                settleHold(in: scrollView)
            }
        }
        let gap = min(Theme.Metrics.refreshHold, max(0, -(scrollView.contentOffset.y + safeTop)))
        if gap != refreshGap {
            refreshGap = gap
        }
    }

    private func maxOffsetY(of scrollView: UIScrollView) -> CGFloat {
        let insets = webView.obscuredContentInsets
        return scrollView.contentSize.height + insets.top + insets.bottom - scrollView.bounds.height
    }

    func scrolled(offsetY: CGFloat, maxOffsetY: CGFloat, tracking: Bool, decelerating: Bool) {
        bars.update(offsetY: offsetY, maxOffsetY: maxOffsetY, isUserScrolling: tracking || decelerating)
        if bars.isHidden != isBarHidden {
            isBarHidden = bars.isHidden
            onBarHiddenChanged?()
            haptics.fire(isBarHidden ? .barHide : .barShow)
        }
        if tracking, offsetY < 0 {
            haptics.prepare(.pullTick, .pullArm)
        }
        if tracking, let event = pull.update(overscroll: max(0, -offsetY)) {
            switch event {
            // A fast pull crosses the steps a frame or two apart; a tick too close to the last pull haptic records
            // silently, so the ratchet never smears into the arm.
            case .ticked(let step):
                let spaced = lastPullHaptic.map { haptics.now - $0 >= Theme.Haptic.pullTickGap } ?? true
                if spaced {
                    lastPullHaptic = haptics.now
                }
                haptics.fire(.pullTick, playing: spaced, step: step)
            case .armed:
                isPullArmed = true
                lastPullHaptic = haptics.now
                haptics.fire(.pullArm)
            case .rearmed:
                isPullArmed = true
            case .disarmed:
                isPullArmed = false
            }
        }
        if tracking, pull.isPulling, pullClock == nil {
            pullClock = FrameClock { [weak self] _ in
                guard let self else { return false }
                pullFrame()
                return pullClock != nil
            }
        }
        if pull.progress != pullProgress {
            pullProgress = pull.progress
        }
    }

    // Each frame of a pull drives the texture under the finger from the page's movement in that frame, so a finger at
    // rest is silent whatever the last scroll said.
    func pullFrame() {
        haptics.drive(Theme.Haptic.pullTexture, pull.level(at: haptics.now))
    }

    private func settleHold(in scrollView: UIScrollView) {
        let start = heldOffsetY
        let target = -obscuredTop
        let velocity = bounceVelocity / (target - start)
        isSettlingHold = true
        heldOffsetY = target
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: start), animated: false)
        Self.springScroll(velocity: velocity) {
            scrollView.contentOffset.y = target
        } completion: {
            self.isSettlingHold = false
        }
    }

    private var bounceVelocity: CGFloat {
        CACurrentMediaTime() - heldOffsetTime < Theme.Motion.refreshBounceHandoff ? heldVelocity : 0
    }

    // The ring follows the page edge on SwiftUI's clock, so the vote lasts the spring's whole run. The spring is not
    // re-added at the full rate: its completion ends the settle, and a replaced animation would end it early.
    static func springScroll(
        velocity: CGFloat, _ changes: @escaping () -> Void, completion: @escaping () -> Void = {}
    ) {
        let spring = Theme.Motion.refreshRelease.spring
        UIView.animate(
            springDuration: spring.duration, bounce: spring.bounce, initialSpringVelocity: velocity, delay: 0,
            options: .allowUserInteraction, animations: changes
        ) { _ in completion() }
        FrameRateVote.hold(Theme.Motion.refreshRelease)
    }

    private func recordHeldOffset(_ y: CGFloat) {
        let now = CACurrentMediaTime()
        if now > heldOffsetTime {
            heldVelocity = (y - heldOffsetY) / CGFloat(now - heldOffsetTime)
        }
        heldOffsetY = y
        heldOffsetTime = now
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userScrollCount += 1
        catchSpring(in: scrollView)
    }

    // A drag during the release or settle spring starts where the page is drawn, not at the spring's target. The
    // insets stay where the spring's block put them.
    private func catchSpring(in scrollView: UIScrollView) {
        let layer = scrollView.layer
        let springs = (layer.animationKeys() ?? []).filter { $0.hasPrefix("bounds.origin") }
        guard !springs.isEmpty else { return }
        let drawnY = layer.presentation()!.bounds.origin.y
        springs.forEach(layer.removeAnimation)
        scrollView.contentOffset.y = drawnY
        isSettlingHold = false
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        released()
    }

    @discardableResult
    func released() -> Bool {
        pullClock?.stop()
        pullClock = nil
        haptics.stop(Theme.Haptic.pullTexture)
        let refreshes = pull.release()
        lastPullHaptic = nil
        if isPullArmed {
            isPullArmed = false
        }
        if refreshes {
            haptics.fire(.pullRelease)
            let navigation = webView.reload()
            isPullRefreshing = webView.isLoading
            if isPullRefreshing {
                holdForRefresh()
                refreshNavigation = navigation
            }
        }
        if pull.progress != pullProgress {
            pullProgress = pull.progress
        }
        return refreshes
    }

    #if DEBUG
    func debugScroll(_ phase: DragPhase, _ sample: DragSample) {
        switch phase {
        case .began:
            scrollViewWillBeginDragging(webView.scrollView)
            debugScrolled(sample)
        case .changed:
            debugScrolled(sample)
        case .ended, .cancelled:
            released()
        }
    }

    private func debugScrolled(_ sample: DragSample) {
        scrolled(
            offsetY: -sample.translation.height, maxOffsetY: maxOffsetY(of: webView.scrollView), tracking: true,
            decelerating: false)
    }
    #endif

    private func discoverFavicon(for pageURL: URL) {
        guard let host = pageURL.host() else { return }
        // Our own content world: the page shares the DOM but cannot replace the globals the script uses.
        webView.evaluateJavaScript(Self.faviconScript, in: nil, in: .defaultClient) { [weak self] result in
            switch result {
            case .failure(let error):
                Self.logger.error("Favicon discovery failed: \(error, privacy: .public)")
            case .success(let value):
                let urls = (value as! [String]).compactMap(URL.init(string:))
                self?.onFavicon?(host, urls)
            }
        }
    }
}
