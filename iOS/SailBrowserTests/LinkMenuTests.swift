import Foundation
import Testing
import UIKit
import WebKit
@testable import SailBrowser

struct LinkMenuTests {
    @Test func aLinkGetsTheFourActionsInOrder() {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        let url = URL(string: "https://example.com/a")!

        #expect(controller.linkMenuConfiguration(for: url) != nil)
        #expect(
            controller.linkMenu(for: url).children.map(\.title)
                == ["Open in New Tab", "Open in Background", "Copy Link", "Share Link"])
    }

    @Test func aNonLinkKeepsWebKitsMenu() {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())

        #expect(controller.linkMenuConfiguration(for: nil) == nil)
    }

    @Test func openInNewTabSwitchesThroughThePopupPath() {
        let env = makeEnvironment()
        env.open(page("a"))
        let opener = env.activeController!
        let url = URL(string: "https://example.com/new")!

        opener.onOpenLink!(url, false)

        #expect(env.browser.activeTab?.url == url)
        #expect(env.activeController?.tabID == env.browser.activeTabID)
        #expect(env.browser.tabs.count == 2)
    }

    @Test func openInBackgroundJoinsNextWithoutAWebView() {
        let env = makeEnvironment()
        env.open(page("a"))
        env.open(page("b"))
        env.open(page("c"))
        let b = env.browser.tabs[1].id
        env.showTab(b, via: .deckCardTap)
        let opener = env.activeController!
        let url = URL(string: "https://example.com/background")!

        opener.onOpenLink!(url, true)

        let added = env.browser.tabs[2]
        #expect(added.url == url)
        #expect(env.browser.tabs.count == 4)
        #expect(env.browser.activeTabID == b)
        #expect(env.activeController === opener)
        #expect(env.pool.liveController(for: added.id) == nil)
        #expect(env.browser.previousTabID != added.id)
    }
}

struct ShareItemsTests {
    @Test func aLivePageSharesItsCleanURLTitleAndPrintFormatter() async throws {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        controller.load(URL(string: "data:text/html,<title>Hello</title><p>x</p>")!)
        try await waitUntil { controller.title == "Hello" }

        let items = SharePresenter.activityItems(for: controller)

        #expect(items.contains { $0 is UIPrintFormatter })
        let page = try #require(items.first as? SharedPage)
        #expect(page.url == controller.url)
        #expect(page.subject == "Hello")
    }

    @Test func aLivePageSharesTheStrippedURL() {
        let page = SharedPage(url: URL(string: "https://example.com/?utm_source=x&id=1")!, subject: "T")

        #expect(page.url == URL(string: "https://example.com/?id=1")!)
    }

    @Test func anArchivedEntrySharesItsURLOnly() {
        let entry = ArchivedTab(
            id: UUID(), url: URL(string: "https://example.com/?utm_source=x&id=1")!, title: "Old", archivedAt: .now)

        let items = SharePresenter.activityItems(for: entry.url)

        #expect(!items.contains { $0 is UIPrintFormatter })
        #expect(items.count == 1)
        #expect(items.first as? URL == URL(string: "https://example.com/?id=1")!)
    }
}
