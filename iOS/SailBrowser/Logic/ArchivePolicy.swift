import Foundation

nonisolated enum ArchivePolicy {
    // A tab opened in the background and never shown has no active time, so it ages from when it was opened.
    static func tabsToArchive(_ tabs: [Tab], now: Date, interval: ArchiveInterval) -> [Tab.ID] {
        let cutoff = now.addingTimeInterval(-interval.duration)
        return tabs.filter { !$0.isPinned && max($0.lastActiveAt, $0.createdAt) <= cutoff }.map(\.id)
    }
}
