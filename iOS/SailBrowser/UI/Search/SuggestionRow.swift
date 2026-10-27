import SwiftUI

// The highlight lands on touch-down with no animation and fades on release. Its animation sits inside the style,
// scoped to the highlight, because the list strips outer animations and row content never animates.
struct SuggestionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SuggestionRowLabel(configuration: configuration)
    }
}

private struct SuggestionRowLabel: View {
    @Environment(AppEnvironment.self) private var env
    let configuration: ButtonStyleConfiguration

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .background {
                Theme.Palette.suggestionHighlight
                    .opacity(pressed ? 1 : 0)
                    .animation(pressed ? nil : Theme.Motion.rowRelease.animation, value: pressed)
            }
            .onChange(of: pressed) { _, isPressed in
                if isPressed {
                    env.haptics.prepare(.suggestionTap)
                } else {
                    FrameRateVote.hold(Theme.Motion.rowRelease)
                }
            }
    }
}

struct SuggestionRow: View {
    @Environment(AppEnvironment.self) private var env
    let suggestion: Suggestion

    var body: some View {
        HStack(spacing: Theme.Metrics.suggestionIconGap) {
            icon
                .frame(width: Theme.Metrics.suggestionFavicon, height: Theme.Metrics.suggestionFavicon)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(Theme.Typography.suggestionTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if case .match(let url, _) = suggestion {
                    Text(SuggestionRanker.bareHost(url))
                        .font(Theme.Typography.suggestionSubtitle)
                        .foregroundStyle(.white.opacity(Theme.Opacity.suggestionSecondary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, Theme.Metrics.suggestionRowLeading)
        .padding(.trailing, Theme.Metrics.suggestionRowTrailing)
        .frame(height: Theme.Metrics.suggestionRowHeight)
        .contentShape(Rectangle())
    }

    private var title: String {
        switch suggestion {
        case .site(let url, let title), .match(let url, let title): title.isEmpty ? url.absoluteString : title
        case .query(let query): query
        }
    }

    @ViewBuilder private var icon: some View {
        switch suggestion {
        case .site(let url, _), .match(let url, _):
            if let host = url.host() {
                Favicon(box: env.favicons.favicon(for: host))
            } else {
                Symbol(name: "globe")
            }
        case .query:
            Symbol(name: "magnifyingglass")
        }
    }
}

private struct Favicon: View {
    let box: FaviconBox

    var body: some View {
        if let image = box.image {
            Image(uiImage: image)
                .resizable()
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.suggestionFaviconCorner, style: .continuous))
        } else {
            Symbol(name: "globe")
        }
    }
}

private struct Symbol: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .font(Theme.Typography.suggestionSymbol)
            .foregroundStyle(.white.opacity(Theme.Opacity.suggestionSecondary))
    }
}
