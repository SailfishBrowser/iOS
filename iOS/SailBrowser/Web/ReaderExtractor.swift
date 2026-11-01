import WebKit
import os

nonisolated struct ReaderArticle: Equatable, Sendable {
    let title: String
    let byline: String?
    let html: String
    let text: String
    let lang: String?
    let dir: String?
}

// A page's title, text and language, read for a summary of the page at that URL.
nonisolated struct PageContent: Equatable, Sendable {
    let url: URL
    let title: String
    let text: String
    let language: Locale.Language?
}

// Mozilla's Readability, run in a world of its own so the page can neither see nor tamper with it, on a clone of the
// document so the live page is untouched.
enum ReaderExtractor {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "reader")
    private static let world = WKContentWorld.world(name: "reader")
    private static let readerable = script("Readability-readerable-0.6.0")
    private static let readability = script("Readability-0.6.0")
    // The article's text with a line after each block, which textContent runs together; parsed inert, so nothing loads.
    private static let articleText = """
        const articleText = html => {
          const body = new DOMParser().parseFromString(html, 'text/html').body;
          body.querySelectorAll('p, li, h1, h2, h3, h4, h5, h6, blockquote, pre, figcaption, tr, dt, dd, br')
            .forEach(element => element.after('\\n'));
          return body.textContent;
        };
        """

    static func isReaderable(in webView: WKWebView) async -> Bool {
        do {
            let result = try await webView.callAsyncJavaScript(
                readerable + "\nreturn isProbablyReaderable(document)", contentWorld: world)
            return result as! Bool
        } catch {
            logger.error("Readable check failed: \(error, privacy: .public)")
            return false
        }
    }

    static func article(in webView: WKWebView) async throws -> ReaderArticle? {
        let result = try await webView.callAsyncJavaScript(
            readability + "\n" + articleText + "\n" + """
                const article = new Readability(document.cloneNode(true)).parse();
                return article && { ...article, text: articleText(article.content) };
                """, contentWorld: world)
        guard let parsed = result as? [String: Any] else { return nil }
        return ReaderArticle(
            title: parsed["title"] as! String, byline: parsed["byline"] as? String, html: parsed["content"] as! String,
            text: parsed["text"] as! String, lang: parsed["lang"] as? String, dir: parsed["dir"] as? String)
    }

    // The article Readability finds on its clone, else what the live page shows, as on a search results page: a
    // detached clone has no layout, so no innerText. Reading the live document changes nothing on it.
    static func content(in webView: WKWebView) async throws -> PageContent {
        let url = webView.url!
        let result = try await webView.callAsyncJavaScript(
            readability + "\n" + articleText + "\n" + """
                const article = new Readability(document.cloneNode(true)).parse();
                const text = article ? articleText(article.content) : '';
                if (text.trim()) return { title: article.title || document.title, text, lang: article.lang || '' };
                return { title: document.title, text: document.body ? document.body.innerText : '',
                  lang: document.documentElement.lang };
                """, contentWorld: world) as! [String: String]
        return content(url: url, title: result["title"]!, text: result["text"]!, lang: result["lang"]!)
    }

    // The reader's own article, so Readability does not run a second time.
    static func content(of article: ReaderArticle, at url: URL) -> PageContent {
        content(url: url, title: article.title, text: article.text, lang: article.lang ?? "")
    }

    // A page that names no language reads as the language its text reads as, through the translator's recognizer.
    private static func content(url: URL, title: String, text: String, lang: String) -> PageContent {
        let text = collapsed(text)
        let language = lang.isEmpty
            ? PageTranslator.recognizedLanguage(String(text.prefix(Theme.Translate.sampleLength)))
            : Locale.Language(identifier: lang)
        return PageContent(url: url, title: title, text: text, language: language)
    }

    // Runs of spaces become one space and runs of lines one line.
    nonisolated static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func script(_ name: String) -> String {
        try! String(contentsOf: Bundle.main.url(forResource: name, withExtension: "js")!, encoding: .utf8)
    }
}
