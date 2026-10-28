import Foundation
import Testing
@testable import SailBrowser

struct TextEdgeTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func resolved(_ text: String) -> String? {
        InputResolver.resolve(text, engine: .google)?.absoluteString
    }

    // A Google results page for the text exactly as typed.
    private func searches(_ text: String) -> Bool {
        let url = InputResolver.resolve(text, engine: .google)
        let query = url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        }
        return url?.host() == "www.google.com" && query == text
    }

    private func tab(_ url: String, _ title: String) -> Tab {
        Tab(
            id: UUID(), url: URL(string: url)!, title: title, isPinned: false, prefersDesktop: false, createdAt: .now,
            lastActiveAt: .now, tint: nil, isPrivate: false)
    }

    private func entry(_ url: String, _ title: String, visits: Int = 1) -> HistoryEntry {
        HistoryEntry(url: URL(string: url)!, title: title, visitCount: visits, lastVisit: start)
    }

    private func matches(_ entries: [HistoryEntry], _ query: String) -> [HistoryEntry] {
        SuggestionRanker.historyMatches(entries.map(HistorySearchKey.init), query: query, limit: 20)
    }

    // Foundation encodes a stray space or non-ASCII in a path, but a space in the host parses as nothing; that text
    // searches instead of leaving the Return key dead.
    @Test func anAddressThatWillNotParseIsEncodedOrSearched() {
        #expect(searches("http://a b"))
        #expect(searches("https://exam ple.com/x"))
        #expect(resolved("https://example.com/a b") == "https://example.com/a%20b")
        #expect(resolved("https://example.com/ä") == "https://example.com/%C3%A4")
        #expect(resolved("münchen.de/ä") == "https://xn--mnchen-3ya.de/%C3%A4")
    }

    @Test(arguments: [
        ("münchen.de", "https://xn--mnchen-3ya.de"),
        ("日本.jp", "https://xn--wgv71a.jp"),
        ("localhost:8080/x", "http://localhost:8080/x"),
        ("192.168.1.1:80", "http://192.168.1.1:80"),
        ("HTTP://EXAMPLE.COM", "HTTP://EXAMPLE.COM"),
    ])
    func hostShapesResolveAsAddresses(text: String, url: String) {
        #expect(resolved(text) == url)
    }

    @Test(arguments: ["a..b", "example.", "-a.com", "a-.com", "a.-b.com"])
    func malformedHostsSearch(text: String) {
        #expect(searches(text))
    }

    @Test func bracketsAndBackslashesInATitleAreEscapedAsMarkdownReadsThem() {
        #expect(
            TabExport.text([tab("https://a.test/", "A [draft] (final) C:\\x")])
                == "- [A \\[draft\\] (final) C:\\\\x](https://a.test/)")
        // Someone else's Markdown: an escaped "]" does not close the title, an unescaped one still may.
        #expect(
            TabImport.tabs(from: "[a \\] b](https://a.test/) [c ] d](https://c.test/)") == [
                ImportedTab(url: URL(string: "https://a.test/")!, title: "a ] b"),
                ImportedTab(url: URL(string: "https://c.test/")!, title: "c ] d"),
            ])
    }

    @Test func anyTitleRoundTripsThroughExportAndImport() {
        let titles = [
            "A [draft] (final)", "See [docs](https://d.test) now", "a\\]b", "C:\\Users\\me", "two\nlines\r\nthree",
            "👨‍👩‍👧‍👦 🎉", "عربي\u{200F} ] ع", "Zoë A\u{308}rger", String(repeating: "ab]c", count: 1_250),
        ]
        let tabs = titles.enumerated().map { tab("https://t\($0.offset).test/p?x=1", $0.element) }
        let imported = TabImport.tabs(from: TabExport.text(tabs))
        #expect(imported.map(\.url) == tabs.map(\.url))
        #expect(imported.map(\.title) == titles.map { $0.split(whereSeparator: \.isNewline).joined(separator: " ") })
    }

    // The title pattern is bounded by its line, so a line of junk brackets costs that line and no more.
    @Test func aFiveMegabytePasteImportsEveryLine() {
        var lines = (0..<100_000).map { "- [Title \u{1F389} [b] (p)](https://example.test/p\($0)?x=1)" }
        lines.insert(String(repeating: "[", count: 1_000) + String(repeating: "]", count: 1_000), at: 0)
        let text = lines.joined(separator: "\n")
        #expect(text.utf8.count > 5_000_000)
        let tabs = TabImport.tabs(from: text)
        #expect(tabs.count == 100_000)
        #expect(tabs.last == ImportedTab(url: URL(string: "https://example.test/p99999?x=1")!, title: "Title 🎉 [b] (p)"))
    }

    // Ten stale 200 KB titles among 5,000 entries: the keys scan to the cap, so a needle past it is not found and the
    // rows equal those of entries stored at the cap.
    @Test func aStaleHugeTitleIsScannedOnlyToTheCap() {
        let huge = String(repeating: "x", count: 200_000) + " zqj"
        var entries = (0..<4_990).map { entry("https://site\($0).test/page", "Page \($0)") }
        entries += (0..<10).map { entry("https://huge\($0).test/", huge) }
        entries.append(entry("https://zqj.test/", "Zqj here"))
        let capped = entries.map {
            HistoryEntry(
                url: $0.url, title: String($0.title.prefix(Theme.Text.titleLimit)), visitCount: $0.visitCount,
                lastVisit: $0.lastVisit)
        }
        #expect(matches(entries, "zqj") == matches(capped, "zqj"))
        #expect(matches(entries, "zqj") == [entries.last!])
        #expect(HistorySearchKey(entries[4_990]).title.count == Theme.Text.titleLimit)
        let long = HistorySearchKey(entry("https://long.test/" + String(repeating: "p", count: 10_000), "L"))
        #expect(long.address.count == Theme.Text.urlLimit)
    }

    @Test func foldingReachesCombiningMarksAndIdeographsButNotEmoji() {
        let precomposed = entry("https://one.test/", "Ärger", visits: 3)
        let decomposed = entry("https://two.test/", "A\u{308}rger", visits: 2)
        let japanese = entry("https://three.test/", "日本語のタイトル")
        let emoji = entry("https://four.test/", "👨‍👩‍👧‍👦🎉😀")
        let all = [precomposed, decomposed, japanese, emoji]
        #expect(matches(all, "arger") == [precomposed, decomposed])
        #expect(matches(all, "ÄRG") == [precomposed, decomposed])
        #expect(matches(all, "a") == [precomposed, decomposed])
        #expect(matches(all, "日本") == [japanese])
        #expect(matches(all, "🎉") == [emoji])
        #expect(HistorySearchKey(emoji).wordStarts.isEmpty)
    }

    @Test func strippingKeepsFiveHundredItemsInOrderAndLeavesOtherSchemesAlone() {
        let items = (0..<500).map { "k\($0)=v%20\($0)+x" }.joined(separator: "&")
        let tracked = URL(string: "https://a.test/p?" + items + "&utm_source=x&k=v%2B")!
        #expect(TrackingParams.strip(tracked).absoluteString == "https://a.test/p?" + items + "&k=v%2B")
        let clean = URL(string: "https://a.test/p?" + items)!
        #expect(TrackingParams.strip(clean) == clean)
        // A "?" in a data URL is data, not a query.
        for other in ["data:text/html,hi?utm_source=x", "about:blank?utm_source=1", "data:text/plain,utm_source=x"] {
            let url = URL(string: other)!
            #expect(TrackingParams.strip(url) == url)
        }
    }

    @Test func aResultsPageQueryDecodesPlusAndPercentsAtAnyLength() {
        let page = URL(string: "https://www.google.com/search?q=a+b%2Bc%20d%26e")!
        #expect(SearchEngine.query(inResultsURL: page) == "a b+c d&e")
        let long = String(repeating: "c++ & café ", count: 1_000)
        for engine in SearchEngine.allCases {
            #expect(SearchEngine.query(inResultsURL: engine.resultsURL(for: long)) == long)
        }
    }
}
