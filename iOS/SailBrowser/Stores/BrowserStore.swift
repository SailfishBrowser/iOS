import Foundation
import Observation

@Observable final class BrowserStore {
    private static let archiveCapacity = 2000

    private(set) var tabs: [Tab]
    private(set) var archived: [ArchivedTab]
    private(set) var activeTabID: Tab.ID?
    var settings: BrowserSettings {
        didSet { save() }
    }

    @ObservationIgnored var onTabsRemoved: (([Tab.ID]) -> Void)?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var lastBackground: (opener: Tab.ID, tab: Tab.ID)?
    @ObservationIgnored private let writer: DebouncedWriter<BrowserState>
    @ObservationIgnored private let archiveWriter: DebouncedWriter<[ArchivedTab]>

    var activeTab: Tab? {
        tabs.first { $0.id == activeTabID }
    }

    var hasPrivateTabs: Bool {
        tabs.contains(where: \.isPrivate)
    }

    var previousTabID: Tab.ID? {
        tabs.filter { $0.id != activeTabID }.max { $0.lastActiveAt < $1.lastActiveAt }?.id
    }

    // A saved file is a boundary: a clock that jumped back leaves times in the future a sweep would never reach, and a
    // hand-edited or half-migrated file can name an active tab that is not there. Both repairs ride the next write.
    init(directories: AppDirectories, now: @escaping () -> Date = Date.init) {
        let fileURL = directories.support.appending(path: "state.json")
        let archiveURL = directories.support.appending(path: "archive.json")
        let state = JSONFile.load(BrowserState.self, from: fileURL) ?? .empty
        let savedArchive = JSONFile.load([ArchivedTab].self, from: archiveURL)
        let date = now()
        let loaded = state.tabs.map { saved in
            var tab = saved
            tab.createdAt = min(tab.createdAt, date)
            tab.lastActiveAt = min(tab.lastActiveAt, date)
            return tab
        }
        tabs = loaded
        archived = savedArchive ?? state.archived
        activeTabID = loaded.contains { $0.id == state.activeTabID }
            ? state.activeTabID : loaded.max { $0.lastActiveAt < $1.lastActiveAt }?.id
        settings = state.settings
        self.now = now
        writer = DebouncedWriter(fileURL: fileURL)
        archiveWriter = DebouncedWriter(fileURL: archiveURL)
        // An earlier saved-state format kept the archive in state.json: it moves to its own file at once, ahead of any state write.
        if savedArchive == nil, !archived.isEmpty {
            saveArchive()
        }
    }

    @discardableResult func openTab(url: URL, isPrivate: Bool = false) -> Tab {
        insert(makeTab(url: url, isPrivate: isPrivate), activate: true)
    }

    // Joins the deck right after the active tab, after any tabs already opened this way from it, and stays unshown.
    @discardableResult func openInBackground(url: URL, isPrivate: Bool = false) -> Tab {
        let opener = activeTabID!
        var after = opener
        if let last = lastBackground, last.opener == opener, tabs.contains(where: { $0.id == last.tab }) {
            after = last.tab
        }
        // Never shown, so it is not the previous tab or a recent until it is visited.
        var tab = makeTab(url: url, isPrivate: isPrivate)
        tab.lastActiveAt = .distantPast
        tabs.insert(tab, at: max(index(of: after) + 1, tabs.count { $0.isPinned }))
        lastBackground = (opener, tab.id)
        save()
        return tab
    }

    func makeTab(url: URL, isPrivate: Bool = false) -> Tab {
        makeTab(url: url, title: "", isPrivate: isPrivate)
    }

    @discardableResult func insert(_ tab: Tab, activate: Bool) -> Tab {
        var tab = tab
        tab.title = tab.title.storedTitle
        if activate || activeTabID == nil {
            tab.lastActiveAt = now()
            activeTabID = tab.id
        }
        tabs.append(tab)
        save()
        return tab
    }

    func activate(_ id: Tab.ID) {
        tabs[index(of: id)].lastActiveAt = now()
        activeTabID = id
        save()
    }

    func archive(_ id: Tab.ID) {
        archive([id])
    }

    // Nil when the entry is already gone: a second tap on an archive row before the sheet has left.
    @discardableResult func restore(_ id: ArchivedTab.ID) -> Tab? {
        guard let i = archived.firstIndex(where: { $0.id == id }) else { return nil }
        let entry = archived.remove(at: i)
        saveArchive()
        return insert(makeTab(url: entry.url, title: entry.title, isPrivate: false), activate: true)
    }

    func deleteArchived(_ id: ArchivedTab.ID) {
        archived.removeAll { $0.id == id }
        saveArchive()
    }

    func clearArchive() {
        archived = []
        saveArchive()
    }

    func setPinned(_ pinned: Bool, for id: Tab.ID) {
        var tab = tabs.remove(at: index(of: id))
        tab.isPinned = pinned
        let pinnedCount = tabs.count { $0.isPinned }
        let destination = pinned
            ? pinnedCount
            : tabs[pinnedCount...].firstIndex { $0.createdAt > tab.createdAt } ?? tabs.endIndex
        tabs.insert(tab, at: destination)
        save()
    }

    func setDesktopMode(_ on: Bool, for id: Tab.ID) {
        tabs[index(of: id)].prefersDesktop = on
        save()
    }

    func updatePage(_ id: Tab.ID, url: URL, title: String, tint: CodableColor?) {
        let i = index(of: id)
        tabs[i].url = url
        tabs[i].title = title.storedTitle
        tabs[i].tint = tint
        save()
    }

    func setTint(_ tint: CodableColor, for id: Tab.ID) {
        let i = index(of: id)
        guard tabs[i].tint != tint else { return }
        tabs[i].tint = tint
        save()
    }

    func touchActiveTab() {
        guard let activeTabID else { return }
        tabs[index(of: activeTabID)].lastActiveAt = now()
        save()
    }

    @discardableResult func runArchiveSweep() -> [Tab.ID] {
        let ids = ArchivePolicy.tabsToArchive(tabs, now: now(), interval: settings.archiveInterval)
        if !ids.isEmpty {
            archive(ids)
        }
        return ids
    }

    // The archive lands first, as on the timer path: a kill between the two leaves an archived tab in both files, not
    // in neither.
    func flush() async {
        await archiveWriter.flush()
        await writer.flush()
    }

    private func makeTab(url: URL, title: String, isPrivate: Bool) -> Tab {
        let date = now()
        return Tab(
            id: UUID(), url: url, title: title, isPinned: false, prefersDesktop: false,
            createdAt: date, lastActiveAt: date, tint: nil, isPrivate: isPrivate)
    }

    private func archive(_ ids: [Tab.ID]) {
        let date = now()
        var entries: [ArchivedTab] = []
        for id in ids {
            let tab = tabs.remove(at: index(of: id))
            if !tab.isPrivate {
                entries.insert(ArchivedTab(id: tab.id, url: tab.url, title: tab.title, archivedAt: date), at: 0)
            }
        }
        if !entries.isEmpty {
            archived = Array((entries + archived).prefix(Self.archiveCapacity))
            saveArchive()
        }
        if let activeTabID, ids.contains(activeTabID) {
            self.activeTabID = tabs.last?.id
        }
        save()
        onTabsRemoved?(ids)
    }

    private func index(of id: Tab.ID) -> Int {
        tabs.firstIndex { $0.id == id }!
    }

    // Only normal tabs are written. With a private tab in front, the most recently active normal one is saved as active.
    private func save() {
        let normal = tabs.filter { !$0.isPrivate }
        let savedActive = normal.contains { $0.id == activeTabID } ? activeTabID
            : normal.max { $0.lastActiveAt < $1.lastActiveAt }?.id
        writer.schedule(BrowserState(tabs: normal, activeTabID: savedActive, settings: settings))
    }

    // The archive has its own file, so a tab switch never rewrites two thousand entries.
    private func saveArchive() {
        archiveWriter.schedule(archived)
    }
}
