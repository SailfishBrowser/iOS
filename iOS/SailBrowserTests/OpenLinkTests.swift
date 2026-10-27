import Foundation
import Testing
@testable import SailBrowser

// Links another app hands over once the app is the default browser.
struct OpenLinkTests {
    private static let first = URL(string: "http://link.test/first")!
    private static let second = URL(string: "https://link.test/second")!

    @Test func theAppDeclaresHttpAndHttpsLinks() throws {
        let types = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(Set(schemes) == ["http", "https"])
    }

    @Test func aLinkOpenedAtLaunchOpensItsTabInFront() {
        let env = makeEnvironment()
        env.launch()
        #expect(env.ui.overlay == .search)

        env.openLink(Self.first)

        let tab = env.browser.activeTab
        #expect(env.browser.tabs.count == 1)
        #expect(tab?.url == Self.first)
        #expect(env.activeController?.tabID == tab?.id)
        #expect(env.ui.overlay == .none)
        #expect(env.ui.searchShrink == 0)
        #expect(env.ui.deckProgress == 0)
    }

    @Test func aLinkWhileTheDeckIsUpClosesTheDeckAndShowsThePage() {
        let env = makeEnvironment()
        env.open(page("a"))
        env.showSwitcher(via: .tabStackTap)
        #expect(env.ui.deckProgress == 1)

        env.openLink(Self.second)

        #expect(env.ui.deckProgress == 0)
        #expect(env.browser.activeTab?.url == Self.second)
        #expect(env.activeController?.tabID == env.browser.activeTabID)
    }

    @Test func aLinkClosesASheetOverTheDeck() {
        let env = makeEnvironment()
        env.open(page("a"))
        env.ui.setDeck(1, animated: false)
        #expect(env.ui.open(.settings))

        env.openLink(Self.second)

        #expect(env.ui.overlay == .none)
        #expect(env.ui.deckProgress == 0)
        #expect(env.browser.activeTab?.url == Self.second)
    }

    @Test func aLinkClosesThePageMenu() {
        let env = makeEnvironment()
        env.open(page("a"))
        #expect(env.ui.open(.menu))

        env.openLink(Self.second)

        #expect(env.ui.overlay == .none)
        #expect(env.browser.activeTab?.url == Self.second)
    }

    @Test(arguments: ["mailto:a@b.test", "ftp://link.test/", "file:///tmp/a.html", "data:text/html,<p>a</p>"])
    func aLinkThatIsNotAWebPageIsIgnored(_ link: String) {
        let env = makeEnvironment()
        env.launch()

        env.openLink(URL(string: link)!)

        #expect(env.browser.tabs.isEmpty)
        #expect(env.ui.overlay == .search)
    }

    @Test func twoLinksInQuickSuccessionOpenTwoTabsInOrder() {
        let env = makeEnvironment()
        env.launch()

        env.openLink(Self.first)
        env.openLink(Self.second)

        #expect(env.browser.tabs.map(\.url) == [Self.first, Self.second])
        #expect(env.browser.activeTab?.url == Self.second)
        #expect(env.activeController?.tabID == env.browser.activeTabID)
    }

    @Test func aLinkThatLoadsIsRecordedInHistory() async throws {
        let env = makeEnvironment()
        env.launch()

        env.openLink(Self.second)
        let controller = try #require(env.activeController)
        controller.webView.loadSimulatedRequest(URLRequest(url: Self.second), responseHTML: "<p>second</p>")
        try await waitUntil(timeout: .seconds(10)) { controller.hasSettled && controller.url == Self.second }

        #expect(env.history.entries.map(\.url) == [Self.second])
    }

    @Test func aLinkToAZoomedSiteStartsAtThatZoom() {
        let env = makeEnvironment()
        env.browser.settings.zoomByHost["link.test"] = 1.5
        env.launch()

        env.openLink(Self.first)

        #expect(env.activeController?.webView.pageZoom == 1.5)
    }

    @Test func aLinkDuringASubmitOpensInFrontOnceTheSubmitLands() throws {
        let env = makeEnvironment()
        env.open(page("a"))
        #expect(env.ui.open(.search, animated: false))
        env.submit(page("searched"), via: .searchSubmit)

        env.openLink(Self.second)
        #expect(env.browser.activeTab?.url == page("a"))

        env.ui.submitHidden()

        #expect(env.browser.tabs.map(\.url) == [page("a"), page("searched"), Self.second])
        #expect(env.browser.activeTab?.url == Self.second)
        #expect(env.activeController?.tabID == env.browser.activeTabID)
        #expect(env.ui.overlay == .none)
        #expect(env.ui.deckProgress == 0)
        #expect(!env.takeCutIn(try #require(env.pool.liveController(for: env.browser.tabs[1].id))))
    }

    // Reopening search cancels the submit; the held link opens behind the search the user has just asked for.
    @Test func aLinkDuringACancelledSubmitStillOpensInFront() {
        let env = makeEnvironment()
        env.open(page("a"))
        #expect(env.ui.open(.search, animated: false))
        env.submit(page("searched"), via: .searchSubmit)
        env.openLink(Self.second)

        #expect(env.ui.open(.search, animated: false))

        #expect(env.browser.tabs.map(\.url) == [page("a"), page("searched"), Self.second])
        #expect(env.browser.activeTab?.url == Self.second)
        #expect(env.activeController?.tabID == env.browser.activeTabID)
        #expect(env.ui.overlay == .search)
    }

    private func staleTab(_ name: String) -> Tab {
        let date = Date().addingTimeInterval(-48 * 3600)
        return Tab(
            id: UUID(), url: page(name), title: name, isPinned: false, prefersDesktop: false, createdAt: date,
            lastActiveAt: date, tint: nil)
    }

    private func environment(withStaleActive tab: Tab) throws -> AppEnvironment {
        let directories = AppDirectories.temporary()
        let state = BrowserState(tabs: [tab], archived: [], activeTabID: tab.id, settings: BrowserSettings())
        try FileManager.default.createDirectory(at: directories.support, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: directories.support.appending(path: "state.json"))
        return makeEnvironment(directories)
    }

    @Test func aLinkArrivingAfterTheForegroundSweepShowsThePage() throws {
        let env = try environment(withStaleActive: staleTab("stale"))
        env.sceneWillEnterForeground()
        #expect(env.ui.overlay == .search)

        env.openLink(Self.first)

        #expect(env.ui.overlay == .none)
        #expect(env.ui.deckProgress == 0)
        #expect(env.browser.tabs.map(\.url) == [Self.first])
        #expect(env.activeController?.tabID == env.browser.activeTabID)
    }

    @Test func aLinkArrivingBeforeTheForegroundSweepSurvivesIt() throws {
        let env = try environment(withStaleActive: staleTab("stale"))

        env.openLink(Self.first)
        env.sceneWillEnterForeground()

        #expect(env.ui.overlay == .none)
        #expect(env.ui.deckProgress == 0)
        #expect(env.browser.tabs.map(\.url) == [Self.first])
        #expect(env.browser.activeTab?.url == Self.first)
    }
}
