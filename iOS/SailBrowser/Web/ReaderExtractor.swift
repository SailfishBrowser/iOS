import WebKit
import os

nonisolated struct ReaderArticle: Equatable, Sendable {
    let title: String
    let byline: String?
    let html: String
    let lang: String?
    let dir: String?
}

// Mozilla's Readability, run in a world of its own so the page can neither see nor tamper with it, on a clone of the
// document so the live page is untouched.
enum ReaderExtractor {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "reader")
    private static let world = WKContentWorld.world(name: "reader")
    private static let readerable = script("Readability-readerable-0.6.0")
    private static let readability = script("Readability-0.6.0")

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
            readability + "\nreturn new Readability(document.cloneNode(true)).parse()", contentWorld: world)
        guard let parsed = result as? [String: Any] else { return nil }
        return ReaderArticle(
            title: parsed["title"] as! String, byline: parsed["byline"] as? String, html: parsed["content"] as! String,
            lang: parsed["lang"] as? String, dir: parsed["dir"] as? String)
    }

    private static func script(_ name: String) -> String {
        try! String(contentsOf: Bundle.main.url(forResource: name, withExtension: "js")!, encoding: .utf8)
    }
}
