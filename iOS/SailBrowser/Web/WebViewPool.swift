import Foundation
import WebKit

struct PageGeometry: Equatable {
    static let zero = PageGeometry(bounds: .zero, safeTop: 0)

    var bounds: CGRect
    var safeTop: CGFloat
}

// Sites gate players and logins on Safari's tokens, which a bare WKWebView user agent lacks.
enum SafariUserAgent {
    static var mobileApplicationName: String { "\(version) Mobile/15E148 Safari/604.1" }
    static var desktop: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(version) Safari/605.1.15"
    }

    private static var version: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Version/\(os.majorVersion).\(os.minorVersion)"
    }
}

final class WebViewPool {
    let configuration: WKWebViewConfiguration
    let trackers = TrackerCounter()
    var onControllerCreated: ((WebTabController) -> Void)?
    // A host's settings for a normal (false) or private (true) tab.
    var siteSettings: (String, Bool) -> SiteSettings = { _, _ in SiteSettings() }
    // Whether a page's language can be translated to the target, read by the controllers built from here on.
    var isTranslationSupported: (Locale.Language, Locale.Language) async -> Bool = PageTranslator.isAvailable
    var page = PageGeometry.zero

    private let blocker: ContentBlocker
    private let sessions: SessionStore
    private let haptics: HapticsEngine
    // Whether a spare web view may be built now: false under reduced energy.
    private let prewarms: () -> Bool
    private var lru: LRUList<Tab.ID>
    private var controllers: [Tab.ID: WebTabController] = [:]
    private(set) var prewarmed: WKWebView?
    // Set by a memory warning; ends at the next foreground, the next new tab's first reveal or the system reporting
    // pressure back to normal. No spare web view is built while it is set.
    private(set) var isUnderPressure = false
    // Every private tab's web view shares this store, made with the first one and dropped with the session.
    private(set) var privateStore: WKWebsiteDataStore?
    private var privateIDs: Set<Tab.ID> = []
    // An evicted private tab's interaction state, kept in memory instead of a session file.
    private var privateSessions: [Tab.ID: Data] = [:]

    init(
        capacity: Int = Theme.Pool.capacity, blocker: ContentBlocker, sessions: SessionStore, haptics: HapticsEngine,
        prewarms: @escaping () -> Bool = { true }
    ) {
        self.blocker = blocker
        self.sessions = sessions
        self.haptics = haptics
        self.prewarms = prewarms
        lru = LRUList(capacity: capacity)
        configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.applicationNameForUserAgent = SafariUserAgent.mobileApplicationName
        configuration.preferences.isElementFullscreenEnabled = true
        blocker.onMissedPage = { [weak self] in self?.reloadMissed($0) }
    }

    func controller(for tab: Tab) -> WebTabController {
        if let controller = controllers[tab.id] {
            evict(lru.touch(tab.id))
            return controller
        }
        if tab.isPrivate {
            privateIDs.insert(tab.id)
        }
        if let session = tab.isPrivate ? privateSessions[tab.id] : sessions.load(tab.id) {
            let controller = build(tab, webView: makeWebView(isPrivate: tab.isPrivate))
            controller.revealsAtFinish = true
            controller.webView.interactionState = session
            // A session with no page (saved before the guard below, or bytes WebKit cannot decode) restores nothing,
            // and a web view that loads nothing stays blank under its cover for good.
            if controller.webView.backForwardList.currentItem == nil {
                controller.load(tab.url)
            }
            return controller
        }
        // The prewarmed web view stays on the default store, for the next normal tab.
        guard !tab.isPrivate else {
            let controller = build(tab, webView: makeWebView(isPrivate: true))
            controller.load(tab.url)
            return controller
        }
        let controller = build(tab, webView: takePrewarmed())
        controller.onFirstRevealOrFailure = { [weak self] in self?.pressureEnded() }
        controller.load(tab.url)
        return controller
    }

    func isPrivate(_ id: Tab.ID) -> Bool {
        privateIDs.contains(id)
    }

    func dataStore(for id: Tab.ID) -> WKWebsiteDataStore {
        isPrivate(id) ? privateStore! : configuration.websiteDataStore
    }

    // The last private tab has gone: its cookies and sessions go with it, and the next private tab starts clean.
    func endPrivateSession() {
        privateStore = nil
        privateSessions = [:]
    }

    func liveController(for id: Tab.ID) -> WebTabController? {
        controllers[id]
    }

    // WebKit hands a popup its opener's configuration, so a private page's popup is already on the private store.
    func adopt(_ webView: WKWebView, as id: Tab.ID) -> WebTabController {
        if privateStore != nil, webView.configuration.websiteDataStore === privateStore {
            privateIDs.insert(id)
        }
        let controller = WebTabController(
            tabID: id, webView: webView, haptics: haptics, isTranslationSupported: isTranslationSupported)
        register(controller)
        return controller
    }

    func prewarm() {
        guard prewarmed == nil, !isUnderPressure, prewarms() else { return }
        let webView = makeWebView(isPrivate: false)
        webView.loadHTMLString("", baseURL: nil)
        prewarmed = webView
    }

    func discard(_ id: Tab.ID) {
        if let controller = controllers.removeValue(forKey: id) {
            stopWork(of: controller)
        }
        lru.remove(id)
        privateIDs.remove(id)
        privateSessions[id] = nil
    }

    func saveAllSessions() {
        for controller in controllers.values {
            saveSession(of: controller)
        }
    }

    // The evicted controllers stop their pending work and save through the normal eviction; the spare web view, a whole
    // content process, goes, and none is built until the pressure ends. The survivors save for crash resilience.
    func handleMemoryWarning(keeping id: Tab.ID?) {
        isUnderPressure = true
        prewarmed = nil
        if let id {
            evict(lru.touch(id))
        }
        evict(lru.shrink(to: Theme.Pool.capacityUnderPressure))
        saveAllSessions()
    }

    func pressureEnded() {
        isUnderPressure = false
        prewarm()
    }

    func controllers(onHost host: String) -> [WebTabController] {
        controllers.values.filter { $0.url?.host() == host }
    }

    private func build(_ tab: Tab, webView: WKWebView) -> WebTabController {
        let controller = WebTabController(
            tabID: tab.id, webView: webView, haptics: haptics, isTranslationSupported: isTranslationSupported)
        controller.prefersDesktop = tab.prefersDesktop
        register(controller)
        return controller
    }

    private func register(_ controller: WebTabController) {
        // A controller can outlive its pool; it then keeps the defaults it had before the pool wired it.
        controller.preparePopup = { [weak self] in self?.prepare($0) }
        controller.applySite = { [weak self, unowned controller] host in
            guard let self else { return SiteSettings() }
            let site = siteSettings(host, isPrivate(controller.tabID))
            blocker.setBlocking(site.blocksTrackers, host: host, on: controller.webView.configuration.userContentController)
            return site
        }
        trackers.route(controller)
        fitToPage(controller)
        controllers[controller.tabID] = controller
        evict(lru.touch(controller.tabID))
        onControllerCreated?(controller)
    }

    // A page that loaded before the lists were on: reloaded now on screen, and at its next attach off it.
    private func reloadMissed(_ content: WKUserContentController) {
        let controller = controllers.values.first { $0.webView.configuration.userContentController === content }
        guard let controller else { return }
        if controller.webView.window != nil {
            controller.reload()
        } else {
            controller.needsReload = true
        }
    }

    private func fitToPage(_ controller: WebTabController) {
        guard controller.webView.window == nil else { return }
        controller.webView.frame = page.bounds
        controller.apply(safeTop: page.safeTop + (isPrivate(controller.tabID) ? Theme.Metrics.privateBandExtra : 0))
    }

    private func stopWork(of controller: WebTabController) {
        controller.cancelPendingWork()
        if controller.onFirstRevealOrFailure != nil {
            prewarm()
        }
    }

    private func evict(_ ids: [Tab.ID]) {
        for id in ids {
            if let controller = controllers.removeValue(forKey: id) {
                stopWork(of: controller)
                saveSession(of: controller)
            }
        }
    }

    // A tab whose only load failed has no page to come back to; an earlier session with a page stays until the next
    // save with one, so an error over a committed page keeps that page.
    private func saveSession(of controller: WebTabController) {
        guard controller.webView.backForwardList.currentItem != nil, let data = controller.interactionStateData() else {
            return
        }
        if isPrivate(controller.tabID) {
            privateSessions[controller.tabID] = data
        } else {
            sessions.save(data, for: controller.tabID)
        }
    }

    private func makeWebView(isPrivate: Bool) -> WKWebView {
        let configuration = configuration.copy() as! WKWebViewConfiguration
        if isPrivate {
            let store = privateStore ?? .nonPersistent()
            privateStore = store
            configuration.websiteDataStore = store
        }
        prepare(configuration)
        return PageWebView(frame: .zero, configuration: configuration)
    }

    // Each web view, popups too, gets its own content controller, so tracker blocking can differ per site.
    private func prepare(_ configuration: WKWebViewConfiguration) {
        configuration.userContentController = WKUserContentController()
        blocker.attach(configuration.userContentController)
        trackers.install(on: configuration.userContentController)
    }

    private func takePrewarmed() -> WKWebView {
        guard let webView = prewarmed else { return makeWebView(isPrivate: false) }
        prewarmed = nil
        return webView
    }
}
