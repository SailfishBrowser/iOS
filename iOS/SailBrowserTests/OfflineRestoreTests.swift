import Foundation
import Testing
import WebKit
@testable import SailBrowser

// A tab whose only load failed has no page: its eviction saves no session, and a restore from a session with no page
// (one saved before the guard, or a file that does not decode) loads the tab URL, so the tab comes back live instead
// of blank under its error picture.
struct OfflineRestoreTests {
    private let blocker = ContentBlocker(categories: Set(BlockingCategory.allCases))
    private let a = URL(string: "fail://page/a")!

    private func makeTab(_ url: URL, isPrivate: Bool = false) -> Tab {
        Tab(
            id: UUID(), url: url, title: "", isPinned: false, prefersDesktop: false, createdAt: .now, lastActiveAt: .now,
            tint: nil, isPrivate: isPrivate)
    }

    private func otherTab(isPrivate: Bool = false) -> Tab {
        makeTab(URL(string: "fail://page/\(UUID().uuidString)")!, isPrivate: isPrivate)
    }

    private func makePool(capacity: Int = 1, sessions: SessionStore) -> (WebViewPool, FailingSchemeHandler) {
        let pool = WebViewPool(capacity: capacity, blocker: blocker, sessions: sessions, haptics: recordingHaptics())
        let handler = FailingSchemeHandler()
        pool.configuration.setURLSchemeHandler(handler, forURLScheme: "fail")
        return (pool, handler)
    }

    // The tab's first load fails offline: the error page shows over nothing committed.
    private func failedController(
        _ pool: WebViewPool, _ handler: FailingSchemeHandler, _ tab: Tab
    ) async throws -> WebTabController {
        handler.failures[tab.url] = .notConnectedToInternet
        let controller = pool.controller(for: tab)
        try await waitUntil { controller.loadError != nil && controller.hasSettled }
        #expect(controller.webView.backForwardList.currentItem == nil)
        return controller
    }

    private func settled(_ pool: WebViewPool, _ tab: Tab) async throws -> WebTabController {
        let controller = pool.controller(for: tab)
        try await waitUntil { controller.hasSettled }
        return controller
    }

    @Test func anEvictedTabThatOnlyFailedComesBackByLoadingItsURL() async throws {
        let sessions = SessionStore(directories: .temporary())
        let (pool, handler) = makePool(sessions: sessions)
        let tab = makeTab(a)
        _ = try await failedController(pool, handler, tab)
        _ = try await settled(pool, otherTab())
        #expect(pool.liveController(for: tab.id) == nil)
        #expect(sessions.load(tab.id) == nil)

        let offline = pool.controller(for: tab)
        try await waitUntil { offline.hasSettled }
        #expect(handler.startedURLs.filter { $0 == a }.count == 2)
        #expect(offline.loadError?.url == a)
        #expect(offline.webView.backForwardList.currentItem == nil)

        _ = try await settled(pool, otherTab())
        #expect(sessions.load(tab.id) == nil)
        handler.failures[a] = nil
        let online = pool.controller(for: tab)
        try await waitUntil { online.hasSettled }
        #expect(online.loadError == nil)
        #expect(online.webView.backForwardList.currentItem?.url == a)
    }

    // A session file written by the code before the guard, with WebKit's state for an empty list, restores no page.
    @Test func aStaleSessionWithNoPageRestoresByLoadingTheTabURL() async throws {
        let directories = AppDirectories.temporary()
        let tab = makeTab(a)
        let empty = try #require(WKWebView().interactionState as? Data)
        let writer = SessionStore(directories: directories)
        writer.save(empty, for: tab.id)
        await writer.flush()

        let (pool, handler) = makePool(sessions: SessionStore(directories: directories))
        let restored = pool.controller(for: tab)
        #expect(restored.revealsAtFinish)
        try await waitUntil { restored.hasSettled }
        #expect(handler.startedURLs == [a])
        #expect(restored.webView.backForwardList.currentItem?.url == a)
    }

    @Test func aSessionFileOfJunkRestoresByLoadingTheTabURL() async throws {
        let directories = AppDirectories.temporary()
        let tab = makeTab(a)
        let writer = SessionStore(directories: directories)
        writer.save(Data("not a session".utf8), for: tab.id)
        await writer.flush()

        let (pool, handler) = makePool(sessions: SessionStore(directories: directories))
        let restored = pool.controller(for: tab)
        #expect(restored.revealsAtFinish)
        try await waitUntil { restored.hasSettled }
        #expect(handler.startedURLs == [a])
        #expect(restored.webView.backForwardList.currentItem?.url == a)
    }

    // The guard is on the current item, not on the error: an error over a committed page keeps that page's session,
    // and the restore shows the page.
    @Test func aFailedReloadOverAPageKeepsThePageAcrossEviction() async throws {
        let sessions = SessionStore(directories: .temporary())
        let (pool, handler) = makePool(sessions: sessions)
        let tab = makeTab(a)
        let controller = try await settled(pool, tab)
        #expect(controller.webView.backForwardList.currentItem?.url == a)
        handler.failures[a] = .notConnectedToInternet
        controller.reload()
        try await waitUntil { controller.loadError != nil && controller.hasSettled }
        #expect(controller.webView.backForwardList.currentItem?.url == a)

        _ = try await settled(pool, otherTab())
        #expect(sessions.load(tab.id) != nil)
        handler.failures[a] = nil
        let restored = pool.controller(for: tab)
        try await waitUntil { restored.hasSettled }
        #expect(restored.loadError == nil)
        #expect(restored.webView.backForwardList.currentItem?.url == a)
        #expect(handler.startedURLs.filter { $0 == a }.count == 3)
    }

    @Test func anEvictedPrivateTabThatOnlyFailedReloadsOnThePrivateStore() async throws {
        let (pool, handler) = makePool(sessions: SessionStore(directories: .temporary()))
        let tab = makeTab(a, isPrivate: true)
        let failed = try await failedController(pool, handler, tab)
        let store = try #require(pool.privateStore)
        #expect(failed.webView.configuration.websiteDataStore === store)
        _ = try await settled(pool, otherTab(isPrivate: true))
        #expect(pool.liveController(for: tab.id) == nil)

        handler.failures[a] = nil
        let back = pool.controller(for: tab)
        try await waitUntil { back.hasSettled }
        #expect(back.webView.configuration.websiteDataStore === store)
        #expect(back.loadError == nil)
        #expect(back.webView.backForwardList.currentItem?.url == a)
    }

    @Test func aMemoryWarningEvictingAFailedTabSavesNoSession() async throws {
        let sessions = SessionStore(directories: .temporary())
        let (pool, handler) = makePool(capacity: Theme.Pool.capacity, sessions: sessions)
        let tab = makeTab(a)
        _ = try await failedController(pool, handler, tab)
        let kept = otherTab()
        _ = try await settled(pool, kept)
        _ = try await settled(pool, otherTab())

        pool.handleMemoryWarning(keeping: kept.id)
        #expect(pool.liveController(for: tab.id) == nil)
        #expect(pool.liveController(for: kept.id) != nil)
        #expect(sessions.load(tab.id) == nil)
        #expect(sessions.load(kept.id) != nil)

        handler.failures[a] = nil
        let back = pool.controller(for: tab)
        try await waitUntil { back.hasSettled }
        #expect(back.loadError == nil)
        #expect(back.webView.backForwardList.currentItem?.url == a)
    }
}
