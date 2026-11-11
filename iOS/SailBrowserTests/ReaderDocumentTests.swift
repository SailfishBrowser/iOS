import Testing
import UIKit
@testable import SailBrowser

struct ReaderDocumentTests {
    private static let large = UITraitCollection(preferredContentSizeCategory: .large)

    @Test func theShellCarriesThePolicyTheStylesheetAndEscapedText() {
        let article = ReaderArticle(
            title: "A <b>&</b>", byline: "By \"Q\"", html: "<p>Body</p>", text: "Body", lang: "fr", dir: "rtl")
        let document = ReaderController.document(for: article, traits: Self.large)
        #expect(document.contains(
            #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'">"#))
        #expect(document.contains("<style>\(ReaderController.stylesheet(compatibleWith: Self.large))</style>"))
        #expect(document.contains("<title>A &lt;b&gt;&amp;&lt;/b&gt;</title>"))
        #expect(document.contains("By &quot;Q&quot;"))
        #expect(document.contains(#"<html lang="fr" dir="rtl">"#))
        #expect(document.contains("<p>Body</p>"))
        #expect(document.range(of: "Content-Security-Policy")!.lowerBound < document.range(of: "<p>Body</p>")!.lowerBound)
    }

    @Test func aLongTitleIsEscapedWhole() {
        let title = String(repeating: "<b>&", count: 25_000)
        let article = ReaderArticle(title: title, byline: nil, html: "<p>Body</p>", text: "Body", lang: nil, dir: nil)
        let document = ReaderController.document(for: article, traits: Self.large)
        let shown = document.split(separator: "<title>")[1].split(separator: "</title>")[0]
        #expect(!shown.contains("<"))
        #expect(String(shown) == String(repeating: "&lt;b&gt;&amp;", count: 25_000))
        #expect(document.contains("<h1>\(shown)</h1>"))
    }

    // The article's type is its measured size at the default text size and follows the user's over the whole range.
    @Test func theTypeFollowsTheTextSize() {
        let atLarge = ReaderController.stylesheet(compatibleWith: Self.large)
        #expect(atLarge.contains("400 19px ui-serif"))
        #expect(atLarge.contains("700 28px ui-serif"))
        let largest = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let body = 19 * UIFont.preferredFont(forTextStyle: .body, compatibleWith: largest).pointSize / 17
        #expect(body > 19)
        #expect(ReaderController.stylesheet(compatibleWith: largest).contains("400 \(Int(body.rounded()))px ui-serif"))
    }
}
