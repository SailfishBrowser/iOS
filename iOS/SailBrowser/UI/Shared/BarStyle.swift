import SwiftUI

// The bar's look in one place: the deck's strip, or the browsing bar over a light or dark page. Both bars, the
// search sheet's copies of their controls, its "+" pill and the material it lands on all read it, so the sheet's
// landing on a bar can never step.
struct BarStyle: Equatable {
    let atDeck: Bool
    let light: Bool
    let isPrivate: Bool

    static let deck = BarStyle(atDeck: true, light: false, isPrivate: false)

    static func browsing(on tint: UIColor, in colorScheme: ColorScheme, isPrivate: Bool) -> BarStyle {
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        return BarStyle(atDeck: false, light: Theme.Palette.isLight(tint, in: traits), isPrivate: isPrivate)
    }

    // A private tab's bar is dark over any page, so its glyphs stay white.
    var glyph: Color { light && !atDeck && !isPrivate ? .black : .white }

    var controlFill: Color {
        if atDeck { return .white.opacity(Theme.Opacity.switcherControlFill) }
        if isPrivate { return Theme.Palette.privateBarControlFill }
        return light ? .black.opacity(Theme.Opacity.browsingControlFill) : .white.opacity(Theme.Opacity.darkBarControlFill)
    }
}

struct BarBackground: View {
    let style: BarStyle

    var body: some View {
        if style.atDeck {
            Theme.Palette.deckBarStrip
        } else if style.isPrivate {
            Theme.Palette.privateBarBackground
        } else {
            ChromeMaterialView(style: Theme.Frost.bar(light: style.light))
        }
    }
}
