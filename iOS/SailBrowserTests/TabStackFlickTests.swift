import SwiftUI
import Testing
import UIKit
@testable import SailBrowser

// The flick: the live page shrinks into the bottom-left corner and the
// previous tab's card rises out of the tab stack over it.
struct TabStackFlickLayoutTests {
    private let screen = CGSize(width: 402, height: 874)
    private let safeTop: CGFloat = 62

    // A grab at the front card's centre.
    private func centred(_ layout: CardLayout) -> CardLayout.FlickGrab {
        layout.flickGrab(at: layout.frontSlot)
    }

    private func edges(_ t: CardTransform) -> (minX: CGFloat, maxX: CGFloat, top: CGFloat, bottom: CGFloat) {
        let centre = screen.width / 2 + t.offset.width
        let top = screen.height / 2 + t.offset.height - screen.height * t.scale / 2
        return (
            centre - screen.width * t.scale / 2, centre + screen.width * t.scale / 2, top + t.clipTop,
            top + t.clipHeight
        )
    }

    @Test func theLivePageShrinksIntoTheBottomLeftCornerAndNeverLifts() {
        let layout = CardLayout(screen: screen)
        let rest = layout.flickLive(arm: 0, drop: 0)
        #expect(rest.scale == 1 && rest.offset == .zero)
        let armed = layout.flickLive(arm: 1, drop: 0)
        #expect(armed.scale == Theme.Metrics.tabStackFlickArmScale)
        #expect(abs(edges(armed).minX - Theme.Metrics.tabStackFlickInset) < 1e-9)
        #expect(abs(edges(armed).bottom - (874 - Theme.Metrics.tabStackFlickBottomInset)) < 1e-9)
        #expect(armed.corner == Theme.Metrics.cardCorner)
        let dropped = layout.flickLive(arm: 1, drop: 1)
        #expect(abs((edges(dropped).minX + edges(dropped).maxX) / 2 - layout.frontSlot.x) < 1e-6)
        #expect(abs((edges(dropped).top + edges(dropped).bottom) / 2 - layout.frontSlot.y) < 1e-6)
        #expect(abs(edges(dropped).maxX - edges(dropped).minX - Theme.Metrics.tabStackThumbnailSize.width) < 1e-6)
        #expect(dropped.opacity == 1)
    }

    @Test func thePreviousCardRisesOutOfTheTabStackOverThePage() {
        let layout = CardLayout(screen: screen)
        // It starts as the stack's front card exactly: that card's size, tilt and place.
        let start = layout.flickIncoming(offset: .zero, grab: centred(layout), grow: 0, land: 0, safeTop: safeTop)
        #expect(abs((edges(start).minX + edges(start).maxX) / 2 - layout.frontSlot.x) < 1e-6)
        #expect(abs((edges(start).top + edges(start).bottom) / 2 - layout.frontSlot.y) < 1e-6)
        #expect(abs(edges(start).maxX - edges(start).minX - Theme.Metrics.tabStackThumbnailSize.width) < 1e-6)
        #expect(abs(edges(start).bottom - edges(start).top - Theme.Metrics.tabStackThumbnailSize.height) < 1e-6)
        #expect(start.rotation == .degrees(Theme.Metrics.tabStackTilt) && start.opacity == 1 && start.clipTop == 0)
        #expect(start.corner == Theme.Metrics.tabStackThumbnailCorner)
        // Under the finger exactly: a straight pull from the card's centre goes straight up, and grown at
        // the peek's height it is the peek: the peek's scale, top at the safe line, centre where the finger is.
        let rise = layout.flickRiseHeight(grab: centred(layout), safeTop: safeTop)
        #expect(abs(rise - 486.69) < 1e-6)
        let peek = layout.flickIncoming(
            offset: CGSize(width: 0, height: -rise), grab: centred(layout), grow: 1, land: 0, safeTop: safeTop)
        #expect(peek.scale == Theme.Metrics.tabStackFlickPeekScale)
        #expect(abs(edges(peek).top - safeTop) < 1e-6)
        #expect(abs((edges(peek).minX + edges(peek).maxX) / 2 - layout.frontSlot.x) < 1e-6)
        let up = layout.flickIncoming(
            offset: CGSize(width: 90, height: -rise), grab: centred(layout), grow: 1, land: 0, safeTop: safeTop)
        #expect(abs((edges(up).minX + edges(up).maxX) / 2 - (layout.frontSlot.x + 90)) < 1e-6)
        #expect(up.zIndex > layout.flickLive(arm: 1, drop: 0).zIndex)
        let landed = layout.flickIncoming(
            offset: CGSize(width: -40, height: -160), grab: centred(layout), grow: 1, land: 1, safeTop: safeTop)
        #expect(landed.scale == 1 && landed.offset == .zero && landed.opacity == 1 && landed.rotation == .zero)
    }

    // Grow is the rise alone, which its input says: a drop adds none, the peek's size exactly at the rise and past it,
    // and the shortest rise, a grab at the thumbnail's bottom edge, is still a long way up.
    @Test func growIsTheRiseAloneAndTheShortestRiseIsStillLong() {
        let layout = CardLayout(screen: screen)
        let grab = centred(layout)
        let rise = layout.flickRiseHeight(grab: grab, safeTop: safeTop)
        func grow(_ rise: CGFloat) -> CGFloat {
            layout.flickGrow(rise: rise, grab: grab, safeTop: safeTop)
        }
        #expect(grow(0) == 0 && grow(-50) == 0)
        #expect(abs(grow(rise / 2) - 0.5) < 1e-9)
        #expect(grow(rise) == 1 && grow(rise + 1) == 1)
        let bottom = layout.flickGrab(at: CGPoint(x: layout.frontSlot.x, y: layout.frontSlot.y + 40))
        #expect(bottom.unit.y == 0.5 && layout.flickRiseHeight(grab: bottom, safeTop: safeTop) > 200)
    }

    // The card leaves at the thumbnail's tilt and is upright by scale 0.2, as it grows.
    @Test func theRisingCardIsUprightByAFifthOfTheScreen() {
        let layout = CardLayout(screen: screen)
        func card(_ grow: CGFloat) -> CardTransform {
            layout.flickIncoming(offset: .zero, grab: centred(layout), grow: grow, land: 0, safeTop: safeTop)
        }
        #expect(card(0).rotation == .degrees(Theme.Metrics.tabStackTilt))
        var grow: CGFloat = 0
        while card(grow).scale < Theme.Metrics.tabStackFlickUprightScale {
            #expect(card(grow).rotation.degrees > 0)
            grow += 0.001
        }
        #expect(card(grow).rotation == .zero && card(1).rotation == .zero)
    }

    // Half grown, in numbers: the card half way from the thumbnail's size to the peek's, under the finger, while the
    // live page holds its armed size, pinned to its corner.
    @Test func halfGrownTheCardIsHalfWayToThePeeksSize() {
        let layout = CardLayout(screen: screen)
        let live = edges(layout.flickLive(arm: 1, drop: 0))
        #expect(abs((live.maxX - live.minX) / 402 - 0.84) < 1e-9)
        #expect(abs(live.minX - 24) < 1e-9 && abs(live.bottom - 773) < 1e-9)
        let rising = edges(
            layout.flickIncoming(
                offset: CGSize(width: 0, height: -100), grab: centred(layout), grow: 0.5, land: 0, safeTop: safeTop))
        let width = 0.63 * 402 * (0.5 + 0.5 * 26 / (402 * 0.63))
        #expect(abs(rising.maxX - rising.minX - width) < 1e-6)
        // Its height is the page's shape at that width, all but shaped.
        #expect(abs(rising.bottom - rising.top - 300.8) < 0.5)
        // Its centre is the finger's: 100 pt straight up from the front slot (53, 824).
        #expect(abs((rising.minX + rising.maxX) / 2 - 53) < 1e-6)
        #expect(abs((rising.top + rising.bottom) / 2 - 724) < 1e-6)
    }

    // The card takes the page's shape ahead of its size: the page at one
    // uniform scale, clipped from its top, whose height runs ahead of its width so that it is page-shaped within the
    // first third of its growth. It is never wider than tall and never shows more page than the screen holds (the
    // old law peaked at an aspect of 1.23, wider than tall, around grow 0.2).
    @Test func theRisingCardTakesThePagesShapeWithinTheFirstThirdOfItsGrowth() {
        let layout = CardLayout(screen: screen)
        func card(_ grow: CGFloat) -> (height: CGFloat, aspect: CGFloat, shown: CGFloat) {
            let t = layout.flickIncoming(
                offset: .zero, grab: centred(layout), grow: grow, land: 0, safeTop: safeTop)
            let e = edges(t)
            return (e.bottom - e.top, (e.maxX - e.minX) / (e.bottom - e.top), t.clipHeight / t.scale)
        }
        #expect(abs(card(0.05).height - 66.5) < 0.5 && abs(card(0.3).height - 197.7) < 0.5)
        #expect(abs(card(0.5).aspect - 0.464) < 0.005)
        #expect(abs(card(1).aspect - 402 / 874) < 1e-9 && abs(card(1).height - 550.62) < 1e-6)
        var last = card(0)
        #expect(abs(last.aspect - 26 / 34) < 1e-9)
        for step in 1...1000 {
            let next = card(CGFloat(step) / 1000)
            #expect(next.height >= last.height && next.aspect <= last.aspect)
            #expect(next.aspect <= 26 / 34 && next.shown <= 874 + 1e-6)
            last = next
        }
    }

    // The corner does not scale with the card: 4 pt on the thumbnail, a card's
    // corner as soon as the card is a card, the deck card's at full size.
    @Test func theRisingCardsCornerIsACardsCornerAsSoonAsItIsACard() {
        let layout = CardLayout(screen: screen)
        func corner(_ grow: CGFloat) -> CGFloat {
            layout.flickIncoming(offset: .zero, grab: centred(layout), grow: grow, land: 0, safeTop: safeTop)
                .corner
        }
        #expect(corner(0) == Theme.Metrics.tabStackThumbnailCorner && corner(1) == Theme.Metrics.cardCorner)
        #expect(abs(corner(0.2) - 13.8) < 0.1)
        var last = corner(0)
        for step in 1...1000 {
            let next = corner(CGFloat(step) / 1000)
            #expect(next >= last)
            last = next
        }
    }

    // The stack's front card leaves it as the travelling card: one card stays, unmoved, and the stack draws its copy
    // while the card is on its way. A page dropped in is drawn in front of both.
    @Test func theStackShowsOneFewerCardWhileItsFrontCardIsOut() {
        let (front, back, dropped) = (UUID(), UUID(), UUID())
        let t = CardLayout(screen: screen).flickIncoming(
            offset: .zero, grab: centred(CardLayout(screen: screen)), grow: 0, land: 0, safeTop: safeTop)
        func leaving(_ f: CGFloat) -> DeckDriver.StackFlight {
            DeckDriver.StackFlight(id: front, transform: t, fromStack: f, leaving: true)
        }
        func ids(_ cards: (fixed: [(id: UUID, rank: Int)], copies: [DeckDriver.StackFlight])) -> ([UUID], [Int], [UUID]) {
            (cards.fixed.map(\.id), cards.fixed.map(\.rank), cards.copies.map(\.id))
        }
        #expect(ids(TabStackThumbnails.cards(recent: [front, back], flights: [])) == ([front, back], [0, 1], []))
        #expect(ids(TabStackThumbnails.cards(recent: [front, back], flights: [leaving(1)])) == ([front, back], [0, 1], []))
        #expect(ids(TabStackThumbnails.cards(recent: [front, back], flights: [leaving(0.95)])) == ([back], [1], [front]))
        #expect(ids(TabStackThumbnails.cards(recent: [front, back], flights: [leaving(0.5)])) == ([back], [1], [front]))
        #expect(ids(TabStackThumbnails.cards(recent: [front, back], flights: [leaving(0)])) == ([back], [1], []))
        let drop = DeckDriver.StackFlight(id: dropped, transform: t, fromStack: 1, leaving: false)
        #expect(ids(TabStackThumbnails.cards(recent: [front, back], flights: [drop])) == ([front, back], [0, 1], [dropped]))
        // The stack draws from the driver's out card: one fewer while that is its front card, both otherwise.
        let outFront = TabStackThumbnails.fixed(recent: [front, back], outOfStack: front)
        #expect(outFront.map(\.id) == [back] && outFront.map(\.rank) == [1])
        #expect(TabStackThumbnails.fixed(recent: [front, back], outOfStack: dropped).map(\.id) == [front, back])
        #expect(TabStackThumbnails.fixed(recent: [front, back], outOfStack: nil).map(\.rank) == [0, 1])
        #expect(TabStackThumbnails.copies(recent: [front, back], flights: [leaving(0.5)]).map(\.id) == [front])
        #expect(TabStackThumbnails.copies(recent: [front, back], flights: [leaving(1), drop]).map(\.id) == [dropped])
        // At the slot the copy is the resting front card exactly: its place, size, tilt and corner.
        let layout = CardLayout(screen: screen)
        let copy = StackCopy.Geometry(t, layout: layout)
        let offset = Theme.Metrics.tabStackThumbnailOffsets[0]
        #expect(abs(copy.centre.x - offset.width) < 1e-6 && abs(copy.centre.y - offset.height) < 1e-6)
        #expect(abs(copy.size.width - Theme.Metrics.tabStackThumbnailSize.width) < 1e-6)
        #expect(abs(copy.size.height - Theme.Metrics.tabStackThumbnailSize.height) < 1e-6)
        #expect(copy.rotation == .degrees(Theme.Metrics.tabStackTilt))
        #expect(copy.corner == Theme.Metrics.tabStackThumbnailCorner)
    }

    // The bar's copy of a landing card goes once the card's bottom clears the bar's top, however tall the bar, or once
    // it grows past the peek's size, a page the bar covers: until then it is copied on every frame, never after.
    @Test func aTallerBarKeepsTheCopyUntilTheLandingCardClearsIt() {
        let layout = CardLayout(screen: screen, barHeight: 200)
        let to = UUID()
        let driver = DeckDriver()
        driver.adopt(layout)
        driver.beginFlick(from: UUID(), to: to, safeTop: safeTop, grab: centred(layout))
        let rise = layout.flickRiseHeight(grab: centred(layout), safeTop: safeTop)
        driver.moveFlick(to: CGSize(width: 0, height: -rise * 0.3), grow: 0.3)
        let start = ContinuousClock.now
        driver.animateFlick(\.offsetY, to: -rise, spring: DeckSnap.flick, start: start)
        driver.animateFlick(\.grow, to: 1, spring: DeckSnap.flick, start: start)
        driver.animateFlick(\.land, to: 1, spring: DeckSnap.flick, start: start)
        var (cleared, copiedFrames) = (false, 0)
        for step in 1...200 {
            driver.apply(at: start + .milliseconds(step * 4))
            let flight = driver.stackFlights(layout: layout).first { $0.id == to }!
            let copied = !TabStackThumbnails.cards(recent: [to], flights: [flight]).copies.isEmpty
            cleared = cleared || layout.bottom(of: flight.transform) <= layout.barTop
            let page = flight.transform.scale > Theme.Metrics.tabStackFlickPeekScale
            #expect(copied == !(cleared || page))
            copiedFrames += copied ? 1 : 0
        }
        #expect(copiedFrames > 0)
    }

    @Test func theDriverLandsTheFlickOnceAndSettlesItOnAStillFrame() {
        let start = ContinuousClock.now
        let driver = DeckDriver()
        let layout = CardLayout(screen: screen)
        driver.adopt(layout)
        driver.beginFlick(from: UUID(), to: UUID(), safeTop: safeTop, grab: centred(layout))
        driver.moveFlick(to: CGSize(width: 30, height: -80), grow: 1)
        var landedAt: [CGFloat] = []
        var settledMoving: [Bool] = []
        driver.animateFlick(\.land, to: 1, spring: DeckSnap.flick, start: start)
        driver.animateFlick(\.drop, to: 1, spring: DeckSnap.flickDrop, start: start)
        driver.releaseFlick(
            landing: { landedAt.append(driver.flick!.land) }, settled: { settledMoving.append(driver.isFlickMoving) })
        for step in 1...200 {
            driver.apply(at: start + .milliseconds(step * 4))
        }
        #expect(landedAt.count == 1 && landedAt[0] > 1 - Theme.Gesture.deckSettledDistance)
        #expect(settledMoving == [false])
        #expect(driver.flick == nil && !driver.isAnimating)
    }
}

// A flick up on the hosted tab stack shrinks the live page into the corner and raises the previous tab over it.
@MainActor @Suite(.serialized)
struct TabStackFlickHostTests {
    private final class ClockedSink: HapticSink {
        var now: ContinuousClock.Instant { .now }
        var onPlay: (HapticFeedback) -> Void = { _ in }

        func prepare(_ feedback: HapticFeedback) {}

        func play(_ feedback: HapticFeedback) {
            onPlay(feedback)
        }

        func drive(_ texture: HapticTexture, _ level: HapticTexture.Level) {}

        func stop(_ texture: HapticTexture) {}
    }

    private struct Hosted {
        let env: AppEnvironment
        let window: UIWindow
        let controller: BehindController
        let flick: TabStackFlick
        let surface: (DragPhase, DragSample) -> Void
        let tabs: [UUID]

        var driver: DeckDriver { env.ui.deck }
    }

    private static let lock = -(Theme.Gesture.axisLockDistance + 2)

    private func hosted(sink: ClockedSink) async throws -> Hosted {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let env = makeEnvironment(hapticSink: sink)
        for index in 0..<3 {
            env.open(page("\(index)"))
        }
        let controller = BehindController(env: env)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        try await waitUntil {
            env.flick != nil && env.debugSurfaces[.tabStack] != nil && env.activeController?.webView.window != nil
        }
        try await waitUntil { !env.ui.deck.isAnimating }
        env.ui.deck.hold()
        return Hosted(
            env: env, window: window, controller: controller, flick: env.flick!,
            surface: env.debugSurfaces[.tabStack]!, tabs: env.browser.tabs.map(\.id))
    }

    private func sample(_ dy: CGFloat, velocity: CGFloat = 0) -> DragSample {
        DragSample(
            startLocation: CGPoint(x: 46, y: 20), location: CGPoint(x: 46, y: 20 + dy),
            translation: CGSize(width: 0, height: dy), velocity: CGSize(width: 0, height: velocity),
            time: Date().addingTimeInterval(1))
    }

    private func sample(_ dx: CGFloat, _ dy: CGFloat, velocity: CGSize = .zero) -> DragSample {
        DragSample(
            startLocation: CGPoint(x: 46, y: 20), location: CGPoint(x: 46 + dx, y: 20 + dy),
            translation: CGSize(width: dx, height: dy), velocity: velocity, time: Date().addingTimeInterval(1))
    }

    // Locks with a slop's move, then lifts the page `travel` points past the lock.
    private func lift(_ hosted: Hosted, travel: CGFloat) {
        hosted.surface(.began, sample(0))
        hosted.surface(.changed, sample(Self.lock))
        hosted.surface(.changed, sample(Self.lock - travel))
    }

    private func flicks(_ env: AppEnvironment) -> [HapticRecord] {
        env.haptics.records.filter { $0.interaction == .tabStackFlick || $0.interaction == .tabStackTap }
    }

    private func drawn(_ hosted: Hosted, _ id: UUID) -> CardGeometry {
        let tabs = hosted.env.browser.tabs
        let active = tabs.firstIndex { $0.id == hosted.env.browser.activeTabID }!
        return hosted.driver.placement(
            index: tabs.firstIndex { $0.id == id }!, activeIndex: active, layout: hosted.flick.layout,
            header: EmptyView(), coverImage: nil, coverFill: .black, isUnrevealed: false, cover: CardCover(), tabID: id
        ).geometry
    }

    // Every flick here runs on the deck's held clock, stepped a display frame at a time.
    private func step(_ hosted: Hosted, until done: () -> Bool) {
        for _ in 0..<1200 where !done() {
            hosted.driver.step(by: Theme.Latency.frame)
        }
    }

    private func settled(_ hosted: Hosted) async throws {
        step(hosted) { hosted.driver.flick == nil && !hosted.driver.isAnimating }
        #expect(hosted.driver.flick == nil && !hosted.driver.isAnimating)
    }

    @Test(.timeLimit(.minutes(1)))
    func aPullOf120PointsShrinksTheLivePageAndRaisesThePreviousCard() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let (active, previous) = (hosted.tabs[2], hosted.tabs[1])
        #expect(hosted.env.browser.previousTabID == previous)
        var captures: [UUID] = []
        hosted.env.onCaptureRequested = { captures.append($0) }
        lift(hosted, travel: 120)
        // The page being left was captured on the bar touch's first move (TabPager.prepare); the lock adds none.
        #expect(captures.isEmpty)
        step(hosted) { hosted.driver.flick!.arm == 1 }
        let layout = hosted.flick.layout
        let flick = hosted.driver.flick!
        // The card is under the finger from the touch-down, the slop included.
        #expect(flick.offset == CGSize(width: 0, height: Self.lock - 120))
        let page = drawn(hosted, active)
        let size = hosted.window.bounds.size
        // 0.84 armed, and that size while the card is dragged; the bottom-left pinned 24 in and 101 up.
        #expect(abs(page.scale - 0.84) < 1e-9)
        #expect(abs(size.width / 2 + page.offset.width - size.width * page.scale / 2 - 24) < 1e-6)
        #expect(abs(size.height / 2 + page.offset.height - size.height * page.scale / 2 + page.clipHeight
            - (size.height - 101)) < 1e-6)
        let rising = drawn(hosted, previous)
        // The card has grown with its rise, this far of the way to the peek's height.
        let rise = layout.flickRiseHeight(grab: flick.grab, safeTop: flick.safeTop)
        #expect(abs(flick.grow - (120 - Self.lock) / rise) < 1e-9)
        let incoming = layout.flickIncoming(
            offset: flick.offset, grab: flick.grab, grow: flick.grow, land: 0, safeTop: hosted.env.pool.page.safeTop)
        #expect(abs(rising.scale - incoming.scale) < 1e-9 && abs(rising.offset.height - incoming.offset.height) < 1e-9)
        #expect(drawn(hosted, hosted.tabs[0]).opacity == 0)
        #expect(flicks(hosted.env).isEmpty)
        #expect(hosted.env.browser.activeTabID == active)
        #expect(hosted.env.ui.deckProgress == 0)
        hosted.surface(.ended, sample(Self.lock - 120))
        try await settled(hosted)
    }

    // The stack's top card pops out and one card is left. The front card is the previous tab and it leaves the
    // stack as the rising card; on the landing the page left enters the stack as the new front card, with no re-rank
    // motion.
    @Test(.timeLimit(.minutes(1)))
    func theStacksFrontCardRisesOutAndThePageLeftDropsIn() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let (oldest, previous, active) = (hosted.tabs[0], hosted.tabs[1], hosted.tabs[2])
        let layout = hosted.flick.layout
        func stack() -> (fixed: [UUID], copies: [UUID]) {
            let recent = hosted.env.browser.tabs.filter { $0.id != hosted.env.browser.activeTabID }
                .sorted { $0.lastActiveAt > $1.lastActiveAt }.prefix(2).map(\.id)
            let cards = TabStackThumbnails.cards(recent: recent, flights: hosted.driver.stackFlights(layout: layout))
            return (cards.fixed.map(\.id), cards.copies.map(\.id))
        }
        #expect(stack().fixed == [previous, oldest])
        lift(hosted, travel: 10)
        hosted.driver.step(by: Theme.Latency.frame)
        #expect(stack().fixed == [oldest] && stack().copies == [previous])
        hosted.surface(.ended, sample(Self.lock - 10, velocity: -1500))
        var dropped = false
        step(hosted) {
            dropped = dropped || stack().copies == [active] && stack().fixed == [oldest]
            return hosted.driver.flick == nil
        }
        #expect(dropped)
        #expect(stack().fixed == [active, oldest] && stack().copies.isEmpty)
    }

    // On every frame of a fast 30 pt flick and of a slow pull, the rising card is opaque in the deck, and wherever the
    // bar would hide it the stack draws its opaque copy at the same place: no seam, no see-through card, and no frame
    // where the copy vanishes while the card is still under the bar.
    @Test(.timeLimit(.minutes(1)))
    func theRisingCardIsCoveredOnEveryFrameOfItsHandOff() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let layout = hosted.flick.layout
        let previous = hosted.tabs[1]
        let barTop = layout.screen.height - Theme.Metrics.barTotalHeight
        func checkFrames(_ count: Int) -> (frames: Int, gaps: Int) {
            var (frames, gaps) = (0, 0)
            for _ in 0..<count where hosted.driver.flick != nil {
                hosted.driver.step(by: Theme.Latency.frame)
                guard let flight = hosted.driver.stackFlights(layout: layout).first(where: { $0.id == previous })
                else { continue }
                let t = flight.transform
                let bottom = layout.screen.height / 2 + t.offset.height - layout.screen.height * t.scale / 2
                    + t.clipHeight
                let underBar = bottom > barTop && t.scale <= Theme.Metrics.tabStackFlickPeekScale
                let recent = [previous, hosted.tabs[0]]
                let copied = TabStackThumbnails.cards(recent: recent, flights: [flight]).copies.contains { $0.id == previous }
                frames += 1
                // A page-sized card is the bar's to cover: the stack never draws it over the bar.
                let pageOverBar = copied && t.scale > Theme.Metrics.tabStackFlickPeekScale
                if t.opacity != 1 || underBar && !copied || pageOverBar {
                    gaps += 1
                }
            }
            return (frames, gaps)
        }
        let travel = 30 + Self.lock
        lift(hosted, travel: travel)
        hosted.surface(.ended, sample(Self.lock - travel, velocity: -1500))
        let fast = checkFrames(600)
        try await settled(hosted)
        hosted.surface(.began, sample(0))
        for step in 1...40 {
            hosted.surface(.changed, sample(Self.lock - CGFloat(step) * 10))
            hosted.driver.step(by: Theme.Latency.frame)
        }
        hosted.surface(.ended, sample(Self.lock - 400))
        let slow = checkFrames(600)
        try await settled(hosted)
        #expect(fast.frames > 0 && fast.gaps == 0)
        #expect(slow.frames > 0 && slow.gaps == 0)
    }

    // The card moves around with the finger. A diagonal pull carries the card by the finger's offset in both
    // axes, and its size and the live page's shrink follow its height.
    @Test(.timeLimit(.minutes(1)))
    func aDiagonalPullCarriesTheCardInBothAxes() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        hosted.surface(.began, sample(0))
        hosted.surface(.changed, sample(Self.lock))
        hosted.surface(.changed, sample(80, Self.lock - 200))
        let follow = Theme.Gesture.tabStackFlickFollow
        let flick = hosted.driver.flick!
        #expect(flick.offset == CGSize(width: 80 * follow, height: (Self.lock - 200) * follow))
        // Its size follows its rise alone: the sideways 80 pt grows it none.
        let layout = hosted.flick.layout
        #expect(flick.grow == layout.flickGrow(rise: (200 - Self.lock) * follow, grab: flick.grab, safeTop: flick.safeTop))
        // The live page holds its armed size whatever the card's height.
        step(hosted) { hosted.driver.flick!.arm == 1 }
        #expect(drawn(hosted, hosted.tabs[2]).scale == 0.84)
        hosted.surface(.ended, sample(80, Self.lock - 200))
        try await settled(hosted)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[1])
    }

    // A lateral wobble never breaks the gesture: the card follows it and the release still lands.
    @Test(.timeLimit(.minutes(1)))
    func aLateralWobbleStillLands() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        hosted.surface(.began, sample(0))
        hosted.surface(.changed, sample(Self.lock))
        hosted.surface(.changed, sample(0, Self.lock - 60))
        for dx: CGFloat in [100, -100, 50] {
            hosted.surface(.changed, sample(dx, Self.lock - 60))
            #expect(hosted.driver.flick!.offset.width == dx)
        }
        hosted.surface(.ended, sample(50, Self.lock - 60))
        try await settled(hosted)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[1])
        #expect(flicks(hosted.env).map(\.interaction) == [.tabStackFlick])
    }

    // A release below the landing line returns the card from where it is drawn, in both axes, with no jump.
    @Test(.timeLimit(.minutes(1)))
    func aReleaseBelowTheLineReturnsFromWhereTheCardIs() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        hosted.surface(.began, sample(0))
        hosted.surface(.changed, sample(Self.lock))
        hosted.surface(.changed, sample(120, Self.lock - 10))
        let held = hosted.driver.flick!.offset
        hosted.surface(.ended, sample(120, Self.lock - 10))
        hosted.driver.step(by: Theme.Latency.frame)
        let first = hosted.driver.flick!.offset
        #expect(first.width < held.width && first.width > held.width - 30)
        #expect(first.height >= held.height && first.height < held.height + 10)
        try await settled(hosted)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[2])
        #expect(flicks(hosted.env).isEmpty)
    }

    // A release keeps the finger's speed in both axes, even away from where the card is going: its first frame moves on
    // the same way, a return and a landing alike.
    @Test(.timeLimit(.minutes(1)))
    func aSidewaysReleaseCarriesItsSpeed() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        func firstFrameX(dy: CGFloat, velocity: CGSize) -> CGFloat {
            hosted.surface(.began, sample(0))
            hosted.surface(.changed, sample(Self.lock))
            hosted.surface(.changed, sample(120, Self.lock + dy))
            let held = hosted.driver.flick!.offset.width
            hosted.surface(.ended, sample(120, Self.lock + dy, velocity: velocity))
            hosted.driver.step(by: Theme.Latency.frame)
            return hosted.driver.flick!.offset.width - held
        }
        // Returning (10 pt up, still) while moving right, away from where it returns to.
        let returning = firstFrameX(dy: -10, velocity: CGSize(width: 600, height: 0))
        try await settled(hosted)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[2])
        // Landing (60 pt up) while moving right.
        let landing = firstFrameX(dy: -60, velocity: CGSize(width: 600, height: -300))
        try await settled(hosted)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[1])
        #expect(returning > 0 && landing > 0)
    }

    // Freeform: a card put far left lands from there. It coasts up toward the peek's height but never sweeps right,
    // so its drawn centre never passes the screen's centre on the way to the screen.
    @Test(.timeLimit(.minutes(1)))
    func aFarLeftLandingNeverSweepsAcross() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        hosted.surface(.began, sample(0))
        hosted.surface(.changed, sample(Self.lock))
        hosted.surface(.changed, sample(-150, Self.lock - 150))
        hosted.surface(.ended, sample(-150, Self.lock - 150))
        let width = hosted.window.bounds.width
        var widest: CGFloat = 0
        step(hosted) {
            if hosted.driver.flick != nil {
                widest = max(widest, width / 2 + drawn(hosted, hosted.tabs[1]).offset.width)
            }
            return hosted.driver.flick == nil
        }
        #expect(widest <= width / 2 + 0.5)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[1])
    }

    // Freeform: a card put low and right, let go still, coasts straight up to the peek's height. It never swings
    // further right before it zooms to the screen.
    @Test(.timeLimit(.minutes(1)))
    func aLowRightLandingCoastsStraightUp() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        hosted.surface(.began, sample(0))
        hosted.surface(.changed, sample(Self.lock))
        hosted.surface(.changed, sample(330, Self.lock - 60))
        let put = drawn(hosted, hosted.tabs[1]).offset.width
        // Right of the screen's centre, so the zoom to the screen only ever moves it left.
        #expect(put > 0)
        hosted.surface(.ended, sample(330, Self.lock - 60))
        var widest = put
        step(hosted) {
            if hosted.driver.flick != nil {
                widest = max(widest, drawn(hosted, hosted.tabs[1]).offset.width)
            }
            return hosted.driver.flick == nil
        }
        #expect(widest <= put + 0.5)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[1])
    }

    // A drag from a point on the stack's front card, in the button's own space.
    private func sample(on card: CGPoint, _ dx: CGFloat, _ dy: CGFloat, layout: CardLayout) -> DragSample {
        let start = CGPoint(
            x: layout.frontSlot.x + card.x - layout.tabStackButtonFrame.minX,
            y: layout.frontSlot.y + card.y - layout.tabStackButtonFrame.minY)
        return DragSample(
            startLocation: start, location: CGPoint(x: start.x + dx, y: start.y + dy),
            translation: CGSize(width: dx, height: dy), velocity: .zero, time: Date().addingTimeInterval(1))
    }

    // Where a point of a card, as a fraction of its size from its centre in its own axes, is on the screen.
    private func point(_ unit: CGPoint, on centre: CGPoint, size: CGSize, rotation: Angle) -> CGPoint {
        let (x, y) = (unit.x * size.width, unit.y * size.height)
        let (c, s) = (cos(rotation.radians), sin(rotation.radians))
        return CGPoint(x: centre.x + x * c - y * s, y: centre.y + x * s + y * c)
    }

    // The previous card's drawn centre, size and tilt, and its copy's over the bar while it has one.
    private func rising(_ hosted: Hosted) -> (card: (CGPoint, CGSize, Angle), copy: (CGPoint, CGSize, Angle)?) {
        let layout = hosted.flick.layout
        let to = hosted.driver.flick!.to
        let flight = hosted.driver.stackFlights(layout: layout).first { $0.id == to }!
        let t = flight.transform
        let screen = layout.screen
        let geometry = drawn(hosted, to)
        #expect(geometry.scale == t.scale && geometry.offset == t.offset && geometry.clipHeight == t.clipHeight)
        let top = screen.height / 2 + t.offset.height - screen.height * t.scale / 2
        let card = (
            CGPoint(x: screen.width / 2 + t.offset.width, y: top + (t.clipTop + t.clipHeight) / 2),
            CGSize(width: screen.width * t.scale, height: t.clipHeight - t.clipTop), t.rotation)
        let copy = TabStackThumbnails.cards(recent: [to], flights: [flight]).copies.first.map { copied in
            let g = StackCopy.Geometry(copied.transform, layout: layout)
            let button = layout.tabStackButtonFrame
            return (CGPoint(x: button.midX + g.centre.x, y: button.midY + g.centre.y), g.size, g.rotation)
        }
        return (card, copy)
    }

    // The card once did not quite follow the finger from the bottom left. The point of the card under
    // the finger at touch-down stays under it, within a point, on every move and every frame of a straight pull and of
    // a diagonal one past the screen's edge, and the bar's copy draws the same point there.
    @Test(.timeLimit(.minutes(1)))
    func theGrabbedPointStaysUnderTheFinger() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let layout = hosted.flick.layout
        let size = Theme.Metrics.tabStackThumbnailSize
        // Low left on the front card, in its own tilted axes.
        let on = CGPoint(x: -0.3 * size.width, y: 0.35 * size.height)
        let tilt = Angle.degrees(Theme.Metrics.tabStackTilt)
        let grabbed = point(
            CGPoint(x: -0.3, y: 0.35), on: layout.frontSlot, size: size, rotation: tilt)
        let start = CGPoint(x: on.x * cos(tilt.radians) - on.y * sin(tilt.radians),
            y: on.x * sin(tilt.radians) + on.y * cos(tilt.radians))
        #expect(abs(grabbed.x - layout.frontSlot.x - start.x) < 1e-9)
        var (checks, misses, copyChecks, copyMisses) = (0, 0, 0, 0)
        func check(_ dx: CGFloat, _ dy: CGFloat) {
            let finger = CGPoint(x: grabbed.x + dx, y: grabbed.y + dy)
            let drawn = rising(hosted)
            let at = point(CGPoint(x: -0.3, y: 0.35), on: drawn.card.0, size: drawn.card.1, rotation: drawn.card.2)
            checks += 1
            if hypot(at.x - finger.x, at.y - finger.y) > 1 { misses += 1 }
            if let copy = drawn.copy {
                let copied = point(CGPoint(x: -0.3, y: 0.35), on: copy.0, size: copy.1, rotation: copy.2)
                copyChecks += 1
                if hypot(copied.x - finger.x, copied.y - finger.y) > 1 { copyMisses += 1 }
            }
        }
        for slope: CGFloat in [0, 0.4] {
            hosted.surface(.began, sample(on: start, 0, 0, layout: layout))
            var lock: CGSize?
            for step in 1...70 {
                let (dx, dy) = (slope * CGFloat(step) * 10, -CGFloat(step) * 10)
                hosted.surface(.changed, sample(on: start, dx, dy, layout: layout))
                guard hosted.driver.flick != nil else { continue }
                // The card makes up the slop over the catch-up's multiple of it, and is exact from then on.
                let slop = lock ?? CGSize(width: dx, height: dy)
                lock = slop
                let since = hypot(dx - slop.width, dy - slop.height)
                guard since >= Theme.Gesture.tabStackFlickCatchUp * hypot(slop.width, slop.height) else { continue }
                check(dx, dy)
                hosted.driver.step(by: Theme.Latency.frame)
                check(dx, dy)
            }
            hosted.surface(.ended, sample(on: start, slope * 700, -700, layout: layout))
            try await settled(hosted)
        }
        #expect(checks > 200 && misses == 0)
        #expect(copyChecks > 4 && copyMisses == 0)
    }

    // A one-second diagonal pull at 120 Hz, one touch move per frame. The card does not move at the lock, where the
    // finger has led it by the slop; it makes the slop up over the catch-up's multiple of it with no frame stepping
    // more than twice the finger's step, and from then on its grabbed point is under the finger on the same frame,
    // within a point.
    @Test(.timeLimit(.minutes(1)))
    func aOneSecondDiagonalPullCatchesUpAndFollowsFrameByFrame() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let layout = hosted.flick.layout
        hosted.surface(.began, sample(on: .zero, 0, 0, layout: layout))
        var (lockFrame, worstAfter, biggestStep, caughtUp) = (Int?.none, CGFloat(0), CGFloat(0), false)
        var (last, slop) = (CGPoint.zero, CGFloat(0))
        for frame in 1...120 {
            let (dx, dy) = (CGFloat(frame) * 2, -CGFloat(frame) * 5)
            hosted.surface(.changed, sample(on: .zero, dx, dy, layout: layout))
            hosted.driver.step(by: Theme.Latency.frame)
            guard let flick = hosted.driver.flick else { continue }
            let drawn = rising(hosted)
            let unit = flick.grab.unit
            let at = point(unit, on: drawn.card.0, size: drawn.card.1, rotation: drawn.card.2)
            let card = CGPoint(x: at.x - flick.grab.point.x, y: at.y - flick.grab.point.y)
            let error = hypot(card.x - dx, card.y - dy)
            if lockFrame == nil {
                lockFrame = frame
                slop = hypot(dx, dy)
                #expect(hypot(card.x, card.y) < 1e-6)
            } else {
                biggestStep = max(biggestStep, hypot(card.x - last.x, card.y - last.y))
            }
            let since = CGFloat(frame - lockFrame!) * hypot(2, 5)
            if since >= Theme.Gesture.tabStackFlickCatchUp * slop {
                caughtUp = true
                worstAfter = max(worstAfter, error)
            }
            last = card
        }
        hosted.surface(.ended, sample(on: .zero, 240, -600, layout: layout))
        try await settled(hosted)
        // No jump: no frame moves the card more than twice the finger's own step.
        #expect(biggestStep < 2 * hypot(2, 5))
        #expect(caughtUp && worstAfter < 1)
    }

    // The lock is radial: a pull up and to the right, a thumb's path, starts at the sample whose travel reaches eight
    // points (the eighth, 9.1 pt; the seventh is 7.99) and never before; the card then makes up the slop and its
    // grabbed point sits under the finger. Mutant: the lead rule starts near the 25th sample.
    @Test(.timeLimit(.minutes(1)))
    func aDiagonalPullStartsWithinNinePoints() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let layout = hosted.flick.layout
        hosted.surface(.began, sample(on: .zero, 0, 0, layout: layout))
        var (lockedAt, slop) = (Int?.none, CGFloat(0))
        var (checks, misses) = (0, 0)
        for k in 1...60 {
            let (dx, dy) = (0.55 * CGFloat(k), -CGFloat(k))
            hosted.surface(.changed, sample(on: .zero, dx, dy, layout: layout))
            guard let flick = hosted.driver.flick else {
                #expect(hypot(dx, dy) < Theme.Gesture.axisLockDistance)
                continue
            }
            if lockedAt == nil {
                lockedAt = k
                slop = hypot(dx, dy)
            }
            hosted.driver.step(by: Theme.Latency.frame)
            guard CGFloat(k - lockedAt!) * hypot(0.55, 1) >= Theme.Gesture.tabStackFlickCatchUp * slop else { continue }
            let drawn = rising(hosted)
            let at = point(flick.grab.unit, on: drawn.card.0, size: drawn.card.1, rotation: drawn.card.2)
            checks += 1
            if hypot(at.x - flick.grab.point.x - dx, at.y - flick.grab.point.y - dy) > 1 {
                misses += 1
            }
        }
        #expect(lockedAt == 8 && slop <= 9.2)
        #expect(checks > 10 && misses == 0)
        hosted.surface(.ended, sample(on: .zero, 33, -60, layout: layout))
        try await settled(hosted)
    }

    // The bar's copy tracks the card in x too, so a sideways drag near the button shows no seam.
    @Test(.timeLimit(.minutes(1)))
    func theStacksCopyTracksTheCardSideways() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        hosted.surface(.began, sample(0))
        hosted.surface(.changed, sample(Self.lock))
        hosted.surface(.changed, sample(40, Self.lock - 5))
        let drawn = rising(hosted)
        let copy = try #require(drawn.copy)
        #expect(hypot(copy.0.x - drawn.card.0.x, copy.0.y - drawn.card.0.y) < 1e-6)
        #expect(abs(copy.1.width - drawn.card.1.width) < 1e-6 && abs(copy.1.height - drawn.card.1.height) < 1e-6)
        #expect(copy.2 == drawn.card.2)
        hosted.surface(.ended, sample(40, Self.lock - 5))
        try await settled(hosted)
    }

    // Once grown to the peek's size,
    // as its top meets the safe line, the card keeps that size, width and height, wherever it is dragged, up, sideways
    // or back down, and the live page stays at its armed size.
    @Test(.timeLimit(.minutes(1)))
    func theCardKeepsOneSizeWhereverItIsDragged() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        hosted.surface(.began, sample(0))
        hosted.surface(.changed, sample(Self.lock))
        let flick = hosted.driver.flick!
        hosted.surface(
            .changed, sample(Self.lock - hosted.flick.layout.flickRiseHeight(grab: flick.grab, safeTop: flick.safeTop)))
        var cards: [CardGeometry] = []
        for (dx, dy): (CGFloat, CGFloat) in [(0, -60), (0, -250), (0, -480), (120, -480), (-80, -150), (0, -45)] {
            hosted.surface(.changed, sample(dx, Self.lock + dy))
            hosted.driver.step(by: Theme.Latency.frame)
            cards.append(drawn(hosted, hosted.tabs[1]))
        }
        step(hosted) { hosted.driver.flick!.arm == 1 }
        let height = Theme.Metrics.tabStackFlickPeekScale * hosted.window.bounds.height
        #expect(cards.allSatisfy { $0.scale == Theme.Metrics.tabStackFlickPeekScale })
        #expect(cards.allSatisfy { abs($0.clipHeight - height) < 1e-6 })
        #expect(drawn(hosted, hosted.tabs[2]).scale == Theme.Metrics.tabStackFlickArmScale)
        hosted.surface(.ended, sample(0, Self.lock - 45))
        try await settled(hosted)
    }

    // The card comes out of the stack with its rise (still 43 pt wide at 40 pt of travel): it leaves at the thumbnail's size and grows in step with its rise toward the
    // peek's height, never shrinking under the finger, the peek's size exactly as its top meets the safe line, and its
    // bottom edge never lower than the front slot's; back at the start it stays that size.
    @Test(.timeLimit(.minutes(1)))
    func theCardGrowsWithItsRiseToThePeek() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let layout = hosted.flick.layout
        let screen = hosted.window.bounds.size
        let peek = Theme.Metrics.tabStackFlickPeekScale
        hosted.surface(.began, sample(0))
        hosted.surface(.changed, sample(Self.lock))
        let thumbnail = Theme.Metrics.tabStackThumbnailSize.width / screen.width
        #expect(abs(drawn(hosted, hosted.tabs[1]).scale - thumbnail) < 1e-9)
        let flick = hosted.driver.flick!
        let rise = layout.flickRiseHeight(grab: flick.grab, safeTop: flick.safeTop)
        var (last, grown) = (thumbnail, (offset: CGFloat, top: CGFloat)?.none)
        for step in 1...60 {
            hosted.surface(.changed, sample(0, Self.lock - CGFloat(step) * 10))
            let card = drawn(hosted, hosted.tabs[1])
            let top = screen.height / 2 + card.offset.height - screen.height * card.scale / 2
            let offset = -hosted.driver.flick!.offset.height
            #expect(card.scale >= last && abs(card.scale - (thumbnail + (peek - thumbnail) * min(offset / rise, 1))) < 1e-9)
            #expect(top + card.clipHeight <= layout.frontSlot.y + Theme.Metrics.tabStackThumbnailSize.height / 2 + 1)
            last = card.scale
            if card.scale == peek, grown == nil {
                grown = (offset, top)
            }
        }
        let first = try #require(grown)
        #expect(first.offset >= rise && first.offset < rise + 10)
        #expect(abs(first.top - (flick.safeTop - (first.offset - rise))) < 1e-6)
        hosted.surface(.changed, sample(Self.lock))
        #expect(drawn(hosted, hosted.tabs[1]).scale == peek)
        hosted.surface(.ended, sample(Self.lock))
        try await settled(hosted)
    }

    // The card once barely grew: it went off the screen still full size. It
    // reached the peek's size within 40 pt of travel, three frames of a flick, with a third of it below the finger
    // and off the screen. The card should be 43 pt wide at 40 pt of travel
    // and its bottom edge never drop below where the thumbnail sat, so 40 pt up it is
    // still a mini card with its bottom edge no lower than the front slot's.
    @Test(.timeLimit(.minutes(1)))
    func theRisingCardIsStillAMiniCardFortyPointsUp() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        lift(hosted, travel: 30)
        #expect(hosted.driver.flick!.offset == CGSize(width: 0, height: -40))
        let screen = hosted.window.bounds.size
        let card = drawn(hosted, hosted.tabs[1])
        let bottom = screen.height / 2 + card.offset.height - screen.height * card.scale / 2 + card.clipHeight
        #expect(screen.width * card.scale < 60)
        #expect(bottom <= hosted.flick.layout.frontSlot.y + Theme.Metrics.tabStackThumbnailSize.height / 2 + 1)
        hosted.surface(.ended, sample(Self.lock - 30))
        try await settled(hosted)
    }

    // The landing from a grown card is a uniform zoom of the page-shaped card to the screen: on every landing frame
    // the card shows the page's height at its scale, growing from the shape it was released at.
    @Test(.timeLimit(.minutes(1)))
    func theLandingZoomsTheGrownCardAtThePagesAspect() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        hosted.surface(.began, sample(0))
        hosted.surface(.changed, sample(Self.lock))
        let flick = hosted.driver.flick!
        let rise = hosted.flick.layout.flickRiseHeight(grab: flick.grab, safeTop: flick.safeTop)
        hosted.surface(.changed, sample(Self.lock - rise))
        step(hosted) { hosted.driver.flick!.arm == 1 }
        let screen = hosted.window.bounds.size
        let released = drawn(hosted, hosted.tabs[1])
        hosted.surface(.ended, sample(Self.lock - rise))
        var (first, last) = (CardGeometry?.none, released.scale)
        for _ in 0..<1200 where hosted.driver.flick != nil {
            hosted.driver.step(by: Theme.Latency.frame)
            guard let flick = hosted.driver.flick, flick.land > 0 else { continue }
            let card = drawn(hosted, hosted.tabs[1])
            #expect(abs(card.clipHeight - screen.height * card.scale) < 1e-6 && card.scale >= last - 1e-6)
            last = card.scale
            if first == nil {
                first = card
            }
        }
        let start = try #require(first)
        #expect(abs(start.scale / released.scale - 1) < 0.05 && abs(start.clipHeight / released.clipHeight - 1) < 0.05)
        try await settled(hosted)
    }

    // With the card growing over its whole rise, most releases land from a part-grown card. From 100 pt up (grow about
    // a quarter) the landing finishes the growth and the shape on the way to the screen: the card never shrinks in
    // either axis on any landing frame, and the flick ends as the screen.
    @Test(.timeLimit(.minutes(1)))
    func aLandingFromAPartGrownCardNeverShrinksOnTheWayToTheScreen() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        lift(hosted, travel: 90)
        step(hosted) { hosted.driver.flick!.arm == 1 }
        let screen = hosted.window.bounds.size
        var last = drawn(hosted, hosted.tabs[1])
        #expect(hosted.driver.flick!.grow < 0.5)
        hosted.surface(.ended, sample(Self.lock - 90))
        for _ in 0..<1200 where hosted.driver.flick != nil {
            hosted.driver.step(by: Theme.Latency.frame)
            guard hosted.driver.flick != nil else { break }
            let card = drawn(hosted, hosted.tabs[1])
            // The same hair of spring overshoot the grown landing allows, in the clip's units.
            #expect(card.scale >= last.scale - 1e-6 && card.clipHeight >= last.clipHeight - 1e-6 * screen.height)
            last = card
        }
        #expect(abs(last.scale - 1) < 0.01 && abs(last.clipHeight - screen.height) < 1)
        try await settled(hosted)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[1])
    }

    // Released part grown with the finger's speed, the card finishes its shape on the way to the screen: the aspect
    // never widens frame to frame and the flick ends as the screen. Released still, it returns and the shape unwinds
    // to the thumbnail's, with no pop at the end (CardLayout.flickGrowPoints).
    @Test(.timeLimit(.minutes(1)))
    func anEarlyReleaseFinishesTheShapeOnTheWayToTheScreen() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let screen = hosted.window.bounds.size
        func run(velocity: CGFloat, widening: Bool) -> CardGeometry {
            lift(hosted, travel: 1)
            hosted.driver.step(by: Theme.Latency.frame)
            let to = hosted.driver.flick!.to
            func card() -> CardGeometry { drawn(hosted, to) }
            var last = card()
            var aspect = screen.width * last.scale / last.clipHeight
            hosted.surface(.ended, sample(Self.lock - 1, velocity: velocity))
            for _ in 0..<1200 where hosted.driver.flick != nil {
                hosted.driver.step(by: Theme.Latency.frame)
                guard hosted.driver.flick != nil else { break }
                last = card()
                let next = screen.width * last.scale / last.clipHeight
                #expect(widening ? next >= aspect - 1e-4 : next <= aspect + 1e-4)
                aspect = next
            }
            return last
        }
        let landed = run(velocity: -1500, widening: false)
        #expect(abs(landed.scale - 1) < 0.01 && abs(landed.clipHeight - screen.height) < 1)
        try await settled(hosted)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[1])
        let returned = run(velocity: 0, widening: true)
        #expect(abs(screen.width * returned.scale - 26) < 1 && abs(returned.clipHeight - 34) < 1)
        try await settled(hosted)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[1])
    }

    // The live page reaches the armed scale within 16 frames at 60 Hz.
    @Test(.timeLimit(.minutes(1)))
    func theLivePageArmsWithinSixteenFrames() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        lift(hosted, travel: 0)
        var elapsed: Duration = .zero
        while hosted.driver.flick!.arm < 1 - Theme.Gesture.deckSettledDistance, elapsed < .seconds(1) {
            hosted.driver.step(by: Theme.Latency.frame)
            elapsed += Theme.Latency.frame
        }
        #expect(elapsed <= .seconds(16.0 / 60))
        hosted.surface(.ended, sample(Self.lock))
        try await settled(hosted)
    }

    // A touch, or the switcher, in the landing's tail after its haptic plays no second one.
    @Test(.timeLimit(.minutes(1)))
    func theLandingsTailPlaysNoSecondHaptic() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        lift(hosted, travel: 120)
        hosted.surface(.ended, sample(Self.lock - 120))
        step(hosted) { (hosted.driver.flick?.land ?? 0) > 1 - Theme.Gesture.deckSettledDistance / 2 }
        #expect(flicks(hosted.env).count == 1 && hosted.driver.flick != nil)
        hosted.controller.caught(true)
        hosted.controller.caught(false)
        hosted.driver.step(by: Theme.Latency.frame)
        hosted.env.showSwitcher(via: .tabStackTap)
        try await settled(hosted)
        #expect(flicks(hosted.env).map(\.interaction) == [.tabStackFlick, .tabStackTap])
        #expect(hosted.env.browser.activeTabID == hosted.tabs[1])
    }

    // A return carries the finger's downward speed: its first frame moves farther than a still release's.
    @Test(.timeLimit(.minutes(1)))
    func aReturnCarriesTheFingersSpeed() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        func firstFrameDrop(velocity: CGFloat) -> CGFloat {
            lift(hosted, travel: 15)
            let before = hosted.driver.flick!.offset.height
            hosted.surface(.ended, sample(Self.lock - 15, velocity: velocity))
            hosted.driver.step(by: Theme.Latency.frame)
            return hosted.driver.flick!.offset.height - before
        }
        let still = firstFrameDrop(velocity: 0)
        try await settled(hosted)
        let flicked = firstFrameDrop(velocity: 800)
        try await settled(hosted)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[2])
        #expect(flicked > still * 1.5)
    }

    // The card reaches its peek before it lands, even on a fast flick: a 30 pt flick coasts the card up higher in its
    // first landing frames than a still 30 pt release does.
    @Test(.timeLimit(.minutes(1)))
    func aFastShortFlickCoastsTheCardUpBeforeItLands() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let travel = 30 + Self.lock
        func peakAfterLanding(velocity: CGFloat) -> CGFloat {
            lift(hosted, travel: travel)
            hosted.surface(.ended, sample(Self.lock - travel, velocity: velocity))
            var peak: CGFloat = 0
            for _ in 0..<6 {
                hosted.driver.step(by: Theme.Latency.frame)
                peak = max(peak, -hosted.driver.flick!.offset.height)
            }
            return peak
        }
        let slow = peakAfterLanding(velocity: 0)
        try await settled(hosted)
        let fast = peakAfterLanding(velocity: -1500)
        try await settled(hosted)
        #expect(fast > slow)
    }

    @Test(.timeLimit(.minutes(1)))
    func aReleasePastTheFlickDistanceLandsOnThePreviousTabWithOneHapticAtTheLanding() async throws {
        let sink = ClockedSink()
        let hosted = try await hosted(sink: sink)
        defer { hosted.window.isHidden = true }
        var playedAt: [CGFloat] = []
        sink.onPlay = { feedback in
            if feedback == Theme.Haptic.medium {
                playedAt.append(hosted.driver.flick?.land ?? -1)
            }
        }
        lift(hosted, travel: 120)
        // The store switches on a still frame.
        let (env, driver) = (hosted.env, hosted.driver)
        let movingAtSwitch = Seen()
        withObservationTracking { _ = env.activeController } onChange: {
            MainActor.assumeIsolated { movingAtSwitch.values.append(driver.isFlickMoving) }
        }
        hosted.surface(.ended, sample(Self.lock - 120))
        #expect(flicks(hosted.env).isEmpty)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[2])
        try await settled(hosted)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[1])
        #expect(hosted.env.activeController?.tabID == hosted.tabs[1])
        #expect(flicks(hosted.env).map(\.interaction) == [.tabStackFlick])
        #expect(playedAt.count == 1 && playedAt[0] > 1 - Theme.Gesture.deckSettledDistance)
        #expect(movingAtSwitch.values == [false])
        let page = drawn(hosted, hosted.tabs[1])
        #expect(page.scale == 1 && page.offset == .zero)
    }

    // The line is the finger's 30 pt since touch-down, the slop included.
    @Test(.timeLimit(.minutes(1)))
    func aShortSlowLiftReturnsSilentlyAndAFastOneFinishes() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        lift(hosted, travel: 15)
        hosted.surface(.ended, sample(Self.lock - 15))
        try await settled(hosted)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[2])
        #expect(flicks(hosted.env).isEmpty)
        let page = drawn(hosted, hosted.tabs[2])
        #expect(page.scale == 1 && page.offset == .zero)
        lift(hosted, travel: 15)
        hosted.surface(.ended, sample(Self.lock - 15, velocity: -1500))
        try await settled(hosted)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[1])
        #expect(flicks(hosted.env).map(\.interaction) == [.tabStackFlick])
    }

    @Test(.timeLimit(.minutes(1)))
    func aSlowLiftOf32PointsOfFingerFinishes() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let travel = 32 + Self.lock
        lift(hosted, travel: travel)
        hosted.surface(.ended, sample(Self.lock - travel))
        try await settled(hosted)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[1])
        #expect(flicks(hosted.env).map(\.interaction) == [.tabStackFlick])
    }

    // Another switch mid-spring lands the flick on the end its spring is heading to, not where its travel sits.
    @Test(.timeLimit(.minutes(1)))
    func aReturningFlickLandedByTheSwitcherStaysOnItsTab() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        lift(hosted, travel: 50)
        hosted.surface(.ended, sample(Self.lock - 50, velocity: 800))
        #expect(hosted.flick.isMoving)
        #expect(-hosted.driver.flick!.offset.height > 30)
        hosted.env.showSwitcher(via: .tabStackTap)
        #expect(hosted.driver.flick == nil)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[2])
        #expect(!hosted.env.haptics.records.contains { $0.interaction == .tabStackFlick })
    }

    @Test(.timeLimit(.minutes(1)))
    func aFinishingFlickLandedByANewTabSwitchesFirst() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        lift(hosted, travel: 8)
        hosted.surface(.ended, sample(Self.lock - 8, velocity: -1500))
        #expect(hosted.flick.isMoving)
        hosted.env.open(page("new"))
        #expect(hosted.driver.flick == nil)
        let records = hosted.env.haptics.records.map(\.interaction)
        #expect(records.filter { $0 == .tabStackFlick }.count == 1)
        #expect(hosted.env.browser.previousTabID == hosted.tabs[1])
    }

    // A touch anywhere during the finish holds both pages where drawn; its lift lands the flick.
    @Test(.timeLimit(.minutes(1)))
    func aTouchMidFinishCatchesWhereDrawn() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        lift(hosted, travel: 120)
        hosted.surface(.ended, sample(Self.lock - 120))
        step(hosted) { (hosted.driver.flick?.land ?? 0) > 0.3 }
        #expect(hosted.driver.flick!.land < 0.9)
        #expect(hosted.flick.isMoving)
        hosted.controller.caught(true)
        let held = hosted.driver.flick!
        let pages = (drawn(hosted, hosted.tabs[2]), drawn(hosted, hosted.tabs[1]))
        #expect(!hosted.driver.isAnimating)
        for _ in 0..<8 {
            hosted.driver.step(by: Theme.Latency.frame)
        }
        #expect(hosted.driver.flick! == held)
        #expect(drawn(hosted, hosted.tabs[2]) == pages.0 && drawn(hosted, hosted.tabs[1]) == pages.1)
        #expect(flicks(hosted.env).isEmpty)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[2])
        hosted.controller.caught(false)
        try await settled(hosted)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[1])
        #expect(flicks(hosted.env).map(\.interaction) == [.tabStackFlick])
    }

    // The tab stack picks a returning page up where it is drawn and lifts it on.
    @Test(.timeLimit(.minutes(1)))
    func theTabStackCatchesAReturnAndLiftsItOn() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        lift(hosted, travel: 15)
        hosted.surface(.ended, sample(Self.lock - 15))
        step(hosted) { -(hosted.driver.flick?.offset.height ?? -100) < 10 }
        #expect(hosted.flick.isMoving)
        hosted.surface(.began, sample(0))
        let held = hosted.driver.flick!.offset
        #expect(!hosted.driver.isAnimating)
        hosted.surface(.changed, sample(-40))
        #expect(hosted.driver.flick!.offset == CGSize(width: held.width, height: held.height - 40))
        hosted.surface(.ended, sample(-40))
        try await settled(hosted)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[1])
        #expect(flicks(hosted.env).map(\.interaction) == [.tabStackFlick])
    }

    // Held clock. The lock writes the flick once (its creation; the arm's first frame comes with the first stepped
    // frame), each move writes it once, the release's batch writes nothing until its first frame, and every frame
    // after that writes it at most once, the end frame's value-then-nil pair excepted. Mutant: today's land adds
    // fifteen writes in the release turn and five per frame.
    @Test(.timeLimit(.minutes(1)))
    func aWholeFlickWritesOncePerEventAndOncePerFrame() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let writes = Writes { _ = hosted.driver.flick }
        hosted.surface(.began, sample(0))
        hosted.surface(.changed, sample(Self.lock))
        #expect(writes.count == 1)
        hosted.driver.step(by: Theme.Latency.frame)
        #expect(writes.count == 2)
        for step in 1...40 {
            hosted.surface(.changed, sample(CGFloat(step), Self.lock - CGFloat(step) * 3))
        }
        #expect(writes.count == 42)
        hosted.surface(.ended, sample(40, Self.lock - 120))
        #expect(writes.count == 42)
        var (frames, over) = (0, 0)
        while hosted.driver.flick != nil, frames < 1200 {
            let before = writes.count
            hosted.driver.step(by: Theme.Latency.frame)
            frames += 1
            if hosted.driver.flick != nil, writes.count - before > 1 {
                over += 1
            }
        }
        #expect(over == 0 && frames > 10)
        #expect(hosted.driver.flick == nil)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[1])
    }

    // A swipe on the bar during a flick's landing lands the flick first and pages from the tab it landed on: the
    // bar's touch reaches the catcher first and holds the landing, the lock then finishes it (its haptic, the switch
    // at once) and the pair is built from the new active tab; the release pages on to its older neighbour with one
    // more switch. Mutant: today's takesSwipe refuses the swipe and the catcher restarts the landing.
    @Test(.timeLimit(.minutes(1)))
    func aSwipeDuringALandingFinishesTheFlickThenPages() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let (b, older) = (hosted.tabs[1], hosted.tabs[0])
        let controllers = Writes { _ = hosted.env.activeController }
        lift(hosted, travel: 120)
        hosted.surface(.ended, sample(Self.lock - 120))
        step(hosted) { (hosted.driver.flick?.land ?? 0) > 0.4 }
        #expect(hosted.driver.flick!.land < 0.9)
        hosted.controller.caught(true)
        let pager = hosted.env.pager!
        #expect(pager.takesSwipe)
        pager.swiped(.began, sample(Theme.Gesture.axisLockDistance, 0))
        #expect(hosted.env.browser.activeTabID == b)
        #expect(flicks(hosted.env).map(\.interaction) == [.tabStackFlick])
        #expect(hosted.driver.flick == nil)
        #expect(hosted.driver.pair?.originID == b)
        let width = hosted.window.bounds.width
        pager.swiped(.changed, sample(0.6 * width, 0))
        pager.swiped(.ended, sample(0.6 * width, 0))
        hosted.controller.caught(false)
        step(hosted) { !hosted.driver.isPaging && !hosted.driver.isAnimating }
        #expect(hosted.env.browser.activeTabID == older)
        let settles = hosted.env.haptics.records.filter { $0.interaction == .barSwipeSettle }
        #expect(settles.count == 1 && hosted.env.haptics.records.last?.interaction == .barSwipeSettle)
        #expect(controllers.count == 2)
    }

    // The toggle: a flick begun during a landing lands it first (its switch and haptic at once) and flicks back from
    // the tab just landed on, fresh from the stack, with one switch and one haptic per landing. The real order: the
    // stack's touch-down reaches the catcher first and holds the landing, the stack declines it, and the lock
    // finishes it. Mutant: today's begin rebuilds the same flick from the same tab and never switches.
    @Test(.timeLimit(.minutes(1)))
    func aSecondFlickDuringTheLandingTogglesBack() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let (a, b) = (hosted.tabs[2], hosted.tabs[1])
        let controllers = Writes { _ = hosted.env.activeController }
        lift(hosted, travel: 120)
        hosted.surface(.ended, sample(Self.lock - 120))
        step(hosted) { (hosted.driver.flick?.land ?? 0) > 0.3 }
        #expect(hosted.driver.flick!.land < 0.9)
        hosted.controller.caught(true)
        hosted.surface(.began, sample(0))
        hosted.surface(.changed, sample(Self.lock))
        #expect(hosted.env.browser.activeTabID == b)
        let flick = try #require(hosted.driver.flick)
        #expect(flick.from == b && flick.to == a && flick.offset == .zero)
        #expect(flicks(hosted.env).map(\.interaction) == [.tabStackFlick])
        #expect(abs(drawn(hosted, b).scale - 1) < 0.01)
        hosted.surface(.changed, sample(Self.lock - 120))
        hosted.surface(.ended, sample(Self.lock - 120))
        hosted.controller.caught(false)
        try await settled(hosted)
        #expect(hosted.env.browser.activeTabID == a)
        #expect(flicks(hosted.env).map(\.interaction) == [.tabStackFlick, .tabStackFlick])
        #expect(controllers.count == 2)
    }

    // A second flick begun after the landing's haptic has played plays no second one for that landing; its own
    // landing plays exactly one.
    @Test(.timeLimit(.minutes(1)))
    func aSecondFlickAfterTheLandingHapticPlaysNoSecondHaptic() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let (a, b) = (hosted.tabs[2], hosted.tabs[1])
        lift(hosted, travel: 120)
        hosted.surface(.ended, sample(Self.lock - 120))
        step(hosted) { (hosted.driver.flick?.land ?? 1) > 0.95 }
        try #require(hosted.driver.flick != nil)
        #expect(flicks(hosted.env).map(\.interaction) == [.tabStackFlick])
        hosted.controller.caught(true)
        hosted.surface(.began, sample(0))
        hosted.surface(.changed, sample(Self.lock))
        #expect(hosted.env.browser.activeTabID == b)
        #expect(flicks(hosted.env).map(\.interaction) == [.tabStackFlick])
        #expect(hosted.driver.flick?.from == b && hosted.driver.flick?.to == a)
        hosted.surface(.changed, sample(Self.lock - 120))
        hosted.surface(.ended, sample(Self.lock - 120))
        hosted.controller.caught(false)
        try await settled(hosted)
        #expect(hosted.env.browser.activeTabID == a)
        #expect(flicks(hosted.env).map(\.interaction) == [.tabStackFlick, .tabStackFlick])
    }

    // The catcher alone, with no stack move, still lands a caught landing: one switch, one haptic.
    @Test(.timeLimit(.minutes(1)))
    func theCatcherAloneStillLandsAFlick() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let controllers = Writes { _ = hosted.env.activeController }
        lift(hosted, travel: 120)
        hosted.surface(.ended, sample(Self.lock - 120))
        step(hosted) { (hosted.driver.flick?.land ?? 0) > 0.3 }
        hosted.controller.caught(true)
        hosted.controller.caught(false)
        try await settled(hosted)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[1])
        #expect(flicks(hosted.env).map(\.interaction) == [.tabStackFlick])
        #expect(controllers.count == 1)
    }

    // The page left is captured on the bar touch's first move (TabPager.prepare), not at the lock or the switch: a
    // pull records no capture, its landing adds none, a prepare during the landing nothing, and a prepare at rest
    // captures the active page once. Mutant: today's begin and flickedTo each capture.
    @Test(.timeLimit(.minutes(1)))
    func aPullCapturesNothingAtTheLockAndItsLandingAddsNone() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        var captures: [UUID] = []
        hosted.env.onCaptureRequested = { captures.append($0) }
        lift(hosted, travel: 120)
        #expect(captures.isEmpty)
        hosted.surface(.ended, sample(Self.lock - 120))
        step(hosted) { (hosted.driver.flick?.land ?? 0) > 0.3 }
        hosted.env.pager!.prepare()
        #expect(captures.isEmpty)
        try await settled(hosted)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[1] && captures.isEmpty)
        hosted.env.pager!.prepare()
        #expect(captures == [hosted.tabs[1]])
    }

    private static func livePage(in view: UIView) -> WebPageView.Container? {
        if let page = view as? WebPageView.Container, page.window != nil, page.hosted != nil {
            return page
        }
        return view.subviews.lazy.compactMap { livePage(in: $0) }.first
    }

    // The live page takes no touch from the lock and takes them again once the flick ends, each after SwiftUI's
    // next update of the flick's ids, which change once per flick.
    @Test(.timeLimit(.minutes(1)))
    func theLivePageTakesTouchesAgainOnTheFlicksEndFrame() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let page = try #require(Self.livePage(in: hosted.controller.view))
        #expect(page.isUserInteractionEnabled)
        lift(hosted, travel: 120)
        #expect(hosted.driver.flickIDs == [hosted.tabs[2], hosted.tabs[1]])
        try await waitUntil { !page.isUserInteractionEnabled }
        hosted.surface(.ended, sample(Self.lock - 120))
        try await settled(hosted)
        #expect(hosted.driver.flickIDs.isEmpty && hosted.env.browser.activeTabID == hosted.tabs[1])
        try await waitUntil {
            let rested = Self.livePage(in: hosted.controller.view)
            return rested?.hosted === hosted.env.activeController?.webView && rested?.isUserInteractionEnabled == true
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aTapStillOpensTheSwitcher() async throws {
        let hosted = try await hosted(sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        hosted.surface(.began, sample(0))
        hosted.surface(.changed, sample(-3))
        #expect(hosted.driver.flick == nil)
        hosted.surface(.ended, DragSample(
            startLocation: CGPoint(x: 46, y: 20), location: CGPoint(x: 46, y: 17),
            translation: CGSize(width: 0, height: -3), velocity: .zero, time: Date()))
        step(hosted) { hosted.driver.progress == 1 && !hosted.driver.isAnimating }
        #expect(flicks(hosted.env).map(\.interaction) == [.tabStackTap])
    }
}

@MainActor private final class Seen {
    var values: [Bool] = []
}
