import Foundation
import Testing
@testable import SailBrowser

struct ArchivePolicyTests {
    private func tab(lastActiveAt: Date, pinned: Bool = false) -> Tab {
        Tab(
            id: UUID(), url: URL(string: "https://example.com")!, title: "", isPinned: pinned,
            prefersDesktop: false, createdAt: .distantPast, lastActiveAt: lastActiveAt, tint: nil)
    }

    @Test func sweepArchivesAtExactBoundaryAndNeverPinned() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let interval = ArchiveInterval.oneDay
        let atBoundary = tab(lastActiveAt: now.addingTimeInterval(-interval.duration))
        let justInside = tab(lastActiveAt: now.addingTimeInterval(-interval.duration + 1))
        let oldPinned = tab(lastActiveAt: .distantPast, pinned: true)
        let oldUnpinned = tab(lastActiveAt: .distantPast)

        let ids = ArchivePolicy.tabsToArchive(
            [atBoundary, justInside, oldPinned, oldUnpinned], now: now, interval: interval)

        #expect(ids == [atBoundary.id, oldUnpinned.id])
    }

    @Test func anUnvisitedTabAgesFromWhenItWasOpened() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let interval = ArchiveInterval.oneDay
        func unvisited(openedAt: Date) -> Tab {
            Tab(
                id: UUID(), url: URL(string: "https://example.com")!, title: "", isPinned: false,
                prefersDesktop: false, createdAt: openedAt, lastActiveAt: .distantPast, tint: nil)
        }
        let fresh = unvisited(openedAt: now.addingTimeInterval(-interval.duration + 1))
        let stale = unvisited(openedAt: now.addingTimeInterval(-interval.duration))

        #expect(ArchivePolicy.tabsToArchive([fresh, stale], now: now, interval: interval) == [stale.id])
    }
}
