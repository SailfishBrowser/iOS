import SwiftUI

struct DeckView: View {
    private struct CoverKey: Equatable {
        var controller: ObjectIdentifier?
        var tabID: UUID?
        var progress: CGFloat
    }

    // A thrown card whose tab was archived by a grab while it still coasts: drawn from what it showed, at its old slot.
    private struct Ghost: Identifiable {
        let id: UUID
        let tab: Tab
        let thumbnail: Thumbnail
        let slot: Int
    }

    private struct Drag: Equatable {
        let id = UUID()
        let startTime: Date
        let activeIndex: Int
        var gesture: DeckGesture
        var liftBase: CGFloat = 0
    }

    @Environment(AppEnvironment.self) private var env
    @State private var covers = CardCovers()
    @State private var frozenOrder: [UUID]?
    @State private var drag: Drag?
    @State private var ghosts: [Ghost] = []
    #if DEBUG
    @State private var hooksOwner = UUID()
    #endif
    @GestureState private var touching = false

    var body: some View {
        let tabs = orderedTabs
        let activeIndex = tabs.firstIndex { $0.id == env.browser.activeTabID }
        GeometryReader { proxy in
            let layout = CardLayout(screen: proxy.size)
            ZStack {
                DeckBackdrop(driver: driver, isEmpty: tabs.isEmpty)
                if let activeIndex {
                    cards(tabs, activeIndex: activeIndex, layout: layout)
                        .contentShape(Rectangle())
                        .gesture(
                            deckGesture(layout: layout),
                            isEnabled: env.ui.deckTakesTouches)
                        .onChange(of: touching) { _, now in
                            guard !now, let id = drag?.id else { return }
                            Task { cancelDrag(id, layout: layout) }
                        }
                        #if DEBUG
                        // The demo's finger is refused whenever the gesture is.
                        .debugSurface(.deck) { phase, sample in
                            guard phase != .began || env.ui.deckTakesTouches else { return }
                            switch phase {
                            case .began:
                                began(sample, layout: layout)
                                changed(sample, layout: layout)
                            case .changed:
                                changed(sample, layout: layout)
                            case .ended:
                                ended(sample, layout: layout)
                                drag = nil
                            case .cancelled:
                                if let id = drag?.id {
                                    cancelDrag(id, layout: layout)
                                }
                            }
                        }
                        // The driver's applied state: any scroll, zoom, lift or fly-off moves the sum.
                        .debugWatch(.deck) {
                            driver.position + driver.progress + driver.lifts.values.reduce(0, +)
                                + driver.departing.values.reduce(0, +)
                        }
                        #endif
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .transaction(value: env.ui.deckProgress) { $0.animation = nil }
            .onAppear {
                #if DEBUG
                env.publishDebugDeck(owner: hooksOwner) {
                    driver.move(to: $0)
                } drawn: {
                    let tabs = orderedTabs
                    guard let activeIndex = tabs.firstIndex(where: { $0.id == env.browser.activeTabID }) else {
                        return ([], driver.lifts)
                    }
                    let (built, flying) = drawn(tabs, activeIndex: activeIndex)
                    return (Set(built.map { tabs[$0].id } + flying.map(\.id)), driver.lifts)
                } throwCard: {
                    driver.finishDeparture()
                    let tabs = orderedTabs
                    let index = min(max(Int(position.rounded()), 0), tabs.count - 1)
                    commitArchive(tabs[index].id, velocity: 0, layout: layout, playing: true)
                }
                #endif
                // The driver is shared and outlives these; a swipe or flick still moving lands before its owner is replaced.
                // The driver's writes take no animation from whatever transaction this runs in.
                withoutAnimation {
                    env.pager?.finish()
                    env.flick?.finish()
                    driver.adopt(layout)
                    env.pager = TabPager(env: env, driver: driver, layout: layout)
                    env.flick = TabStackFlick(env: env, layout: layout)
                    if env.ui.deckProgress != 0 {
                        frozenOrder = tabs.map(\.id)
                        open(layout)
                    } else {
                        recenter(animated: false)
                    }
                }
                if let controller = env.activeController {
                    activate(controller, progress: env.ui.deckProgress)
                }
            }
            #if DEBUG
            .onDisappear {
                env.withdrawDebugDeck(owner: hooksOwner)
            }
            #endif
            // This runs inside the transaction that changed the deck's progress, so the calls that reach the driver
            // are wrapped; the cover's own write is not.
            .onChange(of: coverKey) { old, new in
                if old.progress == 0, new.progress != 0 {
                    covers.update { $0.switcherOpened() }
                    frozenOrder = tabs.map(\.id)
                    withoutAnimation { open(layout) }
                } else if new.progress == 0 {
                    frozenOrder = nil
                }
                if old.controller != new.controller, let controller = env.activeController {
                    let archived = old.tabID.map { id in !env.browser.tabs.contains { $0.id == id } } ?? false
                    // A swipe on the bar switches the tab as its spring lands, and the spring carries on to rest there.
                    if !archived, old.progress == 0, new.progress == 0 {
                        if !driver.isPaging {
                            withoutAnimation { recenter(animated: false) }
                        }
                    } else if !archived {
                        Task { recenter(animated: env.ui.deckProgress == 0) }
                    }
                    activate(controller, progress: old.progress)
                }
            }
            // A ghost and the picture it holds go with its own fly-off, not at the next archive or the burst's end.
            .onChange(of: Set(driver.departing.keys)) { _, flying in
                ghosts.removeAll { !flying.contains($0.id) }
            }
        }
        .background(RevealWatch(controller: env.activeController, revealed: revealed))
    }

    private func revealed(_ id: UUID) {
        guard covers.cover(for: id).phase != .waitingToCut else {
            covers.update { $0.becameRevealable(id) }
            return
        }
        fade(id) { $0.becameRevealable(id) }
    }

    private var driver: DeckDriver {
        env.ui.deck
    }

    private var position: CGFloat {
        driver.position
    }

    private var coverKey: CoverKey {
        CoverKey(
            controller: env.activeController.map(ObjectIdentifier.init), tabID: env.activeController?.tabID,
            progress: env.ui.deckProgress)
    }

    private var orderedTabs: [Tab] {
        let tabs = env.browser.tabs
        guard let frozenOrder else { return tabs }
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        return CardLayout.frozenOrder(frozenOrder, current: tabs.map(\.id)).map { byID[$0]! }
    }

    // The built cards, and the archived cards still flying off. Read from inputs that change once per gesture (the
    // span, the pair's and the flick's ids), never from the per-frame structs, so a frame re-evaluates the cards
    // and not the deck.
    private func drawn(_ tabs: [Tab], activeIndex: Int) -> (built: [Int], flying: [Ghost]) {
        let built = Self.built(
            ids: tabs.map(\.id), activeIndex: activeIndex, span: driver.span, pinned: driver.pagedIDs + driver.flickIDs)
        return (built, ghosts.filter { driver.departing[$0.id] != nil })
    }

    // The cards in the span, the active card, and the cards a swipe or the tab stack's flick moves, wherever they
    // sit in the deck.
    static func built(ids: [UUID], activeIndex: Int, span: ClosedRange<Int>, pinned: [UUID]) -> [Int] {
        ids.indices.filter { span.contains($0) || $0 == activeIndex || pinned.contains(ids[$0]) }
    }

    private func cards(_ tabs: [Tab], activeIndex: Int, layout: CardLayout) -> some View {
        let (built, flying) = drawn(tabs, activeIndex: activeIndex)
        let activeID = tabs[activeIndex].id
        let coverImage = env.snapshots.thumbnail(for: activeID).image
        let controller = env.activeController
        return ZStack {
            ForEach(built.map { (index: $0, tab: tabs[$0]) }, id: \.tab.id) { index, tab in
                DeckCard(
                    driver: driver,
                    content: { TabCardView(tab: tab, isActive: index == activeIndex, layout: layout, geometry: $0) },
                    index: index, activeIndex: activeIndex, layout: layout, header: CardHeader(tab: tab),
                    coverImage: index == activeIndex ? coverImage : nil, tint: tab.tint,
                    controller: index == activeIndex ? controller : nil, covers: covers, tabID: tab.id,
                    isPrivate: tab.isPrivate)
                    .transition(.identity)
            }
            ForEach(flying) { ghost in
                DeckCard(
                    driver: driver,
                    content: { geometry in
                        CardSnapshot(thumbnail: ghost.thumbnail, tab: ghost.tab, layout: layout)
                            .frame(width: layout.screen.width, height: layout.screen.height)
                            .placedAndClipped(geometry)
                    },
                    index: ghost.slot, activeIndex: -1, layout: layout, header: CardHeader(tab: ghost.tab),
                    coverImage: nil, tint: ghost.tab.tint, controller: nil, covers: covers, tabID: ghost.id,
                    isPrivate: ghost.tab.isPrivate)
                    .transition(.identity)
            }
        }
        .frame(width: layout.screen.width, height: layout.screen.height)
    }

    // A submitted page waiting for its first paint keeps the backdrop the staging cover showed, so the hidden step
    // changes no pixel; a tint arriving mid-wait would put a colour step inside it.
    static func coverFill(tint: CodableColor?, waitsToCut: Bool, isPrivate: Bool = false) -> Color {
        if waitsToCut {
            return isPrivate ? Color(uiColor: Theme.Palette.privateSubmitCover) : Theme.Palette.submittedPagePlaceholder
        }
        return tint.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? Theme.Palette.newTabPlaceholder
    }

    private func open(_ layout: CardLayout) {
        guard let index = orderedTabs.firstIndex(where: { $0.id == env.browser.activeTabID }) else { return }
        let target = layout.openPosition(activeIndex: index)
        if let motion = driver.motion, !motion.curve.isSettled(at: .now) {
            zoom(to: target)
        } else {
            jump(to: target, shift: [:])
        }
    }

    private func zoom(to target: CGFloat) {
        let now = ContinuousClock.now
        let next = driver.motion?.retargeted(to: target, at: now, spring: DeckSnap.zoom)
            ?? DeckMotion(from: position, to: target, shift: driver.shift, velocity: 0, start: now, spring: DeckSnap.zoom)
        driver.run(next)
    }

    private func recenter(animated: Bool) {
        guard let index = orderedTabs.firstIndex(where: { $0.id == env.browser.activeTabID }),
            position != CGFloat(index)
        else { return }
        if animated {
            zoom(to: CGFloat(index))
            return
        }
        jump(to: CGFloat(index), shift: [:])
    }

    private func jump(to target: CGFloat, shift: [UUID: CGFloat]) {
        driver.jump(to: target, shift: shift)
    }

    private func snap(to target: CGFloat, velocity: Double, landing: (() -> Void)? = nil) {
        driver.run(
            DeckMotion(
                from: position, to: target, shift: driver.shift, velocity: velocity, start: .now,
                spring: DeckSnap.release(velocity)),
            landing: landing)
    }

    private func returnLift(_ id: UUID, velocity: CGFloat, layout: CardLayout) {
        driver.animateLift(id, .snap(layout.liftReturn(from: driver.lifts[id] ?? 0, velocity: velocity, start: .now)))
    }

    private func slots(_ tabs: [Tab]) -> [CGFloat] {
        tabs.indices.map { CGFloat($0) + driver.shift[tabs[$0].id, default: 0] }
    }

    private func nearestCard(_ tabs: [Tab], layout: CardLayout) -> Int {
        layout.snapTarget(start: position, translation: 0, velocity: 0, slots: slots(tabs)).index
    }

    private func settle(_ tabs: [Tab], layout: CardLayout) {
        snap(to: CGFloat(nearestCard(tabs, layout: layout)), velocity: 0)
    }

    private func activate(_ controller: WebTabController, progress: CGFloat) {
        let id = controller.tabID
        let cutsIn = env.takeCutIn(controller)
        covers.update { $0.activated(id, progress: progress, revealable: controller.isRevealable, cutsIn: cutsIn) }
        guard covers.cover(for: id).phase == .hold else { return }
        Task {
            try await Task.sleep(for: .seconds(Theme.Motion.coverHold))
            fade(id) { $0.holdElapsed(id) }
        }
    }

    private func fade(_ id: UUID, _ change: (inout CardCover) -> Void) {
        let before = covers.cover(for: id)
        FrameRateVote.hold(Theme.Motion.fade)
        withAnimation(Theme.Motion.fade.animation) { covers.update(change) }
        guard covers.cover(for: id) != before else { return }
        Task {
            try await Task.sleep(for: .seconds(Theme.Motion.fadeDuration))
            covers.update { $0.fadeFinished(id) }
        }
    }

    // Every callback reads the deck as it is now: a grab can archive a thrown card first and renumber the rest.
    private func deckGesture(layout: CardLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touching) { value, touching, _ in
                if !touching {
                    touching = true
                    began(DragSample(value), layout: layout)
                }
                changed(DragSample(value), layout: layout)
            }
            .onEnded { value in
                ended(DragSample(value), layout: layout)
                drag = nil
            }
    }

    // A grab inside a throw's gap close is taken: the thrown card's tab is archived first, then the grab catches the
    // closing deck where its last frame drew it.
    private func began(_ value: DragSample, layout: CardLayout) {
        driver.finishDeparture()
        let tabs = orderedTabs
        guard let activeIndex = tabs.firstIndex(where: { $0.id == env.browser.activeTabID }) else { return }
        // A snap caught in flight already played for its landing card.
        let landing = driver.motion.map { Int($0.to.rounded()) }
        if driver.motion != nil {
            jump(to: position, shift: driver.shift)
        }
        let range = layout.visibleRange(from: position, to: position, count: tabs.count)
        let slots = slots(tabs)
        drag = Drag(
            startTime: value.time, activeIndex: activeIndex,
            gesture: DeckGesture(
                start: position, startCard: landing ?? nearestCard(tabs, layout: layout),
                cardIndex: layout.card(
                    at: value.startLocation, activeIndex: activeIndex, position: position, progress: driver.progress,
                    olderProgress: driver.olderProgress, in: range, slot: { slots[$0] }),
                cardHeight: layout.cardSize.height))
        driver.keepLifts(Set(tabs.map(\.id)))
    }

    private func cancelDrag(_ id: UUID, layout: CardLayout) {
        guard let current = drag, current.id == id else { return }
        drag = nil
        let tabs = orderedTabs
        if current.gesture.axis == .vertical, let index = current.gesture.cardIndex {
            returnLift(tabs[index].id, velocity: 0, layout: layout)
        }
        settle(tabs, layout: layout)
    }

    private func changed(_ value: DragSample, layout: CardLayout) {
        guard var current = drag else { return }
        let tabs = orderedTabs
        switch current.gesture.lock(value.translation) {
        case .horizontal:
            env.haptics.fire(.deckScroll)
        case .vertical?:
            guard let index = current.gesture.cardIndex else { break }
            current.liftBase = driver.lifts[tabs[index].id] ?? 0
            env.haptics.fire(.cardLift)
        case nil:
            break
        }
        let translation = current.gesture.effective(value.translation)
        switch current.gesture.axis {
        case .horizontal:
            env.haptics.prepare(.deckSettle)
            let position = current.gesture.start - translation.width / layout.stride
            driver.move(to: layout.stretched(position, count: tabs.count))
        case .vertical:
            if let index = current.gesture.cardIndex {
                let lift = layout.lift(for: translation.height, from: current.liftBase)
                driver.setLift(tabs[index].id, lift)
                if current.gesture.archive.update(-lift) == .armed {
                    env.haptics.fire(.cardArchiveArm)
                }
            }
        case nil:
            break
        }
        if current != drag {
            drag = current
        }
    }

    private func ended(_ value: DragSample, layout: CardLayout) {
        guard let current = drag else { return }
        let tabs = orderedTabs
        let activeIndex = current.activeIndex
        let travel = hypot(value.translation.width, value.translation.height)
        if travel < Theme.Gesture.tapMaxTravel,
            value.time.timeIntervalSince(current.startTime) < Theme.Gesture.tapMaxDuration
        {
            let range = layout.visibleRange(from: position, to: position, count: tabs.count)
            let slots = slots(tabs)
            let hit = layout.card(
                at: value.location, activeIndex: activeIndex, position: position, progress: driver.progress,
                olderProgress: driver.olderProgress, in: range, slot: { slots[$0] })
            let index = hit ?? activeIndex
            zoom(to: CGFloat(index))
            env.showTab(tabs[index].id, via: hit == nil ? .deckBackgroundTap : .deckCardTap)
            return
        }
        let gesture = current.gesture
        switch gesture.axis {
        case .horizontal:
            let target = layout.snapTarget(
                start: gesture.start, translation: gesture.effective(value.translation).width,
                velocity: value.velocity.width, slots: slots(tabs))
            snap(
                to: CGFloat(target.index), velocity: target.velocity,
                landing: target.index == gesture.startCard ? nil : { env.haptics.fire(.deckSettle) })
            trimSnapshots(tabs)
        case .vertical:
            guard let index = gesture.cardIndex else {
                settle(tabs, layout: layout)
                return
            }
            let id = tabs[index].id
            let velocity = value.velocity.height
            guard layout.commitsArchive(armed: gesture.archive.isArmed, lift: driver.lifts[id] ?? 0, velocity: velocity)
            else {
                env.haptics.fire(.cardReturn)
                returnLift(id, velocity: velocity, layout: layout)
                settle(tabs, layout: layout)
                return
            }
            commitArchive(id, velocity: velocity, layout: layout, playing: !gesture.archive.hasArmed)
        case nil:
            settle(tabs, layout: layout)
        }
    }

    private func commitArchive(_ id: UUID, velocity: CGFloat, layout: CardLayout, playing: Bool) {
        driver.finishDeparture()
        let tabs = orderedTabs
        let plan = layout.archivePlan(
            removing: tabs.firstIndex { $0.id == id }!, ids: tabs.map(\.id), shift: driver.shift, position: position,
            start: .now)
        env.haptics.fire(.cardThrow, playing: playing)
        driver.animateLift(
            id, .coast(layout.flyOff(from: driver.lifts[id] ?? 0, velocity: velocity, start: plan.motion.curve.start)))
        driver.run(plan.motion, base: plan.shift, departing: (id, { archive(id) }))
    }

    // Runs once the gap close settles, so the store and disk work lands on a still frame, unless a grab comes first.
    private func archive(_ id: UUID) {
        let tabs = orderedTabs
        if driver.isFlying(id), let slot = tabs.firstIndex(where: { $0.id == id }) {
            ghosts.append(Ghost(id: id, tab: tabs[slot], thumbnail: env.snapshots.thumbnail(for: id), slot: slot))
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if env.browser.tabs.contains(where: { $0.id == id }) {
                env.archive(id)
            }
        }
        if env.browser.tabs.isEmpty {
            env.haptics.fire(.deckEmptied)
        }
    }

    // Every card the snap draws keeps its picture: the span runs from the release to the target.
    private func trimSnapshots(_ tabs: [Tab]) {
        var kept = Set(tabs[driver.span.clamped(to: 0...(tabs.count - 1))].map(\.id))
        if let active = env.browser.activeTabID {
            kept.insert(active)
        }
        if let previous = env.browser.previousTabID {
            kept.insert(previous)
        }
        env.snapshots.trim(keeping: kept)
    }
}

// Watches the active page turn revealable on its own, so the deck view's body never reads the flag.
private struct RevealWatch: View {
    let controller: WebTabController?
    let revealed: (UUID) -> Void

    var body: some View {
        Color.clear
            .onChange(of: controller?.isRevealable) { _, revealable in
                guard revealable == true, let id = controller?.tabID else { return }
                revealed(id)
            }
    }
}

// The card cover, shared by reference: every card reads which tab is covered, and only that card reads the cover, so a
// hold or a fade re-renders the one card instead of the whole deck.
@Observable final class CardCovers {
    private(set) var tabID: UUID?
    private var current = CardCover()

    func cover(for card: UUID) -> CardCover {
        tabID == card ? current : CardCover()
    }

    func update(_ change: (inout CardCover) -> Void) {
        change(&current)
        if tabID != current.tabID {
            tabID = current.tabID
        }
    }
}

private struct DeckBackdrop: View {
    let driver: DeckDriver
    let isEmpty: Bool

    var body: some View {
        ZStack {
            LinearGradient(stops: Theme.Palette.deckGradientStops, startPoint: .topLeading, endPoint: .bottomTrailing)
            if isEmpty {
                EmptyDeckLabel()
            }
        }
        .opacity(driver.progress)
    }
}

private struct EmptyDeckLabel: View {
    @State private var shown = false

    var body: some View {
        Text("No Open Tabs")
            .font(Theme.Typography.emptyDeckLabel)
            .foregroundStyle(.white.opacity(Theme.Opacity.emptyDeckLabel))
            .scaleEffect(shown ? 1 : Theme.Metrics.emptyDeckStartScale)
            .opacity(shown ? 1 : 0)
            .onAppear {
                FrameRateVote.hold(Theme.Motion.emptyDeckAppear)
                withAnimation(Theme.Motion.emptyDeckAppear.animation) { shown = true }
            }
    }
}

private struct DeckCard<Content: View>: View {
    let driver: DeckDriver
    let content: (CardGeometry) -> Content
    let index: Int
    let activeIndex: Int
    let layout: CardLayout
    let header: CardHeader
    let coverImage: UIImage?
    let tint: CodableColor?
    let controller: WebTabController?
    let covers: CardCovers
    let tabID: UUID
    let isPrivate: Bool

    // The active card alone reads whether its page is revealable, so a page turning revealable mid-zoom re-renders
    // this card instead of the whole deck.
    var body: some View {
        let isUnrevealed = controller.map { $0.tabID == tabID && !$0.isRevealable } ?? false
        let cover = covers.cover(for: tabID)
        let placement = driver.placement(
            index: index, activeIndex: activeIndex, layout: layout, header: header, coverImage: coverImage,
            coverFill: DeckView.coverFill(tint: tint, waitsToCut: cover.waitsToCut, isPrivate: isPrivate),
            isUnrevealed: isUnrevealed,
            cover: cover, tabID: tabID, isPrivate: isPrivate)
        content(placement.contentGeometry).modifier(placement)
    }
}
