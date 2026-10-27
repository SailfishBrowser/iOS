import SwiftUI

struct TabCardView: View {
    @Environment(AppEnvironment.self) private var env
    let tab: Tab
    let isActive: Bool
    let layout: CardLayout
    let geometry: CardGeometry

    var body: some View {
        Group {
            if isActive, let controller = env.activeController, controller.tabID == tab.id {
                WebPageView(
                    controller: controller, geometry: geometry,
                    // A sliding or lifting page takes no touch: a touch on it holds the pages instead.
                    isInteractive: env.ui.deckProgress == 0 && env.ui.overlay == .none && !env.ui.deck.isPaging
                        && env.ui.deck.flickIDs.isEmpty,
                    isPrivate: tab.isPrivate)
                    #if DEBUG
                    .debugSurface(.webScroll, controller.debugScroll)
                    #endif
                    .transition(.identity)
            } else {
                CardSnapshot(thumbnail: env.snapshots.thumbnail(for: tab.id), tab: tab, layout: layout)
                    .frame(width: layout.screen.width, height: layout.screen.height)
                    .placedAndClipped(geometry)
                    .transition(.identity)
            }
        }
        .frame(width: layout.screen.width, height: layout.screen.height)
        .onAppear {
            env.snapshots.preload([tab.id])
        }
    }
}

struct CardSnapshot: View {
    let thumbnail: Thumbnail
    let tab: Tab
    let layout: CardLayout

    var body: some View {
        // A full picture that is gone (a memory warning, the budget) leaves the small one until it is decoded again.
        if let image = thumbnail.image ?? thumbnail.small {
            Image(uiImage: image).resizable()
        } else {
            ZStack {
                if let tint = tab.tint {
                    Color(red: tint.red, green: tint.green, blue: tint.blue)
                } else {
                    Theme.Palette.newTabPlaceholder
                }
                CardFavicon(url: tab.url) {
                    Image(systemName: "globe")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.white.opacity(Theme.Opacity.cardHeaderPin))
                }
                .frame(
                    width: Theme.Metrics.cardPlaceholderFavicon / layout.restScale,
                    height: Theme.Metrics.cardPlaceholderFavicon / layout.restScale)
            }
        }
    }
}
