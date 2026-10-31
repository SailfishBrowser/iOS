import Foundation
import Testing
@testable import SailBrowser

struct PrivateTabsTests {
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
        let fixture = try #require(Bundle(for: FixtureBundle.self).url(forResource: "state-before-private-tabs", withExtension: "json"))
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

    @Test func throwingAPrivateTabLeavesNoArchiveEntryThroughTheSweep() {
        let clock = TestClock()
        let store = BrowserStore(directories: .temporary(), now: { [clock] in clock.now })
        let secret = store.openTab(url: URL(string: "https://b.com")!, isPrivate: true)
        let normal = store.openTab(url: URL(string: "https://a.com")!)
        var removed: [Tab.ID] = []
        store.onTabsRemoved = { removed += $0 }
        clock.advance(store.settings.archiveInterval.duration + 1)

        #expect(Set(store.runArchiveSweep()) == [secret.id, normal.id])

        #expect(store.archived.map(\.id) == [normal.id])
        #expect(Set(removed) == [secret.id, normal.id])
    }
}
