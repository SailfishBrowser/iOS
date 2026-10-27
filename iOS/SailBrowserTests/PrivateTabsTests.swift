import Foundation
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import SailBrowser

@MainActor
struct PrivateTabsTests {
    private func blankTab(isPrivate: Bool) -> SailBrowser.Tab {
        SailBrowser.Tab(
            id: UUID(), url: URL(string: "about:blank")!, title: "", isPinned: false, prefersDesktop: false,
            createdAt: .now, lastActiveAt: .now, tint: nil, isPrivate: isPrivate)
    }

    private func finish(_ controller: WebTabController, loading url: String) async {
        await withCheckedContinuation { continuation in
            controller.onFinish = { _, _ in
                controller.onFinish = nil
                continuation.resume()
            }
            controller.webView.loadSimulatedRequest(URLRequest(url: URL(string: url)!), responseHTML: "<p>\(url)</p>")
        }
    }

    private func pool(capacity: Int = 6, sessions: SessionStore = SessionStore(directories: .temporary())) -> WebViewPool {
        WebViewPool(
            capacity: capacity, blocker: ContentBlocker(categories: Set(BlockingCategory.allCases)), sessions: sessions,
            haptics: recordingHaptics())
    }

    @Test func aPrivateTabIsNeverWrittenToState() async throws {
        let directories = AppDirectories.temporary()
        let clock = TestClock()
        let store = BrowserStore(directories: directories, now: { [clock] in clock.now })
        let normal = store.openTab(url: URL(string: "https://a.com")!)
        clock.advance(1)
        let secret = store.openTab(url: URL(string: "https://b.com")!, isPrivate: true)
        #expect(store.activeTabID == secret.id)
        #expect(store.hasPrivateTabs)

        await store.flush()
        let saved = try String(contentsOf: directories.support.appending(path: "state.json"), encoding: .utf8)
        #expect(!saved.contains("isPrivate"))
        #expect(!saved.contains("b.com"))
        let reloaded = BrowserStore(directories: directories)
        #expect(reloaded.tabs.map(\.id) == [normal.id])
        #expect(reloaded.activeTabID == normal.id)
        #expect(!reloaded.hasPrivateTabs)
    }

    @Test func aStateSavedBeforePrivateTabsKeepsEveryTab() throws {
        let directories = AppDirectories.temporary()
        let fixture = try #require(Bundle(for: ReaderFixtures.self).url(forResource: "state-before-private-tabs", withExtension: "json"))
        try FileManager.default.createDirectory(at: directories.support, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: directories.support.appending(path: "state.json"))

        let store = BrowserStore(directories: directories)
        #expect(store.tabs.count == 3)
        #expect(store.tabs.allSatisfy { !$0.isPrivate })
        #expect(store.activeTab?.title == "Hacker News")
        #expect(store.archived.map(\.title) == ["Wikipedia"])
        #expect(store.archived.count == 1)
        #expect(store.settings.zoomByHost == ["github.com": 1.25])
    }

    @Test func privateTabsShareOneNonPersistentStoreAndTheLastCloseDropsIt() throws {
        let env = makeEnvironment()
        env.open(URL(string: "about:blank")!)
        let normal = try #require(env.activeController)
        env.open(URL(string: "about:blank")!, isPrivate: true)
        let first = try #require(env.activeController)
        env.open(URL(string: "about:blank")!, isPrivate: true)
        let second = try #require(env.activeController)

        let store = first.webView.configuration.websiteDataStore
        #expect(second.webView.configuration.websiteDataStore === store)
        #expect(!store.isPersistent)
        #expect(store !== env.pool.configuration.websiteDataStore)
        #expect(env.pool.privateStore === store)
        #expect(normal.webView.configuration.websiteDataStore === env.pool.configuration.websiteDataStore)
        #expect(env.pool.dataStore(for: first.tabID) === store)
        #expect(env.pool.dataStore(for: normal.tabID) === env.pool.configuration.websiteDataStore)

        env.archive(first.tabID)
        #expect(env.pool.privateStore === store)
        env.archive(second.tabID)
        #expect(env.pool.privateStore == nil)

        env.open(URL(string: "about:blank")!, isPrivate: true)
        let next = try #require(env.activeController).webView.configuration.websiteDataStore
        #expect(next !== store)
        #expect(!next.isPersistent)
    }

    @Test func aPrivateTabNeverTakesThePrewarmedWebView() throws {
        let pool = pool()
        pool.prewarm()
        let prewarmed = try #require(pool.prewarmed)

        let controller = pool.controller(for: blankTab(isPrivate: true))

        #expect(pool.prewarmed === prewarmed)
        #expect(controller.webView !== prewarmed)
        #expect(prewarmed.configuration.websiteDataStore === pool.configuration.websiteDataStore)
    }

    @Test func aPrivatePageLeavesNoHistoryFaviconSnapshotOrSession() async throws {
        let directories = AppDirectories.temporary()
        let env = makeEnvironment(directories)
        let server = try await LocalPageServer { _ in "<title>Secret</title><p>secret</p>" }
        defer { withExtendedLifetime(server) {} }
        env.open(server.url("/page-secret"), isPrivate: true)
        let controller = try #require(env.activeController)
        let id = controller.tabID
        let wired = controller.onFinish
        await withCheckedContinuation { continuation in
            controller.onFinish = { url, title in
                wired?(url, title)
                controller.onFinish = wired
                continuation.resume()
            }
        }
        #expect(env.browser.activeTab?.url == server.url("/page-secret"))

        #expect(env.history.entries.isEmpty)
        #expect(controller.onCommit == nil)
        #expect(controller.onFavicon == nil)
        // A normal page on another host, opened after, writes its favicon; by then the private page's would be there too.
        let favicons = directories.caches.appending(path: "favicons")
        env.open(URL(string: server.url("/page-normal").absoluteString.replacing("127.0.0.1", with: "localhost"))!)
        try await waitUntil(timeout: .seconds(10)) {
            FileManager.default.fileExists(atPath: favicons.appending(path: "localhost.png").path(percentEncoded: false))
        }
        #expect(!FileManager.default.fileExists(atPath: favicons.appending(path: "127.0.0.1.png").path(percentEncoded: false)))
        env.pageTo(id)
        env.sceneDidEnterBackground()
        #expect(env.sessions.load(id) == nil)
        await env.browser.flush()
        for folder in [directories.support.appending(path: "sessions"), directories.caches.appending(path: "snapshots")] {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
            #expect(!files.contains { $0.hasPrefix(id.uuidString) })
        }
    }

    @Test func anEvictedPrivateTabComesBackFromMemory() async throws {
        let sessions = SessionStore(directories: .temporary())
        let pool = pool(capacity: 1, sessions: sessions)
        let tab = blankTab(isPrivate: true)
        let controller = pool.controller(for: tab)
        try await waitUntil { controller.hasSettled }
        await finish(controller, loading: "https://example.test/one")
        await finish(controller, loading: "https://example.test/two")
        #expect(controller.webView.canGoBack)

        _ = pool.controller(for: blankTab(isPrivate: false))
        #expect(pool.liveController(for: tab.id) == nil)
        #expect(sessions.load(tab.id) == nil)

        let back = pool.controller(for: tab)
        #expect(back !== controller)
        #expect(back.webView.configuration.websiteDataStore === pool.privateStore)
        try await waitUntil { back.webView.canGoBack }
        #expect(sessions.load(tab.id) == nil)
    }

    @Test func aPopupFromAPrivatePageIsPrivate() async throws {
        let env = makeEnvironment()
        env.pool.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        env.open(server.url("/page-opener"), isPrivate: true)
        let opener = try #require(env.activeController)
        try await waitUntil(timeout: .seconds(10)) { opener.hasSettled }
        _ = try await opener.webView.evaluateJavaScript("document.cookie = 'secret=1; path=/'; 1")

        _ = try await opener.webView.evaluateJavaScript("window.open('/page-popup'); 1")
        try await waitUntil(timeout: .seconds(10)) {
            env.activeController !== opener && env.activeController?.url?.path() == "/page-popup"
        }
        let popup = try #require(env.activeController)
        #expect(env.browser.activeTab?.isPrivate == true)
        #expect(env.pool.isPrivate(popup.tabID))
        #expect(popup.webView.configuration.websiteDataStore === env.pool.privateStore)
        let shared = try await popup.webView.evaluateJavaScript("document.cookie") as? String
        #expect(shared == "secret=1")

        env.open(server.url("/page-normal"))
        let normal = try #require(env.activeController)
        try await waitUntil(timeout: .seconds(10)) { normal.hasSettled }
        let cookies = try #require(try await normal.webView.evaluateJavaScript("document.cookie") as? String)
        #expect(!cookies.contains("secret=1"))
    }

    @Test func aLinkMenuOpenFromAPrivatePageIsPrivate() throws {
        let env = makeEnvironment()
        env.open(URL(string: "about:blank")!, isPrivate: true)
        let controller = try #require(env.activeController)

        controller.onOpenLink?(URL(string: "https://example.test/back")!, true)
        controller.onOpenLink?(URL(string: "https://example.test/front")!, false)

        #expect(env.browser.tabs.count == 3)
        #expect(env.browser.tabs.allSatisfy { $0.isPrivate })
        #expect(env.browser.activeTab?.url.path() == "/front")
    }

    @Test func throwingAPrivateTabLeavesNoArchiveEntry() throws {
        let env = makeEnvironment()
        env.open(URL(string: "about:blank")!)
        env.open(URL(string: "about:blank")!, isPrivate: true)
        let id = try #require(env.browser.activeTabID)

        env.archive(id)

        #expect(env.browser.archived.isEmpty)
        #expect(!env.browser.tabs.contains { $0.id == id })
        #expect(env.pool.liveController(for: id) == nil)
    }

    @Test func throwingAPrivateTabLeavesNoArchiveEntryThroughTheSweep() {
        let clock = TestClock()
        let store = BrowserStore(directories: .temporary(), now: { [clock] in clock.now })
        let secret = store.openTab(url: URL(string: "https://b.com")!, isPrivate: true)
        let normal = store.openTab(url: URL(string: "https://a.com")!)
        var removed: [SailBrowser.Tab.ID] = []
        store.onTabsRemoved = { removed += $0 }
        clock.advance(store.settings.archiveInterval.duration + 1)

        #expect(Set(store.runArchiveSweep()) == [secret.id, normal.id])

        #expect(store.archived.map(\.id) == [normal.id])
        #expect(Set(removed) == [secret.id, normal.id])
    }

    @Test func theModeFollowsTheTabTheSheetOpensOver() throws {
        let env = makeEnvironment()
        env.open(URL(string: "about:blank")!)
        let normal = try #require(env.browser.activeTabID)
        env.open(URL(string: "about:blank")!, isPrivate: true)
        let secret = try #require(env.browser.activeTabID)

        #expect(env.ui.open(.search, animated: false))
        #expect(env.ui.isPrivateMode)
        #expect(env.activeIsPrivate)
        env.ui.close(animated: false)

        env.pageTo(normal)
        #expect(env.ui.open(.search, animated: false))
        #expect(!env.ui.isPrivateMode)
        env.togglePrivateMode()
        #expect(env.ui.isPrivateMode)
        env.ui.close(animated: false)

        env.archive(normal)
        env.archive(secret)
        #expect(env.browser.activeTab == nil)
        env.ui.setDeck(1, animated: false)
        #expect(env.ui.open(.search, animated: false))
        #expect(env.ui.isPrivateMode)
        env.togglePrivateMode()
        env.ui.close(animated: false)
        #expect(env.ui.open(.search, animated: false))
        #expect(!env.ui.isPrivateMode)
    }

    @Test func aSubmitInPrivateModeMakesAPrivateTab() async throws {
        let env = makeEnvironment()
        env.ui.open(.search, animated: false)
        env.togglePrivateMode()
        #expect(env.haptics.records.last?.interaction == .privateToggle)

        env.submit(URL(string: "about:blank")!, via: .searchSubmit)
        env.ui.submitHidden()

        #expect(env.browser.activeTab?.isPrivate == true)
        #expect(env.activeController?.webView.configuration.websiteDataStore === env.pool.privateStore)
    }

    @Test func aPrivateZoomIsNotSaved() async throws {
        let env = makeEnvironment()
        env.open(URL(string: "about:blank")!)
        let normal = try #require(env.activeController)
        try await waitUntil { normal.hasSettled }
        await finish(normal, loading: "https://example.test/a")
        env.open(URL(string: "about:blank")!, isPrivate: true)
        let secret = try #require(env.activeController)
        try await waitUntil { secret.hasSettled }
        await finish(secret, loading: "https://example.test/b")

        env.setZoom(1.25, forHost: "example.test")

        #expect(env.browser.settings.zoomByHost["example.test"] == nil)
        #expect(env.zoom(forHost: "example.test") == 1.25)
        #expect(secret.webView.pageZoom == 1.25)
        #expect(normal.webView.pageZoom == 1)

        env.archive(secret.tabID)
        env.open(URL(string: "about:blank")!, isPrivate: true)
        #expect(env.zoom(forHost: "example.test") == 1)
    }

    @Test func aPrivateSiteSettingDiesWithTheSession() async throws {
        let env = makeEnvironment()
        let host = "example.test"
        let saved = SiteSettings(blocksTrackers: false, allowsJavaScript: true)
        env.sites[host] = saved
        env.open(URL(string: "about:blank")!, isPrivate: true)
        let secret = try #require(env.activeController)
        #expect(env.siteSettings(forHost: host) == saved)

        let changed = SiteSettings(blocksTrackers: false, allowsJavaScript: false)
        env.setSiteSettings(changed, forHost: host)

        #expect(env.siteSettings(forHost: host) == changed)
        #expect(env.sites[host] == saved)
        #expect(env.sites.settings(forHost: host, isPrivate: true) == changed)
        #expect(env.sites.settings(forHost: host, isPrivate: false) == saved)

        env.archive(secret.tabID)
        #expect(env.sites.settings(forHost: host, isPrivate: true) == saved)
    }

    @Test func aPrivateDownloadKeepsNoSourceAndOffersNoRetry() async throws {
        let env = makeEnvironment()
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        let body = Data((0..<4096).map { UInt8($0 % 251) })
        server.routes["/a.zip"] = { _ in
            LocalPageServer.Reply(
                headers: [
                    "Content-Type": "application/zip", "Content-Disposition": "attachment; filename=a.zip",
                    "Content-Length": String(body.count),
                ],
                body: body[..<2048], holdsOpen: true)
        }
        defer { withExtendedLifetime(server) {} }
        env.open(server.url("/a.zip"), isPrivate: true)
        try await waitUntil(timeout: .seconds(10)) { env.downloads.records.first?.bytes == 2048 }
        let record = try #require(env.downloads.records.first)
        #expect(record.sourceURL == nil)

        env.downloads.cancel(record.id)
        try await waitUntil(timeout: .seconds(10)) { env.downloads.records.first?.state == .failed }

        #expect(!env.downloads.canRetry(record.id))
    }

    // The fill, sheet and label run linearly over about 11 frames each way; a second tap mid-motion turns every part
    // back from where it is drawn, over the share of the fade it has covered.
    // A private page's picture lives in memory only, with its band drawn in, so a swipe on the bar can show it. It goes with
    // a memory warning and with the tab, and never reaches the snapshots folder.
    @Test func aPrivateSnapshotStaysInMemoryWithItsBand() async throws {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        window.makeKeyAndVisible()
        let directories = AppDirectories.temporary()
        let env = makeEnvironment(directories)
        env.pool.page = PageGeometry(bounds: window.bounds, safeTop: 62)
        let server = try await LocalPageServer { _ in "<body style='margin:0;background:#ffffff'>page</body>" }
        defer { withExtendedLifetime(server) {} }
        env.open(server.url("/page-normal"))
        let normal = try #require(env.activeController)
        env.open(server.url("/page-secret"), isPrivate: true)
        let secret = try #require(env.activeController)
        for controller in [normal, secret] {
            controller.webView.frame = window.bounds
            window.addSubview(controller.webView)
        }
        try await waitUntil(timeout: .seconds(10)) { normal.hasSettled && secret.hasSettled }

        env.captureSnapshot(of: secret.tabID)
        try await waitUntil(timeout: .seconds(10)) { env.snapshots.thumbnail(for: secret.tabID).image != nil }
        let picture = try #require(env.snapshots.thumbnail(for: secret.tabID).image)
        #expect(pixel(picture, at: CGPoint(x: 0.1, y: 0.02)) == [0, 0, 0])
        env.captureSnapshot(of: normal.tabID)
        let folder = directories.caches.appending(path: "snapshots")
        try await waitUntil(timeout: .seconds(10)) {
            FileManager.default.fileExists(atPath: folder.appending(path: "\(normal.tabID.uuidString).jpg").path(percentEncoded: false))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        #expect(!files.contains { $0.hasPrefix(secret.tabID.uuidString) })

        env.memoryWarning()
        #expect(env.snapshots.thumbnail(for: secret.tabID).image == nil)
    }

    // The stack draws a private tab flat grey, its fixed cards and the flick's rising copy alike; only a swipe's copy
    // carries the page, as the swiping card does.
    @Test func theStackDrawsAPrivateTabFlatGrey() {
        let snapshots = SnapshotStore(directories: .temporary())
        let secret = blankTab(isPrivate: true)
        let normal = blankTab(isPrivate: false)
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        snapshots.hold(picture, for: secret.id)
        snapshots.hold(picture, for: normal.id)

        let grey = StackThumbnail.content(of: secret, snapshots: snapshots, inSwipe: false)
        #expect(grey.thumbnail == nil)
        #expect(grey.fill == Theme.Palette.privateCard)
        #expect(StackThumbnail.content(of: secret, snapshots: snapshots, inSwipe: true).thumbnail?.image === picture)
        #expect(StackThumbnail.content(of: normal, snapshots: snapshots, inSwipe: false).thumbnail?.image === picture)
    }

    // A private download's file lands where the user asked, but its record is never written to downloads.json.
    @Test func aPrivateDownloadLeavesNoRecordOnDisk() async throws {
        let directories = AppDirectories.temporary()
        let env = makeEnvironment(directories)
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        defer { withExtendedLifetime(server) {} }
        server.routes["/a.zip"] = { _ in
            LocalPageServer.Reply(
                headers: ["Content-Type": "application/zip", "Content-Disposition": "attachment; filename=a.zip"],
                body: Data("zip".utf8))
        }
        env.open(server.url("/a.zip"), isPrivate: true)
        try await waitUntil(timeout: .seconds(10)) { env.downloads.records.first?.state == .finished }
        let record = try #require(env.downloads.records.first)
        #expect(FileManager.default.fileExists(atPath: env.downloads.fileURL(of: record).path(percentEncoded: false)))

        await env.downloads.flush()
        let file = directories.support.appending(path: "downloads.json")
        let saved = FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
            ? try JSONDecoder().decode([DownloadRecord].self, from: Data(contentsOf: file)) : []
        #expect(!saved.contains { $0.id == record.id })
    }

    // With Auto-Open Keyboard off the sheet opens unfocused; the eyes flip the mode and leave the field where it is.
    @Test func theEyesFlipTheModeWithoutFocusingOrLiftingTheField() async throws {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let env = makeEnvironment()
        env.browser.settings.autoOpenKeyboard = false
        let controller = SearchSheetController(
            model: SearchModel(history: env.history, service: SuggestionService(), engine: { .google }), env: env)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        env.ui.open(.search, animated: false)
        controller.setActive(true, submitting: false)
        try await waitUntil { !controller.container.isHidden && HeldClock.hasEnded(controller.container.layer) }
        let top = controller.container.layer.presentation()!.frame.minY
        #expect(!controller.field.isFirstResponder)

        controller.field.privateToggle.sendActions(for: .touchDown)
        controller.field.privateToggle.sendActions(for: .primaryActionTriggered)
        CATransaction.flush()

        #expect(env.ui.isPrivateMode)
        #expect(!controller.field.isFirstResponder)
        #expect(controller.container.layer.animationKeys() == nil)
        // A lift would move the sheet by the keyboard's height; a relayout may round it by a fraction of a point.
        #expect(abs(controller.container.layer.presentation()!.frame.minY - top) < 0.5)
    }

    @Test func theToggleRetargetsMidMotion() async throws {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let sink = RecordingHapticSink(start: .now)
        let env = makeEnvironment(hapticSink: sink)
        env.browser.settings.autoOpenKeyboard = false
        let controller = SearchSheetController(
            model: SearchModel(history: env.history, service: SuggestionService(), engine: { .google }), env: env)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        env.ui.open(.search, animated: false)
        controller.setActive(true, submitting: false)
        try await waitUntil { !controller.container.isHidden && HeldClock.hasEnded(controller.capsule.layer) }
        // Our own button: its tap is prepared on touch-down and plays on the tap.
        #expect(!sink.calls.contains(.prepare(Theme.Haptic.medium)))
        controller.field.privateToggle.sendActions(for: .touchDown)
        #expect(sink.calls.last == .prepare(Theme.Haptic.medium))
        let normal = rgba(SearchFieldCapsule.fieldFill.cgColor)
        let dark = rgba(Theme.Palette.privateFieldFill.cgColor)
        let shade = Float(Theme.Opacity.privateSheetShade)
        #expect(close(drawnFill(controller), normal))
        #expect(controller.privateShade.alpha == 0)
        let clock = HeldClock(window.layer)
        guard case .curve(let duration, _) = Theme.Motion.privateToggle else { preconditionFailure() }

        controller.field.privateToggle.sendActions(for: .primaryActionTriggered)
        CATransaction.flush()
        #expect(env.ui.isPrivateMode)
        #expect(controller.privacy.isOn)
        #expect(controller.field.privateToggle.accessibilityLabel == "Turn Off Incognito")
        clock.step(by: duration / 2)
        let mid = drawnFill(controller)
        #expect(abs(mid[3] - (normal[3] + dark[3]) / 2) < 0.02)
        let midShade = controller.privateShade.layer.presentation()!.opacity
        #expect(abs(midShade - shade / 2) < 0.02)
        let wipe = controller.field.privateLabel.layer.mask!
        let fullWidth = controller.field.privateLabel.bounds.width
        let midWipe = wipe.presentation()!.bounds.width
        #expect(abs(midWipe - fullWidth / 2) < 2)

        controller.field.privateToggle.sendActions(for: .primaryActionTriggered)
        CATransaction.flush()
        #expect(!env.ui.isPrivateMode)
        #expect(!controller.privacy.isOn)
        #expect(close(drawnFill(controller), mid))
        #expect(abs(controller.privateShade.layer.presentation()!.opacity - midShade) < 0.005)
        #expect(abs(wipe.presentation()!.bounds.width - midWipe) < 0.5)
        #expect(close(rgba(controller.capsule.backgroundColor!.cgColor), normal))
        clock.step(by: duration / 2)
        #expect(close(drawnFill(controller), normal))
        #expect(controller.privateShade.layer.presentation()!.opacity < 0.005)
        #expect(wipe.presentation()!.bounds.width < 0.5)
        #expect(env.haptics.records.filter { $0.interaction == .privateToggle }.count == 2)
        #expect(sink.played.first == Theme.Haptic.medium)
    }

    @Test func thePrivateCardCoverFollowsDeckProgress() {
        let layout = CardLayout(screen: CGSize(width: 440, height: 956))
        func cover(index: Int, progress: CGFloat) -> CGFloat {
            CardPlacement(
                progress: progress, olderProgress: progress, pair: nil, flick: nil, position: 1, lift: 0,
                slot: CGFloat(index), index: index, activeIndex: 1, layout: layout, header: EmptyView(), coverImage: nil,
                coverFill: .black, isUnrevealed: false, cover: CardCover(), tabID: UUID(), isPrivate: true
            ).privateCoverOpacity
        }
        #expect(cover(index: 1, progress: 0) == 0)
        #expect(cover(index: 1, progress: 0.5) == 0.5)
        #expect(cover(index: 1, progress: 1) == 1)
        #expect(cover(index: 2, progress: 0) == 1)
        #expect(cover(index: 2, progress: 0.5) == 1)
        // A swipe on the bar shows the private neighbour's page.
        let paired = CardPlacement(
            progress: 0, olderProgress: 0,
            pair: DeckDriver.PagePair(origin: 1, originID: UUID(), older: UUID(), newer: UUID(), safeTop: 62), flick: nil,
            position: 1, lift: 0, slot: 2, index: 2, activeIndex: 1, layout: layout, header: EmptyView(), coverImage: nil,
            coverFill: .black, isUnrevealed: false, cover: CardCover(), tabID: UUID(), isPrivate: true)
        #expect(paired.privateCoverOpacity == 0)
    }

    // The bar on a private tab is a dark neutral over any page, its controls a lighter grey with white glyphs.
    @Test func aPrivateBarGoesDarkOverAnyPage() {
        let light = BarStyle.browsing(on: .white, in: .light, isPrivate: true)
        #expect(light.controlFill == Theme.Palette.privateBarControlFill)
        #expect(light.glyph == .white)
        #expect(light.isPrivate)
        #expect(BarStyle.browsing(on: .white, in: .light, isPrivate: false).controlFill != Theme.Palette.privateBarControlFill)
    }

    @Test func theIncognitoNoticeShowsOnlyOnAnEmptyPrivateField() {
        #expect(SearchSheet.showsNotice(isPrivate: true, text: ""))
        #expect(!SearchSheet.showsNotice(isPrivate: true, text: "h"))
        #expect(!SearchSheet.showsNotice(isPrivate: false, text: ""))
    }

    // A private page starts below a black band a little taller than the safe top.
    @Test func aPrivatePageSitsBelowTheTallerBand() {
        let pool = pool()
        pool.page = PageGeometry(bounds: CGRect(x: 0, y: 0, width: 440, height: 956), safeTop: 62)
        let secret = pool.controller(for: blankTab(isPrivate: true))
        let normal = pool.controller(for: blankTab(isPrivate: false))
        #expect(secret.webView.obscuredContentInsets.top == 62 + Theme.Metrics.privateBandExtra)
        #expect(normal.webView.obscuredContentInsets.top == 62)
    }

    // The band rides inside the page's card, over the page, which starts below it.
    @Test func aPrivatePageDrawsItsBandInsideTheCard() throws {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let controller = WebTabController(
            tabID: UUID(), webView: PageWebView(frame: .zero, configuration: WKWebViewConfiguration()),
            haptics: recordingHaptics())
        let host = UIHostingController(
            rootView: WebPageView(
                controller: controller, geometry: .identity(height: window.bounds.height), isInteractive: true,
                isPrivate: true
            ).environment(\.screenInsets, EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        let container = try #require(pageContainer(in: host.view))
        container.layoutIfNeeded()

        #expect(!container.privateBand.isHidden)
        #expect(container.privateBand.frame == CGRect(x: 0, y: 0, width: window.bounds.width, height: 62 + Theme.Metrics.privateBandExtra))
        #expect(container.privateBand.superview === container.band)
        #expect(controller.webView.obscuredContentInsets.top == 62 + Theme.Metrics.privateBandExtra)
    }

    private func pageContainer(in view: UIView) -> WebPageView.Container? {
        view as? WebPageView.Container ?? view.subviews.lazy.compactMap(pageContainer(in:)).first
    }

    // The label sits just under the island, and the ring outlines the island only on a phone that has one.
    @Test func theBandCarriesItsLabelAndTheIslandRing() {
        let band = PrivateBandView()
        band.frame = CGRect(x: 0, y: 0, width: 440, height: 62 + Theme.Metrics.privateBandExtra)
        band.layout(safeTop: 62)
        #expect(band.backgroundColor == Theme.Palette.privateBand)
        #expect(band.label.text == "Incognito")
        #expect(abs(band.label.center.y - (band.bounds.height - Theme.Metrics.privateBandLabelCenterFromBottom)) < 0.001)
        #expect(band.label.center.x == 220)
        #expect(!band.ring.isHidden)
        let island = band.ring.path!.boundingBox
        #expect(abs(island.midX - 220) < 0.001)
        #expect(island.minY < Theme.Metrics.islandTop)
        band.layout(safeTop: 47)
        #expect(band.ring.isHidden)
    }

    private func drawnFill(_ controller: SearchSheetController) -> [CGFloat] {
        rgba(controller.capsule.layer.presentation()!.backgroundColor!)
    }

    private func rgba(_ color: CGColor) -> [CGFloat] {
        color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)!.components!
    }

    private func close(_ a: [CGFloat], _ b: [CGFloat]) -> Bool {
        zip(a, b).allSatisfy { abs($0 - $1) < 0.01 }
    }
}
