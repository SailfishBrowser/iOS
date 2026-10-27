import SwiftUI

// Pages the deck's cards: a horizontal swipe on the browsing
// bar arms the pair as it locks toward a neighbour, the page sliding at full size with the finger while both shrink to
// cards, and moves the armed cards with the finger; the older card comes out of the tab stack. A release springs to a
// tab, one at most, and a touch during the spring holds the cards where they are drawn. The store switches tab as a deck
// tap does once everything has settled, so the tab switch's work never lands in a moving frame.
@MainActor final class TabPager {
    let driver: DeckDriver
    let layout: CardLayout
    private unowned let env: AppEnvironment
    // The position a horizontal drag started from and the finger's translation when it did.
    private var swipe: (start: CGFloat, translation: CGFloat)?
    private var armed = false
    // The pair's channel targets last asked for, so a drag springs a channel only when its target changes.
    private var steering: (arm: CGFloat, emerge: CGFloat, dive: CGFloat)?
    // The 120 Hz vote, held for the finger-down part of the swipe; the frame clock carries the rate after the release.
    private(set) var presence: FrameRateVote.Presence?

    init(env: AppEnvironment, driver: DeckDriver, layout: CardLayout) {
        self.env = env
        self.driver = driver
        self.layout = layout
    }

    // Only in the browser, never under a sheet, during a zoom or while the stack's finger has the flick's card. A
    // flick landing, returning or held by the catcher is landed first (began), so the swipe is taken through it.
    var takesSwipe: Bool {
        env.ui.overlay == .none && env.ui.deckProgress == 0 && !driver.isZooming && env.flick?.isDragging != true
            && env.browser.activeTab != nil
    }

    var isSwiping: Bool {
        swipe != nil
    }

    // Captures the page a swipe or a flick would leave, on the touch's first move and before the lock, where nothing
    // moves yet; a touch that catches or chains into a motion captures nothing, that page being a snapshot card
    // already. Never again at the switch: the picture is current, the page not having taken a touch since.
    func prepare() {
        env.cancelWarmUp()
        guard takesSwipe, !driver.isPaging, driver.flick == nil, let id = env.browser.activeTabID else { return }
        env.captureSnapshot(of: id)
    }

    // Any spring the pair drives: a hard flick's stiffened position settles before the cards stop shrinking back.
    var isMoving: Bool {
        driver.isPaging && driver.isAnimating
    }

    // A touch that held the spring and never became a swipe lets the cards go to the nearest tab.
    func catchEnded() {
        guard !isSwiping, driver.isPaging, !driver.isAnimating else { return }
        settle(release(velocity: 0, from: Int(driver.position.rounded())))
    }

    func swiped(_ phase: DragPhase, _ sample: DragSample) {
        switch phase {
        case .began: began(sample)
        case .changed: changed(sample)
        case .ended: ended(velocity: sample.velocity.width)
        case .cancelled: ended(velocity: 0)
        }
    }

    // The switcher opening mid-spring lands the paging at once, so the deck opens on the tab it was going to.
    func finish() {
        guard driver.isPaging else { return }
        let target = Int((driver.motion?.to ?? driver.position).rounded())
        let id = tab(at: target)
        swipe = nil
        driver.endPaging()
        driver.jump(to: CGFloat(target), shift: [:])
        land(on: id)
    }

    // A touch during the spring holds the cards at the place the last frame drew.
    func hold() {
        guard driver.isPaging else { return }
        if driver.motion != nil {
            driver.jump(to: driver.position, shift: [:])
        }
        driver.holdPaging()
        steering = nil
    }

    // A swipe from rest pages from the active tab; one that catches a spring continues from where it holds it. One
    // batch: the arm's curves start together and their first frame is applied once.
    private func began(_ sample: DragSample) {
        presence = FrameRateVote.Presence()
        // A flick still landing, or held mid-landing, switches to the tab it is heading to first (its haptic if not
        // yet played); a springing return ends where it is. The pair is then built from the tab the store is on.
        if driver.flick != nil {
            env.flick?.finish()
        }
        driver.batch {
            if driver.isPaging {
                hold()
                repair()
            } else {
                begin()
            }
            swipe = (driver.position, sample.translation.width)
            steer(older: sample.translation.width > 0)
        }
        env.haptics.fire(.barSwipe)
        env.haptics.prepare(.barSwipeTick)
    }

    // The switcher or another tab switch can land the swipe while the finger still drags.
    private func changed(_ sample: DragSample) {
        guard let (start, base) = swipe else { return }
        env.haptics.prepare(.barSwipeTick)
        let travel = sample.translation.width - base
        move(from: start, translation: travel)
        steer(older: travel > 0 || travel == 0 && sample.translation.width > 0)
    }

    private func ended(velocity: CGFloat) {
        presence = nil
        guard let start = swipe?.start else { return }
        swipe = nil
        settle(release(velocity: velocity, from: Int(start.rounded())))
    }

    // The pair is the active page and its neighbours in the deck.
    private func begin() {
        let tabs = env.browser.tabs
        let active = tabs.firstIndex { $0.id == env.browser.activeTabID }!
        armed = false
        steering = nil
        driver.jump(to: CGFloat(active), shift: [:])
        driver.beginPaging(
            DeckDriver.PagePair(
                origin: active, originID: tabs[active].id, older: active > 0 ? tabs[active - 1].id : nil,
                newer: active + 1 < tabs.count ? tabs[active + 1].id : nil, safeTop: env.pool.page.safeTop),
            detent: PageDetent(leading: active, count: tabs.count, stride: layout.pageStride)
        ) { [weak self] in
            self?.env.haptics.fire(.barSwipeTick)
        }
    }

    // The channels follow the drag. The pair arms as the pan locks toward a neighbour, even with the page still, and never
    // toward no neighbour. While armed the older card is out of the tab stack whenever the drag is on its side, and the
    // page under the finger is never in the tab stack.
    private func steer(older: Bool) {
        let pair = driver.pair!
        let origin = CGFloat(pair.origin)
        if !armed, (older ? pair.older : pair.newer) != nil {
            armed = true
        }
        guard armed else { return }
        let olderSide = pair.older != nil && (driver.position < origin || driver.position == origin && older)
        target((arm: 1, emerge: olderSide ? 1 : 0, dive: 0))
    }

    // Unchanged targets start no curve and apply nothing, so a move writes the position and nothing else.
    private func target(_ next: (arm: CGFloat, emerge: CGFloat, dive: CGFloat)) {
        let last = steering
        guard last == nil || last! != next else { return }
        steering = next
        driver.animatePair(
            arm: last?.arm == next.arm ? nil : next.arm, emerge: last?.emerge == next.emerge ? nil : next.emerge,
            dive: last?.dive == next.dive ? nil : next.dive)
    }

    // A swipe that catches a paging pages on from the tab it holds nearest: the pair is built around that tab, each
    // card keeping where it is drawn, so one more tab is reachable.
    private func repair() {
        let pair = driver.pair!
        let nearest = Int(driver.position.rounded())
        guard nearest != pair.origin else { return }
        let tabs = env.browser.tabs
        // How far each card is toward the tab stack as it is drawn now.
        func fromStack(_ id: UUID?) -> CGFloat {
            id == pair.originID ? pair.dive : id == pair.older ? 1 - pair.emerge : id == pair.newer ? 0 : 1
        }
        let older = nearest > 0 ? tabs[nearest - 1].id : nil
        var next = DeckDriver.PagePair(
            origin: nearest, originID: tabs[nearest].id, older: older,
            newer: nearest + 1 < tabs.count ? tabs[nearest + 1].id : nil, safeTop: pair.safeTop)
        next.arm = pair.arm
        next.emerge = 1 - fromStack(older)
        next.dive = fromStack(next.originID)
        driver.repair(next)
        armed = pair.arm > 0
    }

    // The pair spans the origin and the neighbours it has; past either end the finger bands.
    private var span: ClosedRange<Int> {
        let pair = driver.pair!
        return (pair.origin - (pair.older == nil ? 0 : 1))...(pair.origin + (pair.newer == nil ? 0 : 1))
    }

    private func move(from start: CGFloat, translation: CGFloat) {
        let low = CGFloat(span.lowerBound)
        driver.move(to: low + BarSwipe.position(
            start: start - low, translation: translation, stride: layout.pageStride, count: span.count))
    }

    private func release(velocity: CGFloat, from start: Int) -> (index: Int, velocity: Double) {
        let low = span.lowerBound
        let release = BarSwipe.release(
            position: driver.position - CGFloat(low), start: start - low, velocity: velocity, stride: layout.pageStride,
            count: span.count)
        return (release.index + low, release.velocity)
    }

    // Landing on the older tab keeps its card out and grows both back; on the newer one the page left drops into the
    // tab stack; a return sends the older card back into it.
    private func settle(_ release: (index: Int, velocity: Double)) {
        let origin = driver.pair!.origin
        let id = tab(at: release.index)
        driver.batch {
            driver.run(
                DeckMotion(
                    from: driver.position, to: CGFloat(release.index), shift: [:], velocity: release.velocity,
                    start: driver.now, spring: DeckSnap.barSwipeRelease(release.velocity), points: layout.pageStride),
                at: driver.now)
            target((arm: 0, emerge: release.index < origin ? 1 : 0, dive: release.index > origin ? 1 : 0))
            steering = nil
            // The tab switch attaches the live page and writes the store; on the phone it cost a frame while the page
            // still moved, so it waits for the still frame.
            driver.releasePaging { [weak self] in self?.land(on: id) }
        }
    }

    private func tab(at index: Int) -> Tab.ID {
        let pair = driver.pair!
        return index < pair.origin ? pair.older! : index > pair.origin ? pair.newer! : pair.originID
    }

    private func land(on id: Tab.ID) {
        if id != env.browser.activeTabID {
            env.pageTo(id)
        }
    }
}
