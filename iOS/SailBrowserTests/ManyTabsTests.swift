import CoreGraphics
import Foundation
import Testing
@testable import SailBrowser

// The store with hundreds of tabs and a full archive: one batch per sweep, the archive in its own file, and the deck's
// order and open position intact.
struct ManyTabsTests {
    let directories = AppDirectories.temporary()
    let clock = TestClock()

    private func makeStore() -> BrowserStore {
        BrowserStore(directories: directories, now: { [clock] in clock.now })
    }

    private func openTabs(_ store: BrowserStore, _ count: Int, from start: Int = 0) -> [Tab] {
        (start..<start + count).map { i in
            clock.advance(1)
            return store.openTab(url: URL(string: "https://t\(i).test/")!)
        }
    }

    private func file(_ name: String) -> URL {
        directories.support.appending(path: name)
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: file(name).path(percentEncoded: false))
    }

    // Two thousand archived entries ride no tab switch: state.json is written without them and only an archive op
    // writes archive.json.
    @Test func theArchiveLivesInItsOwnFileAndTabSwitchesNeverWriteIt() async throws {
        let store = makeStore()
        _ = openTabs(store, 2000)
        clock.advance(ArchiveInterval.oneDay.duration)
        let kept = openTabs(store, 2, from: 2000)
        #expect(store.runArchiveSweep().count == 2000)
        #expect(store.archived.count == 2000)
        await store.flush()

        let state = try String(contentsOf: file("state.json"), encoding: .utf8)
        #expect(!state.contains("archived"))
        let archive = try Data(contentsOf: file("archive.json"))
        #expect(state.utf8.count < archive.count / 100)
        #expect(try JSONDecoder().decode([ArchivedTab].self, from: archive) == store.archived)

        try FileManager.default.removeItem(at: file("archive.json"))
        try FileManager.default.removeItem(at: file("state.json"))
        for i in 0..<50 {
            clock.advance(1)
            store.activate(kept[i % 2].id)
        }
        await store.flush()
        #expect(exists("state.json"))
        #expect(!exists("archive.json"))

        store.archive(kept[0].id)
        await store.flush()
        #expect(exists("archive.json"))
        #expect(makeStore().archived == store.archived)
        #expect(makeStore().tabs.map(\.id) == [kept[1].id])
    }

    @Test func threeHundredStaleTabsSweepInOneBatch() {
        let store = makeStore()
        var removed: [[Tab.ID]] = []
        store.onTabsRemoved = { removed.append($0) }
        let tabs = openTabs(store, 300)
        clock.advance(ArchiveInterval.oneDay.duration)

        let swept = store.runArchiveSweep()

        #expect(swept == tabs.map(\.id))
        #expect(removed == [swept])
        #expect(store.tabs.isEmpty)
        #expect(store.activeTabID == nil)
        #expect(store.archived.map(\.url) == tabs.reversed().map(\.url))
    }

    @Test func theArchiveKeepsTheNewestTwoThousand() {
        let store = makeStore()
        let first = openTabs(store, 300)
        clock.advance(ArchiveInterval.oneDay.duration)
        #expect(store.runArchiveSweep().count == 300)
        let second = openTabs(store, 2200, from: 300)
        clock.advance(ArchiveInterval.oneDay.duration)
        #expect(store.runArchiveSweep().count == 2200)

        #expect(store.archived.count == 2000)
        #expect(store.archived.first?.url == second[2199].url)
        #expect(store.archived.last?.url == second[200].url)
        #expect(!store.archived.contains { $0.url == first[299].url })
    }

    @Test func previousBackgroundAndPinsHoldOverThreeHundredTabs() {
        let store = makeStore()
        let tabs = openTabs(store, 300)
        let ids = tabs.map(\.id)
        clock.advance(1)
        store.activate(ids[100])
        #expect(store.previousTabID == ids[299])
        clock.advance(1)
        store.activate(ids[5])
        #expect(store.previousTabID == ids[100])

        clock.advance(1)
        store.activate(ids[299])
        let added = store.openInBackground(url: URL(string: "https://added.test/")!)
        #expect(store.tabs.count == 301)
        #expect(store.tabs.last?.id == added.id)
        #expect(store.activeTabID == ids[299])
        #expect(store.previousTabID == ids[5])

        store.setPinned(true, for: ids[299])
        store.setPinned(true, for: ids[0])
        #expect(store.tabs.prefix(3).map(\.id) == [ids[299], ids[0], ids[1]])
        let pinnedCount = store.tabs.count { $0.isPinned }
        #expect(pinnedCount == 2)
        store.setPinned(false, for: ids[299])
        store.setPinned(false, for: ids[0])
        let unpinnedOrder = ids + [added.id]
        #expect(store.tabs.map(\.id) == unpinnedOrder)
        #expect(store.tabs.allSatisfy { !$0.isPinned })

        let frozen = CardLayout.frozenOrder(ids, current: store.tabs.map(\.id))
        #expect(frozen.count == 301)
        #expect(Set(frozen).count == 301)
    }

    // A state with 300 tabs and the last one active opens the deck focused on its left neighbour, with the active card
    // peeking right.
    @Test func theDeckOpensOnTheActiveCardsNeighbourWithThreeHundredTabs() throws {
        let now = Date()
        let tabs = (0..<300).map { i in
            Tab(
                id: UUID(), url: URL(string: "https://t\(i).test/")!, title: "t\(i)", isPinned: false,
                prefersDesktop: false, createdAt: now, lastActiveAt: now, tint: nil)
        }
        let state = BrowserState(tabs: tabs, archived: [], activeTabID: tabs[299].id, settings: BrowserSettings())
        try FileManager.default.createDirectory(at: directories.support, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: file("state.json"))

        let env = makeEnvironment(directories)
        env.launch()

        let ids = env.browser.tabs.map(\.id)
        let activeIndex = try #require(ids.firstIndex { $0 == env.browser.activeTabID })
        #expect(activeIndex == 299)
        #expect(CardLayout(screen: CGSize(width: 440, height: 956)).openPosition(activeIndex: activeIndex) == 298)
        #expect(DeckView.built(ids: ids, activeIndex: activeIndex, span: 297...299, pinned: []) == [297, 298, 299])
        #expect(env.ui.deckProgress == 0)
    }
}
