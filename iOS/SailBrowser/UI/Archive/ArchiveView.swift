import SwiftUI

struct ArchiveView: View {
    private static let daysShowingTime = 6

    @Environment(AppEnvironment.self) private var env
    @State private var query = ""
    @State private var grouping = ArchiveSections()

    var body: some View {
        let now = Date.now
        let calendar = Calendar.current
        let sections = grouping.sections(env.browser.archived, query: query, now: now, calendar: calendar)
        let timeCutoff = calendar.date(byAdding: .day, value: -Self.daysShowingTime, to: calendar.startOfDay(for: now))!
        let firstID = sections.first?.entries.first?.id
        NavigationStack {
            List {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.entries) { entry in
                            Button {
                                env.restore(entry.id)
                            } label: {
                                ArchiveRow(entry: entry, showsTime: entry.archivedAt >= timeCutoff)
                            }
                            .tint(.primary)
                            #if DEBUG
                            .background {
                                if entry.id == firstID {
                                    Color.clear.debugAction(.archiveRestore) { env.restore(entry.id) }
                                }
                            }
                            #endif
                        }
                        .onDelete { offsets in
                            for offset in offsets {
                                env.haptics.fire(.archiveDelete)
                                env.browser.deleteArchived(section.entries[offset].id)
                            }
                        }
                    }
                }
            }
            .overlay {
                if sections.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView("No Archived Tabs", systemImage: "archivebox")
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .navigationTitle("Archive")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .sheetDoneButton()
        }
    }
}

private struct ArchiveRow: View {
    @Environment(AppEnvironment.self) private var env
    let entry: ArchivedTab
    let showsTime: Bool

    var body: some View {
        let host = entry.url.host()
        let detail = host ?? entry.url.absoluteString
        HStack {
            SheetFavicon(box: host.map(env.favicons.favicon(for:)), size: Theme.Metrics.archiveFavicon)
            VStack(alignment: .leading) {
                Text(entry.title.isEmpty ? detail : entry.title)
                    .font(Theme.Typography.archiveTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detail)
                    .font(Theme.Typography.archiveDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(entry.archivedAt, format: showsTime ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day())
                .font(Theme.Typography.archiveDetail)
                .foregroundStyle(.secondary)
        }
    }
}

struct SheetFavicon: View {
    let box: FaviconBox?
    let size: CGFloat

    var body: some View {
        Group {
            if let image = box?.image {
                Image(uiImage: image).resizable()
            } else {
                Image(systemName: "globe").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}
