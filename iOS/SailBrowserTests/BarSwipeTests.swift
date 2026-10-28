import SwiftUI
import Testing
import UIKit
@testable import SailBrowser

struct BarSwipeTests {
    private let stride: CGFloat = 414
    private var band: CGFloat { Theme.Gesture.detentHysteresis / 2 / stride }

    private func target(_ position: CGFloat, from start: Int, velocity: CGFloat = 0, count: Int = 3) -> Int {
        BarSwipe.release(position: position, start: start, velocity: velocity, stride: stride, count: count).index
    }

    // Undecided under eight points of radial travel; at it, the swipe's within 35 degrees of horizontal (9 pt at 34
    // degrees is, at 36 is not), else vertical: a 45 degree pull and a flick's path are vertical. A steep start that
    // flattens locks to the swipe on the later sample. Mutant: the lead rule returns nil for (7.8, -4.5) and (10, 10).
    @Test func theLockIsRadialThenByAngle() {
        func lock(_ dx: CGFloat, _ dy: CGFloat) -> BarSwipe.Axis? {
            BarSwipe.lock(CGSize(width: dx, height: dy))
        }
        #expect(lock(7.9, 0) == nil)
        #expect(lock(3, 1) == nil)
        #expect(lock(8, 0) == .horizontal)
        #expect(lock(0, -8) == .vertical)
        #expect(lock(7.46, 5.03) == .horizontal)
        #expect(lock(7.28, 5.29) == .vertical)
        #expect(lock(7.8, -4.5) == .horizontal)
        #expect(lock(4.4, -8) == .vertical)
        #expect(lock(5.66, -5.66) == .vertical)
        #expect(lock(-14, 3) == .horizontal)
        #expect(lock(10, 10) == .vertical)
        #expect(lock(0, -8) == .vertical && lock(20, -10) == .horizontal)
    }

    @Test func aDragLeftMovesTowardTheNextTabOneToOne() {
        #expect(abs(BarSwipe.position(start: 1, translation: -0.6 * stride, stride: stride, count: 3) - 1.6) < 1e-9)
        #expect(abs(BarSwipe.position(start: 1, translation: 0.3 * stride, stride: stride, count: 3) - 0.7) < 1e-9)
    }

    @Test func pastEitherEndTheDragRubberBands() {
        let stretch = Theme.Gesture.barSwipeStretch
        let first = BarSwipe.position(start: 0, translation: 0.5 * stride, stride: stride, count: 3)
        #expect(first < 0 && first > -stretch)
        #expect(first > -0.5 * Theme.Gesture.rubberBandCoefficient - 1e-9)
        let last = BarSwipe.position(start: 2, translation: -2 * stride, stride: stride, count: 3)
        #expect(last > 2 && last < 2 + stretch)
        // A drag that starts inside the band, a catch of a springing return, continues from where it is drawn.
        let caught = BarSwipe.position(start: last, translation: 0, stride: stride, count: 3)
        #expect(abs(caught - last) < 1e-9)
    }

    @Test func aSlowReleaseLandsOnWhicheverTabIsPastTheCommitFraction() {
        #expect(Theme.Gesture.barSwipeCommitFraction == 0.5)
        #expect(target(1.6, from: 1) == 2)
        #expect(target(1.4, from: 1) == 1)
        #expect(target(0.45, from: 1) == 0)
        #expect(target(0.55, from: 1) == 1)
    }

    @Test func aFastReleaseCommitsBeforeTheMidpoint() {
        let fast = Theme.Gesture.barSwipeFlickVelocity + 1
        #expect(target(1.15, from: 1, velocity: -fast) == 2)
        #expect(target(0.9, from: 1, velocity: fast) == 0)
        // Flicked back the other way, it returns.
        #expect(target(1.4, from: 1, velocity: fast) == 1)
        let slow = Theme.Gesture.barSwipeFlickVelocity - 1
        #expect(target(1.15, from: 1, velocity: -slow) == 1)
    }

    // However hard the flick, one swipe moves one tab.
    @Test func aFlickReachesAtMostOneTabAndStopsAtTheEnds() {
        #expect(target(1.3, from: 1, velocity: -6000, count: 8) == 2)
        #expect(target(0.7, from: 1, velocity: 6000, count: 8) == 0)
        #expect(target(1.3, from: 1, velocity: -6000, count: 8) == 1 + Theme.Gesture.barSwipeMaxTabs)
        #expect(target(2.1, from: 2, velocity: -6000) == 2)
        #expect(target(-0.1, from: 0, velocity: 6000) == 0)
    }

    @Test func theSpringCarriesTheFingersSpeedTowardTheTargetOnly() {
        let toward = BarSwipe.release(position: 1.6, start: 1, velocity: -800, stride: stride, count: 3)
        #expect(toward.index == 2)
        #expect(abs(toward.velocity - Double(800 / stride / 0.4)) < 1e-9)
        let away = BarSwipe.release(position: 1.6, start: 1, velocity: 100, stride: stride, count: 3)
        #expect(away.index == 2)
        #expect(away.velocity == 0)
    }

    @Test func theDetentTicksOncePerTabAtTheMidpointWithHysteresis() {
        var detent = PageDetent(leading: 1, count: 3, stride: stride)
        #expect(detent.update(1.45) == 0)
        #expect(detent.update(1.5 + band) == 1)
        #expect(detent.leading == 2)
        // A finger resting on the line cannot chatter.
        #expect(detent.update(1.5) == 0)
        #expect(detent.update(1.5 - band) == 1)
        #expect(detent.leading == 1)
        #expect(detent.update(0.5 - band) == 1)
        #expect(detent.leading == 0)
    }

    @Test func theDetentNeverTicksInTheBandPastAnEnd() {
        var last = PageDetent(leading: 2, count: 3, stride: stride)
        #expect(last.update(2.3) == 0)
        #expect(last.leading == 2)
        var first = PageDetent(leading: 0, count: 3, stride: stride)
        #expect(first.update(-0.4) == 0)
        #expect(first.leading == 0)
    }

    @Test func oneFrameAcrossTwoMidpointsCountsBoth() {
        var detent = PageDetent(leading: 0, count: 5, stride: stride)
        #expect(detent.update(2.4) == 2)
        #expect(detent.leading == 2)
    }

    private let screen = CGSize(width: 402, height: 874)
    private let safeTop: CGFloat = 62

    // The drawn card's edges: its centre, the width it shows, and its top and bottom below the clips.
    private func edges(_ t: CardTransform) -> (minX: CGFloat, maxX: CGFloat, top: CGFloat, bottom: CGFloat) {
        let centre = screen.width / 2 + t.offset.width
        let top = screen.height / 2 + t.offset.height - screen.height * t.scale / 2
        return (
            centre - screen.width * t.scale / 2, centre + screen.width * t.scale / 2, top + t.clipTop,
            top + t.clipHeight
        )
    }

    // The page slides at full size, with nothing beside it, until the drag arms.
    @Test func anUnarmedPageSlidesAtFullSize() {
        let layout = CardLayout(screen: screen)
        let t = layout.pairTransform(offset: 54 / layout.pageStride, fromStack: 0, arm: 0, safeTop: safeTop)
        #expect(abs(t.offset.width - 54) < 1e-9 && t.offset.height == 0)
        #expect(t.scale == 1 && t.clipTop == 0 && t.clipHeight == 874)
        #expect(t.corner == Theme.Metrics.displayCorner && t.dim == 0 && t.opacity == 1)
    }

    // Armed: equal cards at 0.9, side by side 32 pt apart, between the status bar and the bar.
    @Test func theArmedPairSitsSideBySideBetweenTheStatusBarAndTheBar() {
        let layout = CardLayout(screen: screen)
        let scale = Theme.Metrics.barSwipeCardScale
        #expect(abs(layout.pageStride - (scale * 402 + Theme.Metrics.barSwipeGap)) < 1e-9)
        let page = layout.pairTransform(offset: 0, fromStack: 0, arm: 1, safeTop: safeTop)
        let newer = layout.pairTransform(offset: 1, fromStack: 0, arm: 1, safeTop: safeTop)
        #expect(page.scale == scale && newer.scale == scale)
        #expect(abs(edges(page).top - (safeTop - Theme.Metrics.barSwipeCardTopInset)) < 1e-9)
        #expect(edges(page).bottom < 874 - Theme.Metrics.barTotalHeight)
        #expect(abs(edges(newer).minX - edges(page).maxX - Theme.Metrics.barSwipeGap) < 1e-9)
        #expect(page.corner == Theme.Metrics.barSwipeCardCorner && page.dim == 0)
        #expect(edges(newer).top == edges(page).top)
    }

    // The older tab's card comes out of the tab stack button, tilted, and goes back into it.
    @Test func theOlderCardComesOutOfTheTabStack() {
        let layout = CardLayout(screen: screen)
        let stack = layout.pairTransform(offset: -1, fromStack: 1, arm: 1, safeTop: safeTop)
        let e = edges(stack)
        let slot = layout.frontSlot
        #expect(abs((e.minX + e.maxX) / 2 - slot.x) < 1e-6)
        #expect(abs((e.top + e.bottom) / 2 - slot.y) < 1e-6)
        #expect(abs(e.maxX - e.minX - Theme.Metrics.tabStackThumbnailSize.width) < 1e-6)
        #expect(abs(e.bottom - e.top - Theme.Metrics.tabStackThumbnailSize.height) < 1e-6)
        #expect(stack.rotation == .degrees(Theme.Metrics.tabStackTilt))
        #expect(stack.opacity == 1)
        let out = layout.pairTransform(offset: -1, fromStack: 0, arm: 1, safeTop: safeTop)
        #expect(out.rotation == .zero && out.opacity == 1)
        #expect(abs(edges(out).maxX + Theme.Metrics.barSwipeGap - edges(layout.pairTransform(
            offset: 0, fromStack: 0, arm: 1, safeTop: safeTop)).minX) < 1e-9)
    }

    // The routing the swipe leaves to the tab stack: a wobble stays a tap that opens the deck; a horizontal drag is
    // the swipe's, and the button's own release reads it as no tap.
    @Test func aWobbleStaysATapOnTheTabStackAndAHorizontalDragDoesNot() {
        func sample(_ dx: CGFloat, _ dy: CGFloat) -> DragSample {
            DragSample(
                startLocation: .zero, location: CGPoint(x: dx, y: dy), translation: CGSize(width: dx, height: dy),
                velocity: .zero, time: Date())
        }
        #expect(BarSwipe.lock(CGSize(width: 3, height: 1)) == nil)
        #expect(TabStackButton.release(sample(3, 1), duration: 0.1, locked: false) == .tap)
        #expect(BarSwipe.lock(CGSize(width: 20, height: 0)) == .horizontal)
        #expect(TabStackButton.release(sample(20, 0), duration: 0.1, locked: false) == .none)
    }
}

struct DeckDriverPagingTests {
    private let start = ContinuousClock.now

    @Test func theDriverTicksAtEachCrossingAndEndsPagingWhenItSettles() {
        let driver = DeckDriver()
        var ticks: [CGFloat] = []
        driver.beginPaging(pair(origin: 0), detent: PageDetent(leading: 0, count: 4, stride: 400)) {
            ticks.append(driver.position)
        }
        #expect(driver.isPaging)
        driver.move(to: 0.4)
        #expect(ticks.isEmpty)
        driver.run(DeckMotion(from: 0.4, to: 2, shift: [:], velocity: 0, start: start, spring: DeckSnap.barSwipe))
        driver.releasePaging()
        for step in 1...240 {
            driver.apply(at: start + .milliseconds(step * 4))
        }
        #expect(ticks.count == 2)
        #expect(ticks[0] > 0.5 && ticks[0] < 1)
        #expect(ticks[1] > 1.5 && ticks[1] < 2)
        #expect(driver.position == 2)
        #expect(!driver.isPaging)
        #expect(!driver.isAnimating)
    }

    private func pair(origin: Int = 1) -> DeckDriver.PagePair {
        DeckDriver.PagePair(origin: origin, originID: UUID(), older: UUID(), newer: UUID(), safeTop: 62)
    }

    @Test func pagedPlacementDrawsOnlyThePairWhileBrowsing() {
        let layout = CardLayout(screen: CGSize(width: 402, height: 874))
        let driver = DeckDriver()
        let pair = pair()
        driver.jump(to: 1, shift: [:])
        driver.beginPaging(pair, detent: nil) {}
        driver.animatePair(arm: 1, start: start)
        for step in 1...120 {
            driver.apply(at: start + .milliseconds(step * 4))
        }
        #expect(driver.pair!.arm == 1)
        driver.move(to: 1.5)
        func drawn(_ index: Int, _ id: UUID) -> CardGeometry {
            driver.placement(
                index: index, activeIndex: 1, layout: layout, header: EmptyView(), coverImage: nil, coverFill: .black,
                isUnrevealed: false, cover: CardCover(), tabID: id
            ).geometry
        }
        #expect(abs(drawn(2, pair.newer!).offset.width - 0.5 * layout.pageStride) < 1e-9)
        #expect(drawn(2, pair.newer!).opacity == 1)
        #expect(abs(drawn(1, pair.originID).offset.width + 0.5 * layout.pageStride) < 1e-9)
        #expect(drawn(3, UUID()).opacity == 0)
    }

    // The pair's channels spring from where they are drawn, a hold stops them, and paging ends once a released pair
    // and its position have settled.
    @Test func thePairsChannelsHoldAndEndWithTheRelease() {
        let driver = DeckDriver()
        driver.jump(to: 1, shift: [:])
        driver.beginPaging(pair(), detent: nil) {}
        driver.animatePair(arm: 1, emerge: 1, start: start)
        driver.apply(at: start + .milliseconds(60))
        let held = driver.pair!
        #expect(held.arm > 0 && held.arm < 1 && held.emerge > 0)
        driver.holdPaging()
        driver.apply(at: start + .milliseconds(200))
        #expect(driver.pair! == held)
        #expect(driver.isPaging)
        let later = start + .milliseconds(300)
        driver.run(DeckMotion(from: 1, to: 0, shift: [:], velocity: 0, start: later, spring: DeckSnap.barSwipe))
        driver.animatePair(arm: 0, start: later)
        driver.releasePaging()
        for step in 1...200 {
            driver.apply(at: later + .milliseconds(step * 4))
        }
        #expect(!driver.isPaging && driver.pair == nil && !driver.isAnimating)
    }
}

// The bar's swipe pages the hosted deck. A sink on the real clock lets each tick play in its own frame.
@MainActor @Suite(.serialized)
struct BarSwipeHostTests {
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

    // Each page's load asks for its own snapshot a while after it finishes (AppEnvironment.pageFinished). Counts the
    // ones still to come, so a test that watches snapshot requests can start once they are in.
    @MainActor private final class LoadSnapshots {
        private var finished: Set<UUID> = []
        private var due: [UUID: Int] = [:]

        func finish(_ id: UUID) {
            finished.insert(id)
            due[id, default: 0] += 1
        }

        func request(_ id: UUID) {
            if due[id, default: 0] > 0 {
                due[id]! -= 1
            }
        }

        func areIn(for tabs: [UUID]) -> Bool {
            finished.isSuperset(of: tabs) && due.values.allSatisfy { $0 == 0 }
        }
    }

    private struct Hosted {
        let env: AppEnvironment
        let window: UIWindow
        let bar: BarSlideView
        let controller: BehindController
        let tabs: [UUID]
        let pager: TabPager
        let loadSnapshots: LoadSnapshots
    }

    private func hosted(tabs count: Int, active: Int, sink: ClockedSink) async throws -> Hosted {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let env = makeEnvironment(hapticSink: sink)
        for index in 0..<count {
            env.open(page("\(index)"))
        }
        let tabs = env.browser.tabs.map(\.id)
        // The loads finish on later turns, so every finish is seen.
        let loadSnapshots = LoadSnapshots()
        for id in tabs {
            let controller = env.pool.liveController(for: id)!
            let wired = controller.onFinish
            controller.onFinish = { url, title in
                loadSnapshots.finish(id)
                wired?(url, title)
            }
        }
        env.onCaptureRequested = { loadSnapshots.request($0) }
        let controller = BehindController(env: env)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        try await waitUntil { env.pager != nil && Self.bar(in: controller.view) != nil }
        // The tap's own request for the page it leaves is not a load's.
        env.onCaptureRequested = nil
        env.showTab(tabs[active], via: .deckCardTap)
        env.onCaptureRequested = { loadSnapshots.request($0) }
        try await waitUntil { env.activeController?.tabID == tabs[active] && Self.bar(in: controller.view) != nil }
        // The switch's zoom from the browser is a no-op that rests at once, so wait for SwiftUI's update of it: the
        // deck recentred on the tab and its live page in the window.
        try await waitUntil {
            env.pager!.driver.position == CGFloat(active)
                && Self.livePage(in: controller.view)?.hosted === env.activeController?.webView
        }
        try await waitUntil { !env.pager!.driver.isAnimating }
        return Hosted(
            env: env, window: window, bar: Self.bar(in: controller.view)!, controller: controller, tabs: tabs,
            pager: env.pager!, loadSnapshots: loadSnapshots)
    }

    private static func bar(in view: UIView) -> BarSlideView? {
        if let bar = view as? BarSlideView {
            return bar
        }
        return view.subviews.lazy.compactMap { bar(in: $0) }.first
    }

    private func sample(_ dx: CGFloat, velocity: CGFloat = 0) -> DragSample {
        DragSample(
            startLocation: CGPoint(x: 200, y: 30), location: CGPoint(x: 200 + dx, y: 30),
            translation: CGSize(width: dx, height: 0), velocity: CGSize(width: velocity, height: 0), time: Date())
    }

    // Drags in steps to `dx`, then releases at `velocity`.
    private func swipe(_ bar: BarSlideView, to dx: CGFloat, velocity: CGFloat) async throws {
        bar.swiped(.began, sample(0))
        for step in 1...10 {
            bar.swiped(.changed, sample(dx * CGFloat(step) / 10))
            try await Task.sleep(for: .milliseconds(8))
        }
        bar.swiped(.ended, sample(dx, velocity: velocity))
    }

    // Where the card for the tab at this index is drawn, as the deck would draw it now.
    private func drawn(_ hosted: Hosted, _ index: Int) -> CardGeometry {
        let tabs = hosted.env.browser.tabs
        let active = tabs.firstIndex { $0.id == hosted.env.browser.activeTabID }!
        return hosted.pager.driver.placement(
            index: index, activeIndex: active, layout: hosted.pager.layout, header: EmptyView(), coverImage: nil,
            coverFill: .black, isUnrevealed: false, cover: CardCover(), tabID: tabs[index].id
        ).geometry
    }

    private func pair(_ hosted: Hosted) -> DeckDriver.PagePair? {
        hosted.pager.driver.pair
    }

    private func ticks(_ env: AppEnvironment) -> [HapticRecord] {
        env.haptics.records.filter { $0.interaction == .barSwipeTick && $0.played }
    }

    private func settles(_ env: AppEnvironment) -> Int {
        env.haptics.records.count { $0.interaction == .barSwipeSettle }
    }

    // Collects each distinct active tab the store shows until the paging rests.
    private func activeTabs(until hosted: Hosted) async throws -> [UUID?] {
        var seen = [hosted.env.browser.activeTabID]
        try await waitUntil(every: .milliseconds(2)) {
            if seen.last != hosted.env.browser.activeTabID {
                seen.append(hosted.env.browser.activeTabID)
            }
            return !hosted.pager.driver.isPaging && !hosted.pager.driver.isAnimating
        }
        return seen
    }

    // The deck builds its pager each time it appears, while the shared driver runs on. A swipe springing then still
    // lands on its tab, and the replaced pager's landing never runs on it once it is gone.
    @Test(.timeLimit(.minutes(1)))
    func aSwipeSpringingWhenTheDeckReappearsStillLandsOnItsTab() async throws {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let env = makeEnvironment(hapticSink: ClockedSink())
        for index in 0..<3 {
            env.open(page("\(index)"))
        }
        let tabs = env.browser.tabs.map(\.id)
        let controller = BehindController(env: env)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        try await waitUntil { env.pager != nil && Self.bar(in: controller.view) != nil }
        env.showTab(tabs[1], via: .deckCardTap)
        try await waitUntil { env.activeController?.tabID == tabs[1] && Self.bar(in: controller.view) != nil }
        let driver = env.pager!.driver
        try await waitUntil { !driver.isAnimating }

        try await swipe(Self.bar(in: controller.view)!, to: -0.6 * window.bounds.width, velocity: 0)
        #expect(driver.motion != nil)
        weak var replaced = env.pager
        // A new host builds a new deck view on the same environment, whose driver runs on.
        let rehosted = BehindController(env: env)
        window.rootViewController = rehosted
        rehosted.view.layoutIfNeeded()
        let rebuilt = (try? await waitUntil { replaced == nil }) != nil
        #expect(rebuilt, "the deck did not rebuild its pager")
        let rested = (try? await waitUntil { !driver.isPaging && !driver.isAnimating }) != nil
        #expect(rested, "the swipe never came to rest")
        #expect(env.browser.activeTabID == tabs[2])
        #expect(driver.position == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func aSwipeOfMostOfAWidthFromTheMiddleTabLandsOnTheNextWithOneTick() async throws {
        let sink = ClockedSink()
        let hosted = try await hosted(tabs: 3, active: 1, sink: sink)
        defer { hosted.window.isHidden = true }
        let tickedBefore = ticks(hosted.env).count
        let width = hosted.window.bounds.width
        try await swipe(hosted.bar, to: -0.6 * width, velocity: 0)
        let seen = try await activeTabs(until: hosted)
        #expect(seen == [hosted.tabs[1], hosted.tabs[2]])
        #expect(settles(hosted.env) == 1)
        #expect(ticks(hosted.env).count - tickedBefore == 1)
        #expect(hosted.env.activeController?.tabID == hosted.tabs[2])
        #expect(hosted.pager.driver.position == 2)
        #expect(hosted.env.ui.deckProgress == 0)
        let landed = drawn(hosted, 2)
        #expect(landed.scale == 1 && landed.offset == .zero && landed.clipHeight == hosted.window.bounds.height)
    }

    // The pair arms as the pan locks, even with the page still: both
    // pages go to 0.9 on the arm's spring while the page slides at the finger, and the older card comes out of the tab
    // stack.
    @Test(.timeLimit(.minutes(1)))
    func theSwipeArmsThePairAsItLocksTowardANeighbour() async throws {
        let hosted = try await hosted(tabs: 3, active: 1, sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let bar = hosted.bar
        hosted.pager.driver.hold()
        bar.swiped(.began, sample(Theme.Gesture.axisLockDistance))
        // The lock itself arms: the next frame already draws the pages shrinking, with no further move.
        hosted.pager.driver.step(by: Theme.Latency.frame)
        #expect(pair(hosted)!.arm > 0 && pair(hosted)!.emerge > 0)
        #expect(drawn(hosted, 1).scale < 1)
        hosted.pager.driver.resume()
        try await waitUntil(every: .milliseconds(2)) { pair(hosted)!.arm == 1 && pair(hosted)!.emerge == 1 }
        #expect(drawn(hosted, 1).scale == Theme.Metrics.barSwipeCardScale)
        #expect(drawn(hosted, 0).opacity == 1 && drawn(hosted, 0).scale == Theme.Metrics.barSwipeCardScale)
        #expect(pair(hosted)!.older == hosted.tabs[0] && pair(hosted)!.newer == hosted.tabs[2])
        bar.swiped(.ended, sample(Theme.Gesture.axisLockDistance + 1))
        let seen = try await activeTabs(until: hosted)
        #expect(seen == [hosted.tabs[1]])
        #expect(pair(hosted) == nil)
    }

    // Landing on the older tab: its card stays out and both grow back to full size; nothing dives.
    @Test(.timeLimit(.minutes(1)))
    func aLandingOnTheOlderTabGrowsItBackToFullSize() async throws {
        let hosted = try await hosted(tabs: 3, active: 1, sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        try await swipe(hosted.bar, to: 0.6 * hosted.window.bounds.width, velocity: 0)
        var dove: CGFloat = 0
        var emerged: [CGFloat] = []
        try await waitUntil(every: .milliseconds(2)) {
            if let pair = pair(hosted) {
                dove = max(dove, pair.dive)
                emerged.append(pair.emerge)
            }
            return pair(hosted) == nil
        }
        // The older card only ever comes further out.
        #expect(dove == 0 && emerged.last! > 0.9)
        #expect(zip(emerged, emerged.dropFirst()).allSatisfy { $1 >= $0 })
        #expect(hosted.env.browser.activeTabID == hosted.tabs[0])
        #expect(ticks(hosted.env).count == 1)
        let landed = drawn(hosted, 0)
        #expect(landed.scale == 1 && landed.offset == .zero && landed.clipTop == 0)
    }

    // Landing on the newer tab: the page left drops into the tab stack while the new one grows to full size.
    @Test(.timeLimit(.minutes(1)))
    func aLandingOnTheNewerTabDropsThePageLeftIntoTheTabStack() async throws {
        let hosted = try await hosted(tabs: 3, active: 1, sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        // The tab switch's store and snapshot work wait for the still frame: none of it runs while anything moves. The
        // pages' own load snapshots come on a timer after each load, so the swipe starts once they are in.
        try await waitUntil { hosted.loadSnapshots.areIn(for: hosted.tabs) }
        let driver = hosted.pager.driver
        let env = hosted.env
        let movingAtSwitch = Seen()
        withObservationTracking { _ = env.activeController } onChange: {
            MainActor.assumeIsolated { movingAtSwitch.values.append(driver.isAnimating && driver.isPaging) }
        }
        try await swipe(hosted.bar, to: -0.6 * hosted.window.bounds.width, velocity: 0)
        var dove: CGFloat = 0
        var switchedWhileMoving = false
        try await waitUntil(every: .milliseconds(1)) {
            dove = max(dove, pair(hosted)?.dive ?? 0)
            if hosted.env.browser.activeTabID != hosted.tabs[1], driver.position != 2 || (pair(hosted)?.arm ?? 0) > 0 {
                switchedWhileMoving = true
            }
            return pair(hosted) == nil
        }
        #expect(!switchedWhileMoving)
        #expect(movingAtSwitch.values == [false])
        #expect(dove > 0.9)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[2])
        #expect(ticks(hosted.env).count == 1)
        let landed = drawn(hosted, 2)
        #expect(landed.scale == 1 && landed.offset == .zero)
    }

    // On the newest tab a drag toward no neighbour never arms and stretches loosely.
    @Test(.timeLimit(.minutes(1)))
    func aDragPastTheNewestTabNeverArms() async throws {
        let hosted = try await hosted(tabs: 3, active: 2, sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let bar = hosted.bar
        bar.swiped(.began, sample(0))
        bar.swiped(.changed, sample(-250))
        #expect(pair(hosted)!.arm == 0 && !hosted.pager.driver.isAnimating)
        #expect(hosted.pager.driver.position - 2 > 0.2)
        bar.swiped(.ended, sample(-250))
        let seen = try await activeTabs(until: hosted)
        #expect(seen == [hosted.tabs[2]])
    }

    // Steps the held deck clock in display frames.
    private func step(_ hosted: Hosted, _ duration: Duration) {
        let frames = Int(duration / Theme.Latency.frame)
        for _ in 0..<frames {
            hosted.pager.driver.step(by: Theme.Latency.frame)
        }
    }

    // A hard flick stiffens the position's spring past the arm's, so the cards keep shrinking back after the position
    // settles. Until every card is still the pair is moving: a touch holds it, and no landing runs under a finger.
    @Test(.timeLimit(.minutes(1)))
    func aHardFlickStaysGrabbableUntilEveryCardSettles() async throws {
        let hosted = try await hosted(tabs: 3, active: 1, sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let driver = hosted.pager.driver
        let bar = hosted.bar
        driver.hold()
        bar.swiped(.began, sample(-12))
        bar.swiped(.changed, sample(-200))
        step(hosted, .milliseconds(300))
        bar.swiped(.ended, sample(-200, velocity: -6000))
        var gap = false
        for _ in 0..<240 where driver.isPaging && !gap {
            driver.step(by: Theme.Latency.frame)
            gap = driver.motion == nil && driver.isAnimating
        }
        try #require(gap)
        #expect(hosted.pager.isMoving)
        try #require(hosted.pager.isMoving)
        bar.swiped(.began, sample(0))
        step(hosted, .seconds(1))
        #expect(driver.isPaging)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[1])
        bar.swiped(.changed, sample(10))
        bar.swiped(.ended, sample(10))
        driver.resume()
        _ = try await activeTabs(until: hosted)
    }

    // A swipe that catches a landing pages on from the tab it holds: one more tab, one tick each, one store switch.
    @Test(.timeLimit(.minutes(1)))
    func aSecondSwipeDuringALandingReachesTheNextTab() async throws {
        let hosted = try await hosted(tabs: 4, active: 0, sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let driver = hosted.pager.driver
        let bar = hosted.bar
        let width = hosted.window.bounds.width
        // Counted as fired: the engine throttles plays that land close together in real time, as these do here.
        func fired() -> Int { hosted.env.haptics.records.count { $0.interaction == .barSwipeTick } }
        let tickedBefore = fired()
        driver.hold()
        bar.swiped(.began, sample(-12))
        bar.swiped(.changed, sample(-0.6 * width))
        bar.swiped(.ended, sample(-0.6 * width))
        step(hosted, .milliseconds(100))
        #expect(driver.isPaging && hosted.env.browser.activeTabID == hosted.tabs[0])
        bar.swiped(.began, sample(0))
        bar.swiped(.changed, sample(-0.6 * width))
        bar.swiped(.ended, sample(-0.6 * width))
        driver.resume()
        let seen = try await activeTabs(until: hosted)
        #expect(seen == [hosted.tabs[0], hosted.tabs[2]])
        #expect(fired() - tickedBefore == 2)
        #expect(drawn(hosted, 2).scale == 1 && drawn(hosted, 2).offset == .zero)
    }

    // Armed toward the newer tab, then dragged past the page toward the older one: the older card comes out of the
    // tab stack and stays out through its landing.
    @Test(.timeLimit(.minutes(1)))
    func aDragReversedPastThePageBringsTheOlderCardOut() async throws {
        let hosted = try await hosted(tabs: 3, active: 1, sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let driver = hosted.pager.driver
        let bar = hosted.bar
        let width = hosted.window.bounds.width
        driver.hold()
        bar.swiped(.began, sample(-12))
        step(hosted, .milliseconds(500))
        #expect(pair(hosted)!.arm == 1 && pair(hosted)!.emerge == 0)
        bar.swiped(.changed, sample(0.6 * width))
        step(hosted, .milliseconds(500))
        #expect(pair(hosted)!.emerge == 1)
        #expect(drawn(hosted, 0).opacity == 1 && drawn(hosted, 0).scale == Theme.Metrics.barSwipeCardScale)
        bar.swiped(.ended, sample(0.6 * width))
        var emerged: CGFloat = 1
        for _ in 0..<240 where driver.isPaging {
            emerged = min(emerged, pair(hosted)!.emerge)
            driver.step(by: Theme.Latency.frame)
        }
        #expect(emerged == 1)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[0])
        driver.resume()
    }

    // A catch during a newer-tab landing, dragged back: the page left comes back out of the tab stack under the finger.
    @Test(.timeLimit(.minutes(1)))
    func aCatchDuringANewerLandingBringsThePageBackOutOfTheTabStack() async throws {
        let hosted = try await hosted(tabs: 3, active: 1, sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let driver = hosted.pager.driver
        let bar = hosted.bar
        let width = hosted.window.bounds.width
        driver.hold()
        bar.swiped(.began, sample(-12))
        bar.swiped(.changed, sample(-0.6 * width))
        step(hosted, .milliseconds(300))
        bar.swiped(.ended, sample(-0.6 * width))
        step(hosted, .milliseconds(120))
        #expect(pair(hosted)!.dive > 0.5)
        bar.swiped(.began, sample(0))
        bar.swiped(.changed, sample(0.5 * width))
        step(hosted, .milliseconds(500))
        let page = drawn(hosted, 1)
        #expect(page.opacity == 1 && page.scale == Theme.Metrics.barSwipeCardScale)
        #expect(pair(hosted)!.dive == 0)
        bar.swiped(.ended, sample(0.5 * width))
        driver.resume()
        let seen = try await activeTabs(until: hosted)
        #expect(seen == [hosted.tabs[1]])
        let rest = drawn(hosted, 1)
        #expect(rest.scale == 1 && rest.offset == .zero && rest.opacity == 1)
    }

    // The stack never drops a card that is not flying: a swipe toward a deck-older tab that is not the stack's front
    // card leaves the stack whole, with no copy.
    @Test(.timeLimit(.minutes(1)))
    func aSwipeTowardATabThatIsNotTheStacksFrontLeavesTheStackWhole() async throws {
        let hosted = try await hosted(tabs: 4, active: 2, sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let driver = hosted.pager.driver
        let recent = hosted.env.browser.tabs.filter { $0.id != hosted.env.browser.activeTabID }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }.prefix(2).map(\.id)
        #expect(recent.first == hosted.tabs[3])
        driver.hold()
        hosted.bar.swiped(.began, sample(12))
        hosted.bar.swiped(.changed, sample(120))
        step(hosted, .milliseconds(300))
        #expect(pair(hosted)!.older == hosted.tabs[1] && pair(hosted)!.emerge > 0)
        let cards = TabStackThumbnails.cards(recent: recent, flights: driver.stackFlights(layout: hosted.pager.layout))
        #expect(cards.fixed.map(\.id) == recent && cards.copies.isEmpty)
        hosted.bar.swiped(.ended, sample(120))
        driver.resume()
        _ = try await activeTabs(until: hosted)
    }

    @Test(.timeLimit(.minutes(1)))
    func aSlowReleaseShortOfTheMidpointSpringsBackToFullSize() async throws {
        let sink = ClockedSink()
        let hosted = try await hosted(tabs: 3, active: 1, sink: sink)
        defer { hosted.window.isHidden = true }
        try await swipe(hosted.bar, to: -0.3 * hosted.window.bounds.width, velocity: 0)
        #expect(drawn(hosted, 1).scale < 1)
        let seen = try await activeTabs(until: hosted)
        #expect(seen == [hosted.tabs[1]])
        #expect(settles(hosted.env) == 0)
        #expect(hosted.pager.driver.position == 1)
        let back = drawn(hosted, 1)
        #expect(back.scale == 1 && back.offset == .zero)
    }

    @Test(.timeLimit(.minutes(1)))
    func aHardFlickMovesOneTabWithOneTick() async throws {
        let sink = ClockedSink()
        let hosted = try await hosted(tabs: 4, active: 1, sink: sink)
        defer { hosted.window.isHidden = true }
        var tickedAt: [CGFloat] = []
        sink.onPlay = { feedback in
            if feedback == Theme.Haptic.selection {
                tickedAt.append(hosted.pager.driver.position)
            }
        }
        try await swipe(hosted.bar, to: -80, velocity: -4000)
        let seen = try await activeTabs(until: hosted)
        #expect(seen == [hosted.tabs[1], hosted.tabs[2]])
        #expect(settles(hosted.env) == 1)
        #expect(tickedAt.count == 1)
        #expect(tickedAt.count == 1 && tickedAt[0] > 1.5 && tickedAt[0] < 2.5)
        #expect(hosted.pager.driver.position == 2)
    }

    @Test(.timeLimit(.minutes(1)), .timingSensitive)
    func aTouchMidSpringHoldsTheCardsWhereTheyAreDrawn() async throws {
        let sink = ClockedSink()
        let hosted = try await hosted(tabs: 3, active: 1, sink: sink)
        defer { hosted.window.isHidden = true }
        let driver = hosted.pager.driver
        try await swipe(hosted.bar, to: -0.3 * hosted.window.bounds.width, velocity: -2000)
        try await waitUntil(every: .milliseconds(2)) { driver.position > 1.55 }
        #expect(driver.position < 1.95)
        #expect(hosted.pager.isMoving)
        hosted.controller.caught(true)
        let held = driver.position
        let pages = (drawn(hosted, 1), drawn(hosted, 2))
        #expect(pages.0.scale < 1 && pages.1.offset.width > 0)
        #expect(driver.motion == nil)
        try await Task.sleep(for: .milliseconds(60))
        #expect(driver.position == held)
        #expect(drawn(hosted, 1) == pages.0 && drawn(hosted, 2) == pages.1)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[1])
        hosted.controller.caught(false)
        let seen = try await activeTabs(until: hosted)
        #expect(seen == [hosted.tabs[1], hosted.tabs[2]])
    }

    @Test(.timeLimit(.minutes(1)))
    func aCaughtSwipeContinuesFromTheHeldPlace() async throws {
        let sink = ClockedSink()
        let hosted = try await hosted(tabs: 3, active: 1, sink: sink)
        defer { hosted.window.isHidden = true }
        let driver = hosted.pager.driver
        try await swipe(hosted.bar, to: -0.3 * hosted.window.bounds.width, velocity: -2000)
        try await waitUntil(every: .milliseconds(2)) { driver.position > 1.55 }
        hosted.controller.caught(true)
        let held = driver.position
        hosted.bar.swiped(.began, sample(0))
        hosted.bar.swiped(.changed, sample(0.5 * hosted.pager.layout.pageStride))
        #expect(abs(driver.position - (held - 0.5)) < 1e-6)
        hosted.bar.swiped(.ended, sample(0.5 * hosted.pager.layout.pageStride))
        hosted.controller.caught(false)
        let seen = try await activeTabs(until: hosted)
        #expect(seen == [hosted.tabs[1]])
        #expect(settles(hosted.env) == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func theTabStackDuringTheSpringOpensTheDeckOnTheTabItWasGoingTo() async throws {
        let sink = ClockedSink()
        let hosted = try await hosted(tabs: 3, active: 1, sink: sink)
        defer { hosted.window.isHidden = true }
        try await swipe(hosted.bar, to: -0.6 * hosted.window.bounds.width, velocity: 0)
        #expect(hosted.pager.isMoving)
        hosted.env.showSwitcher(via: .tabStackTap)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[2])
        #expect(!hosted.pager.driver.isPaging)
        #expect(hosted.env.ui.deckProgress == 1)
        #expect(settles(hosted.env) == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func theSwitcherOpenedByASecondFingerMidSwipeLeavesTheFirstFingerHarmless() async throws {
        let sink = ClockedSink()
        let hosted = try await hosted(tabs: 3, active: 1, sink: sink)
        defer { hosted.window.isHidden = true }
        let dx = -0.6 * hosted.window.bounds.width
        hosted.bar.swiped(.began, sample(0))
        hosted.bar.swiped(.changed, sample(dx))
        hosted.env.showSwitcher(via: .tabStackTap)
        hosted.bar.swiped(.changed, sample(dx - 40))
        hosted.bar.swiped(.ended, sample(dx - 40, velocity: -900))
        #expect(hosted.env.ui.deckProgress == 1)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[2])
        #expect(!hosted.pager.driver.isPaging)
        #expect(settles(hosted.env) == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func aTabStackFlickDuringTheSpringIsNotUndoneByTheLanding() async throws {
        let sink = ClockedSink()
        let hosted = try await hosted(tabs: 3, active: 1, sink: sink)
        defer { hosted.window.isHidden = true }
        let driver = hosted.pager.driver
        try await swipe(hosted.bar, to: -0.3 * hosted.window.bounds.width, velocity: -2000)
        try await waitUntil(every: .milliseconds(2)) { driver.position > 1.55 }
        hosted.controller.caught(true)
        hosted.env.activatePreviousTab()
        // The flick lands the swipe on the tab it held nearest, then switches back to the one before it.
        let records = hosted.env.haptics.records.map(\.interaction)
        let landed = try #require(records.lastIndex(of: .barSwipeSettle))
        let flicked = try #require(records.lastIndex(of: .tabStackFlick))
        #expect(landed < flicked)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[1])
        hosted.controller.caught(false)
        let seen = try await activeTabs(until: hosted)
        #expect(seen == [hosted.tabs[1]])
        #expect(settles(hosted.env) == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func aTouchDownMidSpringHoldsAtTheDrawnPlaceWithNoTick() async throws {
        let sink = ClockedSink()
        let hosted = try await hosted(tabs: 3, active: 1, sink: sink)
        defer { hosted.window.isHidden = true }
        let driver = hosted.pager.driver
        try await swipe(hosted.bar, to: -0.3 * hosted.window.bounds.width, velocity: -2000)
        try await waitUntil(every: .milliseconds(2)) { driver.position > 1.52 }
        let drawn = driver.position
        let ticked = ticks(hosted.env).count
        #expect(bar(hosted).router.gestureRecognizerShouldBegin(hosted.controller.catcher))
        hosted.controller.caught(true)
        #expect(abs(driver.position - drawn) * hosted.pager.layout.pageStride <= 0.5)
        #expect(ticks(hosted.env).count == ticked)
        hosted.controller.caught(false)
        _ = try await activeTabs(until: hosted)
    }

    @Test(.timeLimit(.minutes(1)))
    func theSlidingPageTakesNoTouchAndTakesThemAgainAtRest() async throws {
        let sink = ClockedSink()
        let hosted = try await hosted(tabs: 3, active: 1, sink: sink)
        defer { hosted.window.isHidden = true }
        let page = try #require(Self.livePage(in: hosted.controller.view))
        #expect(page.isUserInteractionEnabled)
        hosted.bar.swiped(.began, sample(0))
        hosted.bar.swiped(.changed, sample(-60))
        try await waitUntil { !page.isUserInteractionEnabled }
        hosted.bar.swiped(.ended, sample(-60))
        _ = try await activeTabs(until: hosted)
        let rested = try #require(Self.livePage(in: hosted.controller.view))
        try await waitUntil { rested.isUserInteractionEnabled }
    }

    // The page a swipe leaves is captured on the touch's first move on the bar, before the lock, and never again at
    // the lock or the landing; a prepare while paging captures nothing. Mutant: today's begin and pageTo make two
    // more entries.
    @Test(.timeLimit(.minutes(1)))
    func theBarCapturesOnTheFirstMoveNotAtTheLockOrTheLanding() async throws {
        let hosted = try await hosted(tabs: 3, active: 1, sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        try await waitUntil { hosted.loadSnapshots.areIn(for: hosted.tabs) }
        var captures: [UUID] = []
        hosted.env.onCaptureRequested = { captures.append($0) }
        hosted.bar.swipe.onFirstMove()
        #expect(captures == [hosted.tabs[1]])
        let width = hosted.window.bounds.width
        hosted.bar.swiped(.began, sample(-Theme.Gesture.axisLockDistance))
        hosted.bar.swiped(.changed, sample(-0.6 * width))
        hosted.pager.prepare()
        hosted.bar.swiped(.ended, sample(-0.6 * width))
        let seen = try await activeTabs(until: hosted)
        #expect(seen == [hosted.tabs[1], hosted.tabs[2]])
        #expect(captures == [hosted.tabs[1]])
    }

    // A snapshot result waits for the drag to end, not for the arm's spring: the deck reports moving for the whole
    // gesture. Mutant: the clock-based report lets it land mid-drag once the arm settles.
    @Test(.timeLimit(.minutes(1)))
    func aSnapshotResultWaitsForTheDragToEnd() async throws {
        let hosted = try await hosted(tabs: 3, active: 1, sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let driver = hosted.pager.driver
        let width = hosted.window.bounds.width
        driver.hold()
        hosted.bar.swiped(.began, sample(-Theme.Gesture.axisLockDistance))
        step(hosted, .seconds(1))
        #expect(!driver.isAnimating && driver.isPaging)
        var landed = false
        hosted.env.whenDeckRests { landed = true }
        #expect(!landed)
        hosted.bar.swiped(.changed, sample(-0.6 * width))
        hosted.bar.swiped(.ended, sample(-0.6 * width))
        for _ in 0..<240 where driver.isPaging || driver.isAnimating {
            driver.step(by: Theme.Latency.frame)
        }
        // On the turn after the rest, not the switch's.
        #expect(!landed)
        try await waitUntil { landed }
        #expect(hosted.env.browser.activeTabID == hosted.tabs[2])
        driver.resume()
    }

    // A neighbour the warm-up built is the controller the swipe attaches: no build on the switch frame, no capture
    // across the switch, and the switch still on a still frame.
    @Test(.timeLimit(.minutes(1)))
    func aSwipeOntoAWarmedNeighbourAttachesTheControllerThatWasBuilt() async throws {
        let hosted = try await hosted(tabs: 3, active: 1, sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        try await waitUntil { hosted.loadSnapshots.areIn(for: hosted.tabs) }
        let env = hosted.env
        env.pool.discard(hosted.tabs[0])
        #expect(env.pool.liveController(for: hosted.tabs[0]) == nil)
        env.prepareDeckNeighbours()
        let built = try #require(env.pool.liveController(for: hosted.tabs[0]))
        var captures: [UUID] = []
        env.onCaptureRequested = { captures.append($0) }
        let driver = hosted.pager.driver
        let movingAtSwitch = Seen()
        withObservationTracking { _ = env.activeController } onChange: {
            MainActor.assumeIsolated { movingAtSwitch.values.append(driver.isAnimating && driver.isPaging) }
        }
        try await swipe(hosted.bar, to: 0.6 * hosted.window.bounds.width, velocity: 0)
        let seen = try await activeTabs(until: hosted)
        #expect(seen == [hosted.tabs[1], hosted.tabs[0]])
        #expect(env.activeController === built)
        // The built neighbour's own load asks for its picture; the page left is not captured at the switch.
        #expect(!captures.contains(hosted.tabs[1]))
        #expect(movingAtSwitch.values == [false])
    }

    // Held clock. The lock writes the pair once (its creation; the arm's first frame comes with the first stepped
    // frame) and the position not at all, each move writes the position once and the pair never, the release's batch
    // writes nothing until its first frame, and every frame writes each at most once.
    @Test(.timeLimit(.minutes(1)))
    func aSwipeTurnWritesPositionOnceAndPairAtMostTwice() async throws {
        let hosted = try await hosted(tabs: 3, active: 1, sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let driver = hosted.pager.driver
        let bar = hosted.bar
        driver.hold()
        let pairWrites = Writes { _ = driver.pair }
        let positionWrites = Writes { _ = driver.position }
        bar.swiped(.began, sample(-Theme.Gesture.axisLockDistance))
        #expect(pairWrites.count == 1 && positionWrites.count == 0)
        driver.step(by: Theme.Latency.frame)
        #expect(pairWrites.count == 2 && positionWrites.count == 0)
        for step in 1...20 {
            bar.swiped(.changed, sample(-Theme.Gesture.axisLockDistance - CGFloat(step) * 5))
            #expect(positionWrites.count == step)
        }
        #expect(pairWrites.count == 2)
        bar.swiped(.ended, sample(-Theme.Gesture.axisLockDistance - 100))
        #expect(pairWrites.count == 2 && positionWrites.count == 20)
        var over = 0
        for _ in 0..<240 where driver.isPaging {
            let (pairs, positions) = (pairWrites.count, positionWrites.count)
            driver.step(by: Theme.Latency.frame)
            if driver.isPaging, pairWrites.count - pairs > 1 || positionWrites.count - positions > 1 {
                over += 1
            }
        }
        #expect(over == 0 && !driver.isPaging)
        driver.resume()
    }

    // The swipe holds one presence for the finger-down part and no per-touch deadline; after the release the frame
    // clock carries the rate. Mutant: the per-touch hold moves heldUntil on every event.
    @Test(.timeLimit(.minutes(1)))
    func aDragHoldsOnePresenceAndNoPerTouchDeadline() async throws {
        let hosted = try await hosted(tabs: 3, active: 1, sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let bar = hosted.bar
        bar.swiped(.began, sample(-Theme.Gesture.axisLockDistance))
        let heldUntil = FrameRateVote.heldUntil
        #expect(hosted.pager.presence != nil)
        for step in 1...20 {
            bar.swiped(.changed, sample(-Theme.Gesture.axisLockDistance - CGFloat(step) * 5))
        }
        #expect(FrameRateVote.heldUntil == heldUntil)
        #expect(hosted.pager.presence != nil)
        bar.swiped(.ended, sample(-Theme.Gesture.axisLockDistance - 100))
        #expect(hosted.pager.presence == nil)
        #expect(hosted.pager.driver.isAnimating)
        _ = try await activeTabs(until: hosted)
    }

    // The next gesture is taken on the frame the cards visibly rest, about 0.29 s after a slow release and not at the
    // spring's 0.37 s: the store switches there, the swipe and the page's touches are open from the next frame and
    // the catcher is not, and after the switcher closes a swipe is taken as soon as the zoom is at rest. Mutant: the
    // time rule gives 44 frames and a refused swipe at 0.33 s.
    @Test(.timeLimit(.minutes(1)))
    func theNextGestureIsTakenTheFrameTheCardsRest() async throws {
        let hosted = try await hosted(tabs: 3, active: 1, sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let driver = hosted.pager.driver
        let bar = hosted.bar
        let width = hosted.window.bounds.width
        driver.hold()
        bar.swiped(.began, sample(-Theme.Gesture.axisLockDistance))
        bar.swiped(.changed, sample(-0.6 * width))
        step(hosted, .milliseconds(300))
        bar.swiped(.ended, sample(-0.6 * width))
        var (frames, edgeBefore) = (0, CGFloat(0))
        while hosted.env.browser.activeTabID == hosted.tabs[1] || hosted.pager.isMoving, frames < 240 {
            edgeBefore = abs(drawn(hosted, 2).offset.width)
            driver.step(by: Theme.Latency.frame)
            frames += 1
        }
        #expect(frames >= 30 && frames <= 37)
        #expect(edgeBefore <= 1)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[2] && !hosted.pager.isMoving)
        driver.step(by: Theme.Latency.frame)
        let swipe = try #require(bar.gestureRecognizers?.first { $0 is BarSwipeRecognizer })
        #expect(hosted.pager.takesSwipe)
        #expect(bar.router.gestureRecognizerShouldBegin(swipe))
        #expect(!bar.router.gestureRecognizerShouldBegin(hosted.controller.catcher))
        // The page's touches follow on SwiftUI's next update.
        try await waitUntil { Self.livePage(in: hosted.controller.view)?.isUserInteractionEnabled == true }
        hosted.env.ui.setDeck(1)
        step(hosted, .seconds(1))
        #expect(driver.progress == 1 && !hosted.pager.takesSwipe)
        hosted.env.showTab(hosted.tabs[2], via: .deckCardTap)
        for _ in 0..<40 {
            driver.step(by: Theme.Latency.frame)
        }
        #expect(!driver.isZooming && driver.progress == 0)
        #expect(hosted.pager.takesSwipe)
        bar.swiped(.began, sample(Theme.Gesture.axisLockDistance))
        #expect(driver.pair != nil)
        bar.swiped(.ended, sample(Theme.Gesture.axisLockDistance))
        driver.resume()
        _ = try await activeTabs(until: hosted)
    }

    // A catch on the last moving frame of a slow release, let go at once, switches the store within twelve frames
    // and moves no drawn edge of the landing card by more than the rule's last step (landedPoints plus one frame at
    // landedSpeed): the cards were within a point of rest and settle there. Mutant: the time rule re-springs for 44
    // frames.
    @Test(.timeLimit(.minutes(1)))
    func aCatchOnTheLastMovingFrameResettlesWithinTwelveFrames() async throws {
        let hosted = try await hosted(tabs: 3, active: 1, sink: ClockedSink())
        defer { hosted.window.isHidden = true }
        let driver = hosted.pager.driver
        let bar = hosted.bar
        let width = hosted.window.bounds.width
        driver.hold()
        bar.swiped(.began, sample(-Theme.Gesture.axisLockDistance))
        bar.swiped(.changed, sample(-0.6 * width))
        step(hosted, .milliseconds(300))
        bar.swiped(.ended, sample(-0.6 * width))
        while let motion = driver.motion, !motion.curve.isSettled(at: driver.now + Theme.Latency.frame) {
            driver.step(by: Theme.Latency.frame)
        }
        try #require(driver.motion != nil && hosted.pager.isMoving)
        #expect(hosted.env.browser.activeTabID == hosted.tabs[1])
        hosted.controller.caught(true)
        hosted.controller.caught(false)
        var (frames, biggest) = (0, CGFloat(0))
        while hosted.env.browser.activeTabID == hosted.tabs[1], frames < 12 {
            let before = drawn(hosted, 2).offset.width
            driver.step(by: Theme.Latency.frame)
            frames += 1
            biggest = max(biggest, abs(drawn(hosted, 2).offset.width - before))
        }
        #expect(hosted.env.browser.activeTabID == hosted.tabs[2])
        #expect(biggest <= Theme.Gesture.landedPoints + Theme.Gesture.landedSpeed / Theme.Latency.frameRate)
        driver.resume()
    }

    @Test func aHardFlickNeverOvershootsTheLastPageByMoreThanTheDecksBound() {
        let start = ContinuousClock.now
        for velocity in [5.0, 20, 60] {
            let spring = DeckSnap.barSwipeRelease(velocity)
            let snap = DeckSnap(from: 1.9, to: 2, velocity: velocity, start: start, spring: spring)
            let samples = (0...2000).map { snap.position(at: start + .seconds(spring.settlingDuration * Double($0) / 2000)) }
            #expect((samples.max()! - 2) / 0.1 < 0.03)
        }
    }

    private func bar(_ hosted: Hosted) -> BarSlideView {
        hosted.bar
    }

    private static func livePage(in view: UIView) -> WebPageView.Container? {
        if let page = view as? WebPageView.Container, page.window != nil, page.hosted != nil {
            return page
        }
        return view.subviews.lazy.compactMap { livePage(in: $0) }.first
    }

    @Test(.timeLimit(.minutes(1)))
    func theSwipeRunsAlongsideTheBarsControlsAndCancelsThemWhenItBegins() async throws {
        let sink = ClockedSink()
        let hosted = try await hosted(tabs: 3, active: 1, sink: sink)
        defer { hosted.window.isHidden = true }
        let bar = hosted.bar
        let swipe = try #require(bar.gestureRecognizers?.first { $0 is BarSwipeRecognizer })
        let catcher = hosted.controller.catcher
        #expect(catcher.view === hosted.controller.view)
        #expect(!catcher.cancelsTouchesInView)
        let router = bar.router
        #expect(router.gestureRecognizer(swipe, shouldRecognizeSimultaneouslyWith: UITapGestureRecognizer()))
        #expect(router.gestureRecognizerShouldBegin(swipe))
        // The catch sees a touch only while the cards spring.
        #expect(!router.gestureRecognizerShouldBegin(catcher))
        let press = UILongPressGestureRecognizer()
        bar.host.view.addGestureRecognizer(press)
        let touched = bar.hitTest(CGPoint(x: bar.bounds.midX, y: bar.bounds.maxY - 30), with: TouchEvent())
        #expect(touched?.isDescendant(of: bar.host.view) == true)
        let toggles = Toggles()
        let observation = press.observe(\.isEnabled) { _, _ in MainActor.assumeIsolated { toggles.value += 1 } }
        bar.cancelTouchSharers()
        observation.invalidate()
        #expect(toggles.value == 2)
        #expect(press.isEnabled)
        // With the search sheet up or at the deck the bar does not swipe.
        #expect(hosted.env.ui.open(.search, animated: false))
        #expect(!router.gestureRecognizerShouldBegin(swipe))
    }
}

@MainActor private final class Toggles {
    var value = 0
}

@MainActor private final class Seen {
    var values: [Bool] = []
}
