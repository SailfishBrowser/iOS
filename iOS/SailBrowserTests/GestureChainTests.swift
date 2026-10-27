import SwiftUI
import Testing
import UIKit
@testable import SailBrowser

// Chained gestures: a swipe begun inside a flick's landing, a flick inside a swipe's settle, a cancel mid-drag,
// the "+" during a settle. Every chain runs on the deck's held clock, stepped a frame at a time.
@MainActor @Suite(.serialized)
struct GestureChainTests {
    private struct Hosted {
        let env: AppEnvironment
        let window: UIWindow
        let controller: BehindController
        let bar: BarSlideView
        let pager: TabPager
        let flick: TabStackFlick
        let stack: (DragPhase, DragSample) -> Void
        let tabs: [UUID]

        var driver: DeckDriver { env.ui.deck }
    }

    private static let lock = -(Theme.Gesture.axisLockDistance + 2)

    // Opens `count` tabs in order, shows `active` (the last opened when nil) and holds the deck's clock.
    private func hosted(tabs count: Int = 3, active: Int? = nil) async throws -> Hosted {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let env = makeEnvironment()
        for index in 0..<count {
            env.open(page("\(index)"))
        }
        let tabs = env.browser.tabs.map(\.id)
        let controller = BehindController(env: env)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        try await waitUntil {
            env.pager != nil && env.flick != nil && env.debugSurfaces[.tabStack] != nil
                && env.debugActions[.plusTap] != nil && Self.bar(in: controller.view) != nil
        }
        if let active {
            env.showTab(tabs[active], via: .deckCardTap)
            try await waitUntil { env.activeController?.tabID == tabs[active] && env.ui.deck.position == CGFloat(active) }
        }
        try await waitUntil {
            Self.livePage(in: controller.view)?.hosted === env.activeController?.webView && !env.ui.deck.isAnimating
        }
        env.ui.deck.hold()
        return Hosted(
            env: env, window: window, controller: controller, bar: Self.bar(in: controller.view)!, pager: env.pager!,
            flick: env.flick!, stack: env.debugSurfaces[.tabStack]!, tabs: tabs)
    }

    private static func bar(in view: UIView) -> BarSlideView? {
        if let bar = view as? BarSlideView {
            return bar
        }
        return view.subviews.lazy.compactMap { bar(in: $0) }.first
    }

    private static func livePage(in view: UIView) -> WebPageView.Container? {
        if let page = view as? WebPageView.Container, page.window != nil, page.hosted != nil {
            return page
        }
        return view.subviews.lazy.compactMap { livePage(in: $0) }.first
    }

    private func barSample(_ dx: CGFloat, velocity: CGFloat = 0) -> DragSample {
        DragSample(
            startLocation: CGPoint(x: 200, y: 30), location: CGPoint(x: 200 + dx, y: 30),
            translation: CGSize(width: dx, height: 0), velocity: CGSize(width: velocity, height: 0), time: Date())
    }

    private func stackSample(_ dy: CGFloat, velocity: CGFloat = 0) -> DragSample {
        DragSample(
            startLocation: CGPoint(x: 46, y: 20), location: CGPoint(x: 46, y: 20 + dy),
            translation: CGSize(width: 0, height: dy), velocity: CGSize(width: 0, height: velocity),
            time: Date().addingTimeInterval(1))
    }

    // Locks the stack's touch with a slop's move, then lifts the page `travel` points past the lock.
    private func lift(_ hosted: Hosted, travel: CGFloat) {
        hosted.stack(.began, stackSample(0))
        hosted.stack(.changed, stackSample(Self.lock))
        hosted.stack(.changed, stackSample(Self.lock - travel))
    }

    private func step(_ hosted: Hosted, frames: Int) {
        for _ in 0..<frames {
            hosted.driver.step(by: Theme.Latency.frame)
        }
    }

    private func step(_ hosted: Hosted, until done: () -> Bool) {
        for _ in 0..<1200 where !done() {
            hosted.driver.step(by: Theme.Latency.frame)
        }
    }

    private func rest(_ hosted: Hosted) {
        step(hosted) { !hosted.driver.isPaging && hosted.driver.flick == nil && !hosted.driver.isAnimating }
    }

    private func flicks(_ env: AppEnvironment) -> [Interaction] {
        env.haptics.records.map(\.interaction).filter { $0 == .tabStackFlick || $0 == .tabStackTap }
    }

    private func settles(_ env: AppEnvironment) -> Int {
        env.haptics.records.count { $0.interaction == .barSwipeSettle }
    }

    private func drawn(_ hosted: Hosted, _ id: UUID) -> CardGeometry {
        let tabs = hosted.env.browser.tabs
        let active = tabs.firstIndex { $0.id == hosted.env.browser.activeTabID }!
        return hosted.driver.placement(
            index: tabs.firstIndex { $0.id == id }!, activeIndex: active, layout: hosted.pager.layout,
            header: EmptyView(), coverImage: nil, coverFill: .black, isUnrevealed: false, cover: CardCover(), tabID: id
        ).geometry
    }

    // Case 1. A swipe begun inside a flick's landing lands the flick first: the store is on B at once with one haptic,
    // the pair is built around B, and the swipe pages on to B's older neighbour.
    @Test(.timeLimit(.minutes(1)))
    func aSwipeInsideAFlicksLandingSwitchesFirstAndPagesFromThatTab() async throws {
        let hosted = try await hosted()
        defer { hosted.window.isHidden = true }
        let (a, b, c) = (hosted.tabs[2], hosted.tabs[1], hosted.tabs[0])
        lift(hosted, travel: 120)
        hosted.stack(.ended, stackSample(Self.lock - 120))
        step(hosted) { (hosted.driver.flick?.land ?? 0) > 0.4 }
        let landing = try #require(hosted.driver.flick)
        #expect(landing.to == b && landing.land < 0.9)
        hosted.controller.caught(true)
        #expect(hosted.pager.takesSwipe)
        hosted.bar.swiped(.began, barSample(Theme.Gesture.axisLockDistance))
        #expect(hosted.env.browser.activeTabID == b && hosted.env.browser.previousTabID == a)
        #expect(flicks(hosted.env) == [.tabStackFlick])
        #expect(hosted.driver.flick == nil)
        let pair = try #require(hosted.driver.pair)
        #expect(pair.originID == b && pair.older == c && pair.newer == a)
        let width = hosted.window.bounds.width
        hosted.bar.swiped(.changed, barSample(0.6 * width))
        hosted.bar.swiped(.ended, barSample(0.6 * width))
        hosted.controller.caught(false)
        rest(hosted)
        #expect(hosted.env.browser.activeTabID == c && hosted.env.browser.previousTabID == b)
        #expect(settles(hosted.env) == 1 && flicks(hosted.env) == [.tabStackFlick])
    }

    // Case 2. A flick begun inside a swipe's settle lands the swipe first, with one switch, then leaves B toward A,
    // the tab just left; past the line it toggles back to A.
    @Test(.timeLimit(.minutes(1)))
    func aFlickInsideASwipesSettleLandsTheSwipeFirstAndTogglesBack() async throws {
        let hosted = try await hosted(active: 1)
        defer { hosted.window.isHidden = true }
        let (a, b) = (hosted.tabs[1], hosted.tabs[2])
        let width = hosted.window.bounds.width
        hosted.bar.swiped(.began, barSample(-Theme.Gesture.axisLockDistance))
        hosted.bar.swiped(.changed, barSample(-0.6 * width))
        hosted.bar.swiped(.ended, barSample(-0.6 * width))
        step(hosted, frames: 12)
        #expect(hosted.pager.isMoving && hosted.env.browser.activeTabID == a)
        hosted.controller.caught(true)
        hosted.stack(.began, stackSample(0))
        hosted.stack(.changed, stackSample(Self.lock))
        #expect(hosted.env.browser.activeTabID == b && settles(hosted.env) == 1)
        #expect(!hosted.driver.isPaging && hosted.driver.position == 2)
        let flick = try #require(hosted.driver.flick)
        #expect(flick.from == b && flick.to == a)
        hosted.stack(.changed, stackSample(Self.lock - 120))
        hosted.stack(.ended, stackSample(Self.lock - 120))
        hosted.controller.caught(false)
        rest(hosted)
        #expect(hosted.env.browser.activeTabID == a && hosted.env.browser.previousTabID == b)
        #expect(settles(hosted.env) == 1 && flicks(hosted.env) == [.tabStackFlick])
    }

    // Case 3. A touch the system cancels mid-drag lands the swipe on the nearest tab at no speed, lets its presence
    // go, and the next swipe begins cleanly; a cancelled flick lifts at no speed where it is drawn.
    @Test(.timeLimit(.minutes(1)))
    func aSystemCancelMidDragSettlesWhereItIsAndTheNextTouchIsTaken() async throws {
        let hosted = try await hosted(active: 1)
        defer { hosted.window.isHidden = true }
        let (a, b) = (hosted.tabs[1], hosted.tabs[2])
        let width = hosted.window.bounds.width
        hosted.bar.swiped(.began, barSample(-Theme.Gesture.axisLockDistance))
        hosted.bar.swiped(.changed, barSample(-0.3 * width))
        #expect(hosted.pager.presence != nil && hosted.pager.isSwiping)
        hosted.bar.swiped(.cancelled, barSample(-0.3 * width, velocity: -3000))
        #expect(hosted.pager.presence == nil && !hosted.pager.isSwiping)
        rest(hosted)
        #expect(!hosted.driver.isPaging && hosted.driver.pair == nil && hosted.driver.position == 1)
        #expect(hosted.env.browser.activeTabID == a && settles(hosted.env) == 0)
        #expect(hosted.pager.takesSwipe)
        hosted.bar.swiped(.began, barSample(-Theme.Gesture.axisLockDistance))
        #expect(hosted.driver.pair?.originID == a)
        hosted.bar.swiped(.changed, barSample(-0.6 * width))
        hosted.bar.swiped(.cancelled, barSample(-0.6 * width, velocity: 3000))
        rest(hosted)
        #expect(hosted.env.browser.activeTabID == b && settles(hosted.env) == 1 && !hosted.driver.isPaging)
        lift(hosted, travel: 120)
        hosted.stack(.cancelled, stackSample(Self.lock - 120, velocity: 3000))
        #expect(hosted.flick.presence == nil && !hosted.flick.isDragging)
        rest(hosted)
        #expect(hosted.env.browser.activeTabID == a && flicks(hosted.env) == [.tabStackFlick])
        lift(hosted, travel: 10)
        hosted.stack(.cancelled, stackSample(Self.lock - 10))
        rest(hosted)
        #expect(hosted.env.browser.activeTabID == a && hosted.driver.flick == nil && hosted.pager.takesSwipe)
    }

    // Case 4. The app goes inactive mid-gesture and UIKit cancels the touch: nothing stays paging or flicking, and
    // both the swipe and the tab stack take the next touch.
    @Test(.timeLimit(.minutes(1)))
    func goingInactiveMidGestureLeavesTheNextTouchFree() async throws {
        let hosted = try await hosted(active: 1)
        defer { hosted.window.isHidden = true }
        let (a, b) = (hosted.tabs[1], hosted.tabs[2])
        let width = hosted.window.bounds.width
        hosted.bar.swiped(.began, barSample(-Theme.Gesture.axisLockDistance))
        hosted.bar.swiped(.changed, barSample(-0.3 * width))
        hosted.env.sceneWillResignActive()
        hosted.bar.swiped(.cancelled, barSample(-0.3 * width))
        hosted.env.sceneDidBecomeActive()
        rest(hosted)
        #expect(!hosted.driver.isPaging && hosted.pager.presence == nil && hosted.pager.takesSwipe)
        #expect(hosted.env.browser.activeTabID == a)
        lift(hosted, travel: 120)
        #expect(hosted.flick.isDragging && hosted.driver.flick?.to == b)
        hosted.stack(.ended, stackSample(Self.lock - 120))
        rest(hosted)
        #expect(hosted.env.browser.activeTabID == b && flicks(hosted.env) == [.tabStackFlick])
        lift(hosted, travel: 120)
        hosted.env.sceneWillResignActive()
        hosted.stack(.cancelled, stackSample(Self.lock - 120))
        hosted.env.sceneDidBecomeActive()
        rest(hosted)
        #expect(hosted.env.browser.activeTabID == a && hosted.driver.flick == nil && hosted.pager.takesSwipe)
        hosted.bar.swiped(.began, barSample(-Theme.Gesture.axisLockDistance))
        #expect(hosted.driver.pair?.originID == a && hosted.pager.isSwiping)
        hosted.bar.swiped(.ended, barSample(-Theme.Gesture.axisLockDistance))
        rest(hosted)
        #expect(hosted.env.browser.activeTabID == a && !hosted.driver.isPaging)
    }

    // Case 5. One tab alone: a swipe has no neighbour, so it bands and returns with no tick, no arm and no switch; a
    // flick has no previous tab and does nothing; a tap still opens the switcher.
    @Test(.timeLimit(.minutes(1)))
    func oneTabAloneBandsTheSwipeIgnoresTheFlickAndStillOpensTheSwitcherOnATap() async throws {
        let hosted = try await hosted(tabs: 1)
        defer { hosted.window.isHidden = true }
        let only = hosted.tabs[0]
        for direction: CGFloat in [1, -1] {
            hosted.bar.swiped(.began, barSample(direction * Theme.Gesture.axisLockDistance))
            hosted.bar.swiped(.changed, barSample(direction * 250))
            let pair = try #require(hosted.driver.pair)
            #expect(pair.older == nil && pair.newer == nil && pair.arm == 0 && !hosted.driver.isAnimating)
            #expect(direction * hosted.driver.position < -0.2)
            hosted.bar.swiped(.ended, barSample(direction * 250, velocity: direction * 3000))
            rest(hosted)
            #expect(hosted.driver.position == 0 && hosted.driver.pair == nil)
        }
        #expect(settles(hosted.env) == 0)
        #expect(hosted.env.haptics.records.count { $0.interaction == .barSwipeTick } == 0)
        #expect(hosted.env.browser.activeTabID == only && hosted.env.browser.previousTabID == nil)
        lift(hosted, travel: 120)
        #expect(hosted.driver.flick == nil && !hosted.flick.isDragging)
        hosted.stack(.ended, stackSample(Self.lock - 120, velocity: -1500))
        rest(hosted)
        #expect(hosted.env.browser.activeTabID == only && flicks(hosted.env).isEmpty)
        hosted.stack(.began, stackSample(0))
        hosted.stack(
            .ended,
            DragSample(
                startLocation: CGPoint(x: 46, y: 20), location: CGPoint(x: 46, y: 17),
                translation: CGSize(width: 0, height: -3), velocity: .zero, time: Date()))
        step(hosted) { hosted.driver.progress == 1 && !hosted.driver.isAnimating }
        #expect(hosted.env.ui.deckProgress == 1 && flicks(hosted.env) == [.tabStackTap])
    }

    // Case 6. The "+" during a swipe's settle lands the swipe first, so search opens over the tab the swipe was going
    // to: the store is on it before the overlay changes, and no landing runs under the sheet. Mutant: today's open
    // leaves the pager springing, and the sheet rises over the page being left.
    @Test(.timeLimit(.minutes(1)))
    func thePlusLandsAMovingSwipeBeforeSearchOpens() async throws {
        let hosted = try await hosted(active: 1)
        defer { hosted.window.isHidden = true }
        let (a, b) = (hosted.tabs[1], hosted.tabs[2])
        let width = hosted.window.bounds.width
        let plus = try #require(hosted.env.debugActions[.plusTap])
        hosted.bar.swiped(.began, barSample(-Theme.Gesture.axisLockDistance))
        hosted.bar.swiped(.changed, barSample(-0.6 * width))
        hosted.bar.swiped(.ended, barSample(-0.6 * width))
        step(hosted, frames: 12)
        #expect(hosted.pager.isMoving && hosted.env.browser.activeTabID == a)
        let activeAtOpen = Seen()
        withObservationTracking { _ = hosted.env.ui.overlay } onChange: {
            MainActor.assumeIsolated { activeAtOpen.values.append(hosted.env.browser.activeTabID) }
        }
        plus()
        #expect(hosted.env.ui.overlay == .search && activeAtOpen.values == [b])
        #expect(hosted.env.browser.activeTabID == b && settles(hosted.env) == 1)
        #expect(!hosted.driver.isPaging && hosted.driver.position == 2)
        step(hosted, frames: 60)
        #expect(settles(hosted.env) == 1 && hosted.env.browser.activeTabID == b)
    }

    // Case 6, the flick: the "+" during a flick's landing lands it first, its haptic and switch at once.
    @Test(.timeLimit(.minutes(1)))
    func thePlusLandsAMovingFlickBeforeSearchOpens() async throws {
        let hosted = try await hosted()
        defer { hosted.window.isHidden = true }
        let (a, b) = (hosted.tabs[2], hosted.tabs[1])
        let plus = try #require(hosted.env.debugActions[.plusTap])
        lift(hosted, travel: 120)
        hosted.stack(.ended, stackSample(Self.lock - 120))
        step(hosted) { (hosted.driver.flick?.land ?? 0) > 0.3 }
        #expect(hosted.flick.isMoving && hosted.env.browser.activeTabID == a)
        let activeAtOpen = Seen()
        withObservationTracking { _ = hosted.env.ui.overlay } onChange: {
            MainActor.assumeIsolated { activeAtOpen.values.append(hosted.env.browser.activeTabID) }
        }
        plus()
        #expect(hosted.env.ui.overlay == .search && activeAtOpen.values == [b])
        #expect(hosted.driver.flick == nil && flicks(hosted.env) == [.tabStackFlick])
        #expect(hosted.env.browser.activeTabID == b && hosted.env.browser.previousTabID == a)
    }

    // Case 7. Flick, flick inside the landing: one switch to B, then a flick back to A fresh from the stack. The
    // flick's target runs B, A and never B again, and B's landing only ever goes on: the first card never springs back.
    @Test(.timeLimit(.minutes(1)))
    func aFlickInsideAFlicksLandingTogglesBackWithNoSnapBack() async throws {
        let hosted = try await hosted()
        defer { hosted.window.isHidden = true }
        let (a, b) = (hosted.tabs[2], hosted.tabs[1])
        var targets: [UUID?] = []
        func sample() {
            let to = hosted.driver.flick?.to
            if targets.isEmpty || targets.last! != to {
                targets.append(to)
            }
        }
        lift(hosted, travel: 120)
        sample()
        hosted.stack(.ended, stackSample(Self.lock - 120))
        var lands: [CGFloat] = []
        step(hosted) {
            sample()
            lands.append(hosted.driver.flick?.land ?? 1)
            return lands.last! > 0.3
        }
        hosted.controller.caught(true)
        hosted.stack(.began, stackSample(0))
        sample()
        hosted.stack(.changed, stackSample(Self.lock))
        sample()
        #expect(hosted.env.browser.activeTabID == b && hosted.driver.flick?.to == a)
        hosted.stack(.changed, stackSample(Self.lock - 120))
        hosted.stack(.ended, stackSample(Self.lock - 120))
        hosted.controller.caught(false)
        step(hosted) {
            sample()
            return hosted.driver.flick == nil && !hosted.driver.isAnimating
        }
        #expect(targets == [b, a, nil])
        #expect(zip(lands, lands.dropFirst()).allSatisfy { $1 >= $0 })
        #expect(hosted.env.browser.activeTabID == a && flicks(hosted.env) == [.tabStackFlick, .tabStackFlick])
    }

    // Case 8. A catch three frames before the swipe's visible rest, let go at once: the store switches once, within
    // twelve frames of the lift, and the landing card only ever closes on its rest by the rule's last step. The first
    // swipe measures the frames to rest; the second, the same gesture one tab on, is caught at that count less three.
    @Test(.timeLimit(.minutes(1)))
    func aCatchJustBeforeTheSwipesRestSwitchesOnceWithoutARestartedSpring() async throws {
        let hosted = try await hosted(tabs: 4, active: 0)
        defer { hosted.window.isHidden = true }
        let width = hosted.window.bounds.width
        func swipeOn() {
            hosted.bar.swiped(.began, barSample(-Theme.Gesture.axisLockDistance))
            hosted.bar.swiped(.changed, barSample(-0.6 * width))
            step(hosted, frames: 36)
            hosted.bar.swiped(.ended, barSample(-0.6 * width))
        }
        swipeOn()
        var frames = 0
        while hosted.env.browser.activeTabID == hosted.tabs[0] || hosted.pager.isMoving, frames < 240 {
            hosted.driver.step(by: Theme.Latency.frame)
            frames += 1
        }
        #expect(frames > 10 && frames < 240 && settles(hosted.env) == 1)
        step(hosted, frames: 10)
        swipeOn()
        step(hosted, frames: frames - 3)
        try #require(hosted.env.browser.activeTabID == hosted.tabs[1] && hosted.pager.isMoving)
        #expect(hosted.bar.router.gestureRecognizerShouldBegin(hosted.controller.catcher))
        hosted.controller.caught(true)
        hosted.controller.caught(false)
        let landing = hosted.tabs[2]
        var (lifted, steps) = (0, [CGFloat]())
        var edge = abs(drawn(hosted, landing).offset.width)
        while hosted.env.browser.activeTabID == hosted.tabs[1] || hosted.pager.isMoving, lifted < 30 {
            hosted.driver.step(by: Theme.Latency.frame)
            lifted += 1
            let next = abs(drawn(hosted, landing).offset.width)
            steps.append(edge - next)
            edge = next
        }
        let lastStep = Theme.Gesture.landedPoints + Theme.Gesture.landedSpeed / Theme.Latency.frameRate
        #expect(lifted <= 12)
        #expect(steps.allSatisfy { $0 >= 0 && $0 <= lastStep })
        #expect(hosted.env.browser.activeTabID == landing && settles(hosted.env) == 2)
        step(hosted, frames: 30)
        #expect(settles(hosted.env) == 2 && hosted.driver.position == 2 && !hosted.driver.isPaging)
        #expect(drawn(hosted, landing).scale == 1 && drawn(hosted, landing).offset == .zero)
    }
}

@MainActor private final class Seen {
    var values: [UUID?] = []
}

// The switcher's deck: a release's snapshot trim and a thrown card's ghost.
@MainActor @Suite(.serialized)
struct DeckChainTests {
    private struct Deck {
        let env: AppEnvironment
        let window: UIWindow
        let surface: (DragPhase, DragSample) -> Void
        let layout: CardLayout
        let tabs: [UUID]

        var driver: DeckDriver { env.ui.deck }
    }

    // Opens `count` tabs in order, then the switcher over the last one.
    private func deck(tabs count: Int) async throws -> Deck {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let env = makeEnvironment()
        for index in 0..<count {
            env.open(page("\(index)"))
        }
        let controller = BehindController(env: env)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        env.ui.close(animated: false, deckTo: 1)
        controller.view.layoutIfNeeded()
        try await waitUntil { env.pager != nil && env.debugSurfaces[.deck] != nil && env.debugDeckThrow != nil }
        let layout = env.pager!.layout
        try await waitUntil {
            env.ui.deck.position == layout.openPosition(activeIndex: count - 1) && !env.ui.deck.isAnimating
        }
        return Deck(
            env: env, window: window, surface: env.debugSurfaces[.deck]!, layout: layout, tabs: env.browser.tabs.map(\.id))
    }

    private func sample(_ deck: Deck, dx: CGFloat, velocity: CGFloat = 0) -> DragSample {
        let centre = deck.layout.slotCenter
        return DragSample(
            startLocation: centre, location: CGPoint(x: centre.x + dx, y: centre.y),
            translation: CGSize(width: dx, height: 0), velocity: CGSize(width: velocity, height: 0), time: .now)
    }

    private func sample(_ deck: Deck, dy: CGFloat, velocity: CGFloat = 0) -> DragSample {
        let centre = deck.layout.slotCenter
        return DragSample(
            startLocation: centre, location: CGPoint(x: centre.x, y: centre.y + dy),
            translation: CGSize(width: 0, height: dy), velocity: CGSize(width: 0, height: velocity), time: .now)
    }

    // Case 9. A release keeps the picture of every card the snap draws: the span runs from the release to the target,
    // wider than the target's own window, so the card at target - 4 is drawn through the snap. Mutant: a trim to the
    // target's window alone blanks that card on screen.
    @Test(.timeLimit(.minutes(1)))
    func aDeckReleaseKeepsThePicturesOfEveryCardTheSnapDraws() async throws {
        let deck = try await deck(tabs: 9)
        defer { deck.window.isHidden = true }
        for id in deck.tabs {
            deck.env.snapshots.thumbnail(for: id).image = UIImage()
        }
        #expect(deck.driver.position == 7)
        // The axis lock subtracts the sample that locks, so the travel is the second sample's beyond the first.
        let lock = Theme.Gesture.deckAxisLock + 2
        let travel = 0.3 * deck.layout.stride
        deck.surface(.began, sample(deck, dx: 0))
        deck.surface(.changed, sample(deck, dx: -lock))
        deck.surface(.changed, sample(deck, dx: -travel))
        deck.surface(.ended, sample(deck, dx: -travel, velocity: -3000))
        let motion = try #require(deck.driver.motion)
        #expect(motion.to == 8 && abs(motion.from - (7 + (travel - lock) / deck.layout.stride)) < 1e-6)
        #expect(deck.driver.span.clamped(to: 0...8) == 4...8)
        let pictured = deck.tabs.indices.filter { deck.env.snapshots.thumbnail(for: deck.tabs[$0]).image != nil }
        #expect(pictured == [4, 5, 6, 7, 8])
    }

    // Case 10. A thrown card archived while it still coasts is drawn from a ghost; the ghost, and the full picture it
    // holds, go as soon as the fly-off ends, not at the next archive. Mutant: the ghosts pruned before the next append
    // only, so the last one's bitmap stays until then.
    @Test(.timeLimit(.minutes(1)))
    func aGhostAndItsPictureGoWhenTheFlyOffEnds() async throws {
        let deck = try await deck(tabs: 3)
        defer { deck.window.isHidden = true }
        let thrown = deck.tabs[Int(deck.driver.position.rounded())]
        weak var picture: Thumbnail? = deck.env.snapshots.thumbnail(for: thrown)
        let throwCard = try #require(deck.env.debugDeckThrow)
        throwCard()
        #expect(deck.driver.departing[thrown] != nil && deck.env.browser.tabs.count == 3)
        // A grab, a second throw or the scene resigning commits the archive while the card still coasts.
        deck.driver.finishDeparture()
        #expect(deck.driver.isFlying(thrown) && deck.env.browser.tabs.count == 2)
        #expect(picture != nil)
        try await waitUntil { deck.driver.departing.isEmpty && !deck.driver.isAnimating }
        try await waitUntil { picture == nil }
    }

    // Case 10, in a burst. Two throws faster than a fly-off: the first card's ghost and picture go as its own fly-off
    // ends while the second still flies. A hard flick coasts off sooner than the debug throw's floor speed. The held
    // clock steps one frame per display tick, as the deck's own clock does: a run of departing writes inside one turn
    // leaves the ghosts' change unrun until the next write. Mutant: ghosts cleared only once nothing departs, so every
    // bitmap of a burst stays until its last card is gone.
    @Test(.timeLimit(.minutes(1)))
    func aBurstOfThrowsKeepsOnlyTheGhostsStillFlying() async throws {
        let deck = try await deck(tabs: 3)
        defer { deck.window.isHidden = true }
        let throwCard = try #require(deck.env.debugDeckThrow)
        deck.driver.hold()
        let fast = deck.tabs[Int(deck.driver.position.rounded())]
        weak var fastPicture: Thumbnail? = deck.env.snapshots.thumbnail(for: fast)
        let lock = Theme.Gesture.deckAxisLock + 2
        deck.surface(.began, sample(deck, dy: 0))
        deck.surface(.changed, sample(deck, dy: -lock))
        deck.surface(.ended, sample(deck, dy: -lock - 40, velocity: -8000))
        #expect(deck.driver.departing[fast] != nil)
        // The second throw commits the first archive; its own is committed by the grab below.
        throwCard()
        let slow = try #require(deck.driver.departing.keys.first { $0 != fast })
        weak var slowPicture: Thumbnail? = deck.env.snapshots.thumbnail(for: slow)
        deck.driver.finishDeparture()
        #expect(deck.env.browser.tabs.count == 1 && deck.driver.isFlying(fast) && deck.driver.isFlying(slow))
        for _ in 0..<1200 where deck.driver.departing[fast] != nil {
            await InteractionProbe.nextFrame()
            deck.driver.step(by: Theme.Latency.frame)
        }
        #expect(Set(deck.driver.departing.keys) == [slow])
        try await waitUntil { fastPicture == nil }
        #expect(slowPicture != nil && deck.driver.departing[slow] != nil)
    }
}
