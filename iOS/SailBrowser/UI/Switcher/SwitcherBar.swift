import SwiftUI

struct SwitcherBar: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack {
            circleButton("archivebox", label: "Archive", overlay: .archive, interaction: .archiveOpen)
            Spacer()
            SearchPill(fill: BarStyle.deck.controlFill, atDeck: true)
            Spacer()
            circleButton("gearshape", label: "Settings", overlay: .settings, interaction: .settingsOpen)
        }
        .buttonStyle(.plain)
        .foregroundStyle(BarStyle.deck.glyph)
        .padding(.horizontal, Theme.Metrics.barSideInset)
        .frame(height: Theme.Metrics.barHeight)
        .padding(.bottom, Theme.Metrics.barControlCenterFromBottom - Theme.Metrics.barHeight / 2)
        .frame(height: Theme.Metrics.barTotalHeight, alignment: .bottom)
        .background {
            BarBackground(style: .deck)
                .overlay(alignment: .top) { BarHairline() }
        }
    }

    private func circleButton(
        _ symbol: String, label: String, overlay: UIState.Overlay, interaction: Interaction
    ) -> some View {
        let open: @MainActor () -> Void = {
            guard env.ui.canOpen(overlay) else { return }
            env.haptics.fire(interaction)
            env.ui.open(overlay)
        }
        return Button(action: open) {
            Image(systemName: symbol)
                .font(Theme.Typography.barChevronGlyph)
                .frame(width: Theme.Metrics.controlSize, height: Theme.Metrics.controlSize)
                .background(BarStyle.deck.controlFill, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(Theme.Opacity.barEdge), lineWidth: Theme.Metrics.hairlineWidth))
        }
        #if DEBUG
        .debugAction(interaction, open)
        #endif
        .accessibilityLabel(label)
    }
}
