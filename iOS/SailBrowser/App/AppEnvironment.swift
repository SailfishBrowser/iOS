import SwiftUI
import WebKit

@Observable final class AppEnvironment {
    private struct PendingSubmit {
        let tab: Tab
        var hasFinished = false
        var startedDownload = false
    }

    private static let settledSnapshotDelay: Duration = .milliseconds(300)

    let browser: BrowserStore
    let history: HistoryStore
    let sites: SiteSettingsStore
    let downloads: DownloadStore
    let pool: WebViewPool
    let sessions: SessionStore
    let snapshots: SnapshotStore
    let favicons: FaviconStore
    let ui: UIState
    let haptics: HapticsEngine
    let blocker: ContentBlocker
    let energy: EnergyPolicy
    let translation = TranslationHost()

    private(set) var activeController: WebTabController?
    // A zoom set from a private tab: private tabs read it before the saved zoom, and it dies with the private session.
    private var privateZoomByHost: [String: Double] = [:]
    @ObservationIgnored var onCaptureRequested: ((Tab.ID) -> Void)?
    @ObservationIgnored var onSubmitted: ((WebTabController) -> Void)?
    // The deck's pager, which a swipe on the browsing bar drives.
    @ObservationIgnored var pager: TabPager?
    // The tab stack's flick to the previous tab.
    @ObservationIgnored var flick: TabStackFlick?
    // Asks over the page whether its host may use these; nil when the prompt is dismissed without an answer.
    @ObservationIgnored lazy var askMedia: (WKWebView, String, [MediaKind]) async -> Bool? = {
        [unowned self] webView, host, kinds in
        await PermissionPrompt.ask(host: host, kinds: kinds, over: webView, env: self)
    }
    @ObservationIgnored private var pendingSubmit: PendingSubmit?
    @ObservationIgnored private var linksAfterSubmit: [URL] = []
    @ObservationIgnored private weak var cutInController: WebTabController?
    @ObservationIgnored private var deckMoving = false
    @ObservationIgnored private var atRest: [() -> Void] = []
    @ObservationIgnored private var stopPressureWatch: @MainActor () -> Void = {}
    @ObservationIgnored private let assertion: BackgroundAssertion
    // At most one assertion is held: the expiration handler and the flush's completion both end it through
    // endFlushAssertion, so the system sees one end.
    @ObservationIgnored private var endAssertion: (@MainActor () -> Void)?
    @ObservationIgnored private var flushNumber = 0
    @ObservationIgnored private var flushing = false
    // The neighbours' warm-up, armed by a rest in the browser and cancelled by any motion or a touch's first move.
    @ObservationIgnored private(set) var warmUp: Task<Void, Never>?
    @ObservationIgnored private(set) var isWarmArmed = false
    // One pending settle capture per tab: a finish inside the delay replaces it, and a removed tab's goes with the tab.
    @ObservationIgnored private(set) var settledSnapshotTasks: [Tab.ID: Task<Void, any Error>] = [:]
    #if DEBUG
    @ObservationIgnored var debugDeckPosition: ((CGFloat) -> Void)?
    @ObservationIgnored var debugDeckThrow: (() -> Void)?
    // The cards the deck draws now, and every card's lift, for checks that a thrown card never drops out on screen.
    @ObservationIgnored var debugDeckDrawn: (() -> (cards: Set<UUID>, lifts: [UUID: CGFloat]))?
    // The deck that published the three hooks above.
    @ObservationIgnored var debugDeckOwner: UUID?
    @ObservationIgnored var debugLoadStarted: ((Tab.ID) -> Void)?
    @ObservationIgnored var debugSurfaces: [DebugSurface: (DragPhase, DragSample) -> Void] = [:]
    @ObservationIgnored var debugActions: [Interaction: @MainActor () -> Void] = [:]
    @ObservationIgnored var debugWatches: [DebugSurface: () -> CGFloat] = [:]
    @ObservationIgnored var debugActionOwners: [Interaction: UUID] = [:]
    @ObservationIgnored var debugSurfaceOwners: [DebugSurface: UUID] = [:]
    @ObservationIgnored var debugWatchOwners: [DebugSurface: UUID] = [:]
    #endif

    var blocklistVersion: String {
        blocker.manifest.version
    }

    var activeIsPrivate: Bool {
        browser.activeTab?.isPrivate == true
    }

    init(
        directories: AppDirectories, ruleStore: WKContentRuleListStore, hapticSink: any HapticSink,
        energy: EnergyPolicy = EnergyPolicy(), pressure: MemoryPressureRelief = .live,
        assertion: BackgroundAssertion = .live
    ) {
        self.energy = energy
        self.assertion = assertion
        haptics = HapticsEngine(sink: hapticSink)
        ui = UIState(haptics: haptics)
        browser = BrowserStore(directories: directories)
        history = HistoryStore(directories: directories)
        sites = SiteSettingsStore(directories: directories)
        downloads = DownloadStore(directories: directories, assertion: assertion)
        sessions = SessionStore(directories: directories)
        blocker = ContentBlocker(categories: browser.settings.blockedCategories, store: ruleStore)
        pool = WebViewPool(
            blocker: blocker, sessions: sessions, haptics: haptics, prewarms: { [unowned energy] in !energy.isReduced })
        snapshots = SnapshotStore(directories: directories)
        favicons = FaviconStore(directories: directories)

        haptics.keepsWarm = { [unowned energy] in !energy.isReduced }
        favicons.allowsNetwork = { [unowned energy] in !energy.isReduced }
        pool.siteSettings = { [unowned sites] host, isPrivate in sites.settings(forHost: host, isPrivate: isPrivate) }
        ui.activeTabIsPrivate = { [unowned browser] in browser.activeTab?.isPrivate }
        pool.onControllerCreated = { [weak self] controller in
            self?.wire(controller)
        }
        browser.onTabsRemoved = { [weak self] ids in
            self?.tabsRemoved(ids)
        }
        ui.deck.onMotion = { [weak self] in self?.deckMotionChanged(moving: $0) }
        stopPressureWatch = pressure.watch { [weak self] in self?.pool.pressureEnded() }
        observeAdBlocking()
        observeEnergy()
    }

    isolated deinit {
        stopPressureWatch()
    }

    func launch() {
        AudioSession.configure()
        browser.runArchiveSweep()
        presentLaunchState()
    }

    // The lists an earlier run compiled are on before the first page loads; a first run or a new blocklist compiles
    // behind it, and the pages it loaded without them reload when they land.
    func finishLaunch() async {
        snapshots.preload(activeAndNeighborIDs())
        await blocker.loadCachedLists()
        attachActiveController()
        pool.prewarm()
        Task {
            await blocker.compileMissingLists()
            pool.trackers.domains = await TrackerDomains.bundled()
        }
        #if DEBUG
        await DebugLaunchOptions.current().run(in: self)
        #endif
    }

    func sceneWillEnterForeground() {
        pool.pressureEnded()
        downloads.resumeExpired()
        let active = browser.activeTabID
        let removed = browser.runArchiveSweep()
        guard let active, removed.contains(active) else { return }
        attachActiveController()
        if ui.overlay == .menu {
            ui.close(animated: false)
        }
        if ui.overlay == .none || ui.overlay == .search {
            presentLaunchState()
        }
    }

    // A thrown tab is archived when its gap close settles; leaving the foreground commits it first, while the cards
    // keep moving. The assertion is begun here, before the app enters the background, as the system asks.
    func sceneWillResignActive() {
        beginAssertionIfNeeded()
        ui.deck.finishDeparture()
    }

    // A Control Center pull or a Face ID prompt that returns: the assertion begun at the resign is let go.
    func sceneDidBecomeActive() {
        guard !flushing else { return }
        endFlushAssertion()
    }

    // State first and the picture last: the capture waits on a WebKit snapshot a backgrounded content process may never
    // answer, so an expiry can lose the picture, never the state. A later background entry takes over the assertion.
    func sceneDidEnterBackground() {
        beginAssertionIfNeeded()
        ui.deck.finishDeparture()
        browser.touchActiveTab()
        let capture = activeController.flatMap { captureSnapshot(of: $0.tabID) }
        pool.saveAllSessions()
        flushNumber += 1
        let flush = flushNumber
        flushing = true
        Task {
            await browser.flush()
            await history.flush()
            await sites.flush()
            await downloads.flush()
            await sessions.flush()
            await capture?.value
            await snapshots.flush()
            guard flush == flushNumber else { return }
            flushing = false
            endFlushAssertion()
        }
    }

    // The pictures of the cards the deck has built stay, with the ones a swipe, a flick or a zoom-in shows next; a
    // private picture cannot be read back from disk, so a memory warning drops every one.
    func memoryWarning() {
        pool.handleMemoryWarning(keeping: browser.activeTabID)
        favicons.releaseCache()
        let built = browser.tabs.enumerated().filter { ui.deck.span.contains($0.offset) }.map(\.element.id)
        snapshots.trim(keeping: Set(built + neighbourhoodIDs()).filter { !pool.isPrivate($0) })
    }

    // Another tab switch lands a swipe on the bar or a flick on the tab stack first, so its landing cannot undo the
    // switch.
    func open(_ url: URL, isPrivate: Bool = false) {
        flick?.finish()
        pager?.finish()
        captureOutgoingSnapshot()
        let tab = browser.openTab(url: url, isPrivate: isPrivate)
        attachActiveController()
        #if DEBUG
        debugLoadStarted?(tab.id)
        #endif
    }

    // A link another app hands over, as the default browser: it opens in a new tab in front, from whatever is up.
    // SwiftUI delivers a cold launch's link here too, after launch() has put up the search sheet. A link during a
    // submit waits for it to land: the submitted page is staged in front, and its hidden step only runs once the app
    // is back, so opening the link at once would leave it behind the search.
    func openLink(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        guard pendingSubmit == nil else {
            linksAfterSubmit.append(url)
            return
        }
        ui.close(animated: false)
        ui.setDeck(0, animated: false)
        open(url)
    }

    // The tab gets no web view until it is shown; the pool then loads it as it loads a restored tab.
    func openInBackground(_ url: URL, isPrivate: Bool = false) {
        pager?.finish()
        browser.openInBackground(url: url, isPrivate: isPrivate)
    }

    func togglePrivateMode() {
        haptics.fire(.privateToggle)
        ui.setPrivateMode(!ui.isPrivateMode)
    }

    // While incognito is on, the submitted tab is private.
    func submit(_ url: URL, via interaction: Interaction) {
        haptics.fire(interaction)
        let tab = browser.makeTab(url: url, isPrivate: ui.isPrivateMode)
        pendingSubmit = PendingSubmit(tab: tab)
        let controller = pool.controller(for: tab)
        #if DEBUG
        debugLoadStarted?(tab.id)
        #endif
        if let host = url.host() {
            controller.setPageZoom(zoom(forHost: host, isPrivate: tab.isPrivate))
        }
        ui.submitSearch(
            onHidden: { [unowned self] in adoptSubmitted(activate: true) },
            onCancel: { [unowned self] in adoptSubmitted(activate: false) })
        onSubmitted?(controller)
        captureOutgoingSnapshot()
    }

    // True once, for the controller a submit has just made active: the deck cuts it in instead of covering it.
    func takeCutIn(_ controller: WebTabController) -> Bool {
        guard cutInController === controller else { return false }
        cutInController = nil
        return true
    }

    // The zoom-out keeps the live page in the active card, so its snapshot is requested once the deck rests instead
    // of in the tap's turn, where it held back the first frame after a submit.
    func showSwitcher(via interaction: Interaction) {
        guard openSwitcher(via: interaction) else { return }
        atRest.append { [unowned self] in captureOutgoingSnapshot() }
    }

    // The button's zoom-out with the page left live in its card; the caller picks the moment for the page's picture.
    private func openSwitcher(via interaction: Interaction) -> Bool {
        guard ui.overlay == .none else { return false }
        flick?.finish()
        pager?.finish()
        haptics.fire(interaction)
        ui.setDeck(1)
        return true
    }

    func showTab(_ id: Tab.ID, via interaction: Interaction) {
        guard ui.overlay == .none else { return }
        captureOutgoingSnapshot()
        haptics.fire(interaction)
        zoomIn(on: id)
    }

    // A swipe on the bar landed on another tab: it switches in place as a deck tap switches, with no zoom. The page
    // left was captured on the touch's first move (TabPager.prepare), before anything moved, so nothing is captured
    // here.
    func pageTo(_ id: Tab.ID) {
        haptics.fire(.barSwipeSettle)
        browser.activate(id)
        attachActiveController()
    }

    func activatePreviousTab() {
        flick?.finish()
        pager?.finish()
        guard let previous = browser.previousTabID else { return }
        captureOutgoingSnapshot()
        haptics.fire(.tabStackFlick)
        flickedTo(previous)
    }

    // The tab stack's flick landed on the previous tab: it switches in place. Its haptic played as the card landed
    // and the page left was captured on the touch's first move.
    func flickedTo(_ id: Tab.ID) {
        browser.activate(id)
        attachActiveController()
    }

    func archive(_ id: Tab.ID) {
        browser.archive(id)
        attachActiveController()
    }

    func restore(_ id: ArchivedTab.ID) {
        captureOutgoingSnapshot()
        guard let tab = browser.restore(id) else { return }
        ui.close()
        haptics.fire(.archiveRestore)
        zoomIn(on: tab.id)
    }

    // The privacy policy is a page on the web (App Store guideline 5.1.1(i)): the Settings row opens it in a new tab in
    // front, and the sheet gives way to the page as it does to a restored tab.
    func openPrivacyPolicy() {
        haptics.fire(.settingsOpen)
        ui.close()
        open(Theme.Links.privacyPolicy)
        ui.setDeck(0)
    }

    func setPinned(_ pinned: Bool, for id: Tab.ID) {
        browser.setPinned(pinned, for: id)
    }

    func setDesktopMode(_ on: Bool, for id: Tab.ID) {
        browser.setDesktopMode(on, for: id)
        if let controller = pool.liveController(for: id) {
            controller.prefersDesktop = on
            controller.reload()
        }
    }

    // The page menu and Site Settings act on the active tab, so they read and write in its privacy.
    func zoom(forHost host: String) -> Double {
        zoom(forHost: host, isPrivate: activeIsPrivate)
    }

    func setZoom(_ zoom: Double, forHost host: String) {
        if activeIsPrivate {
            privateZoomByHost[host] = zoom
        } else {
            browser.settings.zoomByHost[host] = zoom
        }
        for controller in pool.controllers(onHost: host) {
            controller.setPageZoom(self.zoom(forHost: host, isPrivate: pool.isPrivate(controller.tabID)))
        }
    }

    func siteSettings(forHost host: String) -> SiteSettings {
        sites.settings(forHost: host, isPrivate: activeIsPrivate)
    }

    // A private change reaches only private tabs; a saved one reaches every tab, since private tabs read it too.
    func setSiteSettings(_ settings: SiteSettings, forHost host: String) {
        let isPrivate = activeIsPrivate
        sites.set(settings, forHost: host, isPrivate: isPrivate)
        for controller in pool.controllers(onHost: host) where !isPrivate || pool.isPrivate(controller.tabID) {
            controller.reload()
        }
    }

    func setTrackerBlocking(_ on: Bool, forHost host: String) {
        haptics.fire(on ? .settingsChange : .restorePage)
        var settings = siteSettings(forHost: host)
        settings.blocksTrackers = on
        setSiteSettings(settings, forHost: host)
        ui.close()
    }

    // A saved deny wins, a saved allow needs no asking, and only the kinds still unset are asked for. A page off screen
    // is denied at once, and a dismissed prompt denies this time only. A private tab ignores the saved decisions and
    // remembers nothing, so a choice made in normal browsing never applies there unseen.
    func decideMedia(host: String, kinds: [MediaKind], isPrivate: Bool, in webView: WKWebView) async -> Bool {
        let saved = kinds.map { isPrivate ? .ask : sites[host][$0] }
        if saved.contains(.deny) { return false }
        let unset = zip(kinds, saved).filter { $1 == .ask }.map(\.0)
        if unset.isEmpty { return true }
        guard webView.window != nil, let answer = await askMedia(webView, host, unset) else { return false }
        if !isPrivate {
            for kind in unset {
                sites[host][kind] = answer ? .allow : .deny
            }
        }
        return answer
    }

    // WebKit groups a site's data under its registrable domain, which is the host or a parent of it. From a private tab
    // it clears the private store only.
    func clearSiteData(forHost host: String) async {
        haptics.prepare(.clearData)
        let isPrivate = activeIsPrivate
        // Site Settings opens over the active tab only.
        let store = pool.dataStore(for: browser.activeTabID!)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types).filter {
            host == $0.displayName || host.hasSuffix(".\($0.displayName)")
        }
        await store.removeData(ofTypes: types, for: records)
        // A private tab's clear leaves the saved decisions, which it never used.
        if !isPrivate {
            sites.resetPermissions(forHost: host)
        }
        for controller in pool.controllers(onHost: host) where pool.isPrivate(controller.tabID) == isPrivate {
            controller.reload()
        }
        haptics.fire(.clearData)
    }

    // A private page's picture is held in memory only, for a swipe on the bar; its switcher card stays grey.
    @discardableResult func captureSnapshot(of id: Tab.ID) -> Task<Void, Never>? {
        onCaptureRequested?(id)
        guard let controller = pool.liveController(for: id), let width = controller.webView.window?.bounds.width
        else { return nil }
        return Task { [weak self] in
            guard let image = await controller.snapshot(width: width), let self else { return }
            let tint = CodableColor(controller.barTint)
            whenDeckRests { [weak self] in
                guard let self, browser.tabs.contains(where: { $0.id == id }) else { return }
                if pool.isPrivate(id) {
                    snapshots.hold(image, for: id)
                } else {
                    snapshots.store(image, for: id)
                }
                browser.setTint(tint, for: id)
            }
        }
    }

    // The deck driver reports its motion here. Work queued while it moves runs on the turn after it rests, so the
    // frame that lands a switch carries none of it; a rest in the browser then arms the neighbours' warm-up, and any
    // motion cancels it.
    func deckMotionChanged(moving: Bool) {
        deckMoving = moving
        cancelWarmUp()
        guard !moving else { return }
        Task { [weak self] in self?.runAtRest() }
    }

    // Any touch's first move on the bar: a gesture may follow, so nothing is built under it.
    func cancelWarmUp() {
        warmUp?.cancel()
        warmUp = nil
        isWarmArmed = false
    }

    // The active tab's deck neighbours (index plus and minus one) made live, a cold one restored from its session
    // and started loading, with their thumbnails decoded. The one memory-policy decision of the motion work, in one
    // place, so the efficiency branches can gate it without touching the gesture path.
    func prepareDeckNeighbours() {
        let neighbours = Set(activeAndNeighborIDs()).subtracting([browser.activeTabID].compactMap { $0 })
        let tabs = browser.tabs.filter { neighbours.contains($0.id) }
        // The live one first, to the pool's head, so building the cold one never evicts it.
        for tab in tabs where pool.liveController(for: tab.id) != nil {
            _ = pool.controller(for: tab)
        }
        for tab in tabs where pool.liveController(for: tab.id) == nil {
            _ = pool.controller(for: tab)
        }
        snapshots.preload(Array(neighbours))
    }

    private func runAtRest() {
        guard !deckMoving else { return }
        let work = atRest
        atRest = []
        work.forEach { $0() }
        guard ui.deckProgress == 0, ui.overlay == .none else { return }
        warmUp?.cancel()
        isWarmArmed = true
        warmUp = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Theme.Latency.neighbourWarmDelay))
            guard !Task.isCancelled, let self else { return }
            fireWarmUp()
        }
    }

    // The warm-up's fire: a sheet or the switcher opened since it was armed builds nothing under its rise.
    func fireWarmUp() {
        isWarmArmed = false
        warmUp = nil
        guard ui.deckProgress == 0, ui.overlay == .none else { return }
        prepareDeckNeighbours()
    }

    // A snapshot result writes a thumbnail and a tint, and every card and the tab stack re-render for it, so it waits
    // for the deck to rest instead of costing a frame of a zoom.
    func whenDeckRests(_ work: @escaping () -> Void) {
        if deckMoving {
            atRest.append(work)
        } else {
            work()
        }
    }

    func clearBrowsingData() async {
        haptics.prepare(.clearData)
        await pool.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        haptics.prepare(.clearData)
        history.clear()
        sites.resetAllPermissions()
        await favicons.clear()
        browser.clearArchive()
        haptics.fire(.clearData)
    }

    // One change per arming: the handler re-arms before it acts.
    private func observe(_ read: () -> Void, _ changed: @escaping @Sendable @MainActor () -> Void) {
        withObservationTracking(read) {
            Task { @MainActor in changed() }
        }
    }

    private func observeAdBlocking() {
        observe({ _ = browser.settings.blockedCategories }) { [weak self] in self?.adBlockingChanged() }
    }

    private func adBlockingChanged() {
        observeAdBlocking()
        let categories = browser.settings.blockedCategories
        guard categories != blocker.categories else { return }
        blocker.setCategories(categories)
        activeController?.reload()
    }

    // Energy returning to normal builds the spare web view at once, not after the next new tab's reveal.
    private func observeEnergy() {
        observe({ _ = energy.isReduced }) { [weak self] in self?.energyChanged() }
    }

    private func energyChanged() {
        observeEnergy()
        if !energy.isReduced {
            pool.prewarm()
        }
    }

    private func presentLaunchState() {
        ui.setDeck(browser.activeTab == nil ? 1 : 0, animated: false)
        ui.open(.search, animated: false)
    }

    private func beginAssertionIfNeeded() {
        guard endAssertion == nil else { return }
        endAssertion = assertion.begin("flush") { [weak self] in self?.endFlushAssertion() }
    }

    private func endFlushAssertion() {
        endAssertion?()
        endAssertion = nil
    }

    private func activeAndNeighborIDs() -> [Tab.ID] {
        guard let index = browser.tabs.firstIndex(where: { $0.id == browser.activeTabID }) else { return [] }
        return browser.tabs[max(0, index - 1)...min(browser.tabs.count - 1, index + 1)].map(\.id)
    }

    private func captureOutgoingSnapshot() {
        if let id = browser.activeTabID {
            captureSnapshot(of: id)
        }
    }

    private func zoomIn(on id: Tab.ID) {
        browser.activate(id)
        attachActiveController()
        ui.setDeck(0)
    }

    private func adoptSubmitted(activate: Bool) {
        let pending = pendingSubmit!
        pendingSubmit = nil
        browser.insert(pending.tab, activate: activate)
        retainActiveNeighbourhood()
        if pending.startedDownload {
            ui.endBarIntro()
            closeDownloadTab(pending.tab.id)
            return
        }
        let controller = pool.controller(for: pending.tab)
        if activate {
            cutInController = controller
            ui.scheduleBarIntro()
        }
        if browser.activeTabID == pending.tab.id {
            activeController = controller
        }
        if pending.hasFinished {
            pageFinished(controller, url: controller.webView.url!, title: controller.title)
        }
        guard !linksAfterSubmit.isEmpty else { return }
        cutInController = nil
        let links = linksAfterSubmit
        linksAfterSubmit = []
        links.forEach(openLink)
    }

    private func attachActiveController() {
        retainActiveNeighbourhood()
        guard let tab = browser.activeTab else {
            activeController = nil
            return
        }
        let controller = pool.controller(for: tab)
        if controller.needsReload {
            controller.needsReload = false
            controller.reload()
        }
        if let host = tab.url.host() {
            controller.setPageZoom(zoom(forHost: host, isPrivate: tab.isPrivate))
        }
        controller.prefersDesktop = tab.prefersDesktop
        activeController = controller
    }

    // The pictures a swipe on the bar, a flick or a zoom-in can show next stay decoded, and the neighbours are decoded
    // now if the budget had let them go.
    private func retainActiveNeighbourhood() {
        snapshots.retain(neighbourhoodIDs())
        snapshots.preload(activeAndNeighborIDs())
    }

    // The active tab, its deck neighbours and the previous tab.
    private func neighbourhoodIDs() -> [Tab.ID] {
        var ids = activeAndNeighborIDs()
        if let previous = browser.previousTabID, !ids.contains(previous) {
            ids.append(previous)
        }
        return ids
    }

    private func zoom(forHost host: String, isPrivate: Bool) -> Double {
        (isPrivate ? privateZoomByHost[host] : nil) ?? browser.settings.zoomByHost[host] ?? 1
    }

    // A private page's popups and link opens are private too; it records no history and fetches no favicon.
    private func wire(_ controller: WebTabController) {
        let id = controller.tabID
        let isPrivate = pool.isPrivate(id)
        controller.appOpener = .live(
            opensAppLinks: { [weak browser] in browser?.settings.opensAppLinksInApp == true },
            confirm: { [unowned controller] app in await controller.dialogs.openApp(app, in: controller.webView) })
        controller.onFinish = { [weak self, unowned controller] url, title in
            guard let self else { return }
            if let host = url.host() {
                controller.setPageZoom(zoom(forHost: host, isPrivate: isPrivate))
            }
            if pendingSubmit?.tab.id == id {
                pendingSubmit?.hasFinished = true
            } else {
                pageFinished(controller, url: url, title: title)
            }
        }
        controller.onPinchToSwitcher = { [weak self, unowned controller] in
            self?.pinchedToSwitcher(controller) == true
        }
        controller.onPinchZoomEnded = { [weak self, unowned controller] in self?.pinchZoomEnded(controller) }
        controller.onOpenWindow = { [weak self] webView, url in
            guard let self else { return }
            flick?.finish()
            pager?.finish()
            captureOutgoingSnapshot()
            let tab = browser.openTab(url: url, isPrivate: isPrivate)
            activeController = pool.adopt(webView, as: tab.id)
        }
        controller.onOpenLink = { [weak self] url, inBackground in
            if inBackground {
                self?.openInBackground(url, isPrivate: isPrivate)
            } else {
                self?.open(url, isPrivate: isPrivate)
            }
        }
        controller.onDownload = { [weak self, unowned controller] download in
            self?.downloadStarted(download, from: controller)
        }
        controller.decideMedia = { [weak self, unowned controller] host, kinds in
            guard let self else { return false }
            return await decideMedia(host: host, kinds: kinds, isPrivate: controller.isPrivate, in: controller.webView)
        }
        controller.lastSnapshot = { [weak self] in self?.snapshots.thumbnail(for: id).image }
        guard !isPrivate else { return }
        controller.onFavicon = { [weak self] host, iconURLs in
            self?.favicons.update(host: host, iconURLs: iconURLs)
        }
        history.track(controller)
    }

    // The page stays as it was. A tab with no page of its own opened only for the download.
    private func downloadStarted(_ download: WKDownload, from controller: WebTabController) {
        downloads.track(download, isPrivate: pool.isPrivate(controller.tabID))
        haptics.fire(.settingsChange)
        let id = controller.tabID
        guard controller.showsNoPage else { return }
        // A submitted tab joins the tabs once the search sheet hides, and closes then.
        if pendingSubmit?.tab.id == id {
            pendingSubmit?.startedDownload = true
        } else if browser.tabs.contains(where: { $0.id == id }) {
            closeDownloadTab(id)
        }
    }

    // The user lands on the tab they were on, or on the deck if none is left; the archive keeps no entry.
    private func closeDownloadTab(_ id: Tab.ID) {
        if browser.activeTabID == id, let previous = browser.previousTabID {
            browser.activate(previous)
        }
        browser.archive(id)
        browser.deleteArchived(id)
        attachActiveController()
        if browser.activeTab == nil {
            ui.setDeck(1)
        }
    }

    // The capture waits for the page to settle; a redirect chain or a reload storm inside the delay leaves one capture
    // pending, taken only if the page is still settled when the delay ends.
    private func pageFinished(_ controller: WebTabController, url: URL, title: String) {
        let id = controller.tabID
        browser.updatePage(id, url: url, title: title, tint: CodableColor(controller.barTint))
        settledSnapshotTasks[id]?.cancel()
        settledSnapshotTasks[id] = Task { [weak self] in
            try await Task.sleep(for: Self.settledSnapshotDelay)
            guard let self, !Task.isCancelled else { return }
            settledSnapshotTasks[id] = nil
            if pool.liveController(for: id)?.hasSettled == true {
                captureSnapshot(of: id)
            }
        }
    }

    // The pinch fired on the active page where the tab stack button is reachable (no overlay up, the browsing bar the
    // one drawn, the reader open or not) with no bar swipe or flick in motion: it presses the button. WebKit keeps
    // shrinking the page under the fingers past the deck's rest, so the page's picture waits for its zoom to end.
    private func pinchedToSwitcher(_ controller: WebTabController) -> Bool {
        guard controller === activeController, ui.overlay == .none, !ui.deck.barsShowDeck, pager?.isMoving != true,
            flick?.isMoving != true
        else { return false }
        return openSwitcher(via: .pinchSwitcher)
    }

    private func pinchZoomEnded(_ controller: WebTabController) {
        captureSnapshot(of: controller.tabID)
    }

    private func tabsRemoved(_ ids: [Tab.ID]) {
        for id in ids {
            if let controller = pool.liveController(for: id) {
                controller.onFinish = nil
                controller.onOpenWindow = nil
                controller.onOpenLink = nil
                controller.onFavicon = nil
                controller.onCommit = nil
                controller.onTitle = nil
                controller.onDownload = nil
                controller.onPinchToSwitcher = nil
                controller.onPinchZoomEnded = nil
            }
            settledSnapshotTasks.removeValue(forKey: id)?.cancel()
            pool.discard(id)
            snapshots.remove(id)
            sessions.remove(id)
        }
        if pool.privateStore != nil, !browser.hasPrivateTabs, pendingSubmit?.tab.isPrivate != true {
            pool.endPrivateSession()
            sites.endPrivateSession()
            privateZoomByHost = [:]
        }
    }
}

private extension CodableColor {
    init(_ color: UIColor) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.resolvedColor(with: .current).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(red: red, green: green, blue: blue)
    }
}
