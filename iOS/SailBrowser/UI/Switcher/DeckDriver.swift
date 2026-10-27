import QuartzCore
import SwiftUI

@Observable final class DeckDriver {
    // A flick up on the tab stack: the live page `from` shrinks into the bottom-left as it arms and as the card rises,
    // and the previous tab's card `to` rises out of the tab stack over it, under the finger at `offset`. A landing
    // drops `from` into the tab stack and zooms `to` to the screen.
    struct Flick: Equatable {
        let from: UUID
        let to: UUID
        let safeTop: CGFloat
        let grab: CardLayout.FlickGrab
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0
        var arm: CGFloat = 0
        // How grown the card is out of the stack, 0 the thumbnail and 1 the peek's size.
        var grow: CGFloat = 0
        var drop: CGFloat = 0
        var land: CGFloat = 0
        // The landing card's bottom has cleared the bar's top: the bar covers it from then on, as it covers a page.
        var cleared = false

        // The finger's offset from where it took the card.
        var offset: CGSize {
            CGSize(width: offsetX, height: offsetY)
        }
    }

    // The cards a swipe on the bar moves: the page it started on at `origin`, and the tabs that can come in on either
    // side. `arm` takes them from full size to the armed cards, `emerge` brings the older
    // card out of the tab stack, and `dive` drops the page left into it on a newer-tab landing.
    struct PagePair: Equatable {
        let origin: Int
        let originID: UUID
        let older: UUID?
        let newer: UUID?
        let safeTop: CGFloat
        var arm: CGFloat = 0
        var emerge: CGFloat = 0
        var dive: CGFloat = 0
    }

    private(set) var position: CGFloat = 0
    private(set) var span = CardLayout.span(from: 0, to: 0)
    private(set) var progress: CGFloat = 0
    private(set) var olderProgress: CGFloat = 0
    // The bars' cross-fade, on its own zoom spring; the bars are drawn and hit by it.
    private(set) var barProgress: CGFloat = 0
    private(set) var shift: [UUID: CGFloat] = [:]
    private(set) var lifts: [UUID: CGFloat] = [:]
    private(set) var departing: [UUID: CGFloat] = [:]
    // A swipe on the bar lays the cards out as pages side by side while the deck is closed, until its spring settles.
    private(set) var isPaging = false
    private(set) var pair: PagePair?
    private(set) var flick: Flick?
    // What the deck builds and the stack draws, changing once per gesture rather than per frame: the pair's cards
    // (origin, older, newer), the flick's (from, to), and the stack's front-slot card while it is out of the stack.
    private(set) var pagedIDs: [UUID] = []
    private(set) var flickIDs: [UUID] = []
    private(set) var outOfStack: UUID?
    @ObservationIgnored private(set) var previous: CGFloat = 0
    @ObservationIgnored private(set) var motion: DeckMotion? {
        didSet { landing = nil }
    }
    // Plays when the motion visibly lands, within the settled distance of its target, not at the spring's rest.
    @ObservationIgnored private var landing: (() -> Void)?
    @ObservationIgnored private var baseShift: [UUID: CGFloat] = [:]
    @ObservationIgnored private var departure: (() -> Void)?
    // Thrown cards whose tab is archived while their coast is still on screen; they fly on until it ends.
    @ObservationIgnored private var flying: Set<UUID> = []
    @ObservationIgnored private var progressCurve: DeckSnap?
    @ObservationIgnored private var olderCurve: DeckSnap?
    @ObservationIgnored private var barCurve: DeckSnap?
    @ObservationIgnored private var flickCurves: [WritableKeyPath<Flick, CGFloat>: DeckSnap] = [:]
    // Plays when the flick's card visibly lands, within the settled distance of the screen.
    @ObservationIgnored private var flickLanding: (() -> Void)?
    // Runs once a released flick has settled, on a still frame.
    @ObservationIgnored private var flickSettled: (() -> Void)?
    @ObservationIgnored private var flickReleased = false
    // The deck view's layout: the flick, pair and zoom curves take their rest scales from it and the landing card's
    // clearing of the bar is read against it. Before adoption a curve settles by time; no gesture exists then.
    @ObservationIgnored private var layout: CardLayout?
    @ObservationIgnored private var armCurve: DeckSnap?
    @ObservationIgnored private var emergeCurve: DeckSnap?
    @ObservationIgnored private var diveCurve: DeckSnap?
    // Paging ends once a released pair and its position have settled, and its landing runs then, on a still frame.
    @ObservationIgnored private var pageReleased = false
    @ObservationIgnored private var pageLanding: (() -> Void)?
    @ObservationIgnored private var liftCurves: [UUID: DeckCurve] = [:]
    @ObservationIgnored private var clock: FrameClock?
    @ObservationIgnored private var lastApplied = ContinuousClock.now
    // A test holds the deck's time to touch it on a known frame: frames show the held time, zooms begun while held
    // start at it, and it moves only when stepped.
    @ObservationIgnored private var heldTime: ContinuousClock.Instant?
    // While a batch is open every curve begun inside starts at its instant, and on exit the first frame is applied
    // once and one clock starts if any curve needs it.
    @ObservationIgnored private var batchDepth = 0
    @ObservationIgnored private var batchStart: ContinuousClock.Instant?
    @ObservationIgnored private var batchWantsClock = false
    @ObservationIgnored private var pageDetent: PageDetent?
    @ObservationIgnored private var pageTick: () -> Void = {}
    // Told when the deck starts and stops moving, so work that would land in a motion frame can wait for rest.
    @ObservationIgnored var onMotion: ((Bool) -> Void)?
    @ObservationIgnored private var moving = false

    var isAnimating: Bool {
        motion != nil || progressCurve != nil || olderCurve != nil || barCurve != nil || !liftCurves.isEmpty
            || !flickCurves.isEmpty || armCurve != nil || emergeCurve != nil || diveCurve != nil
    }

    var isFlickMoving: Bool {
        !flickCurves.isEmpty
    }

    // The flick has begun its landing: the card is zooming to the screen or there.
    var isFlickLanding: Bool {
        flickCurves[\.land] != nil || (flick?.land ?? 0) > 0
    }

    // The height the flick's card is springing to, while it springs.
    var flickTarget: CGFloat? {
        flickCurves[\.offsetY]?.to
    }

    // The browsing bar takes touches below the hand-off, the switcher bar from it.
    var barsShowDeck: Bool {
        barProgress >= Theme.Gesture.zoomBarHandOffProgress
    }

    // The deck is zooming or at the switcher: the bar swipe and the flick wait for the browsing page at rest.
    var isZooming: Bool {
        progressCurve != nil || progress != 0
    }

    func adopt(_ layout: CardLayout) {
        self.layout = layout
    }

    // The deck's time: the batch's start while one is open, the held time while a test holds it.
    var now: ContinuousClock.Instant {
        batchStart ?? heldTime ?? .now
    }

    // One gesture turn: the curves begun inside share one start instant, their first frame is applied once on exit,
    // and one clock starts if any of them runs. A batch that begins no curve applies nothing beyond its writes.
    func batch(_ changes: () -> Void) {
        if batchDepth == 0 {
            batchStart = heldTime ?? .now
            batchWantsClock = false
        }
        batchDepth += 1
        defer {
            batchDepth -= 1
            if batchDepth == 0 {
                let start = batchStart!
                batchStart = nil
                if batchWantsClock {
                    startClock(at: start)
                }
            }
        }
        changes()
    }

    func move(to target: CGFloat) {
        finishDeparture()
        motion = nil
        baseShift = [:]
        previous = position
        set(\.position, target)
        set(\.shift, [:])
        updateSpan(to: target)
        trackPage()
    }

    func jump(to target: CGFloat, shift newShift: [UUID: CGFloat]) {
        finishDeparture()
        motion = nil
        baseShift = [:]
        previous = target
        set(\.position, target)
        set(\.shift, newShift)
        updateSpan(to: target)
        trackPage()
    }

    // The tick plays each time the tab leading under the finger changes, on the frame that draws the change.
    func beginPaging(_ pair: PagePair, detent: PageDetent?, tick: @escaping () -> Void) {
        pageDetent = detent
        pageTick = tick
        holdPaging()
        set(\.isPaging, true)
        set(\.pair, pair)
        set(\.pagedIDs, [pair.originID] + [pair.older, pair.newer].compactMap { $0 })
        updateOutOfStack()
        reportMotion()
    }

    func endPaging() {
        pageDetent = nil
        pageTick = {}
        holdPaging()
        set(\.isPaging, false)
        set(\.pair, nil)
        set(\.pagedIDs, [])
        updateOutOfStack()
        reportMotion()
    }

    // Each channel springs from where it is drawn; nil leaves a channel as it is.
    func animatePair(
        arm: CGFloat? = nil, emerge: CGFloat? = nil, dive: CGFloat? = nil, start: ContinuousClock.Instant = .now
    ) {
        let start = starting(start)
        let drawn = pair!
        if let arm {
            armCurve = Self.curve(
                armCurve, from: drawn.arm, to: arm, start: start, spring: DeckSnap.arm, points: layout?.pairArmPoints)
        }
        if let emerge {
            emergeCurve = Self.curve(
                emergeCurve, from: drawn.emerge, to: emerge, start: start, spring: DeckSnap.arm,
                points: layout?.screenPoints)
        }
        if let dive {
            diveCurve = Self.curve(
                diveCurve, from: drawn.dive, to: dive, start: start, spring: DeckSnap.drop, points: layout?.screenPoints)
        }
        startClock(at: start)
    }

    // Stops the pair's channels where the last frame drew them, and keeps paging until the next release.
    func holdPaging() {
        armCurve = nil
        emergeCurve = nil
        diveCurve = nil
        pageReleased = false
        pageLanding = nil
    }

    // A caught paging pages on around another tab, its cards where they are drawn.
    func repair(_ next: PagePair) {
        set(\.pair, next)
        set(\.pagedIDs, [next.originID] + [next.older, next.newer].compactMap { $0 })
        updateOutOfStack()
    }

    func releasePaging(landing: (() -> Void)? = nil) {
        pageReleased = true
        pageLanding = landing
    }

    private static func curve(
        _ running: DeckSnap?, from: CGFloat, to target: CGFloat, start: ContinuousClock.Instant, spring: Spring,
        points: CGFloat?
    ) -> DeckSnap {
        running?.retargeted(to: target, at: start, spring: spring)
            ?? DeckSnap(from: from, to: target, velocity: 0, start: start, spring: spring, points: points)
    }

    // Drawn points per unit of a flick channel, from the adopted layout.
    private func points(_ channel: WritableKeyPath<Flick, CGFloat>) -> CGFloat? {
        guard let layout else { return nil }
        switch channel {
        case \.offsetX, \.offsetY: return 1
        case \.grow: return layout.flickGrowPoints
        case \.arm: return layout.flickArmPoints
        case \.land: return layout.flickLandPoints
        default: return layout.screenPoints
        }
    }

    func beginFlick(from: UUID, to: UUID, safeTop: CGFloat, grab: CardLayout.FlickGrab) {
        holdFlick()
        set(\.flick, Flick(from: from, to: to, safeTop: safeTop, grab: grab))
        set(\.flickIDs, [from, to])
        updateOutOfStack()
        reportMotion()
    }

    // The finger draws the card and its grow; the arm keeps springing. One write per move.
    func moveFlick(to offset: CGSize, grow: CGFloat) {
        flickCurves[\.offsetX] = nil
        flickCurves[\.offsetY] = nil
        flickCurves[\.grow] = nil
        var next = flick!
        next.offsetX = offset.width
        next.offsetY = offset.height
        next.grow = grow
        set(\.flick, next)
        updateOutOfStack()
    }

    func endFlick() {
        holdFlick()
        set(\.flick, nil)
        set(\.flickIDs, [])
        updateOutOfStack()
        reportMotion()
    }

    // Stops every channel of the flick where its last frame drew it, until the next release.
    func holdFlick() {
        flickCurves = [:]
        flickLanding = nil
        flickSettled = nil
        flickReleased = false
    }

    // A channel springs from where it is drawn, carrying a velocity in its own units per second toward its end.
    func animateFlick(
        _ channel: WritableKeyPath<Flick, CGFloat>, to target: CGFloat, spring: Spring, velocity: CGFloat = 0,
        start: ContinuousClock.Instant = .now
    ) {
        let start = starting(start)
        let from = flick![keyPath: channel]
        // Signed: a card moving away from where it is going carries on that way before the spring brings it round.
        let relative = Double(SheetDrag.releaseVelocity(velocity, toward: target - from))
        let points = points(channel)
        flickCurves[channel] = relative == 0
            ? Self.curve(flickCurves[channel], from: from, to: target, start: start, spring: spring, points: points)
            : DeckSnap(
                from: from, to: target, velocity: relative, start: start,
                spring: DeckSnap.stiffened(spring, for: relative), points: points)
        startClock(at: start)
    }

    func releaseFlick(landing: (() -> Void)?, settled: (() -> Void)?) {
        flickReleased = true
        flickLanding = landing
        flickSettled = settled
    }

    private func trackPage() {
        guard var detent = pageDetent else { return }
        let crossed = detent.update(position)
        pageDetent = detent
        for _ in 0..<crossed {
            pageTick()
        }
    }

    // A departing card keeps its place while the rest close the gap, until `archive` runs.
    func run(
        _ next: DeckMotion, base: [UUID: CGFloat] = [:], departing: (card: UUID, archive: () -> Void)? = nil,
        at start: ContinuousClock.Instant = .now, landing: (() -> Void)? = nil
    ) {
        finishDeparture()
        motion = next
        self.landing = landing
        baseShift = base
        if let departing {
            departure = departing.archive
            set(\.departing[departing.card], next.from)
        }
        previous = next.from
        updateSpan(to: next.to)
        startClock(at: starting(start))
    }

    // The one entry reached from inside a SwiftUI animation (UIState.setDeck): wrapped here, so no driver write
    // elsewhere needs a transaction.
    func follow(_ target: CGFloat, animated: Bool, start: ContinuousClock.Instant = .now) {
        withoutAnimation {
            if animated {
                animateProgress(to: target, start: start)
            } else {
                setProgress(target)
            }
        }
    }

    // Archives the thrown card's tab when the gap close settles, or first, before a grab or any other motion
    // replaces it. The closing cards keep the place they show, now under their new indices.
    // A card still coasting keeps its lift and place after the archive, and flies on to the top.
    func finishDeparture() {
        guard let archive = departure else { return }
        departure = nil
        flying.formUnion(departing.keys.filter { liftCurves[$0] != nil })
        archive()
        baseShift = [:]
        let landed = Set(departing.keys).subtracting(flying)
        for card in landed {
            liftCurves[card] = nil
        }
        set(\.lifts, lifts.filter { !landed.contains($0.key) })
        set(\.shift, motion?.presented(at: lastApplied).shift ?? [:])
        set(\.departing, departing.filter { flying.contains($0.key) })
    }

    func isFlying(_ card: UUID) -> Bool {
        flying.contains(card)
    }

    func position(for card: UUID) -> CGFloat {
        departing[card] ?? position
    }

    // A card on its way between the tab stack's front slot and the screen, as the deck draws it: `fromStack` is 1 at
    // the slot, and `leaving` marks the stack's own front card going out, as opposed to a page dropping in.
    struct StackFlight: Equatable {
        let id: UUID
        let transform: CardTransform
        let fromStack: CGFloat
        let leaving: Bool
    }

    // The flick's rising card and the swipe's older card leave the stack while they are out; the page a landing drops
    // goes in.
    func stackFlights(layout: CardLayout) -> [StackFlight] {
        guard progress == 0 else { return [] }
        var flights: [StackFlight] = []
        if let flick {
            // The rising card is half way out once grown to the peek's size, where it stays while dragged, under the
            // bar's copy wherever it is; the landing's zoom is the other half. The bar hands its copy back once the
            // landing card clears it or grows past the peek's size, a page the bar covers.
            let rising = layout.flickIncoming(
                offset: flick.offset, grab: flick.grab, grow: flick.grow, land: flick.land, safeTop: flick.safeTop)
            let page = flick.land > 0 && rising.scale > Theme.Metrics.tabStackFlickPeekScale
            flights.append(StackFlight(
                id: flick.to, transform: rising,
                fromStack: flick.cleared || page ? 0 : 1 - (flick.grow + flick.land) / 2, leaving: true))
            // The page left, held at its armed size, is the bar's to cover until it shrinks to the peek's size.
            if flick.drop > 0 {
                let dropping = layout.flickLive(arm: flick.arm, drop: flick.drop)
                flights.append(StackFlight(
                    id: flick.from, transform: dropping,
                    fromStack: dropping.scale > Theme.Metrics.tabStackFlickPeekScale ? 0 : flick.drop, leaving: false))
            }
        }
        if let pair {
            let along = position - CGFloat(pair.origin)
            if let older = pair.older {
                flights.append(StackFlight(
                    id: older,
                    transform: layout.pairTransform(
                        offset: -1 - along, fromStack: 1 - pair.emerge, arm: pair.arm, safeTop: pair.safeTop),
                    fromStack: 1 - pair.emerge, leaving: true))
            }
            if pair.dive > 0 {
                flights.append(StackFlight(
                    id: pair.originID,
                    transform: layout.pairTransform(
                        offset: -along, fromStack: pair.dive, arm: pair.arm, safeTop: pair.safeTop),
                    fromStack: pair.dive, leaving: false))
            }
        }
        return flights
    }

    func placement<Header: View>(
        index: Int, activeIndex: Int, layout: CardLayout, header: Header, coverImage: UIImage?, coverFill: Color,
        isUnrevealed: Bool, cover: CardCover, tabID: UUID, isPrivate: Bool = false
    ) -> CardPlacement<Header> {
        CardPlacement(
            progress: progress, olderProgress: olderProgress, pair: progress == 0 ? pair : nil,
            flick: progress == 0 ? flick : nil,
            position: position(for: tabID), lift: lifts[tabID] ?? 0,
            slot: CGFloat(index) + shift[tabID, default: 0], index: index, activeIndex: activeIndex, layout: layout,
            header: header, coverImage: coverImage, coverFill: coverFill, isUnrevealed: isUnrevealed, cover: cover,
            tabID: tabID, isPrivate: isPrivate)
    }

    func animateProgress(to target: CGFloat, start: ContinuousClock.Instant = .now) {
        let start = starting(start)
        progressCurve = Self.curve(
            progressCurve, from: progress, to: target, start: start, spring: DeckSnap.zoom, points: layout?.zoomPoints)
        olderCurve = Self.curve(
            olderCurve, from: olderProgress, to: target, start: start, spring: DeckSnap.olderZoom,
            points: layout?.screenPoints)
        barCurve = Self.curve(
            barCurve, from: barProgress, to: target, start: start, spring: DeckSnap.barFade, points: layout?.screenPoints)
        startClock(at: start)
    }

    func setProgress(_ value: CGFloat) {
        progressCurve = nil
        olderCurve = nil
        barCurve = nil
        set(\.progress, value)
        set(\.olderProgress, value)
        set(\.barProgress, value)
        updateOutOfStack()
    }

    func setLift(_ id: UUID, _ value: CGFloat) {
        liftCurves[id] = nil
        set(\.lifts[id], value)
    }

    func animateLift(_ id: UUID, _ curve: DeckCurve, at start: ContinuousClock.Instant = .now) {
        liftCurves[id] = curve
        startClock(at: starting(start))
    }

    func keepLifts(_ ids: Set<UUID>) {
        let kept = ids.union(flying)
        liftCurves = liftCurves.filter { kept.contains($0.key) }
        set(\.lifts, lifts.filter { kept.contains($0.key) })
    }

    func hold() {
        heldTime = lastApplied
    }

    func step(by interval: Duration) {
        heldTime! += interval
        apply(at: heldTime!)
    }

    func resume() {
        heldTime = nil
    }

    // One frame: every running curve is advanced into a local copy of its struct, and each observed property is
    // written at most once, after which the landing and settled callbacks read the written values.
    func apply(at time: ContinuousClock.Instant) {
        let time = max(heldTime ?? time, lastApplied)
        lastApplied = time
        var settled = false
        if let current = motion {
            let presented = current.presented(at: time)
            set(\.position, presented.position)
            set(\.shift, presented.shift.merging(baseShift, uniquingKeysWith: +))
            trackPage()
            if let landed = landing, abs(presented.position - current.to) < Theme.Gesture.deckSettledDistance {
                landing = nil
                landed()
            }
            if current.curve.isSettled(at: time) {
                motion = nil
                settled = true
            }
        }
        if let curve = progressCurve {
            set(\.progress, curve.position(at: time))
            if curve.isSettled(at: time) {
                progressCurve = nil
            }
        }
        if let curve = olderCurve {
            set(\.olderProgress, curve.position(at: time))
            if curve.isSettled(at: time) {
                olderCurve = nil
            }
        }
        if let curve = barCurve {
            set(\.barProgress, curve.position(at: time))
            if curve.isSettled(at: time) {
                barCurve = nil
            }
        }
        if var next = flick {
            for (channel, curve) in flickCurves {
                next[keyPath: channel] = curve.position(at: time)
                if curve.isSettled(at: time) {
                    flickCurves[channel] = nil
                }
            }
            if let layout, next.land > 0, !next.cleared {
                let landing = layout.flickIncoming(
                    offset: next.offset, grab: next.grab, grow: next.grow, land: next.land, safeTop: next.safeTop)
                if layout.bottom(of: landing) <= layout.barTop {
                    next.cleared = true
                }
            }
            set(\.flick, next)
        }
        if var next = pair {
            if let curve = armCurve {
                next.arm = curve.position(at: time)
                if curve.isSettled(at: time) {
                    armCurve = nil
                }
            }
            if let curve = emergeCurve {
                next.emerge = curve.position(at: time)
                if curve.isSettled(at: time) {
                    emergeCurve = nil
                }
            }
            if let curve = diveCurve {
                next.dive = curve.position(at: time)
                if curve.isSettled(at: time) {
                    diveCurve = nil
                }
            }
            set(\.pair, next)
        }
        updateOutOfStack()
        if !liftCurves.isEmpty {
            var next = lifts
            var nextDeparting = departing
            for (id, curve) in liftCurves {
                next[id] = curve.value(at: time)
                if curve.isSettled(at: time) {
                    liftCurves[id] = nil
                    if flying.remove(id) != nil {
                        next[id] = nil
                        nextDeparting[id] = nil
                    }
                }
            }
            set(\.lifts, next)
            set(\.departing, nextDeparting)
        }
        if let landed = flickLanding, flick!.land > 1 - Theme.Gesture.deckSettledDistance {
            flickLanding = nil
            landed()
        }
        if flick != nil, flickReleased, flickCurves.isEmpty {
            let settled = flickSettled
            flickSettled = nil
            settled?()
            endFlick()
        }
        if settled {
            finishDeparture()
        }
        if isPaging, pageReleased, motion == nil, armCurve == nil, emergeCurve == nil, diveCurve == nil {
            let landed = pageLanding
            pageLanding = nil
            landed?()
            endPaging()
        }
        if !isAnimating, let running = clock {
            running.stop()
            clock = nil
        }
        reportMotion()
    }

    // Moving from a swipe's or a flick's begin to its end and through every spring after it, with or without a curve
    // running, so nothing deferred to rest lands under a finger; reported on change only.
    private func reportMotion() {
        let now = isAnimating || isPaging || flick != nil
        guard now != moving else { return }
        moving = now
        onMotion?(now)
    }

    // Inside a batch the batch's instant; held, the held time.
    private func starting(_ start: ContinuousClock.Instant) -> ContinuousClock.Instant {
        batchStart ?? heldTime ?? start
    }

    // Outside a batch the first frame is applied before the first tick; inside one the batch's exit does that once.
    private func startClock(at start: ContinuousClock.Instant) {
        guard batchDepth == 0 else {
            batchWantsClock = true
            return
        }
        apply(at: start + Theme.Latency.frame)
        guard clock == nil, isAnimating else { return }
        clock = FrameClock { [weak self] time in
            guard let self else { return false }
            #if DEBUG
            DebugProfiler.markDeckFrame(at: time)
            #endif
            apply(at: time)
            return isAnimating
        }
        reportMotion()
    }

    private func updateSpan(to target: CGFloat) {
        set(\.span, CardLayout.span(from: previous, to: target))
    }

    // The stack's front-slot card is out while the flick's card is grown or landing, or the swipe's older card has
    // emerged; never at the switcher. The frames it flips on are the ones stackFlights' leaving flight flips on.
    private func updateOutOfStack() {
        var out: UUID?
        if progress == 0 {
            if let flick, flick.grow + flick.land > 0 {
                out = flick.to
            } else if let pair, pair.emerge > 0 {
                out = pair.older
            }
        }
        set(\.outOfStack, out)
    }

    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<DeckDriver, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }
}
