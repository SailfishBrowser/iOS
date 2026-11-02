import SwiftUI

// The page's summary in the order Arc Search lays it out: the site's icon and the page's title over a picture of its
// top, the lead paragraph, then each section under its kind's symbol and its heading, as they stream in, and a round
// close button below at the right. It sits at the top and scrolls, so nothing climbs as the words arrive.
// "Summarizing" shows until the first words, and "No summary" stands for a page with no readable text, a language the
// model does not support, or a failed run. A site with no icon yet shows the switcher's grey square in its place.
struct SummaryCard: View {
    let title: String
    let favicon: FaviconBox?
    let snapshot: UIView
    let summarizer: PageSummarizer
    let done: () -> Void

    var body: some View {
        let ink = Theme.Palette.menuInk(light: false)
        VStack(spacing: Theme.Fold.closeSpacing) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Fold.sectionSpacing) {
                    page(ink: ink)
                    if let summary {
                        Text(summary.lead)
                            .font(Theme.Typography.summaryLead)
                            .foregroundStyle(ink.opacity(Theme.Opacity.menuPrimary))
                        ForEach(summary.sections.indices, id: \.self) { index in
                            section(summary.sections[index], ink: ink)
                        }
                    } else {
                        Text(label)
                            .font(Theme.Typography.summaryLead)
                            .foregroundStyle(ink.opacity(Theme.Opacity.menuSecondary))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            Button(action: done) {
                Image(systemName: "xmark")
                    .font(Theme.Typography.summaryClose)
                    .foregroundStyle(ink.opacity(Theme.Opacity.menuPrimary))
                    .frame(width: Theme.Fold.closeSize, height: Theme.Fold.closeSize)
                    .background(Circle().fill(ink.opacity(Theme.Fold.closeFill)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .environment(\.colorScheme, .dark)
    }

    private func page(ink: Color) -> some View {
        VStack(spacing: Theme.Fold.titleSpacing) {
            HStack(spacing: Theme.Fold.titleSpacing) {
                Group {
                    if let image = favicon?.image {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: Theme.Metrics.missingFaviconCorner)
                            .fill(Theme.Palette.missingFavicon)
                    }
                }
                .frame(width: Theme.Metrics.cardHeaderFavicon, height: Theme.Metrics.cardHeaderFavicon)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardHeaderFaviconCorner))
                .accessibilityHidden(true)
                Text(title)
                    .font(Theme.Typography.cardHeaderTitle)
                    .foregroundStyle(ink.opacity(Theme.Opacity.menuPrimary))
                    .lineLimit(1)
            }
            PageSnapshot(snapshot: snapshot)
                .aspectRatio(1, contentMode: .fit)
                .containerRelativeFrame(.horizontal) { width, _ in width * Theme.Fold.snapshotWidth }
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }

    private func section(_ section: PageSummary.Section, ink: Color) -> some View {
        VStack(alignment: .leading, spacing: Theme.Fold.headingSpacing) {
            HStack(spacing: Theme.Fold.iconSpacing) {
                Image(systemName: Self.symbol(section.kind))
                    .font(Theme.Typography.summaryIcon)
                    .foregroundStyle(.white)
                    .frame(width: Theme.Fold.iconSize, height: Theme.Fold.iconSize)
                    .background(Circle().fill(Theme.Fold.icon))
                    .accessibilityHidden(true)
                Text(section.heading)
                    .font(Theme.Typography.summaryHeading)
                    .foregroundStyle(ink.opacity(Theme.Opacity.menuPrimary))
            }
            Text(section.body)
                .font(Theme.Typography.summaryBody)
                .foregroundStyle(ink.opacity(Theme.Fold.bodyOpacity))
                .padding(.leading, Theme.Fold.iconSize + Theme.Fold.iconSpacing)
        }
    }

    private static func symbol(_ kind: PageSummary.Kind) -> String {
        switch kind {
        case .topics: "list.bullet"
        case .people: "person.2.fill"
        case .dates: "calendar"
        case .how: "gearshape.fill"
        case .where: "mappin"
        case .money: "dollarsign"
        case .other: "text.alignleft"
        }
    }

    private var summary: PageSummary? {
        switch summarizer.state {
        case .summarizing(let summary), .done(let summary):
            summary.lead.isEmpty && summary.sections.isEmpty ? nil : summary
        case .idle, .noSummary: nil
        }
    }

    private var label: String {
        switch summarizer.state {
        case .idle, .summarizing: "Summarizing"
        case .done, .noSummary: "No summary"
        }
    }
}

// The picture of the page's top, a snapshot view scaled down to the width it is given.
private struct PageSnapshot: UIViewRepresentable {
    let snapshot: UIView

    final class Frame: UIView {
        let snapshot: UIView

        init(snapshot: UIView) {
            self.snapshot = snapshot
            super.init(frame: .zero)
            layer.cornerRadius = Theme.Fold.snapshotCorner
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            addSubview(snapshot)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let scale = bounds.width / snapshot.bounds.width
            snapshot.transform = CGAffineTransform(scaleX: scale, y: scale)
            snapshot.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    func makeUIView(context: Context) -> Frame {
        Frame(snapshot: snapshot)
    }

    func updateUIView(_ frame: Frame, context: Context) {}
}
