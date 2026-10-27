import Foundation

nonisolated struct SuggestionService: Sendable {
    struct MalformedResponse: Error {}

    // One session for the app's life keeps the connection to the search host warm.
    static let defaultSession = URLSession(configuration: configuration())

    let session: URLSession
    private let language: String
    private let sleep: @Sendable (Duration) async throws -> Void

    // Ephemeral, cookie free, cache free, off in Low Data Mode (the fetch fails at once and the local rows stand).
    static func configuration() -> URLSessionConfiguration {
        SessionConfiguration.cookieless(
            requestTimeout: Theme.Network.suggestTimeout, resourceTimeout: Theme.Network.suggestResourceTimeout)
    }

    init(
        session: URLSession = SuggestionService.defaultSession,
        language: String = Locale.current.language.languageCode?.identifier ?? "en",
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.session = session
        self.language = language
        self.sleep = sleep
    }

    func suggestions(for trimmedQuery: String, engine: SearchEngine) async throws -> (query: String, suggestions: [String]) {
        // The debounce hook, awaited at zero too: a keystroke inside the window cancels the sleeping task before any
        // request. An injected sleep may resume normally after a cancel, so the cancel is checked here.
        try await sleep(Theme.Network.suggestDebounce)
        try Task.checkCancellation()
        let url = engine.suggestionsURL(for: trimmedQuery, language: language)
        let (data, _) = try await session.data(for: URLRequest(url: url, timeoutInterval: Theme.Network.suggestTimeout))
        return try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> (query: String, suggestions: [String]) {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [Any], array.count >= 2,
            let query = array[0] as? String, let suggestions = array[1] as? [String]
        else { throw MalformedResponse() }
        return (query, suggestions)
    }
}
