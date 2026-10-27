import Foundation
import Testing
@testable import SailBrowser

struct HistoryStoreTests {
    let directories = AppDirectories.temporary()
    let clock = TestClock()

    private func makeStore(capacity: Int = 5000) -> HistoryStore {
        HistoryStore(directories: directories, capacity: capacity, now: { [clock] in clock.now })
    }

    @Test func historySkipsEveryEnginesResultsPages() {
        let store = makeStore()
        for engine in SearchEngine.allCases {
            store.recordVisit(url: engine.resultsURL(for: "swift"), title: "swift")
        }
        #expect(store.entries.isEmpty)
        store.recordVisit(url: URL(string: "https://duckduckgo.com/")!, title: "DuckDuckGo")
        #expect(store.entries.map(\.title) == ["DuckDuckGo"])
    }

    @Test func historySkipsGoogleSearchAndMergesFragments() async {
        let store = makeStore()
        store.recordVisit(url: URL(string: "https://www.google.com/search?q=swift")!, title: "swift - Google Search")
        store.recordVisit(url: URL(string: "https://google.co.uk/search?q=swift")!, title: "swift - Google Search")
        #expect(store.entries.isEmpty)

        store.recordVisit(url: URL(string: "https://a.com/page#one")!, title: "One")
        clock.advance(10)
        store.recordVisit(url: URL(string: "https://b.com/")!, title: "B")
        clock.advance(10)
        store.recordVisit(url: URL(string: "https://a.com/page#two")!, title: "Page")

        #expect(store.entries == [
            HistoryEntry(url: URL(string: "https://a.com/page")!, title: "Page", visitCount: 2, lastVisit: clock.now),
            HistoryEntry(url: URL(string: "https://b.com/")!, title: "B", visitCount: 1, lastVisit: clock.now.addingTimeInterval(-10)),
        ])

        await store.flush()
        #expect(makeStore().entries == store.entries)
    }

    @Test func aRemovedPageStaysRemovedOnTheNextLaunch() async {
        let store = makeStore()
        store.recordVisit(url: URL(string: "https://a.com/")!, title: "A")
        store.recordVisit(url: URL(string: "https://www.a.com/page")!, title: "A page")
        store.recordVisit(url: URL(string: "https://b.com/")!, title: "B")

        store.remove(url: URL(string: "https://a.com/")!)

        #expect(store.entries.map(\.title) == ["B", "A page"])
        #expect(store.searchKeys.map(\.entry.title) == ["B", "A page"])
        await store.flush()
        #expect(makeStore().entries.map(\.title) == ["B", "A page"])
    }

    // A commit records before the page has a title; the title lands on that entry when it arrives.
    @Test func aLateTitleLandsOnTheCommittedEntry() {
        let store = makeStore()
        let page = URL(string: "https://a.com/page#top")!
        store.recordVisit(url: page, title: "")
        store.updateTitle(url: page, title: "Late")

        #expect(store.entries.map(\.title) == ["Late"])
        #expect(store.entries[0].visitCount == 1)
        #expect(store.searchKeys.map(\.title) == ["late"])
    }

    @Test func aRevisitWithNoTitleYetKeepsTheKnownOne() {
        let store = makeStore()
        let page = URL(string: "https://a.com/")!
        store.recordVisit(url: page, title: "Known")
        store.recordVisit(url: page, title: "")

        #expect(store.entries.map(\.title) == ["Known"])
        #expect(store.entries[0].visitCount == 2)
    }

    // A page's first title is written; its later re-titles (a 1 Hz unread count) stay in memory and ride the next
    // visit or the background flush.
    @Test func onlyAPagesFirstTitleSchedulesAWrite() async {
        let store = makeStore()
        let page = URL(string: "https://a.test/")!
        store.recordVisit(url: page, title: "")
        #expect(store.hasPendingWrite)
        await store.flush()
        #expect(!store.hasPendingWrite)

        store.updateTitle(url: page, title: "Inbox")
        #expect(store.hasPendingWrite)
        await store.flush()
        #expect(makeStore().entries.map(\.title) == ["Inbox"])

        for n in 1...5 {
            store.updateTitle(url: page, title: "Inbox \(n)")
        }
        #expect(!store.hasPendingWrite)
        #expect(store.entries.map(\.title) == ["Inbox 5"])
        #expect(store.searchKeys.map(\.title) == ["inbox 5"])
        #expect(makeStore().entries.map(\.title) == ["Inbox"])

        await store.flush()
        #expect(makeStore().entries.map(\.title) == ["Inbox 5"])
        #expect(!store.hasPendingWrite)
        await store.flush()

        store.updateTitle(url: page, title: "Inbox 6")
        #expect(!store.hasPendingWrite)
        clock.advance(1)
        store.recordVisit(url: URL(string: "https://b.test/")!, title: "B")
        #expect(store.hasPendingWrite)
        await store.flush()
        #expect(makeStore().entries.map(\.title) == ["B", "Inbox 6"])
    }

    @Test func historyDropsLeastRecentOverCapacity() {
        let store = makeStore(capacity: 2)
        for name in ["a", "b", "c"] {
            clock.advance(1)
            store.recordVisit(url: URL(string: "https://\(name).com/")!, title: name)
        }

        #expect(store.entries.map(\.title) == ["c", "b"])
        store.clear()
        #expect(store.entries.isEmpty)
    }

    @Test func historyKeysRelativeURLsWithoutFragment() {
        let store = makeStore()
        let base = URL(string: "https://a.com/dir/page")!
        store.recordVisit(url: URL(string: "other#x", relativeTo: base)!, title: "Relative")

        #expect(store.entries.map(\.url.absoluteString) == ["https://a.com/dir/other"])
    }

    @Test func historyRecordsOnlyWebPages() {
        let store = makeStore()
        store.recordVisit(url: URL(string: "about:blank#top")!, title: "Blank")
        store.recordVisit(url: URL(string: "data:text/html,%3Cp%3Ea%3C/p%3E")!, title: "")
        store.recordVisit(url: URL(string: "file:///tmp/a.html")!, title: "File")
        store.recordVisit(url: URL(string: "HTTP://b.com/")!, title: "B")

        #expect(store.entries.map(\.title) == ["B"])
    }

    @Test func searchKeysFollowEntries() async {
        let store = makeStore(capacity: 2)
        #expect(store.searchKeys.isEmpty)

        store.recordVisit(url: URL(string: "https://www.a.com/Docs#one")!, title: "Café Docs")
        #expect(store.searchKeys.map(\.entry) == store.entries)
        #expect(store.searchKeys.map(\.host) == ["a.com"])
        #expect(store.searchKeys.map(\.address) == ["a.com/docs"])
        #expect(store.searchKeys.map(\.title) == ["cafe docs"])

        clock.advance(1)
        store.recordVisit(url: URL(string: "https://b.com/")!, title: "B")
        clock.advance(1)
        store.recordVisit(url: URL(string: "https://www.a.com/Docs#two")!, title: "Docs")
        #expect(store.searchKeys.map(\.entry) == store.entries)
        #expect(store.searchKeys.map(\.title) == ["docs", "b"])
        #expect(store.searchKeys.first?.entry.visitCount == 2)

        clock.advance(1)
        store.recordVisit(url: URL(string: "https://c.com/")!, title: "C")
        #expect(store.searchKeys.map(\.entry) == store.entries)
        #expect(store.searchKeys.map(\.host) == ["c.com", "a.com"])
        #expect(SuggestionRanker.historyMatches(store.searchKeys, query: "doc", limit: 4)
            == SuggestionRanker.historyMatches(store.entries.map(HistorySearchKey.init), query: "doc", limit: 4))

        await store.flush()
        #expect(makeStore(capacity: 2).searchKeys.map(\.entry) == store.entries)

        store.clear()
        #expect(store.searchKeys.isEmpty)
    }
}
