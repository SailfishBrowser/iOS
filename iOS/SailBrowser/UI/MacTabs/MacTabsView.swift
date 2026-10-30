import SwiftUI

struct MacTabsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var page: String?

    var body: some View {
        let store = env.macTabs
        let mac = store.macs.first { $0.id == store.shownMacID }
        let spaces = mac.map(store.spaces(of:)) ?? []
        let ids = spaces.map(\.id)
        Group {
            if spaces.isEmpty {
                ContentUnavailableView("No Spaces", systemImage: "desktopcomputer")
            } else {
                TabView(selection: $page) {
                    ForEach(spaces, id: \.id) { entry in
                        MacSpacePage(space: entry.space)
                            .tag(Optional(entry.id))
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
            }
        }
        .overlay(alignment: .topTrailing) {
            header
        }
        .onAppear {
            land(mac, ids)
        }
        .onChange(of: ids) {
            if !ids.contains(where: { $0 == page }) {
                page = mac?.current.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
            }
        }
        .onChange(of: page) {
            store.sheetPage = page
        }
        .task {
            await store.fetch()
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Metrics.macTabsHeaderGap) {
            if env.macTabs.macs.count > 1 {
                Menu {
                    Picker("Mac", selection: Bindable(env.macTabs).shownMacID) {
                        ForEach(env.macTabs.macs) { mac in
                            Text(mac.name).tag(Optional(mac.id))
                        }
                    }
                } label: {
                    Image(systemName: "desktopcomputer")
                }
                .accessibilityLabel("Mac")
            }
            Button {
                env.haptics.fire(.sheetDone)
                env.ui.close()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityLabel("Close")
        }
        .font(Theme.Typography.macTabsHeaderGlyph)
        .foregroundStyle(.secondary)
        .padding(.top, Theme.Metrics.macTabsTop)
        .padding(.trailing, Theme.Metrics.macTabsInset)
    }

    // The Mac's current space the first time and whenever it has changed since the last open; otherwise the page
    // last viewed. A target the Mac no longer lists gives way to the first page.
    private func land(_ mac: MacDevice?, _ ids: [String]) {
        let store = env.macTabs
        let target = store.sheetPage == nil || mac?.current != store.sheetCurrent ? mac?.current : store.sheetPage
        store.sheetCurrent = mac?.current
        page = target.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
    }
}

private struct MacSpacePage: View {
    let space: MacSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(space.name)
                .font(Theme.Typography.macTabsSpaceTitle)
                .lineLimit(1)
                .padding(.top, Theme.Metrics.macTabsTop)
                .padding(.bottom, Theme.Metrics.macTabsTitleBottom)
                .padding(.leading, Theme.Metrics.macTabsInset)
                .padding(.trailing, Theme.Metrics.macTabsHeaderClearance)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    rows(space.pinned, group: "pinned")
                    if !space.pinned.isEmpty, !space.tabs.isEmpty {
                        Divider()
                            .padding(.horizontal, Theme.Metrics.macTabsInset)
                    }
                    rows(space.tabs, group: "tabs")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // A page can be listed twice, so a row is known by its group and place.
    private func rows(_ pages: [MacSpace.Page], group: String) -> some View {
        ForEach(pages.indices.map { (id: "\(group).\($0)", page: pages[$0]) }, id: \.id) {
            MacPageRow(page: $0.page)
        }
    }
}

private struct MacPageRow: View {
    @Environment(AppEnvironment.self) private var env
    let page: MacSpace.Page

    var body: some View {
        Button {
            env.openFromMac(page.url)
        } label: {
            HStack(spacing: Theme.Metrics.macTabsIconGap) {
                SheetFavicon(box: page.icon.flatMap(UIImage.init(data:)).map(Self.box))
                Text(page.title.isEmpty ? page.url.host() ?? page.url.absoluteString : page.title)
                    .font(Theme.Typography.macTabsRow)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, minHeight: Theme.Metrics.macTabsRowHeight, alignment: .leading)
            .padding(.horizontal, Theme.Metrics.macTabsInset)
            .contentShape(.rect)
        }
        .tint(.primary)
    }

    private static func box(_ image: UIImage) -> FaviconBox {
        let box = FaviconBox()
        box.set(image: image, tint: nil)
        return box
    }
}
