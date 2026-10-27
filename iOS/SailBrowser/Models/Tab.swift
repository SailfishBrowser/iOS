import Foundation

nonisolated struct Tab: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var url: URL
    var title: String
    var isPinned: Bool
    var prefersDesktop: Bool
    var createdAt: Date
    var lastActiveAt: Date
    var tint: CodableColor?
    var isPrivate = false

    // Privacy is never written or read: a private tab is never saved, and a saved tab is never private.
    private enum CodingKeys: String, CodingKey {
        case id, url, title, isPinned, prefersDesktop, createdAt, lastActiveAt, tint
    }
}

nonisolated struct CodableColor: Codable, Hashable, Sendable {
    var red, green, blue: Double
}

nonisolated extension String {
    // A title as the stores keep it: its first line, at most Theme.Text.titleLimit characters. The cut comes first so a
    // huge single-line title is never walked whole on every title tick.
    var storedTitle: String {
        String(prefix(Theme.Text.titleLimit).prefix { !$0.isNewline })
    }
}
