import Testing
@testable import SailBrowser

struct ReaderDocumentTests {
    @Test func theShellCarriesThePolicyTheStylesheetAndEscapedText() {
        let article = ReaderArticle(
            title: "A <b>&</b>", byline: "By \"Q\"", html: "<p>Body</p>", lang: "fr", dir: "rtl")
        let document = ReaderController.document(for: article)
        #expect(document.contains(
            #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'">"#))
        #expect(document.contains("<style>\(ReaderController.stylesheet)</style>"))
        #expect(document.contains("<title>A &lt;b&gt;&amp;&lt;/b&gt;</title>"))
        #expect(document.contains("By &quot;Q&quot;"))
        #expect(document.contains(#"<html lang="fr" dir="rtl">"#))
        #expect(document.contains("<p>Body</p>"))
        #expect(document.range(of: "Content-Security-Policy")!.lowerBound < document.range(of: "<p>Body</p>")!.lowerBound)
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
}
