import SwiftUI

extension EnvironmentValues {
    @Entry var cardTitleOpacity: CGFloat = 1
}

struct CardHeader: View {
    let tab: Tab

    var body: some View {
        HStack {
            if tab.isPinned {
                Image(systemName: "pin.fill")
                    .font(Theme.Typography.cardHeaderPin)
                    .foregroundStyle(.white.opacity(Theme.Opacity.cardHeaderPin))
            }
            CardFavicon(url: tab.url) {
                RoundedRectangle(cornerRadius: Theme.Metrics.missingFaviconCorner).fill(Theme.Palette.missingFavicon)
            }
            .frame(width: Theme.Metrics.cardHeaderFavicon, height: Theme.Metrics.cardHeaderFavicon)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardHeaderFaviconCorner))
            Text(tab.title.isEmpty ? tab.url.host() ?? tab.url.absoluteString : tab.title)
                .font(Theme.Typography.cardHeaderTitle)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                // A private card adds a second line under the title, in the gap above the card.
                .overlay(alignment: .bottomLeading) {
                    if tab.isPrivate {
                        Text("Incognito Tab")
                            .font(Theme.Typography.cardHeaderSubtitle)
                            .foregroundStyle(Theme.Palette.privateCardSubtitle)
                            .fixedSize()
                            .alignmentGuide(.bottom) { $0[.top] }
                    }
                }
                .modifier(CardTitleFade())
        }
    }
}

// The title's opacity follows the deck position every frame. Reading it here, not in the header, keeps the header's
// text and favicon out of the per-frame update.
private struct CardTitleFade: ViewModifier {
    @Environment(\.cardTitleOpacity) private var opacity

    func body(content: Content) -> some View {
        content.opacity(opacity)
    }
}

struct CardFavicon<Missing: View>: View {
    @Environment(AppEnvironment.self) private var env
    let url: URL
    @ViewBuilder let missing: Missing

    var body: some View {
        if let host = url.host(), let image = env.favicons.favicon(for: host).image {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            missing
        }
    }
}
