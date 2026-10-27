import Synchronization
import SwiftUI
import Testing
@testable import SailBrowser

struct DeckSnapTests {
    private let layout = CardLayout(screen: CGSize(width: 440, height: 956))
    private let spring = Spring(mass: 1, stiffness: 320, damping: 32)
    private let start = ContinuousClock.now

    private func elapsed(reaching fraction: Double) -> TimeInterval {
        var low = 0.0
        var high = spring.settlingDuration
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if spring.value(target: 1.0, time: mid) < fraction { low = mid } else { high = mid }
        }
        return low
    }

    @Test func dragDuringSnapStartsFromPresentedPosition() {
        let snap = DeckSnap(from: 1, to: 2, velocity: 0, start: start)
        let time = start + .seconds(elapsed(reaching: 0.4))
        let dragStart = snap.position(at: time)
        #expect(abs(dragStart - 1.4) < 1e-6)
        let slots: [CGFloat] = [0, 1, 2, 3, 4]
        let translation = 0.3 * layout.stride
        let fromPresented = layout.snapTarget(start: dragStart, translation: translation, velocity: 0, slots: slots)
        let fromModel = layout.snapTarget(start: 2, translation: translation, velocity: 0, slots: slots)
        #expect(fromPresented.index == 1)
        #expect(fromModel.index == 2)
    }

    @Test func initialVelocityIsRelativeToDistance() {
        let snap = DeckSnap(from: 3, to: 1, velocity: 1.5, start: start)
        let expected = 3 + spring.value(target: -2.0, initialVelocity: 1.5 * -2.0, time: 0.05)
        #expect(abs(snap.position(at: start + .seconds(0.05)) - expected) < 1e-9)
    }

    @Test func grabAfterSettledSwipeStartsAtSnapTarget() {
        let motion = DeckMotion(from: 1.33, to: 1, shift: [:], velocity: 2.2, start: start)
        let grab = motion.presented(at: start + .seconds(3)).position
        #expect(grab == 1)
    }

    @Test func settledSnapIsExactlyAtTarget() {
        let snap = DeckSnap(from: 0, to: 4, velocity: 2, start: start)
        #expect(snap.position(at: start + .seconds(spring.settlingDuration + 0.01)) == 4)
        #expect(snap.position(at: start) == 0)
    }

    // The rest rule in numbers. deckZoom over a page (428 pt): the first settled millisecond is between 0.27 and
    // 0.31 s, where the spring is within half a point of its target and under the speed rule, and the position reads
    // the target exactly; with no points the time rule holds, at the spring's settling time. Mutant: the time-only
    // rule gives 0.369 s.
    @Test func aChannelSettlesWithinHalfAPointAndAQuarterPointPerFrame() {
        let snap = DeckSnap(from: 0, to: 1, velocity: 0, start: start, spring: DeckSnap.zoom, points: 428)
        var ms = 0
        while !snap.isSettled(at: start + .milliseconds(ms)) {
            ms += 1
        }
        let settled = Double(ms) / 1000
        #expect(settled >= 0.27 && settled <= 0.31)
        #expect(abs(snap.to - snap.raw(at: settled)) * 428 <= Theme.Gesture.landedPoints)
        #expect(abs(snap.velocity(at: start + .milliseconds(ms))) * 428 <= Theme.Gesture.landedSpeed)
        #expect(snap.position(at: start + .milliseconds(ms)) == 1)
        #expect(settled < DeckSnap.zoom.settlingDuration)
        let timed = DeckSnap(from: 0, to: 1, velocity: 0, start: start, spring: DeckSnap.zoom)
        let duration = DeckSnap.zoom.settlingDuration
        #expect(!timed.isSettled(at: start + .seconds(duration - 0.001)))
        #expect(timed.isSettled(at: start + .seconds(duration + 1e-6)))
        #expect(timed.position(at: start + .seconds(duration - 0.001)) < 1)
    }

    // A spring passing through its target is still moving: deckOlderZoom (bounce 0.1) over 2000 pt crosses its target
    // faster than the speed rule, so it is not at rest there and draws its raw value; a flicked page release likewise
    // on every frame its speed is over the rule.
    @Test func aBouncingSpringPassingThroughItsTargetIsNotSettled() {
        let bouncing = DeckSnap(from: 0, to: 1, velocity: 0, start: start, spring: DeckSnap.olderZoom, points: 2000)
        var ms = 1
        while bouncing.raw(at: Double(ms) / 1000) < 1, ms < 2000 {
            ms += 1
        }
        let crossing = start + .milliseconds(ms)
        #expect(Double(ms) / 1000 < DeckSnap.olderZoom.settlingDuration)
        #expect(abs(bouncing.velocity(at: crossing)) * 2000 > Theme.Gesture.landedSpeed)
        #expect(!bouncing.isSettled(at: crossing))
        #expect(bouncing.position(at: crossing) == bouncing.raw(at: Double(ms) / 1000))
        let stride = layout.pageStride
        let spring = DeckSnap.barSwipeRelease(20)
        let flicked = DeckSnap(from: 1.9, to: 2, velocity: 20, start: start, spring: spring, points: stride)
        var fast = 0
        for frame in 0...Int(spring.settlingDuration * 120) {
            let time = start + Theme.Latency.frame * frame
            if abs(flicked.velocity(at: time)) * stride > Theme.Gesture.landedSpeed {
                fast += 1
                #expect(!flicked.isSettled(at: time))
            }
        }
        #expect(fast > 0)
    }

    // Every spring the deck uses, at its channel's scale, sampled per 120 Hz frame: the first settled frame is within
    // half a point and under the speed rule and the frame before is not, before the spring's own time for the
    // channels a gesture waits on; where the time end comes first (a screen-high card on barSwipeDrop, bounce 0,
    // and other screen-high channels) the residual is under a point. Retargeting keeps the scale.
    @Test func everySpringTheDeckUsesSnapsByAtMostHalfAPoint() {
        let frame = Theme.Latency.frame
        func check(_ snap: DeckSnap, _ points: CGFloat, byPoints: Bool, _ name: Comment) {
            var k = 0
            while !snap.isSettled(at: start + frame * k) {
                k += 1
            }
            let elapsed = Double(k) / 120
            let error = abs(snap.to - snap.raw(at: elapsed)) * points
            if elapsed >= snap.spring.settlingDuration {
                #expect(!byPoints && error < 1, name)
                return
            }
            #expect(error <= Theme.Gesture.landedPoints, name)
            #expect(abs(snap.velocity(at: start + frame * k)) * points <= Theme.Gesture.landedSpeed, name)
            let beforeError = abs(snap.to - snap.raw(at: Double(k - 1) / 120)) * points
            let beforeSpeed = abs(snap.velocity(at: start + frame * (k - 1))) * points
            #expect(beforeError > Theme.Gesture.landedPoints || beforeSpeed > Theme.Gesture.landedSpeed, name)
        }
        func snap(_ spring: Spring, _ points: CGFloat, velocity: Double = 0, from: CGFloat = 0, to: CGFloat = 1)
            -> DeckSnap
        {
            DeckSnap(from: from, to: to, velocity: velocity, start: start, spring: spring, points: points)
        }
        let screen = layout.screenPoints
        check(snap(DeckSnap.zoom, layout.pageStride), layout.pageStride, byPoints: true, "position")
        check(snap(DeckSnap.arm, layout.pairArmPoints), layout.pairArmPoints, byPoints: true, "arm")
        check(snap(DeckSnap.arm, screen), screen, byPoints: false, "emerge")
        check(snap(DeckSnap.drop, screen), screen, byPoints: false, "dive")
        check(snap(DeckSnap.flick, 1, to: -400), 1, byPoints: true, "flick offset")
        check(snap(DeckSnap.flick, layout.flickGrowPoints), layout.flickGrowPoints, byPoints: true, "grow")
        check(snap(DeckSnap.flick, layout.flickArmPoints), layout.flickArmPoints, byPoints: true, "flick arm")
        check(snap(DeckSnap.flick, layout.flickLandPoints), layout.flickLandPoints, byPoints: true, "land")
        check(snap(DeckSnap.flickDrop, screen), screen, byPoints: false, "drop")
        check(snap(DeckSnap.zoom, layout.zoomPoints), layout.zoomPoints, byPoints: true, "progress")
        check(snap(DeckSnap.olderZoom, screen), screen, byPoints: false, "older progress")
        check(snap(DeckSnap.barFade, screen), screen, byPoints: false, "bar fade")
        for velocity in [5.0, 20, 60] {
            let release = DeckSnap.barSwipeRelease(velocity)
            check(
                snap(release, layout.pageStride, velocity: velocity, from: 1.9, to: 2), layout.pageStride,
                byPoints: false, "release at \(velocity)")
            let stiffened = DeckSnap.stiffened(DeckSnap.flick, for: velocity)
            check(snap(stiffened, 1, velocity: velocity, to: -400), 1, byPoints: false, "flick at \(velocity)")
        }
        let page = snap(DeckSnap.zoom, 428)
        #expect(page.retargeted(to: 0, at: start + .milliseconds(90), spring: DeckSnap.zoom).points == 428)
        let motion = DeckMotion(from: 0, to: 2, shift: [:], velocity: 0, start: start, spring: DeckSnap.zoom, points: 428)
        #expect(motion.curve.points == 856)
        let turned = motion.retargeted(to: 1, at: start + .milliseconds(90), spring: DeckSnap.zoom)!
        #expect(turned.points == 428)
        #expect(abs(turned.curve.points! - 428 * abs(1 - motion.presented(at: start + .milliseconds(90)).position)) < 1e-9)
    }
}

struct DeckMotionTests {
    private let layout = CardLayout(screen: CGSize(width: 440, height: 956))
    private let spring = Spring(mass: 1, stiffness: 320, damping: 32)
    private let start = ContinuousClock.now
    private let a = UUID(), c = UUID(), d = UUID()

    private func elapsed(reaching fraction: Double) -> TimeInterval {
        var low = 0.0
        var high = spring.settlingDuration
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if spring.value(target: 1.0, time: mid) < fraction { low = mid } else { high = mid }
        }
        return low
    }

    @Test func grabMidArchiveShiftKeepsPresentedSlots() {
        let ids = [a, c, d]
        let motion = DeckMotion(from: 2, to: 1, shift: [c: 1, d: 1], velocity: 0, start: start)
        let frozen = motion.presented(at: start + .seconds(elapsed(reaching: 0.4)))
        #expect(abs(frozen.position - 1.6) < 1e-6)
        #expect(abs(frozen.shift[c]! - 0.6) < 1e-6)
        #expect(abs(frozen.shift[d]! - 0.6) < 1e-6)
        #expect(frozen.shift[a] == nil)
        let slot = { (index: Int) in CGFloat(index) + frozen.shift[ids[index], default: 0] }

        let focused = layout.transform(slot: slot(1), isActive: true, activeIndex: 1, position: frozen.position, progress: 1)
        let focusedBefore = layout.transform(slot: 2, isActive: true, activeIndex: 2, position: 2, progress: 1)
        #expect(abs(focused.offset.width - focusedBefore.offset.width) < 1e-6)
        let right = layout.transform(slot: slot(2), isActive: false, activeIndex: 1, position: frozen.position, progress: 1)
        let rightBefore = layout.transform(slot: 3, isActive: false, activeIndex: 2, position: 2, progress: 1)
        #expect(abs(right.offset.width - rightBefore.offset.width) < 1e-6)

        let point = CGPoint(x: 50, y: layout.slotCenter.y)
        let presentedHit = layout.card(
            at: point, activeIndex: 1, position: frozen.position, progress: 1, olderProgress: 1, in: 0...2, slot: slot)
        let integerHit = layout.card(
            at: point, activeIndex: 1, position: frozen.position, progress: 1, olderProgress: 1, in: 0...2,
            slot: { CGFloat($0) })
        #expect(presentedHit == 0)
        #expect(integerHit == 1)
    }

    @Test func settledMotionLeavesNoShift() {
        let motion = DeckMotion(from: 2, to: 1, shift: [c: 1], velocity: 0, start: start)
        let settled = motion.presented(at: start + .seconds(spring.settlingDuration + 0.01))
        #expect(settled.position == 1)
        #expect(settled.shift.isEmpty)
    }

    @Test func snapTargetOverPresentedSlotsPicksNearestCard() {
        let slots: [CGFloat] = [0, 1.6, 2.6]
        #expect(layout.snapTarget(start: 1.6, translation: 0, velocity: 0, slots: slots).index == 1)
        #expect(layout.snapTarget(start: 1.6, translation: 0.3 * layout.stride, velocity: 0, slots: slots).index == 1)
        #expect(layout.snapTarget(start: 1.6, translation: 1.0 * layout.stride, velocity: 0, slots: slots).index == 0)
        #expect(layout.snapTarget(start: 2.0, translation: 0, velocity: 0, slots: [0, 1, 3]).index == 2)
        #expect(layout.snapTarget(start: 2.0, translation: 0, velocity: 0, slots: [0, 1, 2, 3]).index == 2)
    }
}

struct DeckScrollTests {
    @Test func visibleRangeIsTheClampedSpan() {
        let layout = CardLayout(screen: CGSize(width: 440, height: 956))
        for (start, end) in [(0.0, 0.0), (1.4, 1.4), (0.2, 3.7), (5.0, 2.0)] as [(CGFloat, CGFloat)] {
            let span = CardLayout.span(from: start, to: end)
            #expect(layout.visibleRange(from: start, to: end, count: 6) == max(0, span.lowerBound)...min(5, span.upperBound))
        }
    }

    @Test func spanChangesOnlyWhenACardEntersOrLeaves() {
        let driver = DeckDriver()
        driver.jump(to: 1.1, shift: [:])
        let initial = driver.span
        let changes = Mutex(0)
        withObservationTracking { _ = driver.span } onChange: { changes.withLock { $0 += 1 } }
        driver.jump(to: 1.4, shift: [:])
        #expect(driver.span == initial)
        #expect(changes.withLock { $0 } == 0)
        driver.jump(to: 2.6, shift: [:])
        #expect(driver.span != initial)
        #expect(changes.withLock { $0 } == 1)
    }
}
