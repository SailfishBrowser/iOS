import Foundation
import Testing
@testable import SailBrowser

struct TabTransferTests {
    private func urls(_ text: String) -> [String] {
        TabImport.tabs(from: text).map(\.url.absoluteString)
    }

    private func tab(_ url: String, _ title: String, isPrivate: Bool = false) -> Tab {
        Tab(
            id: UUID(), url: URL(string: url)!, title: title, isPinned: false, prefersDesktop: false, createdAt: .now,
            lastActiveAt: .now, tint: nil, isPrivate: isPrivate)
    }

    @Test func aWikipediaParenthesisStaysAndGluedClosersGo() {
        let page = "https://en.wikipedia.org/wiki/Mercury_(planet)"
        #expect(TabImport.tabs(from: "[Mercury](\(page))") == [ImportedTab(url: URL(string: page)!, title: "Mercury")])
        #expect(urls("\(page).") == [page])
        #expect(urls("(see \(page))") == [page])
        #expect(urls("(see https://a.test)") == ["https://a.test"])
        #expect(urls("https://a.test.") == ["https://a.test"])
        #expect(urls("[A](https://a.test)[B](https://b.test)") == ["https://a.test", "https://b.test"])
    }

    @Test func anyTextWithLinksYieldsItsWebLinksInOrderOnce() {
        let text = """
            - https://one.test/\r
            - https://two.test/path?x=1\r
            [{"title":"A","url":"https://a.test/x?utm_source=1"},{"title":"B","url":"https://b.test/"}]
            <a href="https://d.test/">d</a>
            ftp://e.test javascript:alert(1) file:///etc/hosts mailto:a@b.test
            HTTPS://one.test/ https://one.test/
            """
        let all = [
            "https://one.test/", "https://two.test/path?x=1", "https://a.test/x?utm_source=1", "https://b.test/",
            "https://d.test/", "HTTPS://one.test/",
        ]
        #expect(urls(text) == all)
    }

    @Test func anExportRoundTripsWithoutPrivateTabsOrTrackingParameters() {
        let tabs = [
            tab("https://a.test/x?utm_source=1&k=v", " A\nline\r\ntwo "),
            tab("https://p.test/", "Private", isPrivate: true),
            tab("https://b.test/", "B ] bracket"),
            tab("https://c.test/", ""),
        ]
        let text = TabExport.text(tabs)
        #expect(text == "- [A line two](https://a.test/x?k=v)\n- [B \\] bracket](https://b.test/)\n- https://c.test/")
        #expect(
            TabImport.tabs(from: text) == [
                ImportedTab(url: URL(string: "https://a.test/x?k=v")!, title: "A line two"),
                ImportedTab(url: URL(string: "https://b.test/")!, title: "B ] bracket"),
                ImportedTab(url: URL(string: "https://c.test/")!, title: ""),
            ])
        #expect(TabExport.text([tab("https://p.test/", "P", isPrivate: true)]) == "")
        #expect(TabExport.text([]) == "")
    }
}
