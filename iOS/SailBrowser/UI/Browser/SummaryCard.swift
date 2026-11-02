import SwiftUI

// The page's summary in the order Arc Search lays it out: the site's icon and the page's title over a picture of its
// top, the lead paragraph, then each section under its kind's symbol and its heading, as they stream in, and a round
// close button below at the right. It sits at the top and scrolls, so nothing climbs as the words arrive.
// "Summarizing" shows until the first words, and "No summary" stands for a page with no readable text, a language the
// model does not support, or a failed run. A site with no icon yet shows the switcher's grey square in its place. The
// card shows only while the fold is closed and at rest: it rises in once the fold settles, and goes as a pinch out
// begins.
struct SummaryCard: View {
    let title: String
    let favicon: FaviconBox?
    let snapshot: UIView
    let snapshotSize: CGSize
    let summarizer: PageSummarizer
    let reveal: SummaryReveal
    let done: () -> Void

    var body: some View {
        let ink = Theme.Palette.menuInk(light: false)
        let shown = reveal.isShown
        VStack(spacing: Theme.Fold.closeSpacing) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Fold.sectionSpacing) {
                    page(ink: ink)
                        .revealed(shown, second: false)
                    VStack(alignment: .leading, spacing: Theme.Fold.sectionSpacing) {
                        if let summary {
                            StreamedText(text: summary.lead, color: ink.opacity(Theme.Opacity.menuPrimary))
                                .font(Theme.Typography.summaryLead)
                                .transition(Self.arrival)
                            ForEach(summary.sections.indices, id: \.self) { index in
                                section(summary.sections[index], ink: ink)
                                    .transition(Self.arrival)
                            }
                        } else {
                            Text(label)
                                .font(Theme.Typography.summaryLead)
                                .foregroundStyle(ink.opacity(Theme.Opacity.menuSecondary))
                                .frame(maxWidth: .infinity)
                                .transition(.opacity)
                        }
                    }
                    .animation(Theme.Motion.summarySection.animation, value: summary == nil)
                    .animation(Theme.Motion.summarySection.animation, value: summary?.sections.count)
                    .revealed(shown, second: true)
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
            .revealed(shown, second: true)
        }
        .allowsHitTesting(shown)
        .accessibilityHidden(!shown)
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
                .frame(width: snapshotSize.width, height: snapshotSize.height)
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
                StreamedText(text: section.heading, color: ink.opacity(Theme.Opacity.menuPrimary))
                    .font(Theme.Typography.summaryHeading)
            }
            StreamedText(text: section.body, color: ink.opacity(Theme.Fold.bodyOpacity))
                .font(Theme.Typography.summaryBody)
                .padding(.leading, Theme.Fold.iconSize + Theme.Fold.iconSpacing)
        }
    }

    private static let arrival = AnyTransition.opacity.combined(with: .offset(y: Theme.Fold.sectionRise))

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

// Whether the summary shows: set as the fold settles closed and cleared as it starts to open.
@Observable final class SummaryReveal {
    var isShown = false
}

private extension View {
    // The second part comes in a beat after the first and goes a beat before it.
    func revealed(_ shown: Bool, second: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : Theme.Fold.revealRise)
            .animation(
                Theme.Motion.summaryReveal.animation.delay(shown == second ? Theme.Motion.summaryRevealBeat : 0),
                value: shown)
    }
}

// Text that arrives as the model writes it: each change that extends it adds a part, and a new part fades in where it
// lands while the text before it holds, so the words never pop and no space is held for them. The text a view starts
// with shows whole, as does a change that does not extend it. Parts are counted in characters. Until a change is seen,
// the text past the known parts is not shown, so no frame shows it at full strength. The view redraws on the display's
// clock only while a part is fading.
private struct StreamedText: View {
    private struct Part: Equatable {
        let start: Int
        let at: Date
    }

    let text: String
    let color: Color
    @State private var parts: [Part] = []
    @State private var known: Int
    @State private var settled = Date.distantPast

    init(text: String, color: Color) {
        self.text = text
        self.color = color
        _known = State(initialValue: text.count)
    }

    var body: some View {
        let fade = Theme.Motion.summaryTextFade
        let fading = parts.last.map { $0.at.addingTimeInterval(fade) > settled } ?? false
        TimelineView(.animation(paused: !fading)) { context in
            Text(attributed(at: context.date))
        }
        .onChange(of: text) { old, new in
            let now = Date.now
            parts = new.count > known && new.hasPrefix(old)
                ? parts.filter { now.timeIntervalSince($0.at) < fade } + [Part(start: known, at: now)] : []
            known = new.count
        }
        .task(id: parts.last?.at) {
            guard (try? await Task.sleep(for: .seconds(fade))) != nil else { return }
            settled = .now
        }
    }

    private func attributed(at now: Date) -> AttributedString {
        var string = AttributedString(text)
        string.foregroundColor = color
        let count = string.characters.count
        let bounds = parts.map(\.start) + [known]
        for (index, part) in parts.enumerated() {
            let share = min(1, max(0, now.timeIntervalSince(part.at) / Theme.Motion.summaryTextFade))
            set(&string, from: part.start, to: bounds[index + 1], count: count, opacity: UnitCurve.easeOut.value(at: share))
        }
        set(&string, from: known, to: count, count: count, opacity: 0)
        return string
    }

    private func set(_ string: inout AttributedString, from start: Int, to end: Int, count: Int, opacity: Double) {
        let lower = string.index(string.startIndex, offsetByCharacters: min(start, count))
        let upper = string.index(string.startIndex, offsetByCharacters: min(max(start, end), count))
        string[lower..<upper].foregroundColor = color.opacity(opacity)
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
