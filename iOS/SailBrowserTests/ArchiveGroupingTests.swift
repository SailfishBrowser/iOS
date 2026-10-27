import Foundation
import Testing
@testable import SailBrowser

struct ArchiveGroupingTests {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func entry(_ title: String, _ archivedAt: Date, url: String = "https://example.com") -> ArchivedTab {
        ArchivedTab(id: UUID(), url: URL(string: url)!, title: title, archivedAt: archivedAt)
    }

    @Test func groupingAcrossDSTUsesCalendarDays() {
        let calendar = calendar("America/New_York")
        let now = date(calendar, 2026, 11, 2, 9)
        let sunday = entry("sunday", date(calendar, 2026, 11, 1, 0, 30))
        let saturday = entry("saturday", date(calendar, 2026, 10, 31, 23, 30))

        let sections = ArchiveGrouping.sections([sunday, saturday], now: now, calendar: calendar)

        #expect(sections.map(\.title) == ["Yesterday", "Saturday"])
        #expect(sections.map(\.entries) == [[sunday], [saturday]])

        let afterSpringForward = date(calendar, 2026, 3, 10, 9)
        let springSunday = entry("spring sunday", date(calendar, 2026, 3, 8, 12))
        let springSections = ArchiveGrouping.sections([springSunday], now: afterSpringForward, calendar: calendar)
        #expect(springSections.map(\.title) == ["Sunday"])
    }

    // A query over grouped sections keeps each section's matching entries and drops a section left empty: the same
    // sections as grouping the filtered entries.
    @Test func filteringGroupedSectionsMatchesGroupingTheFilteredEntries() {
        let calendar = calendar("UTC")
        let now = date(calendar, 2026, 10, 22, 12)
        let entries = [
            entry("Swift today", date(calendar, 2026, 10, 22, 9)),
            entry("Rust today", date(calendar, 2026, 10, 22, 8)),
            entry("Swift yesterday", date(calendar, 2026, 10, 21, 9)),
            entry("Rust last week", date(calendar, 2026, 10, 14, 9), url: "https://swift.org/"),
        ]
        let grouped = ArchiveGrouping.sections(entries, now: now, calendar: calendar)

        let shown = ArchiveGrouping.filter(grouped, query: "swift")

        #expect(shown == ArchiveGrouping.sections(ArchiveGrouping.filter(entries, query: "swift"), now: now, calendar: calendar))
        #expect(shown.map(\.title) == ["Today", "Yesterday", "Previous 30 Days"])
        #expect(shown.map { $0.entries.map(\.title) } == [["Swift today"], ["Swift yesterday"], ["Rust last week"]])
        #expect(ArchiveGrouping.filter(grouped, query: "") == grouped)
    }

    // The sheet's sections regroup only when the archive or the day changes; a keystroke filters, an extended query
    // narrows the last result, and a shortened one widens it again.
    @Test func archiveSectionsRegroupOnTheArchiveOrTheDayAndFilterOnTheQuery() {
        let calendar = calendar("UTC")
        let now = date(calendar, 2026, 10, 22, 12)
        let swift = entry("Swift", date(calendar, 2026, 10, 22, 9))
        let swiftUI = entry("SwiftUI", date(calendar, 2026, 10, 21, 9))
        let rust = entry("Rust", date(calendar, 2026, 10, 22, 8))
        let archived = [swift, swiftUI, rust]
        let sections = ArchiveSections()
        func titles(_ query: String, archived: [ArchivedTab] = archived, now: Date = now) -> [[String]] {
            sections.sections(archived, query: query, now: now, calendar: calendar).map { [$0.title] + $0.entries.map(\.title) }
        }

        #expect(titles("") == [["Today", "Swift", "Rust"], ["Yesterday", "SwiftUI"]])
        #expect(titles("swift") == [["Today", "Swift"], ["Yesterday", "SwiftUI"]])
        #expect(titles("swiftu") == [["Yesterday", "SwiftUI"]])
        #expect(titles("s") == [["Today", "Swift", "Rust"], ["Yesterday", "SwiftUI"]])
        let tomorrow = date(calendar, 2026, 10, 23, 12)
        #expect(titles("s", now: tomorrow) == [["Yesterday", "Swift", "Rust"], ["Wednesday", "SwiftUI"]])
        #expect(titles("s", archived: [swift, rust], now: tomorrow) == [["Yesterday", "Swift", "Rust"]])
    }

    @Test func sectionOrderTodayYesterdayWeekdaysThen30DaysThenMonths() {
        let calendar = calendar("UTC")
        let now = date(calendar, 2026, 10, 22, 12)
        let todayLate = entry("today late", date(calendar, 2026, 10, 22, 11))
        let todayEarly = entry("today early", date(calendar, 2026, 10, 22, 1))
        let yesterday = entry("yesterday", date(calendar, 2026, 10, 21, 23))
        let weekdays = (2...6).map { entry("day \($0)", date(calendar, 2026, 10, 22 - $0, 8)) }
        let sevenDays = entry("seven", date(calendar, 2026, 10, 15, 8))
        let thirtyDays = entry("thirty", date(calendar, 2026, 9, 22, 0, 5))
        let thirtyOneDays = entry("thirty one", date(calendar, 2026, 9, 21, 23))
        let august = entry("august", date(calendar, 2026, 8, 3, 8))
        let lastDecember = entry("last december", date(calendar, 2025, 12, 31, 8))
        let all = [todayEarly, todayLate, yesterday, sevenDays, thirtyDays, thirtyOneDays, august, lastDecember] + weekdays

        let sections = ArchiveGrouping.sections(all.shuffled(), now: now, calendar: calendar)

        #expect(
            sections.map(\.title) == [
                "Today", "Yesterday", "Tuesday", "Monday", "Sunday", "Saturday", "Friday", "Previous 30 Days",
                "September 2026", "August 2026", "December 2025",
            ])
        #expect(sections[0].entries == [todayLate, todayEarly])
        #expect(sections[7].entries == [sevenDays, thirtyDays])
        #expect(sections[8].entries == [thirtyOneDays])
        #expect(Set(sections.map(\.id)).count == sections.count)
    }

    @Test func entriesAcrossDaysMergeIntoOneSectionAndOldestSectionIsEmitted() {
        let calendar = calendar("UTC")
        let now = date(calendar, 2026, 10, 22, 12)
        let tomorrow = entry("tomorrow", date(calendar, 2026, 10, 23, 1))
        let todayNoon = entry("today noon", date(calendar, 2026, 10, 22, 12))
        let todayMorning = entry("today morning", date(calendar, 2026, 10, 22, 8))
        let todayMidnight = entry("today midnight", date(calendar, 2026, 10, 22, 0))
        let tenDays = entry("ten days", date(calendar, 2026, 10, 12, 9))
        let twentyDaysLate = entry("twenty days late", date(calendar, 2026, 10, 2, 22))
        let twentyDaysEarly = entry("twenty days early", date(calendar, 2026, 10, 2, 6))
        let thirtyDays = entry("thirty days", date(calendar, 2026, 9, 22, 9))
        let julyLate = entry("july late", date(calendar, 2026, 7, 30, 9))
        let julyEarly = entry("july early", date(calendar, 2026, 7, 1, 9))
        let all = [
            julyEarly, twentyDaysEarly, todayMidnight, thirtyDays, tomorrow, todayNoon, julyLate, tenDays, todayMorning,
            twentyDaysLate,
        ]

        let sections = ArchiveGrouping.sections(all, now: now, calendar: calendar)

        #expect(sections.map(\.id) == ["today", "previous-30", "month-2026-7"])
        #expect(sections.map(\.title) == ["Today", "Previous 30 Days", "July 2026"])
        #expect(
            sections.map(\.entries) == [
                [tomorrow, todayNoon, todayMorning, todayMidnight],
                [tenDays, twentyDaysLate, twentyDaysEarly, thirtyDays],
                [julyLate, julyEarly],
            ])
        #expect(ArchiveGrouping.sections([], now: now, calendar: calendar).isEmpty)
    }

    @Test func filterIsCaseAndDiacriticInsensitive() {
        let resume = entry("Résumé Tips", .now, url: "https://jobs.example/tips")
        let cafe = entry("Menu", .now, url: "https://cafe.example")
        let entries = [resume, cafe]

        #expect(ArchiveGrouping.filter(entries, query: "RESUME") == [resume])
        #expect(ArchiveGrouping.filter(entries, query: "Café") == [cafe])
        #expect(ArchiveGrouping.filter(entries, query: "JOBS") == [resume])
        #expect(ArchiveGrouping.filter(entries, query: "example") == entries)
        #expect(ArchiveGrouping.filter(entries, query: "") == entries)
        #expect(ArchiveGrouping.filter(entries, query: "zzz").isEmpty)
    }
}
