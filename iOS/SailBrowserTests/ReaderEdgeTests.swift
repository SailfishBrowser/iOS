import Testing
import UIKit
import WebKit
@testable import SailBrowser

@Suite(.serialized)
struct ReaderEdgeTests {
    private static let pixel = "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
    // Readability's readerable check looks at each paragraph alone, so a hidden wrapper hides nothing from it; its
    // parse drops hidden nodes and keeps nothing.
    private static let hiddenArticle = """
        <!doctype html><html><head><title>Hidden</title></head><body><div hidden>\
        <p>\(String(repeating: "Hidden prose. ", count: 40))</p><p>\(String(repeating: "More of it. ", count: 40))</p>\
        </div></body></html>
        """

    // A page the readerable check passes and the parse finds no article on: the row offered the reader, nothing opens,
    // and the row disables until the next route or finish checks the page again.
    @Test func aReadablePageWithNoArticleDisablesTheRow() async throws {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        let env = makeEnvironment()
        await loadAndFinish(controller, html: Self.hiddenArticle, base: "https://example.test/hidden")
        try await waitUntil { controller.isReaderable }
        #expect(MenuRow.reader(controller, env: env).isEnabled)

        await controller.openReader(ruleLists: [])

        #expect(controller.readerArticle == nil)
        #expect(!controller.reader.isOpen)
        #expect(!controller.isReaderable)
        #expect(!MenuRow.reader(controller, env: env).isEnabled)
    }

    // The Theme's reader tokens are the one source of the reader's type; reader.css takes them at load.
    @Test func theReaderTokensArePinned() {
        #expect(Theme.Typography.readerBody == WebFont(family: "ui-serif", size: 19, weight: 400))
        #expect(Theme.Typography.readerTitle == WebFont(family: "ui-serif", size: 28, weight: 700))
        #expect(Theme.Metrics.readerMeasure == 640)
        #expect(Theme.Metrics.readerInset == 20)
    }

    // What the article may load under the policy: images over https or inline, nothing else. A javascript: link runs
    // nothing and opens nothing; an http: image, a frame and a video never reach the network.
    @Test(.timeLimit(.minutes(1))) func theArticleLoadsOnlyWhatThePolicyAllows() async throws {
        let server = try await LocalPageServer { _ in "<p>frame</p>" }
        let (reader, window) = shownReader()
        defer { window.isHidden = true }
        let opened = Recorded<URL>()
        reader.onOpen = { opened.values.append($0) }
        let article = ReaderArticle(
            title: "Policy", byline: nil,
            html: """
                <a id="js" href="javascript:document.title='ran'">Run</a> <a id="note" href="#note-1">1</a>\
                <img id="http" src="\(server.url("/pixel.gif"))">\
                <img id="data" src="data:image/gif;base64,\(Self.pixel)">\
                <iframe src="\(server.url("/page-frame"))"></iframe>\
                <video src="\(server.url("/clip.mp4"))"></video>
                """,
            lang: nil, dir: nil)
        reader.present(article, baseURL: URL(string: "https://example.test/a"), zoom: 1, insets: .zero, ruleLists: [])
        let page = try #require(reader.page)
        try await waitUntil { !page.isLoading && page.title == "Policy" }

        let widths = try await page.callAsyncJavaScript(
            "return ['http', 'data'].map(id => document.getElementById(id).naturalWidth)", contentWorld: .defaultClient)
        #expect(widths as? [Int] == [0, 1])
        // MEDIA_ERR_SRC_NOT_SUPPORTED: the source was refused before any request.
        try await waitUntilScript(page, "return document.querySelector('video').error?.code === 4")
        #expect(server.requestedPaths.isEmpty)

        _ = try await page.callAsyncJavaScript("document.getElementById('js').click()", contentWorld: .defaultClient)
        _ = try await page.callAsyncJavaScript("document.getElementById('note').click()", contentWorld: .defaultClient)
        try await waitUntil { page.url?.fragment == "note-1" }
        #expect(opened.values.isEmpty)
        #expect(page.title == "Policy")
    }

    // Readability writes every link absolute, so a <base> left in an article has nothing to move: a link opens where
    // it points, and the reader's own page stays where it was loaded.
    @Test func aBaseInTheArticleMovesNoLink() async throws {
        let (reader, window) = shownReader()
        defer { window.isHidden = true }
        let opened = Recorded<URL>()
        reader.onOpen = { opened.values.append($0) }
        let article = ReaderArticle(
            title: "Base", byline: nil,
            html: #"<base href="https://elsewhere.test/dir/"><p>Text</p>"#
                + #"<a id="out" href="https://example.test/next">Next</a>"#,
            lang: nil, dir: nil)
        reader.present(article, baseURL: URL(string: "https://example.test/a"), zoom: 1, insets: .zero, ruleLists: [])
        let page = try #require(reader.page)
        try await waitUntil { !page.isLoading && page.title == "Base" }

        _ = try await page.callAsyncJavaScript("document.getElementById('out').click()", contentWorld: .defaultClient)
        try await waitUntil { !opened.values.isEmpty }
        #expect(opened.values == [URL(string: "https://example.test/next")!])
        #expect(page.url?.absoluteString == "https://example.test/a")
    }

    // The tab's process going away reloads its page on screen; the reload's start closes the reader as any navigation
    // does, and its finish checks the page again.
    @Test func aProcessTerminationUnderTheReaderClosesIt() async throws {
        let html = try ReaderFixtures.html("readability-001")
        let server = try await LocalPageServer { _ in html }
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        controller.webView.frame = window.bounds
        window.addSubview(controller.webView)
        window.makeKeyAndVisible()
        await finishLoading(controller, server.url("/page-article"))
        await controller.openReader(ruleLists: [])
        #expect(controller.readerArticle != nil)

        controller.webViewWebContentProcessDidTerminate(controller.webView)
        try await waitUntil { controller.readerArticle == nil }
        #expect(!controller.reader.isOpen)
        try await waitUntil { server.requestedPaths.filter { $0 == "/page-article" }.count == 2 }
        try await waitUntil { controller.isReaderable }
    }

    // The article's own process going away leaves nothing to show: the reader closes as a drag would, and the tab is
    // back on its page.
    @Test func aProcessTerminationOfTheReaderClosesIt() async throws {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        await loadAndFinish(
            controller, html: try ReaderFixtures.html("readability-001"), base: "https://example.test/a")
        await controller.openReader(ruleLists: [])
        let page = try #require(controller.reader.page)
        #expect(controller.readerArticle != nil)

        controller.reader.webViewWebContentProcessDidTerminate(page)

        #expect(!controller.reader.isOpen)
        #expect(controller.readerArticle == nil)
    }

    // An evicted tab takes its reader with it: nothing keeps the reader or its page.
    @Test func anEvictedTabReleasesItsReadersPage() async throws {
        let pool = WebViewPool(
            capacity: 1, blocker: ContentBlocker(categories: Set(BlockingCategory.allCases)),
            sessions: SessionStore(directories: .temporary()), haptics: recordingHaptics())
        weak var reader: ReaderController?
        weak var page: WKWebView?
        do {
            let controller = pool.controller(for: tab())
            try await waitUntil { controller.hasSettled }
            await loadAndFinish(
                controller, html: try ReaderFixtures.html("readability-001"), base: "https://example.test/a")
            await controller.openReader(ruleLists: [])
            reader = controller.reader
            page = controller.reader.page
            try await waitUntil { page?.isLoading == false }
        }
        #expect(reader != nil && page != nil)

        _ = pool.controller(for: tab())
        try await waitUntil { reader == nil && page == nil }
    }

    @Test(.timeLimit(.minutes(1))) func aLongArticleLoadsWhole() async throws {
        let (reader, window) = shownReader()
        defer { window.isHidden = true }
        let paragraph = "<p>\(String(repeating: "Long prose. ", count: 83))</p>"
        let article = ReaderArticle(
            title: "Long", byline: nil, html: String(repeating: paragraph, count: 5_000), lang: nil, dir: nil)
        #expect(article.html.utf8.count > 5_000_000)
        reader.present(article, baseURL: URL(string: "https://example.test/a"), zoom: 1, insets: .zero, ruleLists: [])
        let page = try #require(reader.page)
        try await waitUntil(timeout: .seconds(30)) { !page.isLoading && page.title == "Long" }
        let count = try await page.callAsyncJavaScript(
            "return document.querySelectorAll('article p').length", contentWorld: .defaultClient)
        #expect(count as? Int == 5_000)
    }

    @Test func aLongTitleIsEscapedWhole() {
        let title = String(repeating: "<b>&", count: 25_000)
        let article = ReaderArticle(title: title, byline: nil, html: "<p>Body</p>", lang: nil, dir: nil)
        let document = ReaderController.document(for: article)
        let shown = document.split(separator: "<title>")[1].split(separator: "</title>")[0]
        #expect(!shown.contains("<"))
        #expect(String(shown) == String(repeating: "&lt;b&gt;&amp;", count: 25_000))
        #expect(document.contains("<h1>\(shown)</h1>"))
    }

    private func tab() -> Tab {
        Tab(
            id: UUID(), url: URL(string: "about:blank")!, title: "", isPinned: false, prefersDesktop: false,
            createdAt: .now, lastActiveAt: .now, tint: nil)
    }

    private func shownReader() -> (ReaderController, UIWindow) {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let reader = ReaderController(haptics: recordingHaptics())
        window.rootViewController = reader
        window.makeKeyAndVisible()
        return (reader, window)
    }

    private func finishLoading(_ controller: WebTabController, _ url: URL) async {
        await withCheckedContinuation { continuation in
            controller.onFinish = { _, _ in
                controller.onFinish = nil
                continuation.resume()
            }
            controller.load(url)
        }
    }

    // Until the script answers true in the page, within the usual wait.
    private func waitUntilScript(_ page: WKWebView, _ script: String) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try await page.callAsyncJavaScript(script, contentWorld: .defaultClient) as? Bool != true {
            guard ContinuousClock.now < deadline else { throw WaitTimedOut() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
