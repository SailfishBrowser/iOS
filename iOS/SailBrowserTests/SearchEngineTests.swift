import Foundation
import Testing
@testable import SailBrowser

struct SearchEngineTests {
    // Bodies recorded with curl on 2026-10-24, cut to three suggestions.
    static let recorded: [SearchEngine: String] = [
        .google: #"["swift",["swiftx tracking","swift","swift transportation"],[],{"google:suggestsubtypes":[[512],[512],[512]]}]"#,
        .duckDuckGo: #"["swift",["swift","swift transportation","swift code"]]"#,
        .bing: #"["swift",["swift","swift institute","swift code"]]"#,
        .ecosia: #"["swift",["swift","swift code","swiftmd"]]"#,
        .kagi: #"["swift",["swiftly login","swift code","swiftx"]]"#,
    ]

    static let expected: [SearchEngine: [String]] = [
        .google: ["swiftx tracking", "swift", "swift transportation"],
        .duckDuckGo: ["swift", "swift transportation", "swift code"],
        .bing: ["swift", "swift institute", "swift code"],
        .ecosia: ["swift", "swift code", "swiftmd"],
        .kagi: ["swiftly login", "swift code", "swiftx"],
    ]

    @Test(arguments: [
        (SearchEngine.google, "https://www.google.com/search?q=swift%20testing"),
        (.duckDuckGo, "https://duckduckgo.com/?q=swift%20testing"),
        (.bing, "https://www.bing.com/search?q=swift%20testing"),
        (.ecosia, "https://www.ecosia.org/search?q=swift%20testing"),
        (.kagi, "https://kagi.com/search?q=swift%20testing"),
        (.perplexity, "https://www.perplexity.ai/search?q=swift%20testing"),
    ])
    func aQueryResolvesToTheEnginesResultsUrl(engine: SearchEngine, url: String) {
        #expect(InputResolver.resolve("swift testing", engine: engine)?.absoluteString == url)
        #expect(InputResolver.resolve("c++ & go", engine: engine)?.absoluteString.hasSuffix("?q=c%2B%2B%20%26%20go") == true)
        #expect(InputResolver.resolve("swift.org", engine: engine)?.absoluteString == "https://swift.org")
    }

    @Test(arguments: [
        (SearchEngine.google, "https://suggestqueries.google.com/complete/search?client=firefox&ie=utf-8&oe=utf-8&hl=de&q=c%2B%2B%20%26%20go"),
        (.duckDuckGo, "https://duckduckgo.com/ac/?q=c%2B%2B%20%26%20go&type=list"),
        (.bing, "https://api.bing.com/osjson.aspx?query=c%2B%2B%20%26%20go"),
        (.ecosia, "https://ac.ecosia.org/autocomplete?q=c%2B%2B%20%26%20go&type=list"),
        (.kagi, "https://kagisuggest.com/api/autosuggest?q=c%2B%2B%20%26%20go"),
        (.perplexity, "https://suggestqueries.google.com/complete/search?client=firefox&ie=utf-8&oe=utf-8&hl=de&q=c%2B%2B%20%26%20go"),
    ])
    func suggestionsComeFromTheEnginesEndpoint(engine: SearchEngine, url: String) {
        #expect(engine.suggestionsURL(for: "c++ & go", language: "de").absoluteString == url)
    }

    @Test func eachEnginesRecordedAnswerParses() throws {
        for (engine, body) in Self.recorded {
            let parsed = try SuggestionService.decode(Data(body.utf8))
            #expect(parsed.query == "swift")
            #expect(parsed.suggestions == Self.expected[engine])
        }
    }

    @Test func theServiceAsksTheEngineItIsGiven() async throws {
        StubSuggestProtocol.answer("kagi swift", with: #"["kagi swift",["kagi swiftly"]]"#)
        let service = stubService()

        let answer = try await service.suggestions(for: "kagi swift", engine: .kagi)

        #expect(answer.suggestions == ["kagi swiftly"])
        #expect(StubSuggestProtocol.request(for: "kagi swift")?.url?.host() == "kagisuggest.com")
    }

    @Test func everyEnginesResultsPageGivesBackItsQuery() {
        for engine in SearchEngine.allCases {
            #expect(SearchEngine.query(inResultsURL: engine.resultsURL(for: "c++ & café")) == "c++ & café")
        }
        // Engines write a space as "+" in their own links; ours always encode "+" itself.
        let pages: [String: String?] = [
            "https://google.co.uk/search?q=tea&hl=en": "tea",
            "https://www.perplexity.ai/search/new?q=why": "why",
            "https://bing.com/search?form=QBLH&q=a+b%2B": "a b+",
            "https://duckduckgo.com/": nil,
            "https://www.google.com/maps?q=cafe": nil,
            "https://example.com/search?q=tea": nil,
        ]
        for (page, query) in pages {
            #expect(SearchEngine.query(inResultsURL: URL(string: page)!) == query, "\(page)")
        }
    }

    @Test func theChoiceSurvivesASaveAndReload() async {
        let directories = AppDirectories.temporary()
        let store = BrowserStore(directories: directories)
        store.settings.searchEngine = .kagi
        await store.flush()
        #expect(BrowserStore(directories: directories).settings.searchEngine == .kagi)
    }

    @Test func namesMatchTheEnginesOwn() {
        #expect(SearchEngine.allCases.map(\.name) == ["Google", "DuckDuckGo", "Bing", "Ecosia", "Kagi", "Perplexity"])
    }
}
