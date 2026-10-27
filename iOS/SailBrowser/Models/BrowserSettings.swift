import Foundation

nonisolated enum ArchiveInterval: String, Codable, CaseIterable, Sendable {
    case twelveHours, oneDay, threeDays, sevenDays, thirtyDays

    var duration: TimeInterval {
        let hour: TimeInterval = 3600
        return switch self {
        case .twelveHours: 12 * hour
        case .oneDay: 24 * hour
        case .threeDays: 3 * 24 * hour
        case .sevenDays: 7 * 24 * hour
        case .thirtyDays: 30 * 24 * hour
        }
    }

    var label: String {
        switch self {
        case .twelveHours: "12 Hours"
        case .oneDay: "1 Day"
        case .threeDays: "3 Days"
        case .sevenDays: "7 Days"
        case .thirtyDays: "30 Days"
        }
    }
}

nonisolated struct BrowserSettings: Codable, Equatable, Sendable {
    var archiveInterval: ArchiveInterval = .oneDay
    var blocksAds = true
    var blocksTrackers = true
    var blocksCookieBanners = true
    var zoomByHost: [String: Double] = [:]
    var displayOptionsExpanded = true
    var opensAppLinksInApp = true
    var searchEngine = SearchEngine.google
    var autoOpenKeyboard = true

    var blockedCategories: Set<BlockingCategory> {
        var categories: Set<BlockingCategory> = []
        if blocksAds { categories.insert(.ads) }
        if blocksTrackers { categories.insert(.trackers) }
        if blocksCookieBanners { categories.insert(.cookieBanners) }
        return categories
    }

    private enum LegacyKeys: String, CodingKey {
        case adBlockingEnabled
    }

    init() {}

    // A state saved before a setting existed has no key for it and takes the setting's default. One saved before the
    // three blocking toggles carries its single switch into all three.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        archiveInterval = try container.decode(ArchiveInterval.self, forKey: .archiveInterval)
        let blocks = try decoder.container(keyedBy: LegacyKeys.self)
            .decodeIfPresent(Bool.self, forKey: .adBlockingEnabled) ?? true
        blocksAds = try container.decodeIfPresent(Bool.self, forKey: .blocksAds) ?? blocks
        blocksTrackers = try container.decodeIfPresent(Bool.self, forKey: .blocksTrackers) ?? blocks
        blocksCookieBanners = try container.decodeIfPresent(Bool.self, forKey: .blocksCookieBanners) ?? blocks
        zoomByHost = try container.decode([String: Double].self, forKey: .zoomByHost)
        displayOptionsExpanded = try container.decodeIfPresent(Bool.self, forKey: .displayOptionsExpanded) ?? true
        opensAppLinksInApp = try container.decodeIfPresent(Bool.self, forKey: .opensAppLinksInApp) ?? true
        searchEngine = try container.decodeIfPresent(SearchEngine.self, forKey: .searchEngine) ?? .google
        autoOpenKeyboard = try container.decodeIfPresent(Bool.self, forKey: .autoOpenKeyboard) ?? true
    }
}
