import Foundation

// One space of a Mac, as the Mac publishes it. The Mac app defines the same type; both encode it with a default
// JSONEncoder.
nonisolated struct MacSpace: Codable, Equatable, Sendable {
    nonisolated struct Page: Codable, Equatable, Sendable {
        let url: URL
        let title: String
        // A 32-pixel PNG of the page's favicon.
        let icon: Data?
    }

    let name: String
    let pinned: [Page]
    let tabs: [Page]
}
