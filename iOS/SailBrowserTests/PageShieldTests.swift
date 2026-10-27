import Foundation
import Testing
import WebKit
@testable import SailBrowser

@Suite(.serialized)
struct PageShieldTests {
    private static let oneTrustPage = """
        <meta name="viewport" content="width=device-width">
        <body style="overflow: hidden; position: fixed; width: 100%; margin: 0">
        <div id="onetrust-consent-sdk">
          <button id="onetrust-reject-all-handler" onclick="document.body.dataset.rejected = 'yes'">Reject</button>
        </div>
        <div class="onetrust-pc-dark-filter" style="position: fixed; inset: 0; background: black"></div>
        <div style="height: 5000px">story</div>
        </body>
        """
    private static let hideOneTrust =
        ##"[{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":"#onetrust-consent-sdk"}}]"##

    private func pool(_ categories: Set<BlockingCategory>, shield: [BlockingCategory: String] = [:]) async throws
        -> WebViewPool
    {
        let blocker = ContentBlocker(
            categories: categories, store: temporaryRuleStore(),
            bundle: try ruleBundle(lists: [.ads: adRuleJSON, .cookieBanners: Self.hideOneTrust], shield: shield))
        await blocker.prepare()
        let pool = WebViewPool(blocker: blocker, sessions: SessionStore(directories: .temporary()), haptics: recordingHaptics())
        pool.page = PageGeometry(bounds: CGRect(x: 0, y: 0, width: 390, height: 844), safeTop: 0)
        return pool
    }

    // One web view on screen at a time: WebKit runs no animation frames for one outside a window or covered by
    // another, and the cookie check waits for one.
    private static var windows: [UIWindow] = []

    private static func onScreen(_ webView: WKWebView) {
        windows.forEach { $0.isHidden = true }
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.first as! UIWindowScene)
        window.isHidden = false
        window.addSubview(webView)
        windows = [window]
    }

    private func load(_ url: URL, in pool: WebViewPool) async throws -> WebTabController {
        let controller = pool.controller(for: Tab(
            id: UUID(), url: url, title: "", isPinned: false, prefersDesktop: false, createdAt: .now,
            lastActiveAt: .now, tint: nil))
        Self.onScreen(controller.webView)
        try await waitUntil(timeout: .seconds(10)) { controller.hasSettled }
        return controller
    }

    // The script's result once it equals the expected one, or its last result after the timeout.
    private func result(of script: String, in webView: WKWebView, becoming expected: String, timeout: Duration = .seconds(5))
        async throws -> String?
    {
        let deadline = ContinuousClock.now + timeout
        var state = try await webView.evaluateJavaScript(script) as? String
        while state != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            state = try await webView.evaluateJavaScript(script) as? String
        }
        return state
    }

    @Test func aHiddenConsentManagerLeavesThePageScrollableWithoutItsBackdrop() async throws {
        let server = try await LocalPageServer { _ in Self.oneTrustPage }
        let controller = try await load(server.url("/page"), in: try await pool(Set(BlockingCategory.allCases)))
        let expected = #"[true,true,"none","yes"]"#
        let state = try await result(of: """
            (() => {
              scrollTo(0, 0);
              scrollBy(0, 500);
              return JSON.stringify([document.scrollingElement.scrollHeight > innerHeight, scrollY > 0,
                getComputedStyle(document.querySelector('.onetrust-pc-dark-filter')).display,
                document.body.dataset.rejected ?? 'no']);
            })()
            """, in: controller.webView, becoming: expected)
        #expect(state == expected)
    }

    // After the watch window the site's own lock, a menu's, stays.
    @Test func aLockTheSiteSetsAfterTheWatchWindowStays() async throws {
        let relock = """
            <script>addEventListener('load', () => setTimeout(() => {
              document.body.style.overflow = 'hidden';
              document.body.dataset.relocked = 'yes';
            }, \(Int((Theme.Blocking.cookieWallWatch + .milliseconds(500)) / .milliseconds(1)))))</script>
            """
        let server = try await LocalPageServer { _ in Self.oneTrustPage.replacing("</body>", with: relock + "</body>") }
        let controller = try await load(server.url("/page"), in: try await pool(Set(BlockingCategory.allCases)))
        let override = "document.body.style.getPropertyValue('overflow-y')"
        #expect(try await result(of: override, in: controller.webView, becoming: "visible") == "visible")
        let relocked = try await result(
            of: "document.body.dataset.relocked ?? 'no'", in: controller.webView, becoming: "yes", timeout: .seconds(10))
        #expect(relocked == "yes")
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await controller.webView.evaluateJavaScript("getComputedStyle(document.body).overflowY") as? String == "hidden")
    }

    @Test func aBodyLockedByOverflowAloneIsUnlocked() async throws {
        let page = Self.oneTrustPage.replacing("overflow: hidden; position: fixed;", with: "overflow: hidden;")
        let server = try await LocalPageServer { _ in page }
        let controller = try await load(server.url("/page"), in: try await pool(Set(BlockingCategory.allCases)))
        let override = "document.body.style.getPropertyValue('overflow-y')"
        #expect(try await result(of: override, in: controller.webView, becoming: "visible") == "visible")
    }

    @Test func withCookieBannersOffAConsentManagersLockStays() async throws {
        let server = try await LocalPageServer { _ in Self.oneTrustPage }
        let controller = try await load(server.url("/page"), in: try await pool([.ads, .trackers]))
        try await Task.sleep(for: .milliseconds(300))
        let state = try #require(try await controller.webView.evaluateJavaScript("""
            JSON.stringify([document.scrollingElement.scrollHeight > innerHeight, document.body.dataset.rejected ?? 'no'])
            """) as? String)
        #expect(state == #"[false,"no"]"#)
    }

    @Test func aSetConstantRuleRunsBeforeThePagesOwnScript() async throws {
        let pool = try await pool(
            Set(BlockingCategory.allCases),
            shield: [.ads: #"{"127.0.0.1":{"scriptlets":[["set-constant","sailAdsReady","true"]]}}"#])
        let server = try await LocalPageServer { _ in
            "<script>document.title = typeof window.sailAdsReady + ':' + window.sailAdsReady</script>"
        }
        let ruled = try await load(server.url("/page"), in: pool)
        #expect(try await documentTitle(of: ruled.webView) == "boolean:true")

        let other = URL(string: server.url("/page").absoluteString.replacing("127.0.0.1", with: "localhost"))!
        #expect(try await documentTitle(of: try await load(other, in: pool).webView) == "undefined:undefined")
    }

    // The Ads switch takes PageShield with it.
    @Test func withAdsOffTheSitesScriptletsDoNotRun() async throws {
        let pool = try await pool(
            [.trackers, .cookieBanners],
            shield: [.ads: #"{"127.0.0.1":{"scriptlets":[["set-constant","sailAdsReady","true"]]}}"#])
        let server = try await LocalPageServer { _ in "<script>document.title = typeof window.sailAdsReady</script>" }
        #expect(try await documentTitle(of: try await load(server.url("/page"), in: pool).webView) == "undefined")
    }

    @Test func proceduralSelectorsAndStylesHideWhatTheyMatchIncludingLateContent() async throws {
        let rules = #"""
            {"127.0.0.1":{"css":"#styled { color: rgb(1, 2, 3) !important; }","procedural":[
              ".card:has-text(Sponsored)","p.promo:has-text(/^Promo \\d+$/):upward(1)",
              "section:has(> h2:has-text(Partners))",".heading:has-text(Sponsor Posts) + ul"]}}
            """#
        let pool = try await pool(Set(BlockingCategory.allCases), shield: [.ads: rules])
        let server = try await LocalPageServer { _ in
            """
            <div class="card" id="a">Sponsored post</div><div class="card" id="b">Real post</div>
            <div id="c"><p class="promo">Promo 42</p></div><div id="f"><p class="promo">Promo code</p></div>
            <section id="d"><h2>Partners</h2></section><section id="e"><h2>News</h2></section>
            <p id="styled">styled</p>
            <div><h3 class="heading">Sponsor Posts</h3><ul id="g"><li>ad</li></ul><ul id="h"><li>news</li></ul></div>
            <script>setTimeout(() => {
              const late = document.createElement('div');
              late.className = 'card'; late.id = 'late'; late.textContent = 'Sponsored late';
              document.body.append(late);
            }, 50)</script>
            """
        }
        let controller = try await load(server.url("/page"), in: pool)
        let script = """
            (() => {
              const shown = id => getComputedStyle(document.getElementById(id)).display !== 'none';
              return JSON.stringify([shown('a'), shown('b'), shown('c'), shown('f'), shown('d'), shown('e'), shown('g'), shown('h'),
                getComputedStyle(document.getElementById('styled')).color,
                document.getElementById('late') && shown('late')]);
            })()
            """
        let expected = #"[false,true,false,true,false,true,false,true,"rgb(1, 2, 3)",false]"#
        let deadline = ContinuousClock.now + .seconds(5)
        var state = try await controller.webView.evaluateJavaScript(script) as? String
        while state != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            state = try await controller.webView.evaluateJavaScript(script) as? String
        }
        #expect(state == expected)
    }

    // An embedded player's frame gets its own host's scriptlets on another site's page; the page does not.
    @Test func anEmbedHostsFrameRunsItsOwnScriptletsOnAnotherSitesPage() async throws {
        let rules = #"{"localhost":{"scriptlets":[["set-constant","sailEmbed","true"]]}}"#
        let shield = try await PageShield.bundled(
            in: try ruleBundle(lists: [.ads: adRuleJSON], shield: [.ads: rules]), embedHosts: ["localhost"])
        let configuration = WKWebViewConfiguration()
        shield.scripts(for: "127.0.0.1", categories: Set(BlockingCategory.allCases))
            .forEach(configuration.userContentController.addUserScript)
        let port = PortNumber()
        let server = try await LocalPageServer { path in
            path == "/page-frame"
                ? "<script>parent.postMessage(typeof window.sailEmbed + ':' + window.sailEmbed, '*')</script>"
                : #"<script>addEventListener('message', event => { document.title = event.data + '|' + typeof window.sailEmbed })</script>"#
                    + #"<iframe src="http://localhost:\#(port.value)/page-frame"></iframe>"#
        }
        port.value = server.url("/").port!
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        webView.load(URLRequest(url: server.url("/page")))
        let title = try await result(of: "document.title", in: webView, becoming: "boolean:true|undefined")
        #expect(title == "boolean:true|undefined")
    }

    @Test func theAcknowledgementsNameEachListItsLicenceTheScriptletsAndReadability() {
        let notice = AcknowledgementsSection.notice
        for line in [
            "EasyList", "EasyPrivacy", "EasyList Cookie List", "Fanboy's Annoyance List",
            "https://creativecommons.org/licenses/by-sa/3.0/", "https://creativecommons.org/licenses/by/3.0/",
            "Files derived from EasyList or EasyPrivacy are themselves licensed under Creative Commons Attribution-ShareAlike",
            "The scripts that page rules call are written for Sailfish",
            "Readability.js 0.6.0", "Licensed under the Apache License, Version 2.0",
        ] {
            #expect(notice.contains(line), "\(line)")
        }
    }

    @Test func aHostMatchesItsParentsAndCountryWildcards() {
        #expect(PageShield.keys(for: "www.deliveroo.co.uk")
            == ["", "www.deliveroo.co.uk", "deliveroo.co.uk", "deliveroo.*", "co.uk", "co.*", "uk"])
        #expect(PageShield.keys(for: "localhost") == ["", "localhost"])
    }

    @Test func theBundledDataCarriesTheYouTubeAdPruneAndCallsOnlyTheEightScriptlets() throws {
        #expect(Set(PageShieldScriptlets.functions.keys) == [
            "set-constant", "abort-on-property-read", "abort-current-inline-script", "json-prune", "remove-attr",
            "remove-class", "prevent-addEventListener", "prevent-setTimeout",
        ])
        var called: Set<String> = []
        for category in BlockingCategory.allCases {
            let rules = try JSONDecoder().decode(
                [String: PageShield.Rules].self,
                from: Data(contentsOf: try #require(Bundle.main.url(forResource: category.rawValue, withExtension: "json"))))
            called.formUnion(rules.values.flatMap { $0.scriptlets ?? [] }.map { $0[0] })
            if category == .ads {
                let youtube = try #require(rules["youtube.com"]?.scriptlets)
                #expect(youtube.contains { $0.first == "json-prune" && $0[1].contains("playerResponse.adPlacements") })
            }
        }
        #expect(called == Set(PageShieldScriptlets.functions.keys))
    }

    // Each scriptlet as the shipped rules call it, against the page script it targets.
    @Test func eachScriptletDoesWhatItsRulesExpect() async throws {
        let calls: [[String]] = [
            ["set-constant", "site.config.ads", "false"], ["set-constant", "Navigator.prototype.sailPrivacy", "true"],
            ["abort-on-property-read", "adDetector"], ["abort-current-inline-script", "sailTrack", "adblock-check"],
            ["json-prune", "ads.[].imageUrl"], ["remove-attr", "oncontextmenu"],
            ["remove-class", "no-scroll", "body", "stay"], ["prevent-addEventListener", "scroll", "blockScroll"],
            ["prevent-setTimeout", "loginModal"],
        ]
        let rules = String(decoding: try JSONEncoder().encode(["127.0.0.1": ["scriptlets": calls]]), as: UTF8.self)
        let pool = try await pool(Set(BlockingCategory.allCases), shield: [.ads: rules])
        let server = try await LocalPageServer { _ in
            """
            <body class="no-scroll"><div id="menu" oncontextmenu="return false">menu</div>
            <script>
              const r = window.results = {};
              window.site = { config: { ads: true } };
              r.constant = window.site.config.ads;
              r.prototype = navigator.sailPrivacy;
              try { adDetector; r.aborted = false } catch (error) { r.aborted = error instanceof ReferenceError }
              window.sailTrack = () => 'tracked';
            </script>
            <script>/* adblock-check */ try { sailTrack(); r.checked = 'ran' } catch { r.checked = 'aborted' }</script>
            <script>
              r.other = sailTrack();
              r.pruned = JSON.stringify(JSON.parse('{"ads":[{"imageUrl":"x","id":1}]}'));
              const target = new EventTarget();
              target.addEventListener('scroll', function blockScroll() { r.blocked = true });
              target.addEventListener('scroll', () => { r.kept = true });
              target.dispatchEvent(new Event('scroll'));
              setTimeout(() => { r.modal = 'loginModal' }, 0);
              setTimeout(() => { r.timer = true; document.body.classList.add('no-scroll') }, 0);
            </script>
            </body>
            """
        }
        let controller = try await load(server.url("/page"), in: pool)
        let script = """
            JSON.stringify(Object.assign({}, window.results, {
              attribute: document.getElementById('menu').hasAttribute('oncontextmenu'),
              bodyClass: document.body.className }))
            """
        let expected = #"{"constant":false,"prototype":true,"aborted":true,"checked":"aborted","other":"tracked","#
            + ##""pruned":"{\"ads\":[{\"id\":1}]}","kept":true,"timer":true,"attribute":false,"bodyClass":""}"##
        let deadline = ContinuousClock.now + .seconds(5)
        var state = try await controller.webView.evaluateJavaScript(script) as? String
        while state != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            state = try await controller.webView.evaluateJavaScript(script) as? String
        }
        #expect(state == expected)
    }

    // A script the rule leaves alone that reads the trapped property in a loop runs the rule's pattern over its text
    // once. The page counts the pattern's runs on the running script's text by wrapping RegExp's test.
    @Test func abortCurrentInlineScriptMatchesEachScriptOnce() async throws {
        let calls = [["abort-current-inline-script", "sailHot", "adblock-check"]]
        let rules = String(decoding: try JSONEncoder().encode(["127.0.0.1": ["scriptlets": calls]]), as: UTF8.self)
        let pool = try await pool(Set(BlockingCategory.allCases), shield: [.ads: rules])
        let server = try await LocalPageServer { _ in
            """
            <body>
            <script>
              window.sailHot = 1;
              window.sailRuns = 0;
              const test = RegExp.prototype.test;
              RegExp.prototype.test = function (value) {
                if (value === document.currentScript?.textContent) window.sailRuns++;
                return test.call(this, value);
              };
            </script>
            <script>for (let i = 0; i < 100; i++) sailHot; document.title = String(window.sailRuns)</script>
            </body>
            """
        }
        let controller = try await load(server.url("/page"), in: pool)
        #expect(try await result(of: "document.title", in: controller.webView, becoming: "1") == "1")
    }

    private struct HeavyCase {
        let name: String
        let scripts: [WKUserScript]
        let url: URL
    }

    private struct Sample {
        let oneShot: Double
        let recheck: Double
        let work: (pass: Int, recheck: Int, check: Int)
        let checksBeforeRender: Int
        let elements: Int
        let bodyChildren: Int
    }

    // The typical and worst hosts' scripts on 1,500 stories under main, directly in body, or behind a hidden consent manager with the body locked. The pages are
    // cross-origin isolated, where WebKit's clock steps 20 µs instead of 1 ms, so a time is not rounded up a whole
    // millisecond per reading.
    // A typical host has no rules of its own; the worst carries LinkedIn's procedural rules with YouTube's scriptlets.
    // Both carry the YouTube embed hosts' scriptlets, as every page does for its player frames.
    private func shieldScripts() async throws -> (typical: [WKUserScript], worst: [WKUserScript]) {
        let bundled = try JSONDecoder().decode(
            [String: PageShield.Rules].self,
            from: Data(contentsOf: try #require(Bundle.main.url(forResource: "ads", withExtension: "json"))))
        var heaviest = try #require(bundled["linkedin.com"])
        heaviest.scriptlets = try #require(bundled["youtube.com"]?.scriptlets) + [["abort-on-property-read", "adblockDetector"]]
        var rules = bundled.filter { PageShield.embedHosts.contains($0.key) }
        rules["127.0.0.1"] = heaviest
        let shieldData = String(decoding: try JSONEncoder().encode(rules), as: UTF8.self)
        let shield = try await PageShield.bundled(in: try ruleBundle(lists: [.ads: adRuleJSON], shield: [.ads: shieldData]))
        let all = Set(BlockingCategory.allCases)
        return (shield.scripts(for: "news.test", categories: all), shield.scripts(for: "127.0.0.1", categories: all))
    }

    private func heavyCases() async throws -> (LocalPageServer, [HeavyCase]) {
        let (typical, worst) = try await shieldScripts()
        let stories = (0..<1_500).map { index in
            #"<article class="story"><h3>Headline \#(index)</h3><p class="dek">A long standfirst for story \#(index) "#
                + #"with enough words to look like a real one.</p><div class="meta"><span>Author</span>"#
                + ##"<a href="#s\##(index)">More</a></div></article>"##
        }.joined()
        let consent = #"<style>#onetrust-consent-sdk { display: none }</style><div id="onetrust-consent-sdk">Cookies</div>"#
        let server = try await LocalPageServer { _ in "" }
        let pages = [
            "/page": "<body><header><nav>Sections</nav></header><main>" + stories + "</main><footer>About</footer></body>",
            "/page-flat": "<body>" + stories + "</body>",
            "/page-consent": #"<body style="overflow: hidden">"# + consent + "<main>" + stories + "</main></body>",
        ]
        for (path, page) in pages {
            server.routes[path] = { _ in
                LocalPageServer.Reply(
                    headers: [
                        "Content-Type": "text/html", "Cross-Origin-Opener-Policy": "same-origin",
                        "Cross-Origin-Embedder-Policy": "require-corp",
                    ],
                    body: Data(page.utf8))
            }
        }
        return (server, [
            HeavyCase(name: "typical host", scripts: typical, url: server.url("/page")),
            HeavyCase(name: "typical host, stories directly in body", scripts: typical, url: server.url("/page-flat")),
            HeavyCase(name: "worst host", scripts: worst, url: server.url("/page")),
            HeavyCase(
                name: "typical host, hidden consent manager, body locked", scripts: typical,
                url: server.url("/page-consent")),
        ])
    }

    // One load of a heavy page, with fifty more stories added after it to set off a recheck. Document start and
    // DOMContentLoaded are timed between probes added before and after PageShield's scripts in both worlds; the
    // cookie check and the recheck time and count themselves in PageShield's world. It returns once the recheck, if the
    // host has a procedural pass, and a cookie check over the body as it now is have run.
    private func loaded(_ heavy: HeavyCase) async throws -> Sample {
        let worlds = [WKContentWorld.page, PageShield.world]
        let configuration = WKWebViewConfiguration()
        let content = configuration.userContentController
        for world in worlds {
            content.addUserScript(WKUserScript(
                source: """
                    window.sailProbe = [performance.now()];
                    document.addEventListener('DOMContentLoaded', () => { window.sailProbe[2] = performance.now(); });
                    """,
                injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        }
        heavy.scripts.forEach(content.addUserScript)
        for world in worlds {
            content.addUserScript(WKUserScript(
                source: """
                    window.sailProbe[1] = performance.now();
                    document.addEventListener('DOMContentLoaded', () => { window.sailProbe[3] = performance.now(); });
                    """,
                injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        Self.onScreen(webView)
        webView.load(URLRequest(url: heavy.url))
        try await waitUntil(timeout: .seconds(10)) { !webView.isLoading }
        #expect(try await webView.evaluateJavaScript("crossOriginIsolated") as? Bool == true)
        _ = try await webView.evaluateJavaScript("""
            (document.querySelector('main') ?? document.body).insertAdjacentHTML('beforeend',
              document.querySelector('article').outerHTML.repeat(50)); 0
            """)
        let state = """
            [window.sailShieldWork.pass, window.sailShieldWork.recheck, window.sailShieldWork.check,
             document.getElementsByTagName('*').length, document.body.children.length,
             window.sailShieldWork.checksBeforeRender]
            """
        // The recheck has run once it counted any work, unless the host has no procedural pass at all. A check has run
        // over the body as it now is once it counted every child of body and the consent manager ids.
        let deadline = ContinuousClock.now + .seconds(5)
        var counts: [Int] = []
        while true {
            let result = try await webView.evaluateJavaScript(state, in: nil, contentWorld: PageShield.world)
            counts = try #require(result as? [Int])
            if counts[0] == 0 || counts[1] > 0, counts[2] >= counts[4] + Self.consentIDs {
                break
            }
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
        var probes: [[Double]] = []
        for world in worlds {
            let result = try await webView.evaluateJavaScript("window.sailProbe", in: nil, contentWorld: world)
            probes.append(try #require(result as? [Double]))
        }
        let timings = try await webView.evaluateJavaScript(
            "[window.sailShieldTimings.check, window.sailShieldTimings.recheck]", in: nil, contentWorld: PageShield.world)
        let shield = try #require(timings as? [Double])
        let start = probes.map { $0[1] }.max()! - probes.map { $0[0] }.min()!
        let loaded = probes.map { $0[3] }.max()! - probes.map { $0[2] }.min()!
        return Sample(
            oneShot: start + loaded + shield[0], recheck: shield[1], work: (counts[0], counts[1], counts[2]),
            checksBeforeRender: counts[5], elements: counts[3], bodyChildren: counts[4])
    }

    // The cookie check looks up eight consent manager roots by id.
    private static let consentIDs = 8
    // The worst host's pass and recheck each make 11 DOM calls and matches on the 9,300 element page.
    private static let passWork = 64
    // Past body's children, the check counts the consent ids, the reject button, html and body, and the backdrops it
    // finds: 15 behind the hidden consent manager.
    private static let checkWork = 32

    // The shield's DOM work on a heavy page is the same on every load, so it is the suite's budget for the shield's
    // cost. The procedural pass and its recheck never walk the page element by element, and the cookie check reads each
    // child of body once and a fixed few elements more, never below them. One load's time is logged here;
    // pageShieldStaysWithinItsScriptTimeOnAHeavyPage asserts the time.
    @Test func pageShieldStaysWithinItsWorkBudgetOnAHeavyPage() async throws {
        let (server, cases) = try await heavyCases()
        for heavy in cases {
            let sample = try await loaded(heavy)
            print(
                "PageShield, \(heavy.name): work pass \(sample.work.pass), recheck \(sample.work.recheck), "
                    + "check \(sample.work.check) on \(sample.elements) elements, \(sample.bodyChildren) under body; "
                    + "one load: one-shot \(sample.oneShot) ms, recheck \(sample.recheck) ms")
            #expect(sample.work.pass <= Self.passWork, "\(heavy.name): pass \(sample.work.pass)")
            #expect(sample.work.recheck <= Self.passWork, "\(heavy.name): recheck \(sample.work.recheck)")
            #expect(
                sample.work.check <= sample.bodyChildren + Self.checkWork,
                "\(heavy.name): check \(sample.work.check) with \(sample.bodyChildren) under body")
            #expect(sample.checksBeforeRender == 0, "\(heavy.name): \(sample.checksBeforeRender) checks before a render")
        }
        withExtendedLifetime(server) {}
    }

    // Document-start parse is most of the worst host's one-shot time, and it grows with the scripts' source, which no
    // DOM count sees. Each host's scripts stay within their size plus a quarter: the typical host's 15,478 bytes on
    // 2026-10-25 with the YouTube embed script every page carries, and the worst host's 18,632 bytes before it.
    private static let typicalSource = 19_347
    private static let worstSource = 23_290

    @Test func pageShieldsScriptsStayWithinTheirSourceBudget() async throws {
        let (typical, worst) = try await shieldScripts()
        let bytes = { (scripts: [WKUserScript]) in scripts.map { $0.source.utf8.count }.reduce(0, +) }
        print("PageShield source: typical \(bytes(typical)) bytes, worst \(bytes(worst)) bytes")
        #expect(bytes(typical) <= Self.typicalSource)
        #expect(bytes(worst) <= Self.worstSource)
    }

    // Script time of PageShield on the heavy pages, as the median of thirty loads. One-shot work, document start plus
    // DOMContentLoaded plus the first cookie check, stays under 4 ms: it runs once per load in the web content process.
    // A recheck pass recurs while a page changes, so it stays under 2 ms, a quarter of a 120 Hz frame. Wall time in a
    // simulator shared with other runs moves with the host's load, so the suite leaves this out. Any change to
    // PageShield.swift or PageShieldScriptlets.swift runs it on the farm and quotes its figures:
    // TEST_RUNNER_SAIL_MEASURE=1 bash scripts/test.sh \
    //   'SailBrowserTests/PageShieldTests/pageShieldStaysWithinItsScriptTimeOnAHeavyPage()'
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SAIL_MEASURE"] != nil))
    func pageShieldStaysWithinItsScriptTimeOnAHeavyPage() async throws {
        let (server, cases) = try await heavyCases()
        let median = { (values: [Double]) in values.sorted()[values.count / 2] }
        for heavy in cases {
            var samples: [Sample] = []
            for _ in 0..<30 {
                samples.append(try await loaded(heavy))
            }
            let oneShot = median(samples.map(\.oneShot)), recheck = median(samples.map(\.recheck))
            print("PageShield timing, \(heavy.name): one-shot \(oneShot) ms, recheck \(recheck) ms")
            #expect(oneShot < 4, "\(heavy.name): one-shot \(oneShot) ms")
            #expect(recheck < 2, "\(heavy.name): recheck \(recheck) ms")
        }
        withExtendedLifetime(server) {}
    }
}

private final class PortNumber { var value = 0 }
