import Foundation
import Testing
import WebKit
@testable import SailBrowser

@Suite(.serialized)
struct ContentBlockerTests {
    @Test func bundledManifestListsExistingFilesUnderRuleLimit() throws {
        let manifest = BlocklistManifest.bundled(in: .main)
        #expect(manifest.lists == [
            .init(name: "easylist", category: .ads), .init(name: "annoyances", category: .ads),
            .init(name: "easyprivacy", category: .trackers), .init(name: "easylist-cookie", category: .cookieBanners),
        ])
        for list in manifest.lists {
            let url = try #require(Bundle.main.url(forResource: list.name, withExtension: "json"))
            let rules = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [Any])
            #expect((1_000..<150_000).contains(rules.count), "\(list.name) has \(rules.count) rules")
        }
    }

    // Ads off and trackers on: the ad list's image loads, the tracker list's does not.
    @Test func eachCategoryAttachesOnlyItsOwnLists() async throws {
        let blocker = ContentBlocker(
            categories: [.trackers], store: temporaryRuleStore(),
            bundle: try ruleBundle(lists: [.ads: blockRule("ad.gif"), .trackers: blockRule("tracker.gif")]))
        let configuration = WKWebViewConfiguration()
        blocker.attach(configuration.userContentController)
        await blocker.prepare()
        #expect(blocker.blockedCategories(configuration.userContentController) == [.trackers])
        let server = try await LocalPageServer { _ in #"<img src="/ad.gif"><img src="/tracker.gif">"# }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: server.url("/page")))

        try await waitUntil(timeout: .seconds(10)) { server.requestedPaths.contains("/ad.gif") && !webView.isLoading }
        #expect(!server.requestedPaths.contains("/tracker.gif"))
    }

    // Restoring a site lifts every category's lists and PageShield's scripts; the next site gets both back.
    @Test func aRestoredSiteLiftsEveryCategoryAndItsScriptsUntilTheNextSite() async throws {
        let constant = #"{"scriptlets":[["set-constant","sailShield","true"]]}"#
        let blocker = ContentBlocker(
            categories: Set(BlockingCategory.allCases), store: temporaryRuleStore(),
            bundle: try ruleBundle(
                lists: [
                    .ads: blockRule("ad.gif"), .trackers: blockRule("tracker.gif"),
                    .cookieBanners: blockRule("cookie.gif"),
                ],
                shield: [.ads: #"{"127.0.0.1":\#(constant),"localhost":\#(constant)}"#]))
        await blocker.prepare()
        let pool = WebViewPool(blocker: blocker, sessions: SessionStore(directories: .temporary()), haptics: recordingHaptics())
        pool.siteSettings = { host, _ in SiteSettings(blocksTrackers: host != "127.0.0.1") }
        let server = try await LocalPageServer { path in
            let site = path.split(separator: "?")[1]
            return #"<img src="/ad.gif?\#(site)"><img src="/tracker.gif?\#(site)"><img src="/cookie.gif?\#(site)">"#
                + "<script>document.title = String(window.sailShield)</script>"
        }
        let restored = server.url("/page?restored")
        let blocked = URL(string: server.url("/page?blocked").absoluteString.replacing("127.0.0.1", with: "localhost"))!
        let controller = pool.controller(for: Tab(
            id: UUID(), url: restored, title: "", isPinned: false, prefersDesktop: false, createdAt: .now,
            lastActiveAt: .now, tint: nil))
        let finished = FinishedURLs()
        controller.onFinish = { url, _ in finished.urls.append(url) }
        let content = controller.webView.configuration.userContentController
        let shieldScripts = { content.userScripts.filter { $0 !== TrackerCounter.script } }

        try await waitUntil(timeout: .seconds(10)) { finished.urls == [restored] }
        #expect(["ad", "tracker", "cookie"].allSatisfy { server.requestedPaths.contains("/\($0).gif?restored") })
        #expect(try await documentTitle(of: controller.webView) == "undefined")
        #expect(blocker.blockedCategories(content).isEmpty)
        #expect(shieldScripts().isEmpty)

        controller.load(blocked)
        try await waitUntil(timeout: .seconds(10)) { finished.urls == [restored, blocked] }
        #expect(!server.requestedPaths.contains { $0.hasSuffix(".gif?blocked") })
        #expect(try await documentTitle(of: controller.webView) == "true")
        #expect(blocker.blockedCategories(content) == Set(BlockingCategory.allCases))
        #expect(!shieldScripts().isEmpty)
    }

    @Test func prepareCompilesThenReusesCacheAndRemovesStale() async throws {
        let store = temporaryRuleStore()
        let stale = "easylist-2000.01.01"
        _ = try await store.compileContentRuleList(forIdentifier: stale, encodedContentRuleList: adRuleJSON)
        let blocker = ContentBlocker(categories: Set(BlockingCategory.allCases), store: store)
        let current = Set(blocker.manifest.lists.map(blocker.manifest.identifier(for:)))

        await blocker.prepare()
        #expect(blocker.isReady)
        #expect(Set(await store.availableIdentifiers() ?? []) == current)

        let reuse = await ContinuousClock().measure { await blocker.prepare() }
        #expect(reuse < .seconds(1))
        #expect(Set(await store.availableIdentifiers() ?? []) == current)
    }

    @Test func togglingBeforePrepareAppliesCurrentSettingWhenReady() async throws {
        let configuration = WKWebViewConfiguration()
        let blocker = ContentBlocker(categories: Set(BlockingCategory.allCases), store: temporaryRuleStore(), bundle: try adRuleBundle())
        blocker.attach(configuration.userContentController)
        blocker.setCategories([])
        await blocker.prepare()
        #expect(blocker.isReady)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        #expect(try await adDisplay(in: webView, load: 1) == "block")
    }

    @Test func applyTogglesBlockingOnLiveWebView() async throws {
        let configuration = WKWebViewConfiguration()
        let blocker = ContentBlocker(categories: Set(BlockingCategory.allCases), store: temporaryRuleStore(), bundle: try adRuleBundle())
        blocker.attach(configuration.userContentController)
        await blocker.prepare()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        #expect(try await adDisplay(in: webView, load: 1) == "none")

        blocker.setCategories([])
        #expect(try await adDisplay(in: webView, load: 2) == "block")
    }

    @Test func eachControllerFollowsItsOwnSiteSettingUnderTheGlobalSwitch() async throws {
        let blocker = ContentBlocker(categories: Set(BlockingCategory.allCases), store: temporaryRuleStore(), bundle: try adRuleBundle())
        let allowed = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let blocked = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        blocker.attach(allowed.configuration.userContentController)
        blocker.attach(blocked.configuration.userContentController)
        blocker.setBlocking(false, host: "example.test", on: allowed.configuration.userContentController)
        await blocker.prepare()

        #expect(try await adDisplay(in: allowed, load: 1) == "block")
        #expect(try await adDisplay(in: blocked, load: 1) == "none")
        #expect(!blocker.isBlocking(allowed.configuration.userContentController))
        #expect(blocker.isBlocking(blocked.configuration.userContentController))

        blocker.setCategories([])
        #expect(try await adDisplay(in: blocked, load: 2) == "block")
        blocker.setCategories(Set(BlockingCategory.allCases))
        blocker.setBlocking(true, host: "example.test", on: allowed.configuration.userContentController)
        #expect(try await adDisplay(in: allowed, load: 2) == "none")
        #expect(try await adDisplay(in: blocked, load: 3) == "none")
    }

    // The reader's own web view is under the lists its tab's pages are under: none where the site or the switches
    // allow everything, and only the lists of the categories that are on.
    @Test func theReaderPageIsUnderItsTabsLists() async throws {
        let blocker = ContentBlocker(
            categories: Set(BlockingCategory.allCases), store: temporaryRuleStore(), bundle: try adRuleBundle())
        let tab = WKUserContentController()
        blocker.attach(tab)
        #expect(blocker.ruleLists(for: tab).isEmpty)
        await blocker.prepare()

        let webView = WKWebView(frame: .zero, configuration: ReaderController.configuration(ruleLists: blocker.ruleLists(for: tab)))
        #expect(try await adDisplay(in: webView, load: 1) == "none")

        blocker.setBlocking(false, host: "example.test", on: tab)
        #expect(blocker.ruleLists(for: tab).isEmpty)
        blocker.setBlocking(true, host: "example.test", on: tab)
        blocker.setCategories([.trackers, .cookieBanners])
        #expect(blocker.ruleLists(for: tab).isEmpty)
        blocker.setCategories([])
        #expect(blocker.ruleLists(for: tab).isEmpty)
    }
}

let adRuleJSON = ##"[{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":"#ad"}}]"##

func temporaryRuleStore() -> WKContentRuleListStore {
    WKContentRuleListStore(url: FileManager.default.temporaryDirectory.appending(path: "rules-\(UUID().uuidString)"))
}

func adRuleBundle() throws -> Bundle {
    try ruleBundle(adRuleJSON)
}

func ruleBundle(_ json: String) throws -> Bundle {
    try ruleBundle(lists: [.ads: json])
}

// The page's own title. WKWebView's title property reaches the app on its own path and can trail the finish callback.
func documentTitle(of webView: WKWebView) async throws -> String? {
    try await webView.evaluateJavaScript("document.title") as? String
}

// Blocks loads whose URL contains the path.
func blockRule(_ path: String) -> String {
    #"[{"trigger":{"url-filter":"\#(path.replacing(".", with: #"\\."#))"},"action":{"type":"block"}}]"#
}

// A bundle with one list per given category and PageShield data, empty unless given.
func ruleBundle(lists: [BlockingCategory: String], shield: [BlockingCategory: String] = [:]) throws -> Bundle {
    let directory = FileManager.default.temporaryDirectory.appending(path: "blocklists-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let entries = BlockingCategory.allCases.filter { lists[$0] != nil }
        .map { #"{"name":"\#($0.rawValue)-rules","category":"\#($0.rawValue)"}"# }
    try #"{"version":"1","lists":[\#(entries.joined(separator: ","))]}"#
        .write(to: directory.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
    for (category, json) in lists {
        try json.write(to: directory.appending(path: "\(category.rawValue)-rules.json"), atomically: true, encoding: .utf8)
    }
    for category in BlockingCategory.allCases {
        try (shield[category] ?? "{}")
            .write(to: directory.appending(path: "\(category.rawValue).json"), atomically: true, encoding: .utf8)
    }
    return try #require(Bundle(url: directory))
}

func adDisplay(in webView: WKWebView, load: Int) async throws -> String {
    webView.loadHTMLString(#"<body data-load="\#(load)"><div id="ad">ad</div></body>"#, baseURL: URL(string: "https://example.test/"))
    let script = "document.body?.dataset.load === '\(load)' && document.readyState === 'complete' ? getComputedStyle(document.getElementById('ad')).display : 'pending'"
    let deadline = ContinuousClock.now + .seconds(15)
    while true {
        let display = try #require(try await webView.evaluateJavaScript(script) as? String)
        if display != "pending" { return display }
        guard ContinuousClock.now < deadline else { throw WaitTimedOut() }
        try await Task.sleep(for: .milliseconds(20))
    }
}
