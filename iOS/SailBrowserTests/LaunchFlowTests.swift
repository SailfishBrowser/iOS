import Foundation
import Testing
@testable import SailBrowser

struct LaunchFlowTests {
    let directories = AppDirectories.temporary()

    private func tab(_ name: String, idleHours: Double, pinned: Bool = false) -> Tab {
        let date = Date().addingTimeInterval(-idleHours * 3600)
        return Tab(
            id: UUID(), url: page(name), title: name, isPinned: pinned, prefersDesktop: false,
            createdAt: date, lastActiveAt: date, tint: nil)
    }

    private func writeState(_ tabs: [Tab], active: Tab) throws {
        let state = BrowserState(tabs: tabs, archived: [], activeTabID: active.id, settings: BrowserSettings())
        try FileManager.default.createDirectory(at: directories.support, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: directories.support.appending(path: "state.json"))
    }

    @Test func coldLaunchWithNoTabsShowsSearchOverEmptySwitcher() {
        let env = makeEnvironment(directories)
        env.launch()

        #expect(env.ui.overlay == .search)
        #expect(env.ui.searchShrink == 1)
        #expect(env.ui.deckProgress == 1)
        #expect(env.activeController == nil)
    }

    @Test func coldLaunchWithStaleTabsArchivesThenShowsSearch() throws {
        let pinned = tab("pinned", idleHours: 48, pinned: true)
        let stale = tab("stale", idleHours: 48)
        try writeState([pinned, stale], active: stale)
        let env = makeEnvironment(directories)
        env.launch()

        #expect(env.browser.tabs.map(\.id) == [pinned.id])
        #expect(env.browser.archived.map(\.id) == [stale.id])
        #expect(env.browser.activeTabID == pinned.id)
        #expect(env.ui.overlay == .search)
        #expect(env.ui.deckProgress == 0)
    }

    @Test func coldLaunchBuildsNoWebViewBeforeFinishLaunch() async throws {
        let fresh = tab("fresh", idleHours: 0)
        try writeState([fresh], active: fresh)
        let env = makeEnvironment(directories)
        env.launch()

        #expect(env.activeController == nil)
        #expect(env.pool.liveController(for: fresh.id) == nil)
        #expect(env.ui.overlay == .search)
        #expect(env.ui.deckProgress == 0)

        await env.finishLaunch()

        #expect(env.activeController?.tabID == fresh.id)
        #expect(env.pool.liveController(for: fresh.id) === env.activeController)
    }

    @Test func foregroundSweepArchivingActiveShowsSearch() throws {
        let stale = tab("stale", idleHours: 48)
        let fresh = tab("fresh", idleHours: 0)
        try writeState([stale, fresh], active: stale)
        let env = makeEnvironment(directories)
        env.ui.setDeck(1, animated: false)

        env.sceneWillEnterForeground()

        #expect(env.browser.tabs.map(\.id) == [fresh.id])
        #expect(env.activeController?.tabID == fresh.id)
        #expect(env.ui.overlay == .search)
        #expect(env.ui.deckProgress == 0)
    }

    @Test func foregroundSweepWithMenuUpClosesMenuThenShowsSearch() throws {
        let stale = tab("stale", idleHours: 48)
        try writeState([stale], active: stale)
        let env = makeEnvironment(directories)
        #expect(env.ui.open(.menu))

        env.sceneWillEnterForeground()

        #expect(env.ui.overlay == .search)
        #expect(env.ui.deckProgress == 1)
        #expect(env.activeController == nil)
    }

    @Test func foregroundSweepLeavesSettingsInPlace() throws {
        let stale = tab("stale", idleHours: 48)
        try writeState([stale], active: stale)
        let env = makeEnvironment(directories)
        env.ui.setDeck(1, animated: false)
        #expect(env.ui.open(.settings))

        env.sceneWillEnterForeground()

        #expect(env.browser.tabs.isEmpty)
        #expect(env.ui.overlay == .settings)
        #expect(env.ui.deckProgress == 1)
    }

    @Test func foregroundSweepKeepingActiveChangesNothing() throws {
        let fresh = tab("fresh", idleHours: 0)
        try writeState([fresh], active: fresh)
        let env = makeEnvironment(directories)

        env.sceneWillEnterForeground()

        #expect(env.ui.overlay == .none)
        #expect(env.browser.activeTabID == fresh.id)
    }
}
