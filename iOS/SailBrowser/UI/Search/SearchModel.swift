import Foundation
import os

@Observable final class SearchModel {
    private static let topSiteLimit = 8
    nonisolated private static let historyMatchLimit = 4
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "search")

    var text = ""
    private(set) var completedText: String?
    private(set) var rows: [Suggestion]
    private(set) var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var completion: HistoryEntry?
    @ObservationIgnored private var lastRemote: [String] = []
    @ObservationIgnored private var lastMatches: [HistoryEntry] = []
    @ObservationIgnored private var previousQuery = ""
    @ObservationIgnored private var openedOver: URL?

    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let service: SuggestionService
    @ObservationIgnored private let engine: () -> SearchEngine

    init(history: HistoryStore, service: SuggestionService, engine: @escaping () -> SearchEngine) {
        self.history = history
        self.service = service
        self.engine = engine
        rows = SuggestionRanker.topSites(history.entries, excluding: nil, limit: Self.topSiteLimit)
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Every open starts a new tab, so the field rises empty; the page the sheet rises over stays out of its rows.
    func prepareForOpen(over page: URL?) {
        openedOver = page
        lastRemote = []
        lastMatches = []
        text = ""
        textChanged(appending: false)
    }

    func textChanged(appending: Bool) {
        complete(appending: appending)
        rank()
    }

    // The inline completion alone, for the keystroke's own turn; rank() follows on a later one.
    func complete(appending: Bool) {
        completion = appending ? SuggestionRanker.completion(history.searchKeys, typed: text) : nil
        completedText = completion.map { text + SuggestionRanker.bareHost($0.url).dropFirst(text.count) }
    }

    func rank() {
        fetchTask?.cancel()
        let query = trimmedText
        let completion = completion
        guard !query.isEmpty else {
            previousQuery = ""
            lastMatches = []
            fetchTask = nil
            rows = SuggestionRanker.topSites(history.entries, excluding: openedOver, limit: Self.topSiteLimit)
            return
        }
        let carried = lastRemote.filter {
            $0.range(of: query, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
        }
        // The list never thins between keystrokes (four rows stay on "w"): when no earlier answer still matches,
        // the earlier rows stay under the new ones, up to the earlier count, until this query's own answer lands.
        let earlier = rows.filter { $0 != .query(previousQuery) }
        let kept = carried.isEmpty && !previousQuery.isEmpty ? rows.count : 0
        func shown(_ matches: [HistoryEntry]) -> [Suggestion] {
            let merged = SuggestionRanker.merge(query: query, completion: completion, history: matches, remote: carried)
            return merged + earlier.filter { !merged.contains($0) }.prefix(max(0, kept - merged.count))
        }
        rows = shown(lastMatches)
        previousQuery = query
        let engine = engine()
        fetchTask = Task { [service, keys = history.searchKeys] in
            // The scan of the whole history runs off the main actor, out of the keystroke's frame; its rows land on
            // the next turn, ride under the engine's answer and seed the next keystroke's turn until its own scan.
            let matches = await Self.historyMatches(keys, query: query)
            guard !Task.isCancelled else { return }
            lastMatches = matches
            rows = shown(matches)
            do {
                let response = try await service.suggestions(for: query, engine: engine)
                guard response.query == trimmedText else { return }
                lastRemote = response.suggestions
                rows = SuggestionRanker.merge(
                    query: query, completion: completion, history: matches, remote: response.suggestions)
            } catch {
                guard !Task.isCancelled else { return }
                Self.logger.info("Suggest request failed: \(error, privacy: .public)")
                // No answer is coming, so the rows held for it give way to the query's own.
                guard query == trimmedText else { return }
                rows = SuggestionRanker.merge(query: query, completion: completion, history: matches, remote: carried)
            }
        }
    }

    @concurrent private static func historyMatches(_ keys: [HistorySearchKey], query: String) async -> [HistoryEntry] {
        SuggestionRanker.historyMatches(keys, query: query, limit: historyMatchLimit)
    }

    // Only the empty field's rows are recents (.site). A removal takes that page only; the list they sit in is the top
    // sites again.
    func removeRecent(_ url: URL) {
        history.remove(url: url)
        rows = SuggestionRanker.topSites(history.entries, excluding: openedOver, limit: Self.topSiteLimit)
    }

    func submit() -> URL? {
        InputResolver.resolve(completedText ?? text, engine: engine())
    }

    func url(for suggestion: Suggestion) -> URL {
        switch suggestion {
        case .site(let url, _), .match(let url, _): url
        case .query(let query): engine().resultsURL(for: query)
        }
    }
}
