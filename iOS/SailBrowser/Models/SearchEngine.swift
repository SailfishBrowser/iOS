import Foundation

nonisolated enum SearchEngine: String, Codable, CaseIterable, Sendable {
    case google, duckDuckGo, bing, ecosia, kagi, perplexity

    var name: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        case .ecosia: "Ecosia"
        case .kagi: "Kagi"
        case .perplexity: "Perplexity"
        }
    }

    private var results: (host: String, path: String) {
        switch self {
        case .google: ("www.google.com", "/search")
        case .duckDuckGo: ("duckduckgo.com", "/")
        case .bing: ("www.bing.com", "/search")
        case .ecosia: ("www.ecosia.org", "/search")
        case .kagi: ("kagi.com", "/search")
        case .perplexity: ("www.perplexity.ai", "/search")
        }
    }

    func resultsURL(for query: String) -> URL {
        Self.url(results.host, results.path, ["q": query])
    }

    // Each endpoint is the one in the engine's OpenSearch description, and all answer [query, [suggestions]].
    func suggestionsURL(for query: String, language: String) -> URL {
        switch self {
        // Perplexity publishes no suggestions endpoint, so its field suggests from Google.
        case .google, .perplexity:
            Self.url("suggestqueries.google.com", "/complete/search", [
                "client": "firefox", "ie": "utf-8", "oe": "utf-8", "hl": language, "q": query,
            ])
        case .duckDuckGo: Self.url("duckduckgo.com", "/ac/", ["q": query, "type": "list"])
        case .bing: Self.url("api.bing.com", "/osjson.aspx", ["query": query])
        case .ecosia: Self.url("ac.ecosia.org", "/autocomplete", ["q": query, "type": "list"])
        case .kagi: Self.url("kagisuggest.com", "/api/autosuggest", ["q": query])
        }
    }

    // The query of any engine's results page, whichever engine is chosen now, and Google on any country domain.
    static func query(inResultsURL url: URL) -> String? {
        guard let host = url.host()?.lowercased(),
            allCases.contains(where: { $0.isResultsPage(host: Self.bare(host), path: url.path()) })
        else { return nil }
        // Engines write a space as "+" in their own links.
        let item = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems?.first { $0.name == "q" }
        return item?.value?.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    private func isResultsPage(host: String, path: String) -> Bool {
        switch self {
        case .google: host.hasPrefix("google.") && path == results.path
        // A Perplexity search redirects to /search/new before it gets its own page.
        case .perplexity: host == Self.bare(results.host) && [results.path, results.path + "/new"].contains(path)
        default: host == Self.bare(results.host) && path == results.path
        }
    }

    private static func bare(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func url(_ host: String, _ path: String, _ items: KeyValuePairs<String, String>) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}
