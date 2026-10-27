import SwiftUI
import Testing
@testable import SailBrowser

struct DeckCurveTests {
    private let start = ContinuousClock.now

    @Test func retargetedSnapKeepsPresentedValueAndSpeed() {
        let snap = DeckSnap(from: 0, to: 1, velocity: 0, start: start, spring: DeckSnap.zoom)
        let time = start + .milliseconds(90)
        let back = snap.retargeted(to: 0, at: time, spring: DeckSnap.zoom)
        #expect(abs(back.position(at: time) - snap.position(at: time)) < 1e-9)
        #expect(abs(back.velocity(at: time) - snap.velocity(at: time)) < 1e-6)
        #expect(back.to == 0)
    }

    @Test func retargetFromSettledSnapStartsAtRest() {
        let snap = DeckSnap(from: 0, to: 1, velocity: 0, start: start, spring: DeckSnap.zoom)
        let time = start + .seconds(DeckSnap.zoom.settlingDuration + 0.1)
        let back = snap.retargeted(to: 0, at: time, spring: DeckSnap.zoom)
        #expect(back.position(at: time) == 1)
        #expect(back.velocity == 0)
    }

}

struct DeckCoastTests {
    private let layout = CardLayout(screen: CGSize(width: 440, height: 956))
    private let start = ContinuousClock.now

    private func speed(_ coast: DeckCoast, at seconds: Double) -> CGFloat {
        let step = 0.0005
        return (coast.value(at: start + .seconds(seconds + step)) - coast.value(at: start + .seconds(seconds))) / step
    }

    @Test func aFlungCardStartsAtTheFingersSpeedAndOnlySlows() {
        let coast = layout.flyOff(from: -250, velocity: -3000, start: start)
        #expect(coast.velocity == -3000)
        #expect(abs(speed(coast, at: 0) - -3000) < 10)
        var previous = speed(coast, at: 0)
        for frame in 1..<Int(coast.duration * 120) {
            let now = speed(coast, at: Double(frame) / 120)
            #expect(now > previous)
            #expect(now < 0)
            previous = now
        }
        #expect(!coast.isSettled(at: start + .seconds(coast.duration - 0.001)))
        #expect(coast.isSettled(at: start + .seconds(coast.duration + 1e-6)))
        #expect(coast.value(at: start + .seconds(coast.duration + 1e-6)) == -956)
        #expect(coast.value(at: start + .seconds(5)) == -956)
    }

    // An armed card let go without a flick, and the debug throw from rest, still leave at half their start speed.
    @Test func aSlowReleaseStartsFastEnoughToCoastTwiceItsTrip() {
        for lift: CGFloat in [0, -373] {
            let coast = layout.flyOff(from: lift, velocity: 0, start: start)
            let trip = 956 + lift
            #expect(abs(coast.velocity / DeckCoast.rate - -Theme.Motion.archiveFlyOffMinimumCoast * trip) < 1e-6)
            #expect(abs(coast.duration - log(2) / Double(DeckCoast.rate)) < 1e-9)
            #expect(abs(speed(coast, at: coast.duration - 0.001) / coast.velocity - 0.5) < 0.01)
        }
        let downward = layout.flyOff(from: -373, velocity: 400, start: start)
        #expect(downward.velocity == layout.flyOff(from: -373, velocity: 0, start: start).velocity)
    }

    // Today's fixed ease-out started every throw at about 6,000 pt/s; a coast from rest starts under 4,000.
    @Test func noThrowStartsFasterThanItsFingerOrItsFloor() {
        let rest = layout.flyOff(from: 0, velocity: 0, start: start)
        #expect(rest.velocity > -4000)
        #expect(layout.flyOff(from: -100, velocity: -6500, start: start).velocity == -6500)
    }

    @Test func deceleratesAtThePlatformsNormalRate() {
        #expect(abs(DeckCoast.rate - 1000 * (1 - 0.998) / 0.998) < 1e-9)
        let coast = DeckCoast(from: 0, to: -1000, velocity: -3000, start: start)
        #expect(coast.duration > 0.25)
        #expect(abs(speed(coast, at: 0.25) / speed(coast, at: 0) - exp(-DeckCoast.rate * 0.25)) < 0.001)
    }
}

struct DeckDriverTests {
    private let start = ContinuousClock.now

    final class Landings {
        var count = 0
    }

    // The settle haptic plays as the card visibly lands, before the spring's settling time, and only once.
    @Test func aLandingPlaysOnceWithinTheSettledDistanceBeforeTheSpringRests() {
        let driver = DeckDriver()
        let landings = Landings()
        driver.run(
            DeckMotion(from: 0, to: 2, shift: [:], velocity: 0, start: start), at: start,
            landing: { landings.count += 1 })
        var time = start
        while landings.count == 0 {
            time += .milliseconds(5)
            driver.apply(at: time)
        }
        #expect(abs(driver.position - 2) < Theme.Gesture.deckSettledDistance)
        #expect(driver.motion != nil)
        driver.apply(at: time + .seconds(1))
        #expect(driver.motion == nil)
        #expect(landings.count == 1)
    }

    @Test func aCaughtSnapDropsItsLanding() {
        let driver = DeckDriver()
        let landings = Landings()
        driver.run(
            DeckMotion(from: 0, to: 2, shift: [:], velocity: 0, start: start), at: start,
            landing: { landings.count += 1 })
        driver.jump(to: 1, shift: [:])
        driver.run(DeckMotion(from: 1, to: 2, shift: [:], velocity: 0, start: start), at: start)
        driver.apply(at: start + .seconds(1))
        #expect(landings.count == 0)
    }

    @Test func positionJumpLeavesARunningZoomInFlight() {
        let driver = DeckDriver()
        driver.animateProgress(to: 1, start: start)
        driver.jump(to: 2, shift: [:])
        driver.apply(at: start + .milliseconds(100))
        #expect(driver.position == 2)
        #expect(driver.progress > 0.2 && driver.progress < 1)
        #expect(driver.isAnimating)
    }

    @Test func everyCurveSettlesOnItsTargetAndStopsTheClock() {
        let driver = DeckDriver()
        let id = UUID()
        driver.animateProgress(to: 1, start: start)
        driver.run(DeckMotion(from: 0, to: 3, shift: [id: 1], velocity: 0, start: start, spring: DeckSnap.zoom))
        driver.animateLift(id, .coast(DeckCoast(from: 0, to: -900, velocity: -4000, start: start)))
        driver.apply(at: start + .seconds(2))
        #expect(driver.progress == 1)
        #expect(driver.position == 3)
        #expect(driver.shift.isEmpty)
        #expect(driver.lifts[id] == -900)
        #expect(!driver.isAnimating)
    }

    @Test func reversedZoomContinuesFromThePresentedProgress() {
        let driver = DeckDriver()
        driver.animateProgress(to: 1, start: start)
        let time = start + .milliseconds(80)
        driver.apply(at: time)
        let presented = driver.progress
        driver.animateProgress(to: 0, start: time)
        let reversed = DeckSnap(from: 0, to: 1, velocity: 0, start: start, spring: DeckSnap.zoom)
            .retargeted(to: 0, at: time, spring: DeckSnap.zoom)
        #expect(abs(reversed.position(at: time) - presented) < 1e-9)
        #expect(abs(driver.progress - reversed.position(at: time + Theme.Latency.frame)) < 1e-9)
    }

    @Test func directLiftCancelsItsCurve() {
        let driver = DeckDriver()
        let id = UUID()
        driver.animateLift(id, .snap(DeckSnap(from: -200, to: 0, velocity: 0, start: start)))
        driver.setLift(id, -50)
        driver.apply(at: start + .seconds(2))
        #expect(driver.lifts[id] == -50)
        #expect(!driver.isAnimating)
    }

    @Test func runMovesBeforeTheFirstTick() {
        let driver = DeckDriver()
        driver.jump(to: 1, shift: [:])
        driver.run(DeckMotion(from: 1, to: 2, shift: [:], velocity: 3, start: .now))
        let first = driver.position
        #expect(first > 1)
        driver.apply(at: .now)
        #expect(driver.position >= first)
    }

    @Test func progressAndLiftMoveBeforeTheFirstTick() {
        let driver = DeckDriver()
        let id = UUID()
        driver.animateProgress(to: 1)
        #expect(driver.progress > 0)
        driver.animateLift(id, .snap(DeckSnap(from: -200, to: 0, velocity: 0, start: .now)))
        #expect(driver.lifts[id]! > -200)
    }

    @Test func applyNeverStepsBackInTime() {
        let driver = DeckDriver()
        let start = ContinuousClock.now
        driver.animateProgress(to: 1, start: start)
        driver.apply(at: start + .milliseconds(100))
        let later = driver.progress
        driver.apply(at: start + .milliseconds(50))
        #expect(driver.progress == later)
    }

    @Test func theDriverReportsWhenItStartsAndStopsMoving() {
        let driver = DeckDriver()
        var reports: [Bool] = []
        driver.onMotion = { reports.append($0) }
        driver.animateProgress(to: 1, start: start)
        driver.animateLift(UUID(), .snap(DeckSnap(from: -100, to: 0, velocity: 0, start: start)))
        #expect(reports == [true])
        driver.apply(at: start + .milliseconds(100))
        #expect(reports == [true])
        driver.apply(at: start + .seconds(2))
        #expect(reports == [true, false])
    }

    // The deck stays moving from a swipe's or a flick's begin until its end, even with no curve running under the
    // finger, so nothing deferred to rest lands mid-drag. Mutant: the clock-based report adds a false at the arm's end.
    @Test func theDeckStaysMovingThroughADragLongerThanItsArm() {
        let driver = DeckDriver()
        var reports: [Bool] = []
        driver.onMotion = { reports.append($0) }
        driver.beginPaging(
            DeckDriver.PagePair(origin: 0, originID: UUID(), older: nil, newer: UUID(), safeTop: 62), detent: nil) {}
        #expect(reports == [true])
        driver.animatePair(arm: 1, start: start)
        driver.apply(at: start + .seconds(1))
        #expect(reports == [true] && !driver.isAnimating && driver.pair!.arm == 1)
        driver.releasePaging()
        driver.apply(at: start + .seconds(2))
        #expect(reports == [true, false] && !driver.isPaging)
        let layout = CardLayout(screen: CGSize(width: 402, height: 874))
        driver.adopt(layout)
        driver.beginFlick(from: UUID(), to: UUID(), safeTop: 62, grab: layout.flickGrab(at: layout.frontSlot))
        #expect(reports == [true, false, true])
        driver.animateFlick(\.arm, to: 1, spring: DeckSnap.flick, start: start + .seconds(2))
        driver.apply(at: start + .seconds(3))
        #expect(reports == [true, false, true] && !driver.isAnimating && driver.flick != nil)
        driver.releaseFlick(landing: nil, settled: nil)
        driver.apply(at: start + .seconds(4))
        #expect(reports == [true, false, true, false] && driver.flick == nil)
    }

    @Test func spanCoversTheWholeMotionFromItsStart() {
        let driver = DeckDriver()
        driver.jump(to: 0, shift: [:])
        driver.run(DeckMotion(from: 0, to: 6, shift: [:], velocity: 0, start: start))
        #expect(driver.span == CardLayout.span(from: 0, to: 6))
    }
}

struct DeckDriverArchiveTests {
    private let a = UUID(), b = UUID()

    private func gapClose(at commit: ContinuousClock.Instant) -> DeckMotion {
        DeckMotion(from: 1, to: 1, shift: [b: 1], velocity: 0, start: commit, spring: DeckSnap.gapClose)
    }

    @Test func flyOffBaseHoldsLaterCardsUntilTheGapCloseArchives() {
        let driver = DeckDriver()
        let commit = ContinuousClock.now
        var archived: [UUID] = []
        driver.run(gapClose(at: commit), base: [b: -1], departing: (a, { archived.append(a) }))
        #expect(driver.shift[b]! <= 0)
        #expect(driver.shift[b]! > -0.5)
        driver.apply(at: commit + .milliseconds(100))
        #expect(archived.isEmpty)
        #expect(driver.departing[a] != nil)
        driver.apply(at: commit + .seconds(1))
        #expect(archived == [a])
        #expect(driver.shift.isEmpty)
        #expect(driver.departing.isEmpty)
        driver.apply(at: commit + .seconds(2))
        #expect(archived == [a])
    }

    // A grab mid gap close archives first and keeps the closing cards where they show, in the new indices.
    @Test func aGrabDuringTheGapCloseArchivesFirst() {
        let driver = DeckDriver()
        let commit = ContinuousClock.now
        var archived: [UUID] = []
        driver.run(gapClose(at: commit), base: [b: -1], departing: (a, { archived.append(a) }))
        let grab = commit + .milliseconds(80)
        driver.apply(at: grab)
        let shown = driver.shift[b]!
        let presented = driver.motion!.presented(at: grab)
        driver.finishDeparture()
        #expect(archived == [a])
        #expect(driver.departing.isEmpty)
        driver.jump(to: presented.position, shift: presented.shift)
        #expect(abs((driver.shift[b] ?? 0) - 1 - shown) < 1e-9)
        #expect(archived == [a])
    }

    // A grab mid-coast archives the tab but leaves the thrown card flying until its coast ends off the top.
    @Test func aGrabDuringTheCoastKeepsTheThrownCardFlyingToTheTop() {
        let driver = DeckDriver()
        let commit = ContinuousClock.now
        var flyingAtArchive = false
        driver.animateLift(a, .coast(DeckCoast(from: -373, to: -956, velocity: -2337, start: commit)), at: commit)
        driver.run(gapClose(at: commit), base: [b: -1], departing: (a, { flyingAtArchive = driver.isFlying(a) }))
        driver.apply(at: commit + .milliseconds(100))
        let lift = driver.lifts[a]!
        driver.finishDeparture()
        #expect(flyingAtArchive)
        #expect(driver.lifts[a] == lift)
        #expect(driver.departing[a] != nil)
        driver.keepLifts([b])
        driver.apply(at: commit + .milliseconds(200))
        #expect(driver.lifts[a]! < lift)
        driver.apply(at: commit + .seconds(1))
        #expect(driver.lifts[a] == nil)
        #expect(driver.departing[a] == nil)
        #expect(!driver.isFlying(a))
    }

    @Test func aSecondThrowArchivesTheFirstBeforeItsOwn() {
        let driver = DeckDriver()
        let commit = ContinuousClock.now
        var archived: [UUID] = []
        driver.run(gapClose(at: commit), base: [b: -1], departing: (a, { archived.append(a) }))
        driver.run(
            DeckMotion(from: 0, to: 0, shift: [:], velocity: 0, start: commit, spring: DeckSnap.gapClose),
            departing: (b, { archived.append(b) }))
        #expect(archived == [a])
        #expect(driver.departing.keys.sorted() == [b])
        driver.apply(at: commit + .seconds(1))
        #expect(archived == [a, b])
    }

    @Test func anyNewMotionArchivesAPendingThrowFirst() {
        let driver = DeckDriver()
        var archived = 0
        driver.run(gapClose(at: .now), base: [b: -1], departing: (a, { archived += 1 }))
        driver.move(to: 0.5)
        #expect(archived == 1)
        #expect(driver.shift.isEmpty)
    }
}

struct DeckThrowPlacementTests {
    private let layout = CardLayout(screen: CGSize(width: 440, height: 956))
    private let start = ContinuousClock.now
    private let ids = [UUID(), UUID(), UUID()]

    private func x(_ index: Int, in driver: DeckDriver) -> CGFloat {
        driver.placement(
            index: index, activeIndex: 2, layout: layout, header: EmptyView(), coverImage: nil, coverFill: .black,
            isUnrevealed: false, cover: CardCover(), tabID: ids[index]
        ).geometry.offset.width
    }

    @Test func departingCardKeepsItsXWhileTheDeckClosesTheGap() {
        let driver = DeckDriver()
        driver.setProgress(1)
        driver.jump(to: 2, shift: [:])
        let plan = layout.archivePlan(removing: 2, ids: ids, shift: [:], position: 2, start: start)
        driver.run(plan.motion, base: plan.shift, departing: (ids[2], {}))
        driver.apply(at: start)
        let departing = x(2, in: driver)
        let neighbour = x(1, in: driver)
        driver.apply(at: start + .milliseconds(120))
        #expect(driver.position < 2)
        #expect(x(2, in: driver) == departing)
        #expect(x(1, in: driver) != neighbour)
    }
}

struct DeckArchiveTimingTests {
    // The archive waits for the gap close, and the slowest fly-off is off the screen before it settles.
    @Test func theSlowestFlyOffEndsBeforeTheGapCloseArchives() {
        let layout = CardLayout(screen: CGSize(width: 440, height: 956))
        let start = ContinuousClock.now
        let plan = layout.archivePlan(removing: 2, ids: [UUID(), UUID(), UUID()], shift: [:], position: 2, start: start)
        let slowest = layout.flyOff(from: 0, velocity: 0, start: start)
        #expect(slowest.isSettled(at: start + .seconds(plan.motion.curve.spring.settlingDuration)))
        #expect(!plan.motion.curve.isSettled(at: start + .seconds(slowest.duration)))
    }
}

struct DeckDriverFollowTests {
    private let start = ContinuousClock.now

    @Test func animatedZoomNeverCompletesInOneFrame() {
        let driver = DeckDriver()
        driver.follow(1, animated: true, start: start)
        #expect(driver.progress > 0)
        driver.apply(at: start + .milliseconds(9))
        #expect(driver.progress < 1)
        #expect(driver.isAnimating)
    }

    @Test func instantDeckChangeLandsAtOnce() {
        let driver = DeckDriver()
        driver.follow(1, animated: false, start: start)
        #expect(driver.progress == 1)
        #expect(!driver.isAnimating)
    }

    @Test func startedCurvesShowTheirFirstFrameBeforeTheClockTicks() {
        let driver = DeckDriver()
        let id = UUID()
        driver.run(DeckMotion(from: 0, to: 2, shift: [:], velocity: 0, start: start, spring: DeckSnap.zoom), at: start)
        driver.animateLift(id, .coast(DeckCoast(from: 0, to: -900, velocity: -4000, start: start)), at: start)
        #expect(driver.position > 0)
        #expect(driver.lifts[id, default: 0] < 0)
    }
}

struct DeckOlderCardTests {
    private let layout = CardLayout(screen: CGSize(width: 440, height: 956))
    private let start = ContinuousClock.now

    @Test func olderCardsTrailTheActiveCardAndBothSettle() {
        let driver = DeckDriver()
        driver.follow(1, animated: true, start: start)
        driver.apply(at: start + .milliseconds(100))
        #expect(driver.olderProgress < driver.progress)
        driver.apply(at: start + .seconds(1))
        #expect(driver.progress == 1)
        #expect(driver.olderProgress == 1)
        #expect(!driver.isAnimating)
    }

    @Test func onlyOlderCardsReadTheOlderProgress() {
        let older = layout.transform(
            slot: 0, isActive: false, activeIndex: 2, position: 1, progress: 0.8, olderProgress: 0.5)
        #expect(older == layout.transform(slot: 0, isActive: false, activeIndex: 2, position: 1, progress: 0.5))
        let newer = layout.transform(
            slot: 3, isActive: false, activeIndex: 2, position: 1, progress: 0.8, olderProgress: 0.5)
        #expect(newer == layout.transform(slot: 3, isActive: false, activeIndex: 2, position: 1, progress: 0.8))
        let active = layout.transform(
            slot: 2, isActive: true, activeIndex: 2, position: 1, progress: 0.8, olderProgress: 0.5)
        #expect(active == layout.transform(slot: 2, isActive: true, activeIndex: 2, position: 1, progress: 0.8))
    }
}

// Every observed property is written once per gesture event and once per frame: a SwiftUI graph update each.
struct DeckDriverWriteTests {
    private let layout = CardLayout(screen: CGSize(width: 402, height: 874))

    private func flicking() -> DeckDriver {
        let driver = DeckDriver()
        driver.adopt(layout)
        driver.beginFlick(from: UUID(), to: UUID(), safeTop: 62, grab: layout.flickGrab(at: layout.frontSlot))
        return driver
    }

    // Mutant: the three-write moveFlick gives 150.
    @Test func aFlickTouchWritesTheFlickOnce() {
        let driver = flicking()
        let writes = Writes { _ = driver.flick }
        for step in 1...50 {
            driver.moveFlick(
                to: CGSize(width: CGFloat(step), height: -CGFloat(step) * 3), grow: min(CGFloat(step) / 40, 1))
        }
        #expect(writes.count == 50)
    }

    // Mutant: unbatched, the five channels apply fifteen writes before the first frame; the per-channel apply writes
    // five per frame.
    @Test func aBatchedReleaseAppliesOnceAndAFrameWritesEachStructOnce() {
        let driver = DeckDriver()
        var reports: [Bool] = []
        driver.onMotion = { reports.append($0) }
        driver.adopt(layout)
        driver.beginFlick(from: UUID(), to: UUID(), safeTop: 62, grab: layout.flickGrab(at: layout.frontSlot))
        #expect(reports == [true])
        driver.moveFlick(to: CGSize(width: 30, height: -80), grow: 0.5)
        let writes = Writes { _ = driver.flick }
        var changedInside = false
        driver.batch {
            let before = driver.flick
            driver.animateFlick(\.offsetX, to: 60, spring: DeckSnap.flick)
            driver.animateFlick(\.offsetY, to: -400, spring: DeckSnap.flick)
            driver.animateFlick(\.grow, to: 1, spring: DeckSnap.flick)
            driver.animateFlick(\.drop, to: 1, spring: DeckSnap.flickDrop)
            driver.animateFlick(\.land, to: 1, spring: DeckSnap.flick)
            changedInside = driver.flick != before
        }
        #expect(!changedInside)
        #expect(writes.count == 1)
        #expect(reports == [true])
        let start = ContinuousClock.now
        for frame in 1...30 {
            driver.apply(at: start + Theme.Latency.frame * frame)
        }
        #expect(writes.count > 1 && writes.count <= 31)
        #expect(reports == [true])
        let before = writes.count
        driver.batch {}
        #expect(writes.count == before)
        driver.apply(at: start + .seconds(2))
        #expect(!driver.isAnimating && driver.flick != nil)
    }
}

// The deck view's inputs (the span, the pair's and the flick's ids, the stack's out card) change once per gesture;
// a frame never invalidates them.
struct DeckViewInputTests {
    private let layout = CardLayout(screen: CGSize(width: 402, height: 874))
    private let start = ContinuousClock.now

    private func pair() -> DeckDriver.PagePair {
        DeckDriver.PagePair(origin: 1, originID: UUID(), older: UUID(), newer: UUID(), safeTop: 62)
    }

    // Mutant: reading driver.flick inside built invalidates on the first move.
    @Test func aFlickFrameNeverInvalidatesTheDecksBuiltList() {
        let driver = DeckDriver()
        driver.adopt(layout)
        let ids = (0..<4).map { _ in UUID() }
        let builds = Writes {
            _ = DeckView.built(ids: ids, activeIndex: 2, span: driver.span, pinned: driver.pagedIDs + driver.flickIDs)
        }
        driver.beginFlick(from: ids[2], to: ids[1], safeTop: 62, grab: layout.flickGrab(at: layout.frontSlot))
        #expect(builds.count == 1)
        for step in 1...20 {
            driver.moveFlick(to: CGSize(width: CGFloat(step), height: -CGFloat(step) * 5), grow: CGFloat(step) / 20)
        }
        driver.animateFlick(\.arm, to: 1, spring: DeckSnap.flick, start: start)
        driver.animateFlick(\.land, to: 1, spring: DeckSnap.flick, start: start)
        for frame in 1...20 {
            driver.apply(at: start + Theme.Latency.frame * frame)
        }
        #expect(builds.count == 1)
        driver.endFlick()
        #expect(builds.count == 2)
        driver.beginPaging(pair(), detent: nil) {}
        #expect(builds.count == 3)
        driver.animatePair(arm: 1, emerge: 1, start: start)
        for frame in 1...30 {
            driver.apply(at: start + Theme.Latency.frame * frame)
        }
        #expect(builds.count == 3)
        driver.repair(pair())
        #expect(builds.count == 4)
        driver.releasePaging()
        driver.apply(at: start + .seconds(2))
        #expect(!driver.isPaging && builds.count == 5)
    }

    // The driver's out card is the leaving flight's on every frame of a flick and a swipe, and it is written only
    // on the frames it flips.
    @Test func outOfStackMatchesTheFlightsFrameByFrame() {
        let driver = DeckDriver()
        driver.adopt(layout)
        var (checks, misses, flips) = (0, 0, 0)
        var last: UUID?
        func check() {
            let flight = driver.stackFlights(layout: layout).first { $0.leaving && $0.fromStack < 1 }?.id
            checks += 1
            if driver.outOfStack != flight {
                misses += 1
            }
            if driver.outOfStack != last {
                flips += 1
                last = driver.outOfStack
            }
        }
        let writes = Writes { _ = driver.outOfStack }
        let (from, to) = (UUID(), UUID())
        driver.beginFlick(from: from, to: to, safeTop: 62, grab: layout.flickGrab(at: layout.frontSlot))
        check()
        for step in 1...10 {
            driver.moveFlick(to: CGSize(width: 0, height: -CGFloat(step) * 8), grow: CGFloat(step) / 10)
            check()
        }
        driver.batch {
            driver.animateFlick(\.offsetY, to: -400, spring: DeckSnap.flick, start: start)
            driver.animateFlick(\.grow, to: 1, spring: DeckSnap.flick, start: start)
            driver.animateFlick(\.drop, to: 1, spring: DeckSnap.flickDrop, start: start)
            driver.animateFlick(\.land, to: 1, spring: DeckSnap.flick, start: start)
            driver.releaseFlick(landing: nil, settled: nil)
        }
        check()
        for frame in 1...60 {
            driver.apply(at: start + Theme.Latency.frame * frame)
            check()
        }
        #expect(driver.flick == nil && driver.outOfStack == nil)
        let later = start + .seconds(1)
        driver.jump(to: 1, shift: [:])
        driver.beginPaging(pair(), detent: nil) {}
        check()
        driver.animatePair(arm: 1, emerge: 1, start: later)
        check()
        for frame in 1...60 {
            driver.apply(at: later + Theme.Latency.frame * frame)
            check()
        }
        driver.releasePaging()
        driver.animatePair(arm: 0, emerge: 0, start: later + .seconds(1))
        for frame in 1...60 {
            driver.apply(at: later + .seconds(1) + Theme.Latency.frame * frame)
            check()
        }
        #expect(!driver.isPaging && driver.outOfStack == nil)
        #expect(checks > 150 && misses == 0)
        #expect(flips == 4 && writes.count == 4)
    }
}

@MainActor
struct DeckDriverHoldTests {
    // A held deck shows the time it is stepped to, whatever its display link's time, and a zoom begun while held starts
    // at the held time.
    @Test func aHeldDeckMovesOnlyWhenStepped() async throws {
        let driver = DeckDriver()
        driver.animateProgress(to: 1)
        driver.hold()
        let held = driver.barProgress
        try await Task.sleep(for: .milliseconds(100))
        #expect(driver.barProgress == held)
        driver.step(by: .milliseconds(50))
        let stepped = driver.barProgress
        #expect(stepped > held)
        #expect(stepped < 1)
        driver.animateProgress(to: 0)
        #expect(abs(driver.barProgress - stepped) < 1e-9)
        driver.resume()
        try await waitUntil { !driver.isAnimating }
        #expect(driver.barProgress == 0)
    }
}
