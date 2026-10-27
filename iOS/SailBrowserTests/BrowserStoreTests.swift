import Foundation
import Synchronization
import Testing
@testable import SailBrowser

final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

struct BrowserStoreTests {
    let directories = AppDirectories.temporary()
    let clock = TestClock()

    private func makeStore() -> BrowserStore {
        BrowserStore(directories: directories, now: { [clock] in clock.now })
    }

    private func openTabs(_ store: BrowserStore, _ names: String...) -> [Tab] {
        names.map { name in
            clock.advance(1)
            return store.openTab(url: URL(string: "https://\(name).com")!)
        }
    }

    @Test func madeTabJoinsOnlyWhenInsertedAndActivatesOnlyWhenAsked() {
        let store = makeStore()
        let first = openTabs(store, "a")[0]
        clock.advance(1)
        let made = store.makeTab(url: URL(string: "https://b.com")!)
        #expect(store.tabs.map(\.id) == [first.id])

        clock.advance(1)
        store.insert(made, activate: false)
        #expect(store.tabs.map(\.id) == [first.id, made.id])
        #expect(store.activeTabID == first.id)

        let other = store.makeTab(url: URL(string: "https://c.com")!)
        clock.advance(1)
        store.insert(other, activate: true)
        #expect(store.activeTabID == other.id)
        #expect(store.tabs.last?.lastActiveAt == clock.now)
    }

    @Test func openInBackgroundJoinsAfterTheActiveTabAndKeepsItActive() {
        let store = makeStore()
        let tabs = openTabs(store, "a", "b", "c")
        store.activate(tabs[1].id)

        let first = store.openInBackground(url: URL(string: "https://d.com")!)
        let second = store.openInBackground(url: URL(string: "https://e.com")!)

        #expect(store.tabs.map(\.id) == [tabs[0].id, tabs[1].id, first.id, second.id, tabs[2].id])
        #expect(store.activeTabID == tabs[1].id)
    }

    @Test func aBackgroundTabIsNotPreviousUntilVisited() {
        let store = makeStore()
        let tabs = openTabs(store, "a", "b")
        clock.advance(1)
        let added = store.openInBackground(url: URL(string: "https://c.com")!)

        #expect(store.previousTabID == tabs[0].id)
        #expect(store.runArchiveSweep().isEmpty)

        clock.advance(1)
        store.activate(added.id)
        clock.advance(1)
        store.activate(tabs[1].id)
        #expect(store.previousTabID == added.id)
    }

    @Test func openInBackgroundFromAPinnedTabJoinsAfterThePinnedTabs() {
        let store = makeStore()
        let tabs = openTabs(store, "a", "b", "c")
        store.setPinned(true, for: tabs[0].id)
        store.setPinned(true, for: tabs[1].id)
        store.activate(tabs[0].id)

        let added = store.openInBackground(url: URL(string: "https://d.com")!)

        #expect(store.tabs.map(\.id) == [tabs[0].id, tabs[1].id, added.id, tabs[2].id])
        #expect(!store.tabs[2].isPinned)
        #expect(store.activeTabID == tabs[0].id)
    }

    @Test func insertingWithoutActivationIntoAnEmptyStoreActivatesTheTab() {
        let store = makeStore()
        let made = store.makeTab(url: URL(string: "https://a.com")!)
        clock.advance(1)

        store.insert(made, activate: false)

        #expect(store.activeTabID == made.id)
        #expect(store.tabs[0].lastActiveAt == clock.now)
    }

    @Test func activeTabTouchedOnBackgroundSurvivesSweep() {
        let store = makeStore()
        let tabs = openTabs(store, "a")
        clock.advance(25 * 3600)
        store.touchActiveTab()
        clock.advance(60)

        #expect(store.runArchiveSweep().isEmpty)
        #expect(store.tabs.map(\.id) == tabs.map(\.id))
    }

    @Test func activationNeverReordersAndUnpinReturnsToCreationSlot() {
        let store = makeStore()
        let tabs = openTabs(store, "a", "b", "c")
        let (a, b, c) = (tabs[0].id, tabs[1].id, tabs[2].id)

        store.activate(a)
        #expect(store.tabs.map(\.id) == [a, b, c])
        #expect(store.activeTabID == a)
        #expect(store.previousTabID == c)

        store.setPinned(true, for: c)
        #expect(store.tabs.map(\.id) == [c, a, b])
        store.setPinned(true, for: b)
        #expect(store.tabs.map(\.id) == [c, b, a])

        store.setPinned(false, for: c)
        #expect(store.tabs.map(\.id) == [b, a, c])
        store.setPinned(false, for: b)
        #expect(store.tabs.map(\.id) == [a, b, c])
    }

    @Test func archivingActivePicksRightmostRemaining() throws {
        let store = makeStore()
        let tabs = openTabs(store, "a", "b", "c")
        var removed: [[Tab.ID]] = []
        store.onTabsRemoved = { removed.append($0) }

        store.activate(tabs[1].id)
        store.archive(tabs[1].id)
        #expect(store.activeTabID == tabs[2].id)
        #expect(store.archived.map(\.url) == [tabs[1].url])

        store.archive(tabs[0].id)
        #expect(store.activeTabID == tabs[2].id)
        store.archive(tabs[2].id)
        #expect(store.activeTabID == nil)
        #expect(store.archived.map(\.url) == [tabs[2].url, tabs[0].url, tabs[1].url])
        #expect(removed == [[tabs[1].id], [tabs[0].id], [tabs[2].id]])

        let restored = try #require(store.restore(store.archived[1].id))
        #expect(restored.url == tabs[0].url)
        #expect(store.tabs.map(\.id) == [restored.id])
        #expect(store.activeTabID == restored.id)
        #expect(store.archived.map(\.url) == [tabs[2].url, tabs[1].url])
    }

    @Test func sweepArchivesStaleTabsInOneBatch() {
        let store = makeStore()
        let tabs = openTabs(store, "a", "b", "c")
        store.setPinned(true, for: tabs[0].id)
        var removed: [[Tab.ID]] = []
        store.onTabsRemoved = { removed.append($0) }
        clock.advance(ArchiveInterval.oneDay.duration)

        let swept = store.runArchiveSweep()

        #expect(swept == [tabs[1].id, tabs[2].id])
        #expect(removed == [swept])
        #expect(store.tabs.map(\.id) == [tabs[0].id])
        #expect(store.activeTabID == tabs[0].id)
    }

    @Test func unchangedTintNeitherMutatesNorSchedulesWrite() async throws {
        let store = makeStore()
        let tab = openTabs(store, "a")[0]
        let tint = CodableColor(red: 0.2, green: 0.6, blue: 0.4)
        store.setTint(tint, for: tab.id)
        await store.flush()
        let file = directories.support.appending(path: "state.json")
        try FileManager.default.removeItem(at: file)
        let mutated = Mutex(false)
        withObservationTracking {
            _ = store.tabs
        } onChange: {
            mutated.withLock { $0 = true }
        }

        store.setTint(tint, for: tab.id)
        await store.flush()

        #expect(!mutated.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))

        store.setTint(CodableColor(red: 0.1, green: 0.1, blue: 0.1), for: tab.id)
        await store.flush()
        #expect(mutated.withLock { $0 })
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    @Test func stateRoundTripsThroughFlush() async {
        let store = makeStore()
        let tabs = openTabs(store, "a", "b")
        store.archive(tabs[0].id)
        store.settings.archiveInterval = .sevenDays
        await store.flush()

        let reloaded = makeStore()
        #expect(reloaded.tabs == store.tabs)
        #expect(reloaded.archived == store.archived)
        #expect(reloaded.activeTabID == tabs[1].id)
        #expect(reloaded.settings.archiveInterval == .sevenDays)
    }

    @Test func theDisplayOptionsFoldSurvivesASaveAndReload() async {
        let store = makeStore()
        #expect(store.settings.displayOptionsExpanded)
        store.settings.displayOptionsExpanded = false
        await store.flush()
        #expect(!makeStore().settings.displayOptionsExpanded)
    }

    @Test func theAutoOpenKeyboardSettingSurvivesASaveAndReload() async {
        let store = makeStore()
        #expect(store.settings.autoOpenKeyboard)
        store.settings.autoOpenKeyboard = false
        await store.flush()
        #expect(!makeStore().settings.autoOpenKeyboard)
    }

    // A state saved before the fold and the engine choice existed keeps its settings, opens the fold expanded and searches
    // with Google.
    @Test func settingsSavedBeforeTheFoldExistedStillLoad() throws {
        let saved = Data(#"{"archiveInterval":"sevenDays","adBlockingEnabled":false,"zoomByHost":{"a.test":1.5}}"#.utf8)
        let settings = try JSONDecoder().decode(BrowserSettings.self, from: saved)
        #expect(settings.archiveInterval == .sevenDays)
        #expect(settings.blockedCategories.isEmpty)
        #expect(settings.zoomByHost == ["a.test": 1.5])
        #expect(settings.displayOptionsExpanded)
        #expect(settings.searchEngine == .google)
        #expect(settings.autoOpenKeyboard)
    }

    // The single blocking switch of older builds carries into each of the three toggles.
    @Test func theOldBlockingSwitchDecodesIntoAllThreeCategories() throws {
        for blocks in [false, true] {
            let saved = Data(#"{"archiveInterval":"oneDay","adBlockingEnabled":\#(blocks),"zoomByHost":{}}"#.utf8)
            let settings = try JSONDecoder().decode(BrowserSettings.self, from: saved)
            #expect(settings.blocksAds == blocks && settings.blocksTrackers == blocks && settings.blocksCookieBanners == blocks)
        }
    }

    @Test func eachBlockingCategorySurvivesASaveAndReloadOnItsOwn() async {
        let store = makeStore()
        #expect(store.settings.blockedCategories == Set(BlockingCategory.allCases))
        store.settings.blocksTrackers = false
        await store.flush()
        #expect(makeStore().settings.blockedCategories == [.ads, .cookieBanners])
    }

    // An install updated from a build without the fold has a state.json with no key for it: it loads whole, every tab
    // kept, and opens the fold expanded. Without its own decoder the settings would fail to decode, and the store would
    // move the file aside and start empty.
    @Test func aStateSavedBeforeTheFoldKeepsEveryTab() async throws {
        let store = makeStore()
        let tabs = openTabs(store, "a", "b", "c")
        store.archive(tabs[0].id)
        await store.flush()
        let file = directories.support.appending(path: "state.json")
        var state = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var settings = state["settings"] as! [String: Any]
        settings.removeValue(forKey: "displayOptionsExpanded")
        settings.removeValue(forKey: "searchEngine")
        settings.removeValue(forKey: "autoOpenKeyboard")
        state["settings"] = settings
        try JSONSerialization.data(withJSONObject: state).write(to: file)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("displayOptionsExpanded") == false)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("searchEngine") == false)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("autoOpenKeyboard") == false)

        let reloaded = makeStore()
        #expect(reloaded.tabs == store.tabs)
        #expect(reloaded.archived == store.archived)
        #expect(reloaded.activeTabID == store.activeTabID)
        #expect(reloaded.settings.displayOptionsExpanded)
        #expect(reloaded.settings.searchEngine == .google)
        #expect(reloaded.settings.autoOpenKeyboard)
    }

    @Test func corruptStateFileIsMovedAsideAndStoreStartsEmpty() throws {
        try FileManager.default.createDirectory(at: directories.support, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directories.support.appending(path: "state.json"))

        let store = makeStore()

        #expect(store.tabs.isEmpty)
        #expect(store.activeTabID == nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: directories.support.path(percentEncoded: false))
        #expect(files.count == 1)
        #expect(files[0].hasPrefix("state.corrupt-") && files[0].hasSuffix(".json"))
    }
}
