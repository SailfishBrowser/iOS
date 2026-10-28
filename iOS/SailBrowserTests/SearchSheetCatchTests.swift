import Testing
import UIKit
@testable import SailBrowser

// A rising sheet is caught where it is drawn: touches go by its drawn frame, and a touch-down holds it there.
// Each test focuses its own sheet's field; run in parallel they take the one first responder from each other.
@MainActor @Suite(.serialized)
struct SearchSheetCatchTests {
    // The keyboard has shown once, which teaches the sheet its rest; the next open is an empty field's, which springs
    // ahead of the keyboard from the bar to that rest.
    private func knowingTheKeyboard() async throws -> (SearchSheetController, UIWindow, CGFloat) {
        let env = makeEnvironment()
        for (url, title) in [("https://github.com/", "GitHub"), ("https://apple.com/", "Apple")] {
            env.history.recordVisit(url: URL(string: url)!, title: title)
        }
        let (controller, window) = hostedSearchSheet(env)
        controller.view.layoutIfNeeded()
        try await waitUntil { controller.restTop != nil && controller.keyboardShown }
        let rest = controller.restTop!
        controller.setActive(false, submitting: false)
        try await waitUntil { controller.container.isHidden }
        return (controller, window, rest)
    }

    private func drawnTop(_ controller: SearchSheetController) -> CGFloat {
        controller.container.layer.presentation()!.frame.minY
    }

    // Opens the sheet and returns once its drawn top has covered `fraction` of the way from the bar to its rest, and no
    // more than 80% of it. The open runs on a held clock moved on a quarter of a 60 Hz frame per read, so the poll cannot
    // miss the band however late its turn comes; the clock then runs on in real time from there.
    private func openedTo(_ fraction: CGFloat) async throws -> (SearchSheetController, UIWindow, CGFloat) {
        let (controller, window, rest) = try await knowingTheKeyboard()
        let barTop = window.bounds.height - Theme.Metrics.barTotalHeight
        let clock = HeldClock(window.layer)
        controller.setActive(true, submitting: false)
        CATransaction.flush()
        let start = clock.now
        while barTop - drawnTop(controller) < fraction * (barTop - rest) {
            try #require(clock.now - start < 1)
            await afterTheCommit()
            clock.step(by: 1.0 / 240)
        }
        #expect(barTop - drawnTop(controller) < 0.8 * (barTop - rest))
        clock.resume()
        return (controller, window, rest)
    }

    @Test func theCatchIsATouchDownThatRunsAlongsideThePanAndTheRows() async throws {
        let (controller, window, _) = try await openedTo(0.3)
        let press = controller.catcher
        #expect(press.minimumPressDuration == 0)
        #expect(!press.cancelsTouchesInView)
        #expect(press.view === controller.container)
        let pan = try #require(controller.container.gestureRecognizers?.first { $0 is UIPanGestureRecognizer })
        #expect(controller.gestureRecognizer(press, shouldRecognizeSimultaneouslyWith: pan))
        #expect(controller.gestureRecognizer(press, shouldRecognizeSimultaneouslyWith: UITapGestureRecognizer()))
        // It sees only a touch whose hit test caught the sheet.
        #expect(!controller.gestureRecognizerShouldBegin(press))
        let sheet = controller.container.layer.presentation()!.frame
        let touched = controller.view.hitTest(CGPoint(x: sheet.midX, y: sheet.minY + 10), with: TouchEvent())
        #expect(controller.gestureRecognizerShouldBegin(press))
        // A beginning pan cancels what shares its touch, but not the catch, which would re-rise the sheet it takes.
        let toggled = Count()
        let observation = press.observe(\.isEnabled) { _, _ in MainActor.assumeIsolated { toggled.value += 1 } }
        controller.cancelTouchSharers(from: touched, keeping: pan)
        #expect(toggled.value == 0)
        // The observation does see a toggle.
        press.isEnabled = false
        press.isEnabled = true
        observation.invalidate()
        #expect(toggled.value == 2)
        window.isHidden = true
    }

    // Today the sheet keeps rising under the finger until the pan begins.
    @Test(.timeLimit(.minutes(1)), arguments: [0.3, 0.6] as [CGFloat])
    func aTouchDownMidOpenHoldsTheSheetWhereItIsDrawn(_ fraction: CGFloat) async throws {
        let (controller, window, _) = try await openedTo(fraction)
        let sheet = controller.container.layer.presentation()!.frame
        let pill = controller.capsule.layer.presentation()!.frame
        let onField = CGPoint(x: sheet.minX + pill.midX, y: sheet.minY + pill.midY)
        let hit = try #require(controller.view.hitTest(onField, with: TouchEvent()))
        #expect(hit.isDescendant(of: controller.capsule))
        #expect(abs(controller.container.frame.minY - sheet.minY) < 0.5)
        try await Task.sleep(for: .milliseconds(20))
        #expect(abs(drawnTop(controller) - sheet.minY) < 0.5)
        #expect(controller.field.isFirstResponder)
        window.isHidden = true
    }

    // The rows are one SwiftUI host, which resolves a press from the touch's place in it. The touch's own hit test holds
    // the sheet, so by the time the host reads the touch it sits on the drawn second row, never a lower one.
    private func touchesTheDrawnSecondRow(_ controller: SearchSheetController) throws {
        #expect(controller.model.rows.count >= 2)
        let rowHeight = Theme.Metrics.suggestionRowHeight
        let sheet = controller.container.layer.presentation()!.frame
        let onRow = CGPoint(x: sheet.midX, y: sheet.minY + SearchSheet.fieldSlotHeight + 1.5 * rowHeight)
        let hit = try #require(controller.view.hitTest(onRow, with: TouchEvent()))
        #expect(hit.isDescendant(of: controller.sheet.view))
        let inSheet = controller.sheet.view.convert(onRow, from: controller.view).y
        let row = Int(((inSheet - SearchSheet.fieldSlotHeight) / rowHeight).rounded(.down))
        #expect(row == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func aTouchOnTheDrawnSecondRowMidOpenLandsOnThatRow() async throws {
        let (controller, window, _) = try await openedTo(0.5)
        try touchesTheDrawnSecondRow(controller)
        window.isHidden = true
    }

    // An open during a close rises from where the close has drawn the sheet; its rows are caught where drawn too.
    @Test(.timeLimit(.minutes(1)), .timingSensitive)
    func aTouchOnTheDrawnSecondRowMidReopenLandsOnThatRow() async throws {
        let (controller, window, rest) = try await knowingTheKeyboard()
        let barTop = window.bounds.height - Theme.Metrics.barTotalHeight
        controller.setActive(true, submitting: false)
        try await waitUntil { controller.container.layer.animationKeys() == nil && controller.keyboardShown }
        controller.setActive(false, submitting: false)
        try await waitUntil(timeout: .seconds(1)) { drawnTop(controller) > rest + 0.7 * (barTop - rest) }
        controller.setActive(true, submitting: false)
        CATransaction.flush()
        try await waitUntil(timeout: .seconds(1)) { drawnTop(controller) < rest + 0.5 * (barTop - rest) }
        #expect(drawnTop(controller) > rest + 0.1 * (barTop - rest))
        try touchesTheDrawnSecondRow(controller)
        window.isHidden = true
    }

    // Between the rest top and the drawn top there is no sheet yet: the touch goes to the dim behind, which closes it.
    @Test(.timeLimit(.minutes(1)))
    func aTouchAboveTheDrawnSheetMidOpenGoesBehindIt() async throws {
        let (controller, window, rest) = try await openedTo(0.5)
        let above = CGPoint(x: controller.view.bounds.midX, y: (rest + drawnTop(controller)) / 2)
        #expect(controller.view.hitTest(above, with: TouchEvent()) == nil)
        #expect(controller.container.layer.animationKeys() != nil)
        window.isHidden = true
    }

    @Test(.timeLimit(.minutes(1)))
    func aCatchLetGoWithoutMovingRisesToRestWithTheFieldFocused() async throws {
        let (controller, window, rest) = try await openedTo(0.5)
        let sheet = controller.container.layer.presentation()!.frame
        _ = controller.view.hitTest(CGPoint(x: sheet.midX, y: sheet.minY + 10), with: TouchEvent())
        controller.catchEnded()
        try await waitUntil(timeout: .seconds(2)) {
            controller.container.layer.animationKeys() == nil && abs(drawnTop(controller) - rest) < 0.5
        }
        #expect(controller.field.isFirstResponder)
        #expect(controller.view.hitTest(CGPoint(x: controller.view.bounds.midX, y: rest - 20), with: nil) == nil)
        window.isHidden = true
    }

    // Before the keyboard's first show its guide sits at the bottom of the screen. A catch then learns no rest from it:
    // let go, the sheet rides the keyboard up and rests on it with no step. The window's animation clock is held and moved
    // on one 60 Hz frame per read, so a late turn under load never merges two frames into one step.
    @Test(.timeLimit(.minutes(1)))
    func aCatchBeforeTheFirstKeyboardRidesTheKeyboardUpWithNoStep() async throws {
        let (controller, window) = hostedSearchSheet()
        controller.view.layoutIfNeeded()
        CATransaction.flush()
        #expect(!controller.keyboardShown)
        controller.catchBegan()
        #expect(controller.restTop == nil)
        let clock = HeldClock(window.layer)
        controller.catchEnded()
        var tops = [drawnTop(controller)]
        while !(controller.keyboardShown && HeldClock.hasEnded(controller.container.layer)) {
            try await Task.sleep(for: .milliseconds(16))
            clock.step()
            tops.append(drawnTop(controller))
        }
        let guideTop = controller.view.keyboardLayoutGuide.layoutFrame.minY - Theme.Metrics.searchSheetAboveKeyboard
        let rest = try #require(controller.restTop)
        #expect(abs(rest - guideTop) < 0.5)
        #expect(abs(drawnTop(controller) - rest) < 0.5)
        // The keyboard ride moves up to about 70 pt in a 60 Hz frame; the step this guards against is a keyboard height.
        let steps = zip(tops, tops.dropFirst()).map { abs($1 - $0) }
        #expect(
            steps.max()! < controller.view.keyboardLayoutGuide.layoutFrame.height / 2,
            "\(tops.map { Int($0.rounded()) })")
        // Back on real time, a late keyboard event, such as a re-capture on a frame change, leaves the sheet at rest.
        clock.resume()
        try await waitUntil { controller.container.layer.animationKeys() == nil }
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(drawnTop(controller) - rest) < 0.5)
        window.isHidden = true
    }
}

@MainActor final class Count {
    var value = 0
}
