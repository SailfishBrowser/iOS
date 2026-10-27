import Foundation

nonisolated struct ArchivedTab: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let title: String
    let archivedAt: Date
}
