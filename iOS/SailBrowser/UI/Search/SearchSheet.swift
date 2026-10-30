import SwiftUI

struct SearchSheet: View {
    private let model: SearchModel
    private let swipe: RecentSwipe
    private let privacy: SearchPrivacy
    private let onSelect: (Suggestion) -> Void

    init(model: SearchModel, swipe: RecentSwipe, privacy: SearchPrivacy, onSelect: @escaping (Suggestion) -> Void) {
        self.model = model
        self.swipe = swipe
        self.privacy = privacy
        self.onSelect = onSelect
    }

    // An empty incognito field shows no rows; typing brings them back at once.
    static func hidesRows(isPrivate: Bool, text: String) -> Bool {
        isPrivate && text.isEmpty
    }

    static let fieldSlotHeight = Theme.Metrics.searchSheetTopPadding + Theme.Metrics.searchFieldHeight
        + Theme.Metrics.searchFieldGap

    var body: some View {
        let hidden = Self.hidesRows(isPrivate: privacy.isOn, text: model.text)
        VStack(spacing: 0) {
            Color.clear
                .frame(height: Self.fieldSlotHeight)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.rows, id: \.self) { suggestion in
                        Button {
                            onSelect(suggestion)
                        } label: {
                            SuggestionRow(suggestion: suggestion)
                        }
                        .buttonStyle(SuggestionRowStyle())
                        .modifier(RecentSwipeReveal(swipe: swipe, suggestion: suggestion))
                        // A removed row goes at once; the rows below close its gap.
                        .transition(.identity)
                    }
                }
            }
            .scrollDisabled(true)
            .frame(height: Theme.Metrics.suggestionRowHeight * CGFloat(Theme.Metrics.suggestionRowCount))
            .transaction { transaction in
                if !transaction.recentSwipeMotion {
                    transaction.animation = nil
                }
            }
            // Only the toggle animates the rows; text changes show or hide them at once.
            .opacity(hidden ? 0 : 1)
            .animation(Theme.Motion.privateRowsFade.animation, value: privacy.isOn)
        }
        #if DEBUG
        .debugAction(.suggestionTap) { onSelect(model.rows[0]) }
        #endif
        .frame(height: Theme.Metrics.searchSheetAboveKeyboard, alignment: .top)
    }
}

@Observable final class SearchPrivacy {
    var isOn = false
}

// The bar the sheet lands in, or rises from.
@Observable final class SearchBarLook {
    var style = BarStyle.deck
}

struct SearchBarCopies: View {
    let atDeck: Bool
    let look: SearchBarLook

    var body: some View {
        HStack {
            if atDeck {
                circle("archivebox")
            } else {
                TabStackThumbnails(foreground: look.style.glyph)
                    .frame(width: Theme.Metrics.tabStackButtonSize.width, height: Theme.Metrics.tabStackButtonSize.height)
            }
            Spacer()
            circle(atDeck ? "gearshape" : "chevron.up")
        }
        .foregroundStyle(look.style.glyph)
        .padding(.horizontal, Theme.Metrics.barSideInset)
        .frame(height: Theme.Metrics.barHeight)
        .allowsHitTesting(false)
    }

    private func circle(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(Theme.Typography.barChevronGlyph)
            .frame(width: Theme.Metrics.controlSize, height: Theme.Metrics.controlSize)
            .background(look.style.controlFill, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(Theme.Opacity.barEdge), lineWidth: Theme.Metrics.hairlineWidth))
    }
}

struct SearchPlusGlyph: View {
    let look: SearchBarLook

    var body: some View {
        Image(systemName: "plus")
            .font(Theme.Typography.barPlusGlyph)
            .foregroundStyle(look.style.glyph)
    }
}
