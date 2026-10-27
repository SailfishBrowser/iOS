import Foundation

nonisolated struct HistoryEntry: Codable, Hashable, Sendable {
    var url: URL
    var title: String
    var visitCount: Int
    var lastVisit: Date
}

nonisolated extension URL {
    var isWebPage: Bool {
        scheme?.lowercased() == "https" || scheme?.lowercased() == "http"
    }

    // History's key for a page.
    var withoutFragment: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: true) else { return self }
        components.fragment = nil
        return components.url ?? self
    }
}
