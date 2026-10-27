import Foundation

nonisolated enum BlockingCategory: String, Codable, CaseIterable, Sendable {
    case ads, trackers, cookieBanners
}

nonisolated struct BlocklistManifest: Codable, Sendable {
    struct List: Codable, Equatable, Sendable {
        let name: String
        let category: BlockingCategory
    }

    let version: String
    let lists: [List]

    func identifier(for list: List) -> String {
        "\(list.name)-\(version)"
    }

    static func bundled(in bundle: Bundle) -> BlocklistManifest {
        let url = bundle.url(forResource: "manifest", withExtension: "json")!
        return try! JSONDecoder().decode(BlocklistManifest.self, from: Data(contentsOf: url))
    }
}
