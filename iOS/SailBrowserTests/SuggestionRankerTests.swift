import Foundation
import Testing
@testable import SailBrowser

struct SuggestionRankerTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ url: String, _ title: String, visits: Int, age: TimeInterval = 0) -> HistoryEntry {
        HistoryEntry(url: URL(string: url)!, title: title, visitCount: visits, lastVisit: start.addingTimeInterval(-age))
    }

    private func keys(_ entries: [HistoryEntry]) -> [HistorySearchKey] {
        entries.map(HistorySearchKey.init)
    }

    @Test func hostPrefixOutranksTitleAndVisitCount() {
        let tips = entry("https://blog.example.com/tips", "GitHub tips", visits: 50)
        let github = entry("https://github.com/", "GitHub", visits: 2)
        let matches = SuggestionRanker.historyMatches(keys([tips, github]), query: "git", limit: 4)
        #expect(matches == [github, tips])
    }

    @Test func titleWordPrefixOutranksSubstringThenVisitsThenRecency() {
        let substring = entry("https://a.com/", "Legitimate", visits: 90)
        let olderWord = entry("https://b.com/", "Learn Git", visits: 5, age: 100)
        let newerWord = entry("https://c.com/", "Pro Git book", visits: 5, age: 10)
        let busierWord = entry("https://d.com/", "Café git notes", visits: 7)
        let wwwHost = entry("https://www.gitlab.com/", "Lab", visits: 1)
        let unrelated = entry("https://e.com/", "Swift", visits: 100)

        let matches = SuggestionRanker.historyMatches(
            keys([substring, olderWord, newerWord, busierWord, wwwHost, unrelated]), query: "GIT", limit: 10)

        #expect(matches == [wwwHost, busierWord, newerWord, olderWord, substring])
        #expect(SuggestionRanker.historyMatches(keys([substring, olderWord]), query: "git", limit: 1) == [olderWord])
        #expect(SuggestionRanker.historyMatches(keys([busierWord]), query: "cafe", limit: 4) == [busierWord])
    }

    @Test func schemeIsNeverMatched() {
        let plain = entry("https://a.com/docs", "Docs", visits: 3)
        let secure = entry("http://b.com/", "Using https everywhere", visits: 1)
        let pathHit = entry("https://c.com/https-guide", "Guide", visits: 2)

        #expect(SuggestionRanker.historyMatches(keys([plain, secure, pathHit]), query: "https", limit: 4) == [secure, pathHit])
        #expect(SuggestionRanker.historyMatches(keys([plain]), query: "http", limit: 4).isEmpty)
    }

    @Test func onlyWebPagesAreSuggested() {
        let data = entry("data:text/html,%3Cmeta%20name%3D%22a%22%3E", "", visits: 40)
        let blank = entry("about:blank", "about", visits: 30)
        let web = entry("https://about.com/", "About", visits: 1)

        #expect(SuggestionRanker.topSites([data, blank, web], excluding: nil, limit: 8) == [.site(url: web.url, title: "About")])
        #expect(SuggestionRanker.historyMatches(keys([data, blank, web]), query: "a", limit: 4) == [web])
    }

    // Top sites list pages, not sites, by visit count then recency.
    @Test func topSitesArePagesByVisitCountThenRecency() {
        let entries = [
            entry("https://a.com/x", "A x", visits: 5),
            entry("https://www.a.com/y", "A y", visits: 9),
            entry("https://b.com/", "B", visits: 4),
            entry("https://c.com/", "C", visits: 4, age: 50),
            entry("https://d.com/", "D", visits: 1),
        ]

        #expect(SuggestionRanker.topSites(entries, excluding: nil, limit: 4) == [
            .site(url: URL(string: "https://www.a.com/y")!, title: "A y"),
            .site(url: URL(string: "https://a.com/x")!, title: "A x"),
            .site(url: URL(string: "https://b.com/")!, title: "B"),
            .site(url: URL(string: "https://c.com/")!, title: "C"),
        ])
    }

    // Top sites leave out the page the sheet opens over; it shows only when the sheet opens over another page.
    @Test func topSitesLeaveOutThePageTheSheetOpensOver() {
        let entries = [
            entry("https://a.com/", "A", visits: 9),
            entry("https://b.com/", "B", visits: 4),
        ]

        let over = URL(string: "https://a.com/#section")!
        #expect(SuggestionRanker.topSites(entries, excluding: over, limit: 4) == [
            .site(url: URL(string: "https://b.com/")!, title: "B"),
        ])
    }

    @Test func mergeCapsHistoryAndDropsDuplicateQueries() {
        let history = (1...5).map { entry("https://h\($0).com/", "Swift \($0)", visits: $0) }
        let remote = ["Swift", "swift 2", "swift ui", "swift ui", "swift a", "swift b", "swift c", "swift d", "swift e", "swift f"]

        let rows = SuggestionRanker.merge(query: "swift", completion: nil, history: history, remote: remote)

        #expect(rows == [.query("swift")] + history.prefix(3).map { .match(url: $0.url, title: $0.title) }
            + ["swift ui", "swift a", "swift b", "swift c", "swift d", "swift e"].map { .query($0) })
    }

    @Test func completedSiteThenTypedQueryThenHistoryThenRemote() {
        let amazon = entry("https://www.amazon.com/", "Amazon", visits: 9)
        let others = (1...4).map { entry("https://amazon\($0).example/", "Amazon \($0)", visits: $0) }
        let remote = ["amaz", "Amazon", "amazon prime", "amazon 1", "amazon stock"]

        let rows = SuggestionRanker.merge(query: "amaz", completion: amazon, history: [amazon] + others, remote: remote)

        #expect(rows == [.match(url: amazon.url, title: "Amazon"), .query("amaz")]
            + others.prefix(3).map { .match(url: $0.url, title: $0.title) }
            + [.query("amazon prime"), .query("amazon stock")])
    }

    @Test func completionMatchesBareHostPrefixOnly() {
        let busy = entry("https://www.github.com/a", "A", visits: 9)
        let quiet = entry("https://github.com/b", "B", visits: 2)
        let titled = entry("https://example.com/", "github", visits: 50)

        #expect(SuggestionRanker.completion(keys([quiet, titled, busy]), typed: "GIT") == busy)
        #expect(SuggestionRanker.completion(keys([quiet, busy]), typed: "github.com/") == nil)
        #expect(SuggestionRanker.completion(keys([quiet]), typed: "git hub") == nil)
    }

    @Test func searchKeyFoldsAddressAndTitleOnce() {
        let key = HistorySearchKey(entry("https://WWW.Example.com/Docs/Guide?q=1", "Café Git-notes 2", visits: 1))

        #expect(key.host == "example.com")
        #expect(key.address == "example.com/docs/guide")
        #expect(key.title == "cafe git-notes 2")
        #expect(key.wordStarts.map { key.title[$0...].prefix(1) } == ["c", "g", "n", "2"])
    }

    @Test func keysRankTheSameAcrossQueries() {
        let hostPrefix = entry("https://github.com/", "Home", visits: 1)
        let wordStart = entry("https://a.com/", "Learn Git", visits: 1)
        let titleSubstring = entry("https://b.com/", "Digital", visits: 2)
        let pathSubstring = entry("https://c.com/legit-tips", "Tips", visits: 1)
        let unrelated = entry("https://d.com/", "Swift", visits: 9)
        let searchKeys = keys([unrelated, pathSubstring, titleSubstring, wordStart, hostPrefix])

        let ranked = [hostPrefix, wordStart, titleSubstring, pathSubstring]
        #expect(SuggestionRanker.historyMatches(searchKeys, query: "gi", limit: 10) == ranked)
        #expect(SuggestionRanker.historyMatches(searchKeys, query: "GIT", limit: 10) == ranked)
        #expect(SuggestionRanker.historyMatches(searchKeys, query: "gith", limit: 10) == [hostPrefix])
        #expect(SuggestionRanker.historyMatches(searchKeys, query: "tips", limit: 10) == [pathSubstring])
        #expect(SuggestionRanker.historyMatches(searchKeys, query: "zzz", limit: 10).isEmpty)
    }
}
