import Foundation
import Testing
@testable import SailBrowser

struct InputResolverTests {
    private func query(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
    }

    private func isSearch(_ url: URL?) -> Bool {
        url?.host() == "www.google.com" && url?.path() == "/search"
    }

    @Test func searchQueryEncodesPlusAmpersandHashAndUnicode() {
        let text = "c++ & c# 100% café"
        let url = SearchEngine.google.resultsURL(for: text)
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""

        #expect(url.absoluteString.hasPrefix("https://www.google.com/search?q="))
        #expect(query(url) == text)
        #expect(!raw.contains("+"))
        for encoded in ["%2B%2B", "%26", "%23", "%25"] {
            #expect(raw.contains(encoded))
        }
    }

    @Test func resolvesHostsPortsAndIPsButSearchesSentences() {
        #expect(InputResolver.resolve("localhost:3000", engine: .google)?.absoluteString == "http://localhost:3000")
        #expect(InputResolver.resolve("192.168.1.1", engine: .google)?.absoluteString == "http://192.168.1.1")
        #expect(InputResolver.resolve("Example.COM/Path", engine: .google)?.absoluteString == "https://Example.COM/Path")
        #expect(InputResolver.resolve("about:blank", engine: .google)?.absoluteString == "about:blank")

        let sentence = InputResolver.resolve("swift.org is great", engine: .google)
        #expect(isSearch(sentence))
        #expect(sentence.flatMap(query) == "swift.org is great")
        #expect(InputResolver.resolve("   ", engine: .google) == nil)
    }

    @Test func trimsAndClassifiesEdgeInputs() {
        #expect(InputResolver.resolve("  https://swift.org/x?a=1  ", engine: .google)?.absoluteString == "https://swift.org/x?a=1")
        #expect(InputResolver.resolve("localhost", engine: .google)?.absoluteString == "http://localhost")
        #expect(InputResolver.resolve("10.0.0.2:8080/admin", engine: .google)?.absoluteString == "http://10.0.0.2:8080/admin")
        #expect(InputResolver.resolve("news.bbc.co.uk", engine: .google)?.absoluteString == "https://news.bbc.co.uk")
        #expect(isSearch(InputResolver.resolve("999.1.1.1", engine: .google)))
        #expect(isSearch(InputResolver.resolve("version1.2", engine: .google)))
        #expect(isSearch(InputResolver.resolve("swift", engine: .google)))
        #expect(isSearch(InputResolver.resolve("mailto:a@b.com", engine: .google)))
        #expect(InputResolver.resolve("\n\t", engine: .google) == nil)
    }

    @Test func searchesFileSchemeButPassesWebSchemesThrough() {
        let file = InputResolver.resolve("file:///etc/passwd", engine: .google)
        #expect(isSearch(file))
        #expect(file.flatMap(query) == "file:///etc/passwd")
        #expect(isSearch(InputResolver.resolve("FILE:///private/var/mobile", engine: .google)))

        #expect(InputResolver.resolve("http://example.com", engine: .google)?.absoluteString == "http://example.com")
        #expect(InputResolver.resolve("https://example.com", engine: .google)?.absoluteString == "https://example.com")
        #expect(InputResolver.resolve("about:blank", engine: .google)?.absoluteString == "about:blank")
        #expect(InputResolver.resolve("data:text/plain,hi", engine: .google)?.absoluteString == "data:text/plain,hi")
    }
}
