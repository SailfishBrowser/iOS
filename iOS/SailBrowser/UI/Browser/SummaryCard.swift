import SwiftUI

// The page's summary on a plain card in the page menu's material: the page's title, Done, and the summary as it
// streams in, with nothing else. "Summarizing" shows until the first words, and "No summary" stands for a page with no
// readable text, a language the model does not support, or a failed run.
struct SummaryCard: View {
    let title: String
    let summarizer: PageSummarizer
    let look: MenuLook
    let done: () -> Void

    var body: some View {
        let ink = Theme.Palette.menuInk(light: look.isLight)
        ViewThatFits(in: .vertical) {
            content(ink: ink)
            ScrollView { content(ink: ink) }
        }
        .background { CardMaterial(look: look) }
        .clipShape(.rect(cornerRadius: Theme.Metrics.menuSheetCorner, style: .continuous))
        // At the top, so the title and Done hold still while the summary grows below them.
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, look.isLight ? .light : .dark)
    }

    private func content(ink: Color) -> some View {
        VStack(alignment: .leading, spacing: Theme.Fold.cardSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Fold.cardSpacing) {
                Text(title)
                    .font(Theme.Typography.summaryTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Done", action: done)
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(ink.opacity(Theme.Opacity.menuPrimary))
            Text(text)
                .foregroundStyle(ink.opacity(hasSummary ? Theme.Opacity.menuPrimary : Theme.Opacity.menuSecondary))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Fold.cardPadding)
    }

    private var text: String {
        switch summarizer.state {
        case .idle, .summarizing(""): "Summarizing"
        case .done(""), .noSummary: "No summary"
        case .summarizing(let text), .done(let text): text
        }
    }

    private var hasSummary: Bool {
        switch summarizer.state {
        case .idle, .summarizing(""), .done(""), .noSummary: false
        case .summarizing, .done: true
        }
    }
}

// The menu sheet's own background: its thick material under its measured gradient.
private struct CardMaterial: UIViewRepresentable {
    let look: MenuLook

    func makeUIView(context: Context) -> MenuSheetBackground {
        MenuSheetBackground()
    }

    func updateUIView(_ view: MenuSheetBackground, context: Context) {
        view.apply(look)
    }
}
