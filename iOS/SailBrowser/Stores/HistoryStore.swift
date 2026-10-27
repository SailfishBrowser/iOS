import Foundation
import Observation

@Observable final class HistoryStore {
    private(set) var entries: [HistoryEntry]
    private(set) var searchKeys: [HistorySearchKey]

    @ObservationIgnored private let capacity: Int
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let writer: DebouncedWriter<[HistoryEntry]>
    @ObservationIgnored private var hasUnsavedTitles = false

    init(directories: AppDirectories, capacity: Int = 5000, now: @escaping () -> Date = Date.init) {
        let fileURL = directories.support.appending(path: "history.json")
        let loaded = JSONFile.load([HistoryEntry].self, from: fileURL) ?? []
        entries = loaded
        searchKeys = loaded.map(HistorySearchKey.init)
        self.capacity = capacity
        self.now = now
        writer = DebouncedWriter(fileURL: fileURL)
    }

    // Every committed main-frame page, under the URL it committed with (a server redirect's final one). Same-document
    // navigations do not commit, so they add nothing. The title follows as the page sets it.
    func track(_ controller: WebTabController) {
        // A controller can outlive the store, so its hooks hold it weakly.
        controller.onCommit = { [weak self] url, title in self?.recordVisit(url: url, title: title) }
        controller.onTitle = { [weak self] url, title in self?.updateTitle(url: url, title: title) }
    }

    // A commit usually comes before the page's title, so an empty one keeps the title already known.
    func recordVisit(url: URL, title: String) {
        guard url.isWebPage, SearchEngine.query(inResultsURL: url) == nil else { return }
        let key = url.withoutFragment
        let title = title.storedTitle
        var entry = HistoryEntry(url: key, title: title, visitCount: 0, lastVisit: now())
        if let i = entries.firstIndex(where: { $0.url == key }) {
            let old = entries.remove(at: i)
            entry.visitCount = old.visitCount
            if title.isEmpty {
                entry.title = old.title
            }
            searchKeys.remove(at: i)
        }
        entry.visitCount += 1
        entries.insert(entry, at: 0)
        searchKeys.insert(HistorySearchKey(entry), at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
            searchKeys.removeLast(searchKeys.count - capacity)
        }
        save()
    }

    // A page's first title is written. A page that re-titles itself every second (an unread count) changes memory
    // only and rides the next visit, removal, clear or the background flush, instead of rewriting the file each tick.
    func updateTitle(url: URL, title: String) {
        let key = url.withoutFragment
        let title = title.storedTitle
        guard !title.isEmpty, let i = entries.firstIndex(where: { $0.url == key }), entries[i].title != title else { return }
        let first = entries[i].title.isEmpty
        entries[i].title = title
        searchKeys[i] = HistorySearchKey(entries[i])
        if first {
            save()
        } else {
            hasUnsavedTitles = true
        }
    }

    func remove(url: URL) {
        entries.removeAll { $0.url == url }
        searchKeys.removeAll { $0.entry.url == url }
        save()
    }

    func clear() {
        entries = []
        searchKeys = []
        save()
    }

    func flush() async {
        if hasUnsavedTitles {
            save()
        }
        await writer.flush()
    }

    var hasPendingWrite: Bool {
        writer.isPending
    }

    private func save() {
        hasUnsavedTitles = false
        writer.schedule(entries)
    }
}
