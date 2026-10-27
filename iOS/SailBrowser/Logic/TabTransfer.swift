import Foundation

// "Export Open Tabs": the open tabs as a list that pastes as tappable links, one Markdown line per tab, in deck
// order with pinned tabs first. Private tabs are never written; tracking parameters go, as on every share. Brackets
// and backslashes in a title are backslash-escaped, as Markdown reads them, so no title can close its own link.
nonisolated enum TabExport {
    static func text(_ tabs: [Tab]) -> String {
        tabs.filter { !$0.isPrivate }.map { tab in
            let url = TrackingParams.strip(tab.url).absoluteString
            let title = tab.title.split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
                .replacing(#/[\\\[\]]/#) { "\\" + $0.0 }
            return title.isEmpty ? "- \(url)" : "- [\(title)](\(url))"
        }.joined(separator: "\n")
    }
}

nonisolated struct ImportedTab: Equatable, Sendable {
    let url: URL
    let title: String
}

// Reads any text that holds web links: the Arc browser's "Export Open Tabs" list, a Markdown list, JSON, HTML.
// Tracking parameters stay; these are the user's own tabs.
nonisolated enum TabImport {
    static func tabs(from text: String) -> [ImportedTab] {
        var seen: Set<String> = []
        var tabs: [ImportedTab] = []
        // A Markdown link first, its title taking a backslash and the character after it whole (an escaped "]" does
        // not close it) and its URL allowing one level of balanced parentheses, else a bare URL up to the next
        // whitespace or quote, so a compact JSON line or an href yields each URL on its own.
        let link = #/\[((?:[^\n\\]|\\[^\n])*?)\]\((https?://(?:[^\s()]|\([^\s()]*\))+)\)|(https?://[^\s<>"']+)/#
            .ignoresCase()
        for match in text.matches(of: link) {
            var url = match.2 ?? match.3!
            // A ")" goes only while the URL holds more ")" than "(" (Wikipedia URLs end in a balanced one).
            while let last = url.last,
                "\"'>],.;:!?".contains(last)
                    || last == ")" && url.count(where: { $0 == ")" }) > url.count(where: { $0 == "(" })
            {
                url.removeLast()
            }
            guard seen.insert(String(url)).inserted, let parsed = URL(string: String(url)) else { continue }
            tabs.append(ImportedTab(url: parsed, title: match.1.map(title) ?? ""))
        }
        return tabs
    }

    // Markdown's backslash escapes: a backslash before ASCII punctuation stands for that character.
    private static func title(_ raw: Substring) -> String {
        String(raw.replacing(#/\\([!-/:-@\[-`{-~])/#) { $0.1 }).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
