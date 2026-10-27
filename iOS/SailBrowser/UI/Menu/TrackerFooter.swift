import SwiftUI

// The count is a floor: WebKit reports no rule list matches, so only blocked element loads are seen.
struct TrackerFooter: View {
    enum Content: Equatable {
        case scrubbed(Int), allowed

        static func of(blocksGlobally: Bool, blocksSite: Bool, count: Int) -> Content? {
            guard blocksGlobally else { return nil }
            guard blocksSite else { return .allowed }
            return count > 0 ? .scrubbed(count) : nil
        }
    }

    // What the footer shows, and for which site its tap acts.
    struct Shown: Equatable {
        let host: String
        let content: Content
    }

    @Environment(AppEnvironment.self) private var env
    let shown: Shown
    let fill: Color
    let isLight: Bool

    var body: some View {
        Button {
            env.setTrackerBlocking(shown.content == .allowed, forHost: shown.host)
        } label: {
            label
                .font(Theme.Typography.menuFooter)
                .frame(maxWidth: .infinity, minHeight: Theme.Metrics.menuFooterHeight, alignment: .leading)
                .padding(.horizontal, Theme.Metrics.menuFooterInset)
                .background(fill, in: RoundedRectangle(cornerRadius: Theme.Metrics.menuListCorner, style: .continuous))
                .contentShape(Rectangle())
        }
    }

    private var label: some View {
        let secondary = isLight
            ? AnyShapeStyle(Color(uiColor: Theme.Palette.menuFooterSecondary)) : AnyShapeStyle(.secondary)
        return VStack(alignment: .leading, spacing: 0) {
            switch shown.content {
            case .scrubbed(let count):
                let number = Text(count, format: .number).font(Theme.Typography.menuFooterCount)
                Text("Sailfish scrubbed \(number) \(count == 1 ? "tracker" : "trackers")")
                Text("Problems? Tap to restore original page").foregroundStyle(secondary)
            case .allowed:
                Text("Trackers allowed on this site")
                Text("Tap to block them again").foregroundStyle(secondary)
            }
        }
    }
}
