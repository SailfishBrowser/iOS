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

    @Test func aFreshInstallOpensOnAnEmptyList() {
        let model = makeModel()

        #expect(model.prepareForOpen(over: nil).text == "")
        #expect(model.rows.isEmpty)
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

    // With more recents than show, a removal brings the next one into the last slot and keeps the others as they were,
    // so the rows below only move up and one row comes in.
    @Test func removingARecentBringsTheNextOneIn() {
        for name in ["e", "d", "c", "b", "a"] {
            visit("https://\(name).com/", name)
        }
        let site = { (name: String) in Suggestion.site(url: URL(string: "https://\(name).com/")!, title: name) }
        let model = makeModel()
        #expect(Array(model.rows.prefix(Theme.Metrics.suggestionRowCount)) == ["a", "b", "c", "d"].map(site))

        model.removeRecent(URL(string: "https://a.com/")!)

        #expect(Array(model.rows.prefix(Theme.Metrics.suggestionRowCount)) == ["b", "c", "d", "e"].map(site))
    }

    @Test func staleSuggestionResponseIsDropped() async {
        StubSuggestProtocol.answer("swift", with: #"["sw",["swift","swiftui","swift playgrounds"],[]]"#)
        let model = makeModel()

        model.text = "swift"
        model.textChanged(appending: true)
        await model.fetchTask?.value

        #expect(model.rows == [.query("swift")])
    }

    // The history scan runs off the main actor in the fetch task: the keystroke's own turn shows the query, the
    // matches follow on the next, ahead of the engine's answer.
    @Test func historyMatchesFollowTheKeystrokeFromOffTheMainActor() async {
        visit("https://developer.apple.com/metal/", "Metal Tips", times: 3)
        StubSuggestProtocol.answer("metal", with: #"["metal",[],[]]"#)
        let model = makeModel()
        let site = Suggestion.match(url: URL(string: "https://developer.apple.com/metal/")!, title: "Metal Tips")

        model.text = "metal"
        model.textChanged(appending: true)
        #expect(model.rows == [.query("metal")])
        await model.fetchTask?.value
        #expect(model.rows == [.query("metal"), site])
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

    @Test func keystrokeKeepsTheLastRemoteRowsThatStillMatchUntilItsOwnAnswerArrives() async {
        StubSuggestProtocol.answer("go", with: #"["go",["google","gopro","google maps"],[]]"#)
        StubSuggestProtocol.answer("goo", with: #"["goo",["google","goodreads"],[]]"#)
        let model = makeModel()
        model.text = "go"
        model.textChanged(appending: true)
        await model.fetchTask?.value
        #expect(model.rows == [.query("go"), .query("google"), .query("gopro"), .query("google maps")])

        model.text = "goo"
        model.textChanged(appending: true)
        #expect(model.rows == [.query("goo"), .query("google"), .query("google maps")])
        await model.fetchTask?.value
        #expect(model.rows == [.query("goo"), .query("google"), .query("goodreads")])
    }

    // Four rows stay on "w"; the list once dropped to the query alone for a frame when no carried row still
    // matched. The earlier rows stay under the new query until its own answer lands.
    @Test func aKeystrokeThatWouldLeaveOnlyTheQueryKeepsTheEarlierRowsUntilItsAnswer() async {
        StubSuggestProtocol.answer("a", with: #"["a",["amazon","amazon prime","airbnb"],[]]"#)
        StubSuggestProtocol.answer("aw", with: #"["aw",["aws","away luggage"],[]]"#)
        let model = makeModel()
        model.text = "a"
        model.textChanged(appending: true)
        await model.fetchTask?.value
        #expect(model.rows == [.query("a"), .query("amazon"), .query("amazon prime"), .query("airbnb")])

        model.text = "aw"
        model.textChanged(appending: true)
        #expect(model.rows == [.query("aw"), .query("amazon"), .query("amazon prime"), .query("airbnb")])
        await model.fetchTask?.value
        #expect(model.rows == [.query("aw"), .query("aws"), .query("away luggage")])
    }

    @Test func aKeystrokeWithAHistoryMatchButNoCarriedAnswerKeepsTheEarlierCount() async {
        visit("https://www.google.com/search?q=aw", "aw - Google Search")
        StubSuggestProtocol.answer("a", with: #"["a",["amazon","amazon prime","airbnb"],[]]"#)
        let model = makeModel()
        model.text = "a"
        model.textChanged(appending: true)
        await model.fetchTask?.value
        let before = model.rows.count

        model.text = "aw"
        model.textChanged(appending: true)
        #expect(model.rows.first == .query("aw"))
        #expect(model.rows.count == before)
        #expect(!model.rows.contains(.query("a")))
    }

    // A match row shown on the last keystroke stays on the next one's own turn, as a carried remote row does, until
    // its scan lands: dropped for that turn it would blink out and the rows under it would shift up and back down.
    // A cleared field starts over: its first keystroke seeds nothing.
    @Test func aKeystrokeKeepsTheLastScansMatchRowsUntilItsOwnScanLands() async {
        visit("https://docs.vapor.codes/", "Vapor Docs", times: 3)
        StubSuggestProtocol.answer("vap", with: #"["vap",["vapor","vape"],[]]"#)
        StubSuggestProtocol.answer("vapo", with: #"["vapo",["vapor"],[]]"#)
        StubSuggestProtocol.answer("zz", with: #"["zz",[],[]]"#)
        let model = makeModel()
        let site = Suggestion.match(url: URL(string: "https://docs.vapor.codes/")!, title: "Vapor Docs")
        model.text = "vap"
        model.textChanged(appending: true)
        await model.fetchTask?.value
        #expect(model.rows == [.query("vap"), site, .query("vapor"), .query("vape")])

        model.text = "vapo"
        model.textChanged(appending: true)
        #expect(model.rows == [.query("vapo"), site, .query("vapor")])
        await model.fetchTask?.value
        #expect(model.rows == [.query("vapo"), site, .query("vapor")])

        model.text = ""
        model.textChanged(appending: false)
        model.text = "zz"
        model.textChanged(appending: true)
        #expect(model.rows == [.query("zz")])
        await model.fetchTask?.value
    }

    // A keystroke that reaches the field without the edit callback (a paste, the system's own text input) is not
    // marked as appending; the list still keeps its earlier rows.
    @Test func anEditNotMarkedAsAppendingKeepsTheEarlierRowsToo() async {
        StubSuggestProtocol.answer("a", with: #"["a",["amazon","amazon prime","airbnb"],[]]"#)
        let model = makeModel()
        model.text = "a"
        model.textChanged(appending: true)
        await model.fetchTask?.value

        model.text = "aw"
        model.textChanged(appending: false)
        #expect(model.rows == [.query("aw"), .query("amazon"), .query("amazon prime"), .query("airbnb")])
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

    // Low Data Mode fails the fetch at once: the local rows stand. The session flag that makes it fail is pinned in
    // SuggestionServiceTests.defaultSessionIsCookielessAndSkipsLowDataMode; a clock bound here would time the main
    // actor's hop, not the path.
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

struct SheetDragTests {
    @Test func closesWhileArmedOrPredictedPastTwoHundred() {
        #expect(SheetDrag.closes(armed: true, translation: 81, velocity: -1000))
        #expect(!SheetDrag.closes(armed: false, translation: 60, velocity: 0))
        #expect(SheetDrag.closes(armed: false, translation: 0, velocity: 500))
        #expect(!SheetDrag.closes(armed: false, translation: 50, velocity: 200))
    }

    @Test func releaseVelocityIsAFractionOfTheRemainingTravel() {
        #expect(SheetDrag.releaseVelocity(1500, toward: 500) == 3)
        #expect(SheetDrag.releaseVelocity(300, toward: -60) == -5)
        #expect(SheetDrag.releaseVelocity(-200, toward: -100) == 2)
        #expect(SheetDrag.releaseVelocity(800, toward: 0) == 0)
    }

    @Test func offsetFollowsDownAndStretchesUpUnderTheLimit() {
        #expect(SheetDrag.offset(translation: 42) == 42)
        let up = SheetDrag.offset(translation: -30)
        #expect(up < 0 && up > -30)
        #expect(abs(up - Magnet.rubberBand(-30, stretch: Theme.Gesture.sheetStretch)) < 1e-9)
        #expect(SheetDrag.offset(translation: -10_000) > -Theme.Gesture.sheetStretch)
    }
}
