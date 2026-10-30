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

    // What the footer shows, and for which site.
    struct Shown: Equatable {
        let host: String
        let content: Content
    }

    let shown: Shown
    let fill: Color
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            label
                .font(Theme.Typography.menuFooter)
                .frame(maxWidth: .infinity, minHeight: Theme.Metrics.menuListRowHeight, alignment: .leading)
                .padding(.horizontal, Theme.Metrics.menuFooterInset)
                .background(fill, in: RoundedRectangle(cornerRadius: Theme.Metrics.menuListCorner, style: .continuous))
                .contentShape(Rectangle())
        }
        .accessibilityHint("Opens Site Settings")
    }

    @ViewBuilder private var label: some View {
        switch shown.content {
        case .scrubbed(let count):
            let number = Text(count, format: .number).font(Theme.Typography.menuFooterCount)
            Text("\(number) \(count == 1 ? "tracker" : "trackers") blocked")
        case .allowed:
            Text("Trackers allowed")
        }
    }
}
