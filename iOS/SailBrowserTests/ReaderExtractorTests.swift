import Testing
import WebKit
@testable import SailBrowser

final class ReaderFixtures {
    static func html(_ name: String) throws -> String {
        let url = try #require(Bundle(for: ReaderFixtures.self).url(forResource: name, withExtension: "html"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func dataURL(_ name: String) throws -> URL {
        URL(string: "data:text/html;base64," + Data(try html(name).utf8).base64EncodedString())!
    }
}

final class LoadWatcher: NSObject, WKNavigationDelegate {
    private(set) var finished = false

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
    }
}

func loadedFixture(_ name: String) async throws -> WKWebView {
    let webView = WKWebView()
    let watcher = LoadWatcher()
    webView.navigationDelegate = watcher
    webView.loadHTMLString(try ReaderFixtures.html(name), baseURL: URL(string: "https://example.test/article"))
    try await waitUntil(timeout: .seconds(15)) { watcher.finished }
    return webView
}

@Suite(.serialized)
struct ReaderExtractorTests {
    // Mozilla's test page 001 and its expected metadata (mozilla/readability test/test-pages/001 at 0.6.0).
    @Test func anArticleIsReaderableAndGivesItsTitleBylineAndText() async throws {
        let webView = try await loadedFixture("readability-001")
        #expect(await ReaderExtractor.isReaderable(in: webView))

        let article = try #require(try await ReaderExtractor.article(in: webView))
        #expect(article.title == "Get your Frontend JavaScript Code Covered | Code")
        #expect(article.byline == "Nicolas Perriault")
        #expect(article.lang == "en")
        #expect(article.dir == nil)
        #expect(article.html.contains("The idea behind code coverage is to record which parts of your code"))
    }

    @Test func aFormWithNoProseIsNotReaderable() async throws {
        let webView = try await loadedFixture("app-form")
        #expect(!(await ReaderExtractor.isReaderable(in: webView)))
    }

    // The extraction works on a clone in its own world: the page keeps every node and never sees the library.
    @Test func extractionLeavesTheLivePageUntouched() async throws {
        let webView = try await loadedFixture("readability-001")
        let count = "return document.getElementsByTagName('*').length"
        let before = try #require(try await webView.callAsyncJavaScript(count, contentWorld: .page) as? Int)

        _ = try await ReaderExtractor.article(in: webView)

        #expect(try await webView.callAsyncJavaScript(count, contentWorld: .page) as? Int == before)
        let seen = "return typeof Readability + typeof isProbablyReaderable"
        #expect(try await webView.callAsyncJavaScript(seen, contentWorld: .page) as? String == "undefinedundefined")
    }
}
