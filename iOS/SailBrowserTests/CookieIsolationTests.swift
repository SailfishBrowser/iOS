import Foundation
import Testing
import WebKit
@testable import SailBrowser

// Private and normal tabs on one host never share a cookie, proved on the wire: the server sets one cookie per kind
// of tab and echoes back whatever the next request carries.
struct CookieIsolationTests {
    private let host = "127.0.0.1"

    private func makeTab(_ url: URL, isPrivate: Bool = false) -> Tab {
        Tab(
            id: UUID(), url: url, title: "", isPinned: false, prefersDesktop: false, createdAt: .now, lastActiveAt: .now,
            tint: nil, isPrivate: isPrivate)
    }

    private func makePool() -> WebViewPool {
        WebViewPool(
            blocker: ContentBlocker(categories: Set(BlockingCategory.allCases)),
            sessions: SessionStore(directories: .temporary()), haptics: recordingHaptics())
    }

    // "/page-set-<kind>" sets the cookie "<kind>=1"; "/page-echo" shows the request's Cookie header, or "none".
    private func makeServer() async throws -> LocalPageServer {
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        for kind in ["normal", "private"] {
            server.routes["/page-set-\(kind)"] = { _ in
                LocalPageServer.Reply(
                    headers: ["Content-Type": "text/html", "Set-Cookie": "\(kind)=1; Path=/"], body: Data("<p>set</p>".utf8))
            }
        }
        server.routes["/page-echo"] = { request in
            let cookie = request.split(separator: "\r\n").first { $0.lowercased().hasPrefix("cookie:") }
                .map { $0.dropFirst("cookie:".count).trimmingCharacters(in: .whitespaces) } ?? "none"
            return LocalPageServer.Reply(
                headers: ["Content-Type": "text/html"], body: Data("<p id='c'>\(cookie)</p>".utf8))
        }
        return server
    }

    private func finish(_ controller: WebTabController, loading url: URL) async {
        let wired = controller.onFinish
        await withCheckedContinuation { continuation in
            controller.onFinish = { url, title in
                wired?(url, title)
                controller.onFinish = wired
                continuation.resume()
            }
            controller.load(url)
        }
    }

    private func echoedCookie(_ controller: WebTabController, _ server: LocalPageServer) async throws -> String {
        await finish(controller, loading: server.url("/page-echo"))
        return try #require(
            try await controller.webView.evaluateJavaScript("document.getElementById('c').textContent") as? String)
    }

    private func settled(_ controller: WebTabController) async throws {
        try await waitUntil(timeout: .seconds(10)) { controller.hasSettled }
    }

    @Test func aCookieSetInOneKindOfTabNeverReachesTheOther() async throws {
        let server = try await makeServer()
        let pool = makePool()
        let normal = pool.controller(for: makeTab(server.url("/page-set-normal")))
        let secret = pool.controller(for: makeTab(server.url("/page-set-private"), isPrivate: true))
        try await settled(normal)
        try await settled(secret)

        let normalCookie = try await echoedCookie(normal, server)
        let privateCookie = try await echoedCookie(secret, server)
        #expect(normalCookie == "normal=1")
        #expect(privateCookie == "private=1")
    }

    // The last private tab's close ends the session: the next private tab on the host starts with no cookie.
    @Test func endingThePrivateSessionDropsItsCookies() async throws {
        let server = try await makeServer()
        let pool = makePool()
        let secret = pool.controller(for: makeTab(server.url("/page-set-private"), isPrivate: true))
        try await settled(secret)
        let before = try await echoedCookie(secret, server)
        #expect(before == "private=1")

        pool.discard(secret.tabID)
        pool.endPrivateSession()
        let next = pool.controller(for: makeTab(server.url("/page-echo"), isPrivate: true))
        try await settled(next)
        #expect(next.webView.configuration.websiteDataStore !== secret.webView.configuration.websiteDataStore)
        let after = try await echoedCookie(next, server)
        #expect(after == "none")
    }

    @Test func aPopupFromAPrivatePageSendsThePrivateCookie() async throws {
        let server = try await makeServer()
        let env = makeEnvironment()
        env.pool.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        env.open(server.url("/page-set-private"), isPrivate: true)
        let opener = try #require(env.activeController)
        try await settled(opener)

        _ = try await opener.webView.evaluateJavaScript("window.open('/page-echo'); 1")
        try await waitUntil(timeout: .seconds(10)) {
            env.activeController !== opener && env.activeController?.url?.path() == "/page-echo"
        }
        let popup = try #require(env.activeController)
        try await settled(popup)
        #expect(env.pool.isPrivate(popup.tabID))
        let echoed = try await popup.webView.evaluateJavaScript("document.getElementById('c').textContent") as? String
        #expect(echoed == "private=1")
    }

    // Clearing a site's data from a private tab empties the private store only.
    @Test func clearingSiteDataFromAPrivateTabLeavesTheNormalCookie() async throws {
        let server = try await makeServer()
        let env = makeEnvironment()
        env.open(server.url("/page-set-normal"))
        let normal = try #require(env.activeController)
        env.open(server.url("/page-set-private"), isPrivate: true)
        let secret = try #require(env.activeController)
        try await settled(normal)
        try await settled(secret)
        let before = try await echoedCookie(secret, server)
        #expect(before == "private=1")

        await env.clearSiteData(forHost: host)

        let normalCookie = try await echoedCookie(normal, server)
        let privateCookie = try await echoedCookie(secret, server)
        #expect(normalCookie == "normal=1")
        #expect(privateCookie == "none")
    }

    // A submit in progress is a private tab the browser does not list yet; closing the last listed private tab must not
    // end the session under it.
    @Test func aPendingPrivateSubmitKeepsThePrivateSessionAlive() throws {
        let env = makeEnvironment()
        env.open(URL(string: "about:blank")!, isPrivate: true)
        let secret = try #require(env.activeController)
        let store = try #require(env.pool.privateStore)
        env.ui.open(.search, animated: false)
        #expect(env.ui.isPrivateMode)
        env.submit(URL(string: "about:blank")!, via: .searchSubmit)

        env.archive(secret.tabID)
        #expect(!env.browser.hasPrivateTabs)
        #expect(env.pool.privateStore === store)

        env.ui.submitHidden()
        #expect(env.browser.activeTab?.isPrivate == true)
        #expect(env.activeController?.webView.configuration.websiteDataStore === store)
    }
}
