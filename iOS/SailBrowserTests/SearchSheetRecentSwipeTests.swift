import Testing
import UIKit
@testable import SailBrowser

private final class ScriptedPan: UIPanGestureRecognizer {
    var scriptedVelocity = CGPoint.zero

    override func velocity(in view: UIView?) -> CGPoint { scriptedVelocity }
}

// Each test focuses its own sheet's field; run in parallel they take the one first responder from each other.
@MainActor @Suite(.serialized)
struct SearchSheetRecentSwipeTests {
    private let sink = RecordingHapticSink(start: .now)
    private let a = URL(string: "https://a.com/")!
    private let b = URL(string: "https://b.com/")!

    private func risen() -> (SearchSheetController, UIWindow) {
        let env = makeEnvironment(hapticSink: sink)
        env.history.recordVisit(url: b, title: "B")
        env.history.recordVisit(url: a, title: "A")
        let (controller, window) = hostedSearchSheet(env)
        controller.view.layoutIfNeeded()
        sink.advance(by: Theme.Latency.frame)
        return (controller, window)
    }

    private func onRow(_ index: Int, of controller: SearchSheetController) -> CGPoint {
        CGPoint(
            x: controller.sheet.view.bounds.midX,
            y: SearchSheet.fieldSlotHeight + (CGFloat(index) + 0.5) * Theme.Metrics.suggestionRowHeight)
    }

    // A display link holds its clock, so a sheet freed mid-motion leaves the clock running: its steps must not read it.
    // The sheet's time is held from the motion's start and stepped a frame at a time through its settling time once the
    // sheet is gone, so every step comes due; then the clock has stopped, and once the motion's timed hold has lapsed
    // no link is held.
    private func freedMid(settling: TimeInterval, _ start: (SearchSheetController) -> AnyObject?) async throws {
        weak var freed: SearchSheetController?
        weak var motion: AnyObject?
        let clock: HeldClock
        do {
            let (controller, window) = risen()
            freed = controller
            clock = HeldClock(controller.view.layer)
            motion = try #require(start(controller))
            window.rootViewController = nil
            window.isHidden = true
        }
        try await waitUntil { freed == nil }
        for _ in 0...Int((settling * 60).rounded(.up)) {
            clock.step()
            await nextDisplayFrame()
        }
        #expect(motion == nil)
        try await waitUntil { !FrameRateVote.isHolding }
    }

    // A finger on a recent holds a presence while it is down; the release's return holds for its spring.
    @Test func aRowSwipeHoldsWhileTheFingerIsDown() {
        let (controller, window) = risen()
        let row = controller.recentRow(at: onRow(0, of: controller))!
        controller.rowSwipeBegan(row)
        #expect(controller.rowPresence != nil)
        let now = CACurrentMediaTime()
        controller.rowSwipeEnded(velocity: 0)
        #expect(controller.rowPresence == nil)
        #expect(FrameRateVote.heldUntil >= now + Theme.Motion.recentReturn.settlingDuration - 1 / Theme.Latency.frameRate)
        window.isHidden = true
    }

    // The recognizer's cancel bypasses the ended path: it must still let the presence go, or a 120 Hz link would run
    // until the next row swipe.
    @Test func aCancelledRowSwipeReleasesItsPresence() {
        let (controller, window) = risen()
        let row = controller.recentRow(at: onRow(0, of: controller))!
        controller.rowSwipeBegan(row)
        let now = CACurrentMediaTime()
        controller.rowSwipeCancelled()
        #expect(controller.rowPresence == nil)
        #expect(FrameRateVote.heldUntil >= now + Theme.Motion.recentReturn.settlingDuration - 1 / Theme.Latency.frameRate)
        window.isHidden = true
    }

    @Test func aSheetFreedMidRowReturnStopsTheReturn() async throws {
        try await freedMid(settling: Theme.Motion.recentReturn.settlingDuration) { controller in
            let row = controller.recentRow(at: onRow(0, of: controller))!
            controller.rowSwipeBegan(row)
            controller.rowSwipeChanged(0.3 * controller.container.bounds.width)
            controller.rowSwipeEnded(velocity: 0)
            return controller.rowReturn
        }
    }

    @Test func aSheetFreedMidCloseRunsNoCloseStep() async throws {
        try await freedMid(settling: Theme.Motion.searchTapClose.settlingDuration) { controller in
            controller.setActive(false, submitting: false)
            return controller.closeClock
        }
    }

    @Test func aShortSwipeSpringsBackAndKeepsTheRecent() async throws {
        let (controller, window) = risen()
        let row = controller.recentRow(at: onRow(0, of: controller))!
        #expect(row == .site(url: a, title: "A"))
        let width = controller.container.bounds.width
        let played = sink.played.count

        controller.rowSwipeBegan(row)
        controller.rowSwipeChanged(0.2 * width)
        #expect(controller.recentSwipe.offset(for: row) == 0.2 * width)
        controller.rowSwipeEnded(velocity: 0)

        try await waitUntil { controller.recentSwipe.row == nil }
        #expect(controller.recentSwipe.offset(for: row) == 0)
        #expect(controller.model.rows.contains(row))
        #expect(controller.env.history.entries.contains { $0.url == a })
        #expect(sink.played.count == played)
        window.isHidden = true
    }

    // A release moving left carries on left before the return brings it home; one flicked back toward rest stops at
    // rest, never past it. Neither bounces.
    @Test(.timeLimit(.minutes(1)))
    func theReturnCarriesTheFlicksVelocityWithoutPassingRest() async throws {
        let (controller, window) = risen()
        let row = controller.recentRow(at: onRow(0, of: controller))!
        let released = 0.2 * controller.container.bounds.width
        // The return counts in the window's animation time, held here and stepped a 60 Hz frame at a time, so every
        // frame of it is read however late the test's turns run.
        let clock = HeldClock(window.layer)
        // Each step's value is drawn on the next display tick; two frames make sure one has run.
        func returned() async throws -> [CGFloat] {
            let begin = clock.now
            var drawn: [CGFloat] = []
            while controller.recentSwipe.row == row {
                try #require(clock.now - begin < 1)
                clock.step()
                await nextDisplayFrame()
                await nextDisplayFrame()
                drawn.append(controller.recentSwipe.offset(for: row))
            }
            return drawn
        }

        controller.rowSwipeBegan(row)
        controller.rowSwipeChanged(released)
        controller.rowSwipeEnded(velocity: 1500)
        let carried = try await returned()
        #expect(carried.max()! > released + 0.5)
        #expect(carried.min()! >= 0)

        controller.rowSwipeBegan(row)
        controller.rowSwipeChanged(released)
        controller.rowSwipeEnded(velocity: -4000)
        let flickedBack = try await returned()
        #expect(flickedBack.min()! >= 0)
        #expect(controller.model.rows.contains(row))
        window.isHidden = true
    }

    // The arm is visible: the swiped row is armed from the line on, which moves the capsule's label to its leading
    // side, and disarmed back under it, so the haptic lands on that move.
    @Test func theRowIsArmedFromTheLineOn() {
        let (controller, window) = risen()
        let row = controller.recentRow(at: onRow(0, of: controller))!
        let line = Theme.Gesture.recentRemoveFraction * controller.container.bounds.width
        controller.rowSwipeBegan(row)
        controller.rowSwipeChanged(line - 1)
        #expect(!controller.recentSwipe.isArmed(row))
        controller.rowSwipeChanged(line)
        #expect(controller.recentSwipe.isArmed(row))
        controller.rowSwipeChanged(line - 2 * Theme.Gesture.detentHysteresis)
        #expect(!controller.recentSwipe.isArmed(row))
        controller.rowSwipeEnded(velocity: 0)
        window.isHidden = true
    }

    // A touch on a recent springing back holds it where it is drawn, as a touch on the moving sheet does. A swipe takes it
    // from there; a release lets it spring on from there.
    @Test func aTouchMidReturnHoldsTheRowWhereItIsDrawnAndASwipeTakesItFromThere() async throws {
        let (controller, window) = risen()
        let row = controller.recentRow(at: onRow(0, of: controller))!
        let from = 0.3 * controller.container.bounds.width
        controller.rowSwipeBegan(row)
        controller.rowSwipeChanged(from)
        controller.rowSwipeEnded(velocity: 0)

        try await waitUntil(every: .milliseconds(4)) { controller.recentSwipe.offset(for: row) <= from / 2 }
        let drawn = controller.recentSwipe.offset(for: row)
        #expect(drawn > 0)
        controller.rowCaught()
        #expect(abs(controller.recentSwipe.offset(for: row) - drawn) < 0.5)
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(controller.recentSwipe.offset(for: row) - drawn) < 0.5)

        controller.rowSwipeBegan(row)
        controller.rowSwipeChanged(20)
        #expect(abs(controller.recentSwipe.offset(for: row) - (drawn + 20)) < 0.5)
        controller.rowSwipeEnded(velocity: 0)
        try await waitUntil { controller.recentSwipe.row == nil }
        window.isHidden = true
    }

    @Test func aReleaseMidReturnLetsTheRowSpringOnFromWhereItWasHeld() async throws {
        let (controller, window) = risen()
        let row = controller.recentRow(at: onRow(0, of: controller))!
        controller.rowSwipeBegan(row)
        controller.rowSwipeChanged(0.3 * controller.container.bounds.width)
        controller.rowSwipeEnded(velocity: 0)
        try await waitUntil(every: .milliseconds(4)) { controller.recentSwipe.offset(for: row) <= 40 }
        controller.rowCaught()
        let held = controller.recentSwipe.offset(for: row)

        controller.rowReleased()
        #expect(abs(controller.recentSwipe.offset(for: row) - held) < 0.5)
        try await waitUntil { controller.recentSwipe.row == nil }
        #expect(controller.recentSwipe.offset(for: row) == 0)
        #expect(controller.model.rows.contains(row))
        window.isHidden = true
    }

    // As with the platform's swipe actions, a tap on a row springing back only catches it: the touch-down holds the row
    // on its own turn, the catch cancels the row's press so the tap never opens the page, and the release lets the
    // return finish with the entry kept.
    @Test func aTapOnAReturningRowOnlyCatchesIt() async throws {
        let (controller, window) = risen()
        let point = onRow(0, of: controller)
        let row = controller.recentRow(at: point)!
        let from = 0.3 * controller.container.bounds.width
        controller.rowSwipeBegan(row)
        controller.rowSwipeChanged(from)
        controller.rowSwipeEnded(velocity: 0)
        try await waitUntil(every: .milliseconds(4)) { controller.recentSwipe.offset(for: row) <= from / 2 }
        let hit = try #require(controller.sheet.view.hitTest(point, with: nil))
        let press = TrackingPress()
        hit.addGestureRecognizer(press)

        let drawn = controller.recentSwipe.offset(for: row)
        controller.rowTouched(at: point)
        #expect(abs(controller.recentSwipe.offset(for: row) - drawn) < 0.5)
        controller.rowCatchBegan(from: hit)
        #expect(press.cancelled)
        #expect(press.isEnabled)
        controller.rowReleased()

        try await waitUntil { controller.recentSwipe.row == nil }
        #expect(controller.recentSwipe.offset(for: row) == 0)
        #expect(controller.env.history.entries.contains { $0.url == a })
        #expect(!controller.env.haptics.records.contains { $0.interaction == .suggestionTap })
        window.isHidden = true
    }

    // The row swipe begins only on a recent, and the row catch holds only the row that is springing back.
    @Test func theRowGatesTakeOnlyTheirOwnTouches() async throws {
        let (controller, window) = risen()
        let first = onRow(0, of: controller)
        let second = onRow(1, of: controller)
        #expect(controller.rowSwipeMayBegin(at: first))
        #expect(!controller.rowSwipeMayBegin(at: CGPoint(x: first.x, y: SearchSheet.fieldSlotHeight / 2)))
        #expect(!controller.rowCatchHolds(at: first))

        controller.rowSwipeBegan(controller.recentRow(at: first)!)
        controller.rowSwipeChanged(60)
        controller.rowSwipeEnded(velocity: 0)
        #expect(controller.rowCatchHolds(at: first))
        #expect(!controller.rowCatchHolds(at: second))
        try await waitUntil { controller.recentSwipe.row == nil }
        #expect(!controller.rowCatchHolds(at: first))
        window.isHidden = true
    }

    @Test func aClosingSheetRefusesARowSwipe() {
        let (controller, window) = risen()
        let point = onRow(0, of: controller)
        #expect(controller.rowSwipeMayBegin(at: point))
        controller.setActive(false, submitting: false)
        #expect(controller.closeTop != nil)
        #expect(!controller.rowSwipeMayBegin(at: point))
        window.isHidden = true
    }

    // A swipe on another row while the first springs back leaves the first to finish on its own spring; the first's
    // return never takes over the new swipe.
    @Test func aSecondRowSwipedDuringAReturnKeepsItsOwnOffset() async throws {
        let (controller, window) = risen()
        let first = controller.recentRow(at: onRow(0, of: controller))!
        let second = controller.recentRow(at: onRow(1, of: controller))!
        controller.rowSwipeBegan(first)
        controller.rowSwipeChanged(60)
        controller.rowSwipeEnded(velocity: 0)

        controller.rowSwipeBegan(second)
        controller.rowSwipeChanged(30)
        try await Task.sleep(for: .milliseconds(600))
        #expect(controller.recentSwipe.row == second)
        #expect(controller.recentSwipe.offset(for: second) == 30)
        controller.rowSwipeEnded(velocity: 0)
        window.isHidden = true
    }

    // A second finger is handed back to UIKit, so the swipe never waits on it and the row stays with the first.
    @Test func everyTouchButTheTrackedFingerIsIgnored() {
        let first = UITouch()
        let second = UITouch()
        #expect(RowSwipeRecognizer.ignored([first], tracking: first).isEmpty)
        #expect(RowSwipeRecognizer.ignored([first, second], tracking: first).map(ObjectIdentifier.init) == [ObjectIdentifier(second)])
        #expect(RowSwipeRecognizer.ignored([second], tracking: first).map(ObjectIdentifier.init) == [ObjectIdentifier(second)])
    }

    @Test func aTapOnARowAtRestSelectsIt() {
        let (controller, window) = risen()
        controller.env.debugActions[.suggestionTap]!()
        #expect(controller.env.haptics.records.contains { $0.interaction == .suggestionTap })
        window.isHidden = true
    }

    // A vertical drag during the return still takes the sheet.
    @Test func theSheetsPanBeginsWhileARowSpringsBack() {
        let (controller, window) = risen()
        let row = controller.recentRow(at: onRow(0, of: controller))!
        controller.rowSwipeBegan(row)
        controller.rowSwipeChanged(40)
        controller.rowSwipeEnded(velocity: 0)
        let pan = ScriptedPan()
        pan.scriptedVelocity = CGPoint(x: 0, y: 300)
        #expect(controller.gestureRecognizerShouldBegin(pan))
        window.isHidden = true
    }

    // Past the line the row vanishes at the release in one frame, and the rows close its gap. The arm is
    // the only haptic.
    @Test func aSwipePastTheLineRemovesTheRecentAtOnceWithOneHaptic() {
        let (controller, window) = risen()
        let row = controller.recentRow(at: onRow(0, of: controller))!
        let width = controller.container.bounds.width
        let played = sink.played.count

        controller.rowSwipeBegan(row)
        controller.rowSwipeChanged(0.6 * width)
        controller.rowSwipeEnded(velocity: 0)

        #expect(controller.model.rows == [.site(url: b, title: "B")])
        #expect(!controller.env.history.entries.contains { $0.url == a })
        #expect(Array(sink.played.dropFirst(played)) == [Theme.Haptic.medium])
        #expect(sink.playsArePrepared)
        #expect(controller.recentSwipe.row == nil)
        window.isHidden = true
    }

    // A mostly vertical drag that starts on a recent never starts the row's swipe; the sheet's pan takes it.
    @Test func aVerticalDragOnARecentDragsTheSheetAndLeavesTheRowAtRest() {
        let (controller, window) = risen()
        let row = controller.recentRow(at: onRow(0, of: controller))!
        #expect(RowSwipe.starts(CGSize(width: 4, height: 30)) == false)

        let pan = ScriptedPan()
        pan.scriptedVelocity = CGPoint(x: 40, y: 300)
        #expect(controller.gestureRecognizerShouldBegin(pan))
        controller.dragBegan()
        let top = controller.container.frame.minY
        controller.dragChanged(64)

        #expect(abs(controller.container.frame.minY - (top + 64)) < 0.5)
        #expect(controller.recentSwipe.offset(for: row) == 0)
        #expect(controller.env.history.entries.count == 2)
        window.isHidden = true
    }

    // While a row is swiped the sheet leaves the touch alone, whichever way the finger then turns.
    @Test func aSwipingRowKeepsTheSheetsPanFromBeginning() {
        let (controller, window) = risen()
        let row = controller.recentRow(at: onRow(1, of: controller))!
        controller.rowSwipeBegan(row)
        controller.rowSwipeChanged(30)

        let pan = ScriptedPan()
        pan.scriptedVelocity = CGPoint(x: 0, y: 300)
        #expect(!controller.gestureRecognizerShouldBegin(pan))
        controller.rowSwipeEnded(velocity: 0)
        #expect(controller.gestureRecognizerShouldBegin(pan))
        window.isHidden = true
    }

    @Test func onlyStoredRecentsSwipe() {
        let (controller, window) = risen()
        #expect(controller.recentRow(at: CGPoint(x: 10, y: SearchSheet.fieldSlotHeight / 2)) == nil)
        #expect(controller.recentRow(at: onRow(2, of: controller)) == nil)
        controller.model.text = "a"
        controller.model.textChanged(appending: false)
        #expect(controller.recentRow(at: onRow(0, of: controller)) == nil)
        window.isHidden = true
    }
}
