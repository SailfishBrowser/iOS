import Foundation
import Testing
@testable import SailBrowser

struct SearchModelTests {
    let history = HistoryStore(directories: AppDirectories.temporary())

    private func makeModel(
        sleep: @escaping @Sendable (Duration) async throws -> Void = HeldSleep(holding: false).sleep
    ) -> SearchModel {
        SearchModel(history: history, service: stubService(sleep: sleep), engine: { .google })
    }

    private func visit(_ url: String, _ title: String, times: Int = 1) {
        for _ in 0..<times {
            history.recordVisit(url: URL(string: url)!, title: title)
        }
    }

    // A removal takes that page only: another page of the same site stays in the store and can show.
    @Test func removingARecentDropsThatPageFromTheStoreAndTheNextOpen() {
        visit("https://a.com/", "A", times: 3)
        visit("https://www.a.com/page", "A page", times: 2)
        visit("https://b.com/", "B")
        let model = makeModel()
        let a = URL(string: "https://a.com/")!
        #expect(model.rows.first == .site(url: a, title: "A"))

        model.removeRecent(a)

        #expect(history.entries.map(\.title) == ["B", "A page"])
        let rows: [Suggestion] = [
            .site(url: URL(string: "https://www.a.com/page")!, title: "A page"),
            .site(url: URL(string: "https://b.com/")!, title: "B"),
        ]
        #expect(model.rows == rows)
        #expect(makeModel().rows == rows)
        // The completion alone: a ranked "a" would ask the suggestion stub, which has no answer for it.
        model.text = "a"
        model.complete(appending: true)
        #expect(model.completedText == "a.com")
    }

    // Five pages across three sites, the last still open behind the sheet: the other four, newest first, two of them
    // from one site.
    @Test func fivePagesAcrossThreeSitesOpenOnTheOtherFour() {
        let clock = TestClock()
        let history = HistoryStore(directories: AppDirectories.temporary(), now: { [clock] in clock.now })
        let pages = [
            ("https://en.wikipedia.org/wiki/WebKit", "WebKit"),
            ("https://www.iana.org/help/example-domains", "Example Domains"),
            ("https://en.wikipedia.org/wiki/Safari", "Safari"),
            ("https://news.ycombinator.com/", "Hacker News"),
            ("https://www.iana.org/domains/root", "Root Zone Management"),
        ]
        for (url, title) in pages {
            clock.advance(10)
            history.recordVisit(url: URL(string: url)!, title: title)
        }
        let model = SearchModel(history: history, service: stubService(), engine: { .google })

        _ = model.prepareForOpen(over: URL(string: pages[4].0)!)

        #expect(model.rows == pages[0..<4].reversed().map { .site(url: URL(string: $0.0)!, title: $0.1) })
    }

    // A swipe removes the page it is on; the site's other pages keep their rows.
    @Test func removingARecentLeavesTheSitesOtherPages() {
        visit("https://a.com/one", "One", times: 2)
        visit("https://a.com/two", "Two")
        let model = makeModel()

        model.removeRecent(URL(string: "https://a.com/one")!)

        #expect(model.rows == [.site(url: URL(string: "https://a.com/two")!, title: "Two")])
    }

    @Test func staleSuggestionResponseIsDropped() async {
        StubSuggestProtocol.answer("swift", with: #"["sw",["swift","swiftui","swift playgrounds"],[]]"#)
        let model = makeModel()

        model.text = "swift"
        model.textChanged(appending: true)
        await model.fetchTask?.value

        #expect(model.rows == [.query("swift")])
    }

    @Test func freshResponseFollowsTheHistoryRowsShownAheadOfIt() async {
        visit("https://developer.apple.com/swiftui/", "SwiftUI Tips", times: 3)
        StubSuggestProtocol.answer("swiftui", with: #"["swiftui",["SwiftUI","swiftui tips","swiftui tutorial"],[]]"#)
        let model = makeModel()
        let site = Suggestion.match(url: URL(string: "https://developer.apple.com/swiftui/")!, title: "SwiftUI Tips")

        model.text = "  swiftui "
        model.textChanged(appending: true)
        #expect(model.rows == [.query("swiftui")])
        await model.fetchTask?.value

        #expect(model.rows == [.query("swiftui"), site, .query("swiftui tutorial")])
    }

    // Offline the answer never lands, so the earlier rows held under the query must give way to its own rows: a tap
    // on a held row would submit a suggestion that does not match what was typed.
    @Test func aFailedAnswerReplacesTheHeldRowsWithTheQuerysOwn() async {
        StubSuggestProtocol.answer("ab", with: #"["ab",["abc news","abercrombie","absolute"],[]]"#)
        StubSuggestProtocol.fail("abx")
        let model = makeModel()
        model.text = "ab"
        model.textChanged(appending: true)
        await model.fetchTask?.value

        model.text = "abx"
        model.textChanged(appending: true)
        #expect(model.rows.count == 4)
        await model.fetchTask?.value
        #expect(model.rows == [.query("abx")])
    }

    // The next keystroke's cancel reaches the loader's stop, not just the answer's handling.
    @Test func aSupersededKeystrokeStopsItsRequestAtTheTransport() async throws {
        StubSuggestProtocol.hold("we")
        StubSuggestProtocol.answer("we", with: #"["we",["weather","web"],[]]"#)
        StubSuggestProtocol.answer("wea", with: #"["wea",["weather","weapon"],[]]"#)
        let model = makeModel()
        model.text = "we"
        model.textChanged(appending: true)
        try await waitUntil { StubSuggestProtocol.request(for: "we") != nil }

        model.text = "wea"
        model.textChanged(appending: true)

        try await waitUntil { StubSuggestProtocol.stopped.contains("we") }
        StubSuggestProtocol.release("we")
        await model.fetchTask?.value
        #expect(model.rows == [.query("wea"), .query("weather"), .query("weapon")])
    }

    // Low Data Mode fails the fetch at once: the local rows stand.
    @Test func aConstrainedPathKeepsTheLocalRowsAtOnce() async {
        visit("https://constrained.test/", "Constrained")
        StubSuggestProtocol.fail(
            "constrained",
            with: URLError(
                .notConnectedToInternet,
                userInfo: [NSURLErrorNetworkUnavailableReasonKey: URLError.NetworkUnavailableReason.constrained.rawValue]))
        let model = makeModel()
        model.text = "constrained"
        model.textChanged(appending: true)

        await model.fetchTask?.value

        let page = URL(string: "https://constrained.test/")!
        #expect(model.rows == [.match(url: page, title: "Constrained"), .query("constrained")])
    }

    // The hold is what makes the window, not the token: the first keystroke's task is parked in its sleep when the
    // next keystroke lands and is cancelled there, so only the last keystroke of a burst sends a request, while its
    // local rows are ranked at once.
    @Test func keystrokesInsideTheDebounceSendOneRequest() async throws {
        StubSuggestProtocol.answer("sw", with: #"["sw",["swift","swiftui"],[]]"#)
        let held = HeldSleep(holding: true)
        let model = makeModel(sleep: held.sleep)
        model.text = "s"
        model.textChanged(appending: true)
        #expect(model.rows == [.query("s")])
        try await waitUntil { held.requested.count == 1 }
        model.text = "sw"
        model.textChanged(appending: true)
        #expect(model.rows.first == .query("sw"))
        try await waitUntil { held.requested.count == 2 }

        held.release()
        await model.fetchTask?.value

        #expect(StubSuggestProtocol.request(for: "s") == nil)
        #expect(StubSuggestProtocol.request(for: "sw") != nil)
        #expect(model.rows == [.query("sw"), .query("swift"), .query("swiftui")])
    }

    @Test func firstOpenEmptyLaterOpensPrefillLastQuery() async {
        visit("https://swift.org/", "Swift", times: 2)
        visit("https://apple.com/", "Apple")
        StubSuggestProtocol.answer("swift", with: #"["sw",["swift","swiftui","swift playgrounds"],[]]"#)
        let model = makeModel()
        model.text = "swift"
        model.textChanged(appending: true)
        let fetch = model.fetchTask

        let first = model.prepareForOpen(over: nil)

        #expect(first.text == "" && !first.selectAll)
        #expect(model.text == "")
        #expect(fetch?.isCancelled == true)
        #expect(model.fetchTask == nil)
        #expect(model.rows == SuggestionRanker.topSites(history.entries, excluding: nil, limit: 8))
        #expect(model.rows.count == 2)

        StubSuggestProtocol.answer("swift tips", with: #"["swift tips",[],[]]"#)
        model.record(SearchEngine.google.resultsURL(for: "swift tips"))
        let later = model.prepareForOpen(over: nil)

        #expect(later.text == "swift tips" && later.selectAll)
        #expect(model.lastSubmitted == "swift tips")
        #expect(model.completedText == nil)
        #expect(model.rows.first == .query("swift tips"))
    }

    @Test func urlSubmitPrefillsHostWithoutTLD() {
        StubSuggestProtocol.answer("google", with: #"["google",[],[]]"#)
        StubSuggestProtocol.answer("amazon.co", with: #"["amazon.co",[],[]]"#)
        let model = makeModel()

        model.record(URL(string: "https://google.com")!)
        #expect(model.prepareForOpen(over: nil).text == "google")

        model.record(URL(string: "https://www.amazon.co.uk/x")!)
        #expect(model.prepareForOpen(over: nil).text == "amazon.co")
    }

    // Any engine's results page prefills its query, so a page submitted before a change of engine still does.
    @Test func anyEnginesResultsPagePrefillsItsQuery() {
        StubSuggestProtocol.answer("tea time", with: #"["tea time",[],[]]"#)
        let model = makeModel()
        model.record(SearchEngine.bing.resultsURL(for: "tea time"))
        #expect(model.prepareForOpen(over: nil) == (text: "tea time", selectAll: true))
    }

    // Typing asks the chosen engine, and a submit or a row tap searches with it.
    @Test func theModelFollowsTheChosenEngine() async {
        StubSuggestProtocol.answer("ddg", with: #"["ddg",["ddg app"]]"#)
        var engine = SearchEngine.google
        let model = SearchModel(history: history, service: stubService(), engine: { engine })
        engine = .duckDuckGo

        model.text = "ddg"
        model.textChanged(appending: false)
        await model.fetchTask?.value

        #expect(StubSuggestProtocol.request(for: "ddg")?.url?.host() == "duckduckgo.com")
        #expect(model.rows == [.query("ddg"), .query("ddg app")])
        #expect(model.submit() == SearchEngine.duckDuckGo.resultsURL(for: "ddg"))
        #expect(model.url(for: .query("ddg app")) == SearchEngine.duckDuckGo.resultsURL(for: "ddg app"))
    }

    @Test func rowTapRecordsLastSubmitted() {
        let model = makeModel()

        model.record(model.url(for: .query("swift ui")))
        #expect(model.lastSubmitted == "swift ui")

        let site = Suggestion.match(url: URL(string: "https://www.github.com/apple")!, title: "Apple")
        model.record(model.url(for: site))
        #expect(model.lastSubmitted == "github")
    }

    @Test func inlineCompletionPrefersBestRankedHost() async {
        visit("https://github.com/apple", "Apple on GitHub", times: 3)
        visit("https://google.com/", "Google")
        visit("https://www.gmail.com/", "Gmail", times: 2)
        let model = makeModel()
        let expected: [(typed: String, completed: String?)] = [
            ("g", "github.com"), ("goo", "google.com"), ("GM", "GMail.com"), ("www.gm", nil), ("g h", nil), ("", nil),
            ("x", nil),
        ]
        for (typed, completed) in expected {
            StubSuggestProtocol.answer(typed, with: #"["\#(typed)",[],[]]"#)
            model.text = typed
            model.textChanged(appending: true)
            #expect(model.completedText == completed)
        }
        await model.fetchTask?.value
    }

    @Test func deletionDoesNotRecomplete() {
        visit("https://github.com/apple", "Apple on GitHub")
        StubSuggestProtocol.answer("g", with: #"["g",[],[]]"#)
        StubSuggestProtocol.answer("gi", with: #"["gi",[],[]]"#)
        let model = makeModel()
        let github = Suggestion.match(url: URL(string: "https://github.com/apple")!, title: "Apple on GitHub")

        model.text = "g"
        model.textChanged(appending: true)
        #expect(model.completedText == "github.com")
        #expect(model.rows.prefix(2) == [github, .query("g")])
        #expect(model.submit() == URL(string: "https://github.com"))

        model.text = "g"
        model.textChanged(appending: false)
        #expect(model.completedText == nil)
        #expect(model.rows.first == .query("g"))
        #expect(model.submit() == SearchEngine.google.resultsURL(for: "g"))

        model.text = "gi"
        model.textChanged(appending: true)
        #expect(model.completedText == "github.com")
    }

    @Test func whitespaceOnlySubmitReturnsNil() {
        let model = makeModel()
        model.text = " \n\t "
        #expect(model.submit() == nil)

        model.text = " github.com "
        #expect(model.submit() == URL(string: "https://github.com"))
        #expect(model.url(for: .query("c++ tips")) == SearchEngine.google.resultsURL(for: "c++ tips"))
        #expect(model.url(for: .site(url: URL(string: "https://a.com/")!, title: "A")) == URL(string: "https://a.com/"))
    }
}
