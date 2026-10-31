import Foundation
import Testing
@testable import SailBrowser

// What a saved state can carry that the store's invariants do not allow, and what the store makes of it.
struct StoreInvariantTests {
    let directories = AppDirectories.temporary()
    let clock = TestClock()

    private func makeStore() -> BrowserStore {
        BrowserStore(directories: directories, now: { [clock] in clock.now })
    }

    private func tab(_ name: String, createdAt: Date, lastActiveAt: Date) -> Tab {
        Tab(
            id: UUID(), url: URL(string: "https://\(name).test/")!, title: name, isPinned: false,
            prefersDesktop: false, createdAt: createdAt, lastActiveAt: lastActiveAt, tint: nil)
    }

    private func writeState(_ tabs: [Tab], activeTabID: UUID?) throws {
        let state = BrowserState(tabs: tabs, archived: [], activeTabID: activeTabID, settings: BrowserSettings())
        try FileManager.default.createDirectory(at: directories.support, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: directories.support.appending(path: "state.json"))
    }

    // A hand-edited or half-migrated state.json names an active tab that is not there: the most recently active tab
    // takes its place.
    @Test func aForeignActiveTabIDFallsBackToTheMostRecentlyActiveTab() throws {
        let now = Date()
        let tabs = zip([0, 1, 2], [-100.0, -10, -50]).map { i, idle in
            tab("t\(i)", createdAt: now.addingTimeInterval(-100 + Double(i)), lastActiveAt: now.addingTimeInterval(idle))
        }
        try writeState(tabs, activeTabID: UUID())

        let store = BrowserStore(directories: directories)
        #expect(store.activeTabID == tabs[1].id)
        #expect(store.activeTab?.url == tabs[1].url)
    }

    // A second tap on an archive row before the sheet has left asks for an entry already restored: nothing happens.
    @Test func restoringAnEntryTwiceOpensOneTab() {
        let store = makeStore()
        let tab = store.openTab(url: URL(string: "https://a.test/")!)
        store.archive(tab.id)
        #expect(store.restore(tab.id)?.url == tab.url)
        #expect(store.restore(tab.id) == nil)
        #expect(store.tabs.map(\.url) == [tab.url])
        #expect(store.archived.isEmpty)
    }

    // A page's <title> can be anything: the stores keep its first line, to the title limit.
    @Test func titlesAreCappedAtTheStoreBoundary() {
        let huge = String(repeating: "x", count: 200_000)
        let store = makeStore()
        let tab = store.openTab(url: URL(string: "https://a.test/")!)
        store.updatePage(tab.id, url: tab.url, title: huge, tint: nil)
        #expect(store.tabs[0].title.count == Theme.Text.titleLimit)
        var made = store.makeTab(url: URL(string: "https://b.test/")!)
        made.title = "First line\nSecond line"
        store.insert(made, activate: false)
        #expect(store.tabs[1].title == "First line")

        let history = HistoryStore(directories: directories, now: { [clock] in clock.now })
        let page = URL(string: "https://c.test/")!
        history.recordVisit(url: page, title: huge)
        #expect(history.entries[0].title.count == Theme.Text.titleLimit)
        history.updateTitle(url: page, title: "Short\n" + huge)
        #expect(history.entries.map(\.title) == ["Short"])
        #expect(history.searchKeys.map(\.title) == ["short"])
    }

    @Test func aStateWithNoTabsHasNoActiveTab() throws {
        try writeState([], activeTabID: UUID())
        let store = makeStore()
        #expect(store.activeTabID == nil)
        #expect(store.tabs.isEmpty)
    }

    // A clock that jumped back leaves tabs with times in the future, which a sweep would never reach.
    @Test func timesInTheFutureAreClampedToNowAtLoad() throws {
        let day = ArchiveInterval.oneDay.duration
        let visited = tab("visited", createdAt: clock.now.addingTimeInterval(-2 * day), lastActiveAt: clock.now.addingTimeInterval(day))
        let unshown = tab("unshown", createdAt: clock.now.addingTimeInterval(day), lastActiveAt: .distantPast)
        try writeState([visited, unshown], activeTabID: visited.id)

        let store = makeStore()
        #expect(store.tabs.map(\.lastActiveAt) == [clock.now, .distantPast])
        #expect(store.tabs.map(\.createdAt) == [visited.createdAt, clock.now])
        clock.advance(day - 1)
        #expect(store.runArchiveSweep().isEmpty)
        clock.advance(1)
        #expect(store.runArchiveSweep() == [visited.id, unshown.id])
    }
}
