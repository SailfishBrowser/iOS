import SwiftUI

// Hides a private tab's page in the switcher behind a flat grey card, with no glyph and no page detail.
struct PrivateCardCover: View {
    var body: some View {
        Theme.Palette.privateCard
    }
}
