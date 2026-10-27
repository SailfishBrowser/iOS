import Foundation

nonisolated struct ArchiveSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let entries: [ArchivedTab]
}

nonisolated enum ArchiveGrouping {
    private static let weekdayDays = 2...6
    private static let previousDays = 7...30

    static func sections(_ entries: [ArchivedTab], now: Date, calendar: Calendar) -> [ArchiveSection] {
        let today = calendar.startOfDay(for: now)
        var sections: [ArchiveSection] = []
        var day: Date?
        var key: (id: String, title: String)?
        var buffer: [ArchivedTab] = []
        func flush() {
            if let key { sections.append(ArchiveSection(id: key.id, title: key.title, entries: buffer)) }
        }
        for entry in entries.sorted(by: { $0.archivedAt > $1.archivedAt }) {
            let entryDay = calendar.startOfDay(for: entry.archivedAt)
            if entryDay != day {
                day = entryDay
                let entryKey = sectionKey(forDay: entryDay, today: today, calendar: calendar)
                if entryKey.id != key?.id {
                    flush()
                    key = entryKey
                    buffer = []
                }
            }
            buffer.append(entry)
        }
        flush()
        return sections
    }

    static func filter(_ entries: [ArchivedTab], query: String) -> [ArchivedTab] {
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.title.localizedStandardContains(query) || $0.url.host()?.localizedStandardContains(query) == true
        }
    }

    // A query over grouped sections: each keeps its matching entries, and one left empty goes.
    static func filter(_ sections: [ArchiveSection], query: String) -> [ArchiveSection] {
        guard !query.isEmpty else { return sections }
        return sections.compactMap { section in
            let entries = filter(section.entries, query: query)
            return entries.isEmpty ? nil : ArchiveSection(id: section.id, title: section.title, entries: entries)
        }
    }

    private static func sectionKey(forDay day: Date, today: Date, calendar: Calendar) -> (id: String, title: String) {
        let distance = calendar.dateComponents([.day], from: day, to: today).day!
        switch distance {
        case ...0:
            return ("today", "Today")
        case 1:
            return ("yesterday", "Yesterday")
        case weekdayDays:
            let weekday = calendar.component(.weekday, from: day)
            return ("day-\(distance)", calendar.weekdaySymbols[weekday - 1])
        case previousDays:
            return ("previous-30", "Previous 30 Days")
        default:
            let parts = calendar.dateComponents([.year, .month], from: day)
            let month = calendar.standaloneMonthSymbols[parts.month! - 1]
            return ("month-\(parts.year!)-\(parts.month!)", "\(month) \(parts.year!)")
        }
    }
}

// The sheet's sections: the sort and the calendar work run once per archive and day, a keystroke only filters, and
// one that extends the last query narrows its own result.
final class ArchiveSections {
    private var archived: [ArchivedTab] = []
    private var day = Date.distantPast
    private var calendar = Calendar.current
    private var grouped: [ArchiveSection] = []
    private var query = ""
    private var shown: [ArchiveSection] = []

    func sections(_ archived: [ArchivedTab], query: String, now: Date, calendar: Calendar) -> [ArchiveSection] {
        let day = calendar.startOfDay(for: now)
        if archived != self.archived || day != self.day || calendar != self.calendar {
            (self.archived, self.day, self.calendar) = (archived, day, calendar)
            grouped = ArchiveGrouping.sections(archived, now: now, calendar: calendar)
            (self.query, shown) = ("", grouped)
        }
        if query != self.query {
            shown = ArchiveGrouping.filter(query.hasPrefix(self.query) ? shown : grouped, query: query)
            self.query = query
        }
        return shown
    }
}
