import Foundation

nonisolated enum Suggestion: Hashable, Sendable {
    case site(url: URL, title: String)
    case match(url: URL, title: String)
    case query(String)
}

nonisolated struct HistorySearchKey: Sendable {
    let entry: HistoryEntry
    let host: String
    let address: String
    let title: String
    let wordStarts: [String.Index]

    init(_ entry: HistoryEntry) {
        self.entry = entry
        host = SuggestionRanker.bareHost(entry.url)
        // Cut before folding: a title saved before the store capped them would otherwise cost every keystroke.
        address = SuggestionRanker.fold((host + entry.url.path()).prefix(Theme.Text.urlLimit))
        title = SuggestionRanker.fold(entry.title.prefix(Theme.Text.titleLimit))
        wordStarts = SuggestionRanker.wordStarts(in: title)
    }
}

nonisolated enum SuggestionRanker {
    private static let historyRowLimit = 3
    private static let remoteRowLimit = 6

    // Pages, not sites; the page the sheet opens over is left out.
    static func topSites(_ entries: [HistoryEntry], excluding page: URL?, limit: Int) -> [Suggestion] {
        let shown = page?.withoutFragment
        return entries.filter { $0.url.isWebPage && $0.url != shown }.sorted(by: byVisitsThenRecency)
            .prefix(limit)
            .map { .site(url: $0.url, title: $0.title) }
    }

    static func historyMatches(_ keys: [HistorySearchKey], query: String, limit: Int) -> [HistoryEntry] {
        let needle = fold(query)
        return keys.filter(\.entry.url.isWebPage).compactMap { key in rank(key, needle).map { (key.entry, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : byVisitsThenRecency($0.0, $1.0) }
            .prefix(limit)
            .map(\.0)
    }

    static func merge(query: String, completion: HistoryEntry?, history: [HistoryEntry], remote: [String]) -> [Suggestion] {
        let completed = completion.map { [$0] } ?? []
        let rows = history.filter { $0.url != completion?.url }.prefix(historyRowLimit)
        var seen = Set((completed + rows).map { fold($0.title) })
        seen.insert(fold(query))
        let queries = remote.filter { seen.insert(fold($0)).inserted }.prefix(remoteRowLimit)
        return completed.map(match) + [.query(query)] + rows.map(match) + queries.map { .query($0) }
    }

    static func completion(_ keys: [HistorySearchKey], typed: String) -> HistoryEntry? {
        let needle = fold(typed)
        guard !needle.isEmpty, !needle.contains(where: \.isWhitespace) else { return nil }
        return keys.filter { $0.host.hasPrefix(needle) }.map(\.entry).min(by: byVisitsThenRecency)
    }

    static func bareHost(_ url: URL) -> String {
        let host = url.host()?.lowercased() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func match(_ entry: HistoryEntry) -> Suggestion {
        .match(url: entry.url, title: entry.title)
    }

    private static func rank(_ key: HistorySearchKey, _ needle: String) -> Int? {
        if key.address.hasPrefix(needle) {
            return 0
        }
        let inTitle = key.title.contains(needle)
        guard inTitle || key.address.contains(needle) else { return nil }
        if inTitle, key.wordStarts.contains(where: { key.title[$0...].hasPrefix(needle) }) {
            return 1
        }
        return 2
    }

    fileprivate static func wordStarts(in text: String) -> [String.Index] {
        var previous: Character = " "
        return text.indices.filter { index in
            defer { previous = text[index] }
            return isWordCharacter(text[index]) && !isWordCharacter(previous)
        }
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func byVisitsThenRecency(_ a: HistoryEntry, _ b: HistoryEntry) -> Bool {
        a.visitCount != b.visitCount ? a.visitCount > b.visitCount : a.lastVisit > b.lastVisit
    }

    fileprivate static func fold(_ text: some StringProtocol) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
