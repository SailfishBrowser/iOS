import Foundation

nonisolated struct BrowserState: Equatable, Sendable {
    var tabs: [Tab]
    // Read only: builds before archive.json kept the archive here, and the store moves it out on the first load.
    var archived: [ArchivedTab] = []
    var activeTabID: UUID?
    var settings: BrowserSettings

    static let empty = BrowserState(tabs: [], activeTabID: nil, settings: BrowserSettings())
}

// The archive is decoded when a file carries it and never written.
nonisolated extension BrowserState: Codable {
    private enum CodingKeys: String, CodingKey {
        case tabs, archived, activeTabID, settings
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try container.decode([Tab].self, forKey: .tabs)
        archived = try container.decodeIfPresent([ArchivedTab].self, forKey: .archived) ?? []
        activeTabID = try container.decodeIfPresent(UUID.self, forKey: .activeTabID)
        settings = try container.decode(BrowserSettings.self, forKey: .settings)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tabs, forKey: .tabs)
        try container.encodeIfPresent(activeTabID, forKey: .activeTabID)
        try container.encode(settings, forKey: .settings)
    }
}
