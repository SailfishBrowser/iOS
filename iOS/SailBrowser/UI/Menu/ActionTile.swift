import SwiftUI
import UIKit

// A tile with its glyph centred, and its label under it.
struct ActionTile: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let systemImage: String
    let fill: Color
    let ink: Color
    let preparing: Interaction
    let action: () -> Void

    private static let label = Theme.Typography.menuTileLabelUIFont
    // A text's frame starts above its cap top and ends below its baseline by the font's own metrics.
    private static let labelGap = Theme.Metrics.menuTileLabelGap - (label.ascender - label.capHeight)
    static let labelToList = Theme.Metrics.menuLabelToList - (label.lineHeight - label.ascender)

    var body: some View {
        VStack(spacing: Self.labelGap) {
            Button(action: action) {
                // No symbol transition: the first one in the process holds its frame about 200 ms while it is
                // prepared, so the pin tile's swap would miss the tap's frame. The glyph swaps with its title.
                Image(systemName: systemImage)
                    .font(Theme.Typography.menuTileIcon)
                    .foregroundStyle(ink.opacity(Theme.Opacity.menuIcon))
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.Metrics.menuTileHeight)
                    .background(
                        fill, in: RoundedRectangle(cornerRadius: Theme.Metrics.menuTileCorner, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.menuTileCorner, style: .continuous))
            }
            .buttonStyle(PressStyle(scale: Theme.Metrics.pressScale, preparing: preparing))
            .accessibilityLabel(title)
            Text(title)
                .font(Theme.Typography.menuTileLabel)
                .tracking(Theme.Metrics.menuTileLabelTracking)
                .foregroundStyle(ink.opacity(Theme.Opacity.menuSecondary))
                .accessibilityHidden(true)
        }
        .opacity(isEnabled ? 1 : Theme.Opacity.navPillDisabled)
    }
}
