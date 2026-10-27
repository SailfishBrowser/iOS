import SwiftUI

// A tap opens the switcher; a flick up switches to the previous tab, lifting the live page off as it goes
// (TabStackFlick).
struct TabStackButton: View {
    enum Release: Equatable { case tap, flick, none }

    static let hitOutset: CGFloat = {
        let size = Theme.Metrics.tabStackThumbnailSize
        let tilt = CGFloat(Angle.degrees(Theme.Metrics.tabStackTilt).radians)
        let drawnHeight: CGFloat = size.height * cos(tilt) + size.width * sin(tilt)
        let shift: CGFloat = Theme.Metrics.tabStackThumbnailOffsets.map { abs($0.height) }.max()!
        return drawnHeight / 2 + shift - Theme.Metrics.tabStackButtonSize.height / 2
    }()

    @Environment(AppEnvironment.self) private var env
    @GestureState private var isTracking = false
    @State private var startedAt = Date.distantPast
    // The touch picked up a flick already moving, so its release is the flick's whatever its own travel.
    @State private var caught = false
    let foreground: Color

    var body: some View {
        TabStackThumbnails(foreground: foreground)
            .frame(width: Theme.Metrics.tabStackButtonSize.width, height: Theme.Metrics.tabStackButtonSize.height)
            .contentShape(Rectangle().inset(by: -Self.hitOutset))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isTracking) { value, isTracking, _ in
                        guard !isTracking else { return }
                        isTracking = true
                        began(DragSample(value))
                    }
                    .onChanged { changed(DragSample($0)) }
                    .onEnded { ended(DragSample($0)) })
            // A cancelled touch lets the flick go where it is drawn; after an end this finds nothing to release.
            .onChange(of: isTracking) { _, isTracking in
                if !isTracking {
                    env.flick?.lifted(velocity: .zero)
                }
            }
            #if DEBUG
            .debugSurface(.tabStack) { phase, sample in
                switch phase {
                case .began: began(sample)
                case .changed: changed(sample)
                case .ended: ended(sample)
                case .cancelled: env.flick?.lifted(velocity: .zero)
                }
            }
            #endif
            .accessibilityLabel("Tabs")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { env.showSwitcher(via: .tabStackTap) }
    }

    // A pull that locked is never a tap, however short: the flick returns instead of the switcher opening over an
    // armed page. A flick needs the vertical lock, upward, and a coast past the line.
    static func release(_ sample: DragSample, duration: TimeInterval, locked: Bool) -> Release {
        let translation = sample.translation
        if !locked, hypot(translation.width, translation.height) < Theme.Gesture.tapMaxTravel,
            duration < Theme.Gesture.tapMaxDuration
        {
            return .tap
        }
        guard BarSwipe.lock(translation) == .vertical, translation.height < 0 else { return .none }
        return finishes(travel: -translation.height, velocity: sample.velocity.height) ? .flick : .none
    }

    // The flick finishes where the release's coast takes it past the flick distance, so a still finger past it
    // finishes and a flick down returns. Velocity is the finger's, down positive.
    static func finishes(travel: CGFloat, velocity: CGFloat) -> Bool {
        travel + Magnet.project(velocity: -velocity, rate: Theme.Gesture.decelerationFast)
            >= Theme.Gesture.tabStackFlickDistance
    }

    private func began(_ sample: DragSample) {
        startedAt = sample.time
        env.haptics.prepare(.tabStackTap, .tabStackFlick)
        caught = env.flick?.touchDown() == true
    }

    private func changed(_ sample: DragSample) {
        env.haptics.prepare(.tabStackFlick)
        env.flick?.moved(sample.translation, from: sample.startLocation)
    }

    private func ended(_ sample: DragSample) {
        let locked = env.flick?.isDragging == true
        if !caught, Self.release(sample, duration: sample.time.timeIntervalSince(startedAt), locked: locked) == .tap {
            env.showSwitcher(via: .tabStackTap)
            return
        }
        env.flick?.lifted(velocity: sample.velocity)
    }
}

struct TabStackThumbnails: View {
    private static let tilts = [Theme.Metrics.tabStackTilt, -Theme.Metrics.tabStackTilt]

    @Environment(AppEnvironment.self) private var env
    let foreground: Color

    // The stack: the two most recent other tabs, the front one the tab a
    // flick goes to. While the front card is out of the stack, as the flick's rising card or the swipe's older card,
    // the stack shows one fewer card and the back card stays put. The deck draws the travelling card under the bar,
    // so the bar draws an opaque copy of it over its controls (TabStackCopies): the same picture, crop and place,
    // clipped to the bar. A page a landing drops in is drawn the same way until the store switches tab, which
    // re-ranks the stack with no motion. A swipe whose older neighbour is not the front card takes no card from the
    // stack.
    static func cards(recent: [Tab.ID], flights: [DeckDriver.StackFlight]) -> (
        fixed: [(id: Tab.ID, rank: Int)], copies: [DeckDriver.StackFlight]
    ) {
        let out = flights.first { $0.leaving && $0.fromStack < 1 }?.id
        return (fixed(recent: recent, outOfStack: out), copies(recent: recent, flights: flights))
    }

    // The stack's own cards: one fewer while its front card is the one out.
    static func fixed(recent: [Tab.ID], outOfStack: Tab.ID?) -> [(id: Tab.ID, rank: Int)] {
        recent.enumerated().filter { !(outOfStack == recent.first && $0.offset == 0) }
            .map { (id: $0.element, rank: $0.offset) }
    }

    // The bar's copies: the front card on its way, and any page dropping in.
    static func copies(recent: [Tab.ID], flights: [DeckDriver.StackFlight]) -> [DeckDriver.StackFlight] {
        let front = recent.first
        return flights.filter { flight in
            flight.fromStack > 0 && (flight.leaving ? flight.id == front && flight.fromStack < 1 : true)
        }
    }

    @MainActor static func recent(in env: AppEnvironment) -> [Tab.ID] {
        env.browser.tabs.filter { $0.id != env.browser.activeTabID }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }.prefix(tilts.count).map(\.id)
    }

    @MainActor static func cards(in env: AppEnvironment) -> (
        fixed: [(id: Tab.ID, rank: Int)], copies: [DeckDriver.StackFlight]
    ) {
        let flights = env.pager.map { env.ui.deck.stackFlights(layout: $0.layout) } ?? []
        return cards(recent: recent(in: env), flights: flights)
    }

    // Reads the driver's out card, written once per gesture, not the per-frame flights.
    var body: some View {
        let byID = Dictionary(uniqueKeysWithValues: env.browser.tabs.map { ($0.id, $0) })
        let fixed = Self.fixed(recent: Self.recent(in: env), outOfStack: env.ui.deck.outOfStack)
        ZStack {
            ForEach(fixed.reversed(), id: \.id) { card in
                let content = StackThumbnail.content(of: byID[card.id]!, snapshots: env.snapshots, inSwipe: false)
                StackThumbnail(thumbnail: content.thumbnail, fill: content.fill, foreground: foreground)
                    .rotationEffect(.degrees(Self.tilts[card.rank]))
                    .offset(Theme.Metrics.tabStackThumbnailOffsets[card.rank])
            }
        }
    }
}

// The bar's copies of the cards travelling to or from the tab stack, over every control on the bar and clipped to it,
// so the part of a card the bar hides shows over the "+" pill and the chevron as the deck draws it.
struct TabStackCopies: View {
    @Environment(AppEnvironment.self) private var env
    let foreground: Color

    var body: some View {
        if let layout = env.pager?.layout {
            let byID = Dictionary(uniqueKeysWithValues: env.browser.tabs.map { ($0.id, $0) })
            let button = layout.tabStackButtonFrame
            ZStack {
                ForEach(TabStackThumbnails.cards(in: env).copies, id: \.id) { flight in
                    // The copy shows what the deck's card under it shows.
                    let content = StackThumbnail.content(
                        of: byID[flight.id]!, snapshots: env.snapshots, inSwipe: env.ui.deck.pair != nil)
                    StackCopy(
                        geometry: StackCopy.Geometry(flight.transform, layout: layout),
                        thumbnail: content.thumbnail, fill: content.fill, foreground: foreground)
                }
            }
            .frame(width: 0, height: 0)
            .position(x: button.midX, y: button.midY - (layout.screen.height - Theme.Metrics.barTotalHeight))
            .frame(width: layout.screen.width, height: Theme.Metrics.barTotalHeight)
            .clipped()
            .allowsHitTesting(false)
        }
    }
}

// The bar's copy of a card travelling to or from the tab stack's front slot: drawn exactly where the deck draws it,
// relative to the tab stack button's centre.
struct StackCopy: View {
    struct Geometry: Equatable {
        let centre: CGPoint
        let size: CGSize
        let rotation: Angle
        let corner: CGFloat

        init(_ t: CardTransform, layout: CardLayout) {
            let screen = layout.screen
            let button = layout.tabStackButtonFrame
            let top = screen.height / 2 + t.offset.height - screen.height * t.scale / 2
            centre = CGPoint(
                x: screen.width / 2 + t.offset.width - button.midX,
                y: top + (t.clipTop + t.clipHeight) / 2 - button.midY)
            size = CGSize(width: screen.width * t.scale, height: t.clipHeight - t.clipTop)
            rotation = t.rotation
            corner = t.corner
        }
    }

    let geometry: Geometry
    let thumbnail: Thumbnail?
    let fill: Color
    let foreground: Color

    var body: some View {
        StackCard(
            thumbnail: thumbnail, fill: fill, foreground: foreground, size: geometry.size, corner: geometry.corner)
            .rotationEffect(geometry.rotation)
            .offset(x: geometry.centre.x, y: geometry.centre.y)
            .allowsHitTesting(false)
    }
}

// A tab's picture as the stack draws it: the page from its top, as the deck's card clips it, with a hairline border.
struct StackCard: View {
    @Environment(\.displayScale) private var displayScale
    let thumbnail: Thumbnail?
    let fill: Color
    let foreground: Color
    let size: CGSize
    let corner: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner)
        Group {
            if let image = thumbnail?.image ?? thumbnail?.small {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: size.width, height: size.width * image.size.height / image.size.width)
                    .frame(width: size.width, height: size.height, alignment: .top)
            } else {
                fill
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(foreground.opacity(Theme.Opacity.tabStackBorder), lineWidth: 1 / displayScale))
    }
}

struct StackThumbnail: View {
    let thumbnail: Thumbnail?
    let fill: Color
    let foreground: Color

    // A tab with no snapshot yet (a submitted page while the bar slides in) shows its tint, or the submit's neutral
    // backdrop before the page has one, never a black card.
    static func fill(tint: CodableColor?) -> Color {
        tint.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? Theme.Palette.submitBackdrop
    }

    // A private tab is flat grey in the stack: its picture shows only on a swipe's copy, as on the swiping card.
    static func content(of tab: Tab, snapshots: SnapshotStore, inSwipe: Bool) -> (thumbnail: Thumbnail?, fill: Color) {
        guard tab.isPrivate else { return (snapshots.thumbnail(for: tab.id), fill(tint: tab.tint)) }
        return (inSwipe ? snapshots.thumbnail(for: tab.id) : nil, Theme.Palette.privateCard)
    }

    var body: some View {
        StackCard(
            thumbnail: thumbnail, fill: fill, foreground: foreground, size: Theme.Metrics.tabStackThumbnailSize,
            corner: Theme.Metrics.tabStackThumbnailCorner)
    }
}
