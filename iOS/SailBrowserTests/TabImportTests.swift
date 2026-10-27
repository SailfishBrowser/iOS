import Foundation
import Testing
@testable import SailBrowser

struct TabImportTests {
    private static let imported = [
        ImportedTab(url: URL(string: "https://i1.test/")!, title: "One"),
        ImportedTab(url: URL(string: "https://i2.test/")!, title: ""),
        ImportedTab(url: URL(string: "https://i3.test/")!, title: "Three"),
    ]

    @Test func importedTabsJoinTheEndOfTheDeckUnshown() {
        let env = makeEnvironment()
        env.open(URL(string: "https://a.test/")!)
        env.open(URL(string: "https://b.test/")!)
        let first = env.browser.tabs[0].id
        let active = env.browser.activeTabID
        let controller = env.activeController
        env.importTabs(Self.imported)

        #expect(env.browser.activeTabID == active)
        #expect(env.activeController === controller)
        #expect(env.browser.previousTabID == first)
        let added = env.browser.tabs.dropFirst(2)
        #expect(added.map(\.url) == Self.imported.map(\.url))
        #expect(added.map(\.title) == Self.imported.map(\.title))
        #expect(added.allSatisfy { $0.lastActiveAt == .distantPast && !$0.isPrivate })
        #expect(added.allSatisfy { env.pool.liveController(for: $0.id) == nil })
        #expect(env.browser.runArchiveSweep().isEmpty)
    }

    @Test func anEmptyDeckShowsTheFirstImportedTab() {
        let env = makeEnvironment()
        env.importTabs(Array(Self.imported.prefix(2)))
        let tabs = env.browser.tabs
        #expect(tabs.map(\.url) == Self.imported.prefix(2).map(\.url))
        #expect(tabs.map(\.title) == ["One", ""])
        #expect(env.browser.activeTabID == tabs[0].id)
        #expect(env.activeController?.tabID == tabs[0].id)
        #expect(env.pool.liveController(for: tabs[1].id) == nil)
    }

    @Test func importedTitlesAreCappedLikeAnyOther() {
        let env = makeEnvironment()
        let huge = String(repeating: "x", count: 200_000)
        env.importTabs([
            ImportedTab(url: URL(string: "https://i1.test/")!, title: huge),
            ImportedTab(url: URL(string: "https://i2.test/")!, title: huge),
        ])
        #expect(env.browser.tabs.map(\.title.count) == [Theme.Text.titleLimit, Theme.Text.titleLimit])
    }

    @Test func importedTabsAreNeverPrivate() {
        let env = makeEnvironment()
        env.ui.setPrivateMode(true)
        env.importTabs(Self.imported)
        #expect(!env.browser.hasPrivateTabs)
        #expect(env.browser.tabs.count == 3)
    }
}
