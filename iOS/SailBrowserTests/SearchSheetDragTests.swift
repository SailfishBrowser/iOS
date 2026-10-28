import Testing
import UIKit
@testable import SailBrowser

private final class ScriptedPan: UIPanGestureRecognizer {
    var scriptedVelocity = CGPoint.zero

    override func velocity(in view: UIView?) -> CGPoint { scriptedVelocity }
}

// Each test focuses its own sheet's field; run in parallel they take the one first responder from each other.
@MainActor @Suite(.serialized)
struct SearchSheetDragTests {
    private func risen(_ env: AppEnvironment = makeEnvironment()) -> (SearchSheetController, UIWindow) {
        let (controller, window) = hostedSearchSheet(env)
        controller.view.layoutIfNeeded()
        return (controller, window)
    }

    private func firstList(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.firstList(in: $0) }.first
    }

    @Test func aDownwardDragMovesTheSheetAndTheListCannotScroll() {
        let (controller, window) = risen()
        #expect(!firstList(in: controller.container)!.isScrollEnabled)

        let pan = ScriptedPan()
        pan.scriptedVelocity = CGPoint(x: 4, y: 300)
        #expect(controller.gestureRecognizerShouldBegin(pan))

        controller.dragBegan()
        let top = controller.container.frame.minY
        controller.dragChanged(64)
        #expect(abs(controller.container.frame.minY - (top + 64)) < 0.5)
        window.isHidden = true
    }

    @Test func theBarUncoversInTheSameCallThatHidesTheSheet() async throws {
        let (controller, window) = risen()
        let ui = controller.env.ui
        #expect(ui.isSearchCoveringBar)
        #expect(!controller.container.isHidden)
        let atUncover = SheetAtUncover(container: controller.container)
        withObservationTracking {
            _ = ui.isSearchCoveringBar
        } onChange: {
            MainActor.assumeIsolated { atUncover.sheetHidden = atUncover.container.isHidden }
        }
        controller.setActive(false, submitting: true)
        try await waitUntil { !ui.isSearchCoveringBar }
        #expect(atUncover.sheetHidden == true)
        window.isHidden = true
    }

    // A finger on the sheet holds a presence for exactly as long as it is down; the release's motion holds for its
    // settling time, and a close arriving mid-drag leaves nothing held.
    @Test func aDragHoldsAPresenceOnlyWhileTheFingerIsDown() async throws {
        let slack = 1 / Theme.Latency.frameRate
        let m = Theme.Motion.self
        let guide = makeEnvironment()
        guide.browser.settings.autoOpenKeyboard = false
        var (controller, window) = risen(guide)
        await nextDisplayFrame()
        controller.dragBegan()
        #expect(controller.presence != nil)
        controller.dragChanged(40)
        var now = CACurrentMediaTime()
        controller.dragEnded(translation: 40, velocity: 0)
        #expect(controller.presence == nil)
        #expect(FrameRateVote.heldUntil >= now + max(m.searchReturn.settlingDuration, MotionToken.keyboard.settlingDuration) - slack)
        controller.dragBegan()
        controller.dragCancelled()
        #expect(controller.presence == nil)
        window.isHidden = true

        (controller, window) = risen()
        try await waitUntil { controller.keyboardShown }
        controller.dragBegan()
        controller.dragChanged(40)
        now = CACurrentMediaTime()
        controller.dragEnded(translation: 40, velocity: 0)
        #expect(controller.presence == nil)
        #expect(FrameRateVote.heldUntil >= now + m.searchReturn.settlingDuration - slack)
        controller.dragBegan()
        controller.dragChanged(300)
        now = CACurrentMediaTime()
        controller.dragEnded(translation: 300, velocity: 900)
        #expect(controller.presence == nil)
        let release = max(m.searchReleaseClose.settlingDuration, Double(m.searchReleaseCloseFrames) * m.searchCloseFrame)
        #expect(FrameRateVote.heldUntil >= now + release - slack)
        try await waitUntil { controller.container.isHidden }
        window.isHidden = true

        (controller, window) = risen()
        await nextDisplayFrame()
        controller.dragBegan()
        controller.setActive(false, submitting: false)
        try await waitUntil { controller.container.isHidden }
        #expect(controller.presence == nil)
        #expect(controller.rowPresence == nil)
        window.isHidden = true
    }

    @Test func theBarCoverBelongsToTheSheetsOwnEnvironment() {
        let (controller, window) = risen()
        #expect(controller.env.ui.isSearchCoveringBar)
        #expect(!makeEnvironment().ui.isSearchCoveringBar)
        window.isHidden = true
    }

    // A grab inside the open's first 50 ms takes the sheet where it is drawn, with no settle first, and is recorded as a
    // grab during the open. The keyboard stays with the field.
    @Test(.timeLimit(.minutes(1)), .timingSensitive)
    func aGrabEarlyInTheOpenTakesTheDrawnSheetAndKeepsTheKeyboard() async throws {
        let (controller, window) = risen()
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(30))
        let drawnTop = controller.container.layer.presentation()!.frame.minY
        controller.dragBegan()
        controller.dragChanged(0)
        #expect(abs(controller.container.frame.minY - drawnTop) < 2)
        #expect(controller.container.layer.animationKeys() == nil)
        #expect(controller.field.isFirstResponder)
        #expect(controller.env.haptics.records.last?.interaction == .searchGrabDuringOpen)
        controller.dragChanged(40)
        #expect(abs(controller.container.frame.minY - drawnTop - 40) < 2)
        #expect(controller.field.isFirstResponder)
        window.isHidden = true
    }

    // A swipe on the suggestions during the open reaches the sheet's pan: the touch lands inside the sheet where it is
    // drawn, and the pan runs alongside the rows' own recognizers instead of waiting for them to fail.
    // The touch waits until the open has drawn the first rows on screen.
    @Test func aSwipeOnTheSuggestionsDuringTheOpenReachesTheSheetsPan() async throws {
        let (controller, window) = risen()
        let rowsBelowTop = Theme.Metrics.searchSheetTopPadding + Theme.Metrics.searchFieldHeight
            + Theme.Metrics.suggestionRowHeight
        try await waitUntil {
            controller.container.layer.presentation()!.frame.minY + rowsBelowTop < controller.view.bounds.height
        }
        let drawn = controller.container.layer.presentation()!.frame
        let onRows = CGPoint(x: drawn.midX, y: drawn.minY + rowsBelowTop)
        let hit = try #require(controller.view.hitTest(onRows, with: nil))
        #expect(hit.isDescendant(of: controller.container))
        let pan = try #require(controller.container.gestureRecognizers?.first { $0 is UIPanGestureRecognizer })
        let rowPress = UILongPressGestureRecognizer()
        rowPress.minimumPressDuration = 0
        hit.addGestureRecognizer(rowPress)
        #expect(controller.gestureRecognizer(pan, shouldRecognizeSimultaneouslyWith: rowPress))
        #expect(pan.cancelsTouchesInView)
        window.isHidden = true
    }

    // A pan that begins on a row cancels the row's press (and anything else tracking that touch), so a drag that starts
    // on a suggestion never ends in its tap; the pan itself keeps going.
    // The open has settled, so the sheet is drawn where its model is.
    @Test func aPanBeginningOnARowCancelsTheRowsPress() async throws {
        let (controller, window) = risen()
        try await waitUntil { controller.hostView.drawnTarget == nil }
        let onRows = controller.container.convert(
            CGPoint(x: controller.container.bounds.midX, y: Theme.Metrics.searchSheetTopPadding
                + Theme.Metrics.searchFieldHeight + Theme.Metrics.suggestionRowHeight), to: controller.view)
        let hit = try #require(controller.view.hitTest(onRows, with: nil))
        #expect(hit.isDescendant(of: controller.container))
        let press = TrackingPress()
        hit.addGestureRecognizer(press)
        let pan = try #require(controller.container.gestureRecognizers?.first { $0 is UIPanGestureRecognizer })
        controller.cancelTouchSharers(from: hit, keeping: pan)
        #expect(press.cancelled)
        #expect(press.isEnabled)
        #expect(pan.isEnabled)
        window.isHidden = true
    }

    // A pan that begins in the field cancels the field's own recognizers too, so the drag moves the sheet and leaves the
    // caret and the selection where they were.
    @Test func aPanBeginningInTheFieldCancelsItsSelectionAndKeepsTheCaret() async throws {
        let (controller, window) = risen()
        try await waitUntil { controller.hostView.drawnTarget == nil }
        let field = controller.field
        field.text = "sail search"
        let caret = field.position(from: field.beginningOfDocument, offset: 3)!
        field.selectedTextRange = field.textRange(from: caret, to: caret)
        let inField = field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: controller.view)
        let hit = try #require(controller.view.hitTest(inField, with: nil))
        #expect(hit.isDescendant(of: field))
        let selection = TrackingPress()
        hit.addGestureRecognizer(selection)
        let pan = try #require(controller.container.gestureRecognizers?.first { $0 is UIPanGestureRecognizer })
        controller.cancelTouchSharers(from: hit, keeping: pan)
        #expect(selection.cancelled)
        let range = try #require(field.selectedTextRange)
        #expect(field.offset(from: field.beginningOfDocument, to: range.start) == 3)
        #expect(range.isEmpty)
        controller.dragBegan()
        controller.dragChanged(60)
        #expect(controller.container.transform.ty > 50)
        window.isHidden = true
    }

    // A touch that lands on the field's bottom edge and moves down has left the field by the time the pan is detected,
    // about 10 pt on. The cancel starts from the view the touch landed on, so the field's selection is still cancelled.
    @Test func aPanFromTheFieldsBottomEdgeCancelsItsSelection() async throws {
        let (controller, window) = risen()
        try await waitUntil { controller.hostView.drawnTarget == nil }
        let field = controller.field
        let edge = field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.maxY - 1), to: controller.view)
        let hit = try #require(controller.view.hitTest(edge, with: TouchEvent()))
        #expect(hit.isDescendant(of: field))
        #expect(controller.hostView.touchedDown === hit)
        let detected = CGPoint(x: edge.x, y: edge.y + 10)
        #expect(controller.view.hitTest(detected, with: nil)?.isDescendant(of: field) != true)
        let selection = TrackingPress()
        hit.addGestureRecognizer(selection)
        let pan = try #require(controller.container.gestureRecognizers?.first { $0 is UIPanGestureRecognizer })
        controller.cancelTouchSharers(from: controller.hostView.touchedDown, keeping: pan)
        #expect(selection.cancelled)
        window.isHidden = true
    }

    // A closing sheet can be grabbed back whichever way the finger goes; a submitted one is gone.
    @Test func aClosingSheetTakesAVerticalDragEitherWayAndASubmittingOneNone() {
        let (controller, window) = risen()
        let pan = ScriptedPan()
        controller.setActive(false, submitting: false)
        for y: CGFloat in [300, -300] {
            pan.scriptedVelocity = CGPoint(x: 0, y: y)
            #expect(controller.gestureRecognizerShouldBegin(pan))
        }
        pan.scriptedVelocity = CGPoint(x: 300, y: 100)
        #expect(!controller.gestureRecognizerShouldBegin(pan))
        window.isHidden = true
        let (submitting, other) = risen()
        submitting.setActive(false, submitting: true)
        pan.scriptedVelocity = CGPoint(x: 0, y: 300)
        #expect(!submitting.gestureRecognizerShouldBegin(pan))
        other.isHidden = true
    }

    private func tappedClose() async throws -> (AppEnvironment, SearchSheetController, UIWindow, CFTimeInterval) {
        let env = makeEnvironment()
        #expect(env.ui.open(.search, animated: false))
        let (controller, window) = risen(env)
        try await waitUntil { controller.keyboardShown }
        controller.setActive(false, submitting: false)
        env.ui.close(animated: false)
        let begin = try #require(controller.container.layer.animation(forKey: "transform")).beginTime
        return (env, controller, window, begin)
    }

    // A grab at 30, 60 or 90 percent of a tapped close takes the sheet where it is drawn: the top and the field hold
    // with no jump, the close's motion and hand-off end, and easing it back up reopens search.
    @Test(.timeLimit(.minutes(1)), .timingSensitive, arguments: [0.3, 0.6, 0.9])
    func aGrabDuringATappedCloseTakesTheSheetWhereItIsDrawn(_ fraction: Double) async throws {
        let (env, controller, window, begin) = try await tappedClose()
        let at = begin + fraction * Double(Theme.Motion.searchTapCloseFrames) * Theme.Motion.searchCloseFrame
        try await waitUntil(timeout: .seconds(1)) { CACurrentMediaTime() >= at }
        let drawnTop = controller.container.layer.presentation()!.frame.minY
        let drawnWidth = controller.capsule.layer.presentation()!.bounds.width
        controller.dragBegan()
        controller.dragChanged(0)
        #expect(abs(controller.container.frame.minY - drawnTop) < 2)
        #expect(abs(controller.capsule.bounds.width - drawnWidth) < 2)
        #expect(controller.container.layer.animationKeys() == nil)
        #expect(controller.capsule.layer.animationKeys() == nil)
        try await Task.sleep(for: .milliseconds(450))
        #expect(!controller.container.isHidden)
        let reach = controller.container.frame.minY - controller.restTop!
        controller.dragChanged(-reach)
        controller.dragEnded(translation: -reach, velocity: 0)
        #expect(env.ui.overlay == .search)
        let full = controller.view.bounds.width - 2 * Theme.Metrics.searchFieldInset
        try await waitUntil(timeout: .seconds(2)) {
            abs(controller.capsule.layer.presentation()!.bounds.width - full) < 0.5
                && abs(controller.container.layer.presentation()!.frame.minY - controller.restTop!) < 0.5
        }
        window.isHidden = true
    }

    // During a close the sheet's model is already at the bar; touches go by where it is drawn. The drawn pill opens
    // search on touch-down, as "+" does, and the rest of the drawn sheet is there to grab.
    @Test(.timeLimit(.minutes(1)), .timingSensitive)
    func aTouchOnTheDrawnPillDuringACloseOpensSearch() async throws {
        let (env, controller, window, begin) = try await tappedClose()
        try await waitUntil(timeout: .seconds(1)) { CACurrentMediaTime() >= begin + 10 * Theme.Motion.searchCloseFrame }
        let sheet = controller.container.layer.presentation()!.frame
        let pill = controller.capsule.layer.presentation()!.frame.offsetBy(dx: sheet.minX, dy: sheet.minY)
        #expect(controller.view.hitTest(CGPoint(x: sheet.midX, y: sheet.minY + 4), with: nil) === controller.container)
        #expect(controller.view.hitTest(CGPoint(x: sheet.midX, y: sheet.minY - 20), with: nil) == nil)
        let barTop = window.bounds.height - Theme.Metrics.barTotalHeight
        // Early in the close the sheet is still far above the bar: a touch on the bar's strip grabs the sheet.
        #expect(controller.view.hitTest(CGPoint(x: 30, y: barTop + 10), with: nil) === controller.container)
        let target = try #require(controller.view.hitTest(CGPoint(x: pill.midX, y: pill.midY), with: nil) as? UIControl)
        target.sendActions(for: .touchDown)
        #expect(env.ui.overlay == .search)
        #expect(env.haptics.records.last?.interaction == .plusTap)
        window.isHidden = true
    }

    // A return waits for the keyboard only once its rest is known; before that the sheet rides the keyboard itself.
    @Test func everyWayOutForgetsAReturnsPendingReattach() async throws {
        for submitting in [false, true] {
            let (controller, window) = risen()
            try await waitUntil { controller.restTop != nil }
            controller.dragBegan()
            controller.dragEnded(translation: 10, velocity: 0)
            #expect(controller.attachesWhenKeyboardShown)
            controller.setActive(false, submitting: submitting)
            #expect(!controller.attachesWhenKeyboardShown)
            window.isHidden = true
        }
    }

    // A release closes on the release spring from its first frame, the field collapsing at once.
    @Test(.timeLimit(.minutes(1)))
    func aDismissingReleaseClosesOnTheReleaseSpringFromItsFirstFrame() async throws {
        let (controller, window) = risen()
        try await waitUntil { controller.keyboardShown }
        controller.dragBegan()
        controller.dragChanged(240)
        controller.dragEnded(translation: 240, velocity: 1500)
        let m = Theme.Motion.self
        let close = try #require(controller.container.layer.animation(forKey: "transform") as? CASpringAnimation)
        #expect(abs(close.stiffness - m.searchReleaseClose.spring.stiffness) < 1e-6)
        #expect(close.initialVelocity == m.searchReleaseCloseVelocity)
        let capsule = controller.capsule.layer
        for key in capsule.animationKeys() ?? [] {
            #expect(abs(capsule.animation(forKey: key)!.beginTime - close.beginTime) < 1e-3)
        }
        window.isHidden = true
    }

    // A closed sheet whose field is focused again, as when a resign inside the keyboard's show did not take.
    private func closedButFocused() async throws -> (SearchSheetController, UIWindow, SearchField) {
        let (controller, window) = risen()
        try await waitUntil { controller.keyboardShown }
        controller.setActive(false, submitting: false)
        try await waitUntil { controller.container.isHidden }
        let field = try #require(controller.view.firstSearchField())
        #expect(field.becomeFirstResponder())
        return (controller, window, field)
    }

    @Test(.timeLimit(.minutes(1)))
    func anOpenBetweenTheShowAndItsResignKeepsTheFieldFocused() async throws {
        let (controller, window, field) = try await closedButFocused()
        NotificationCenter.default.post(name: UIResponder.keyboardDidShowNotification, object: nil)
        controller.setActive(true, submitting: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(field.isFirstResponder)
        window.isHidden = true
    }

    @Test(.timeLimit(.minutes(1)), .timingSensitive)
    func aFieldStillFocusedWhenTheSheetHidesIsRecoveredThere() async throws {
        let (controller, window) = risen()
        try await waitUntil { controller.keyboardShown }
        let field = try #require(controller.view.firstSearchField())
        controller.setActive(false, submitting: false)
        let begin = try #require(controller.container.layer.animation(forKey: "transform")).beginTime
        try await waitUntil(timeout: .seconds(1)) { CACurrentMediaTime() >= begin + 8 * Theme.Motion.searchCloseFrame }
        #expect(!field.isFirstResponder)
        // Focused again late in the close, as after a resign that did not take; the controller is told no show is
        // in flight, so only the hide itself can recover it before the real show ends.
        let showing = Task {
            for await _ in NotificationCenter.default.notifications(named: UIResponder.keyboardWillShowNotification) {
                return
            }
        }
        #expect(field.becomeFirstResponder())
        await showing.value
        NotificationCenter.default.post(
            name: UIResponder.keyboardWillHideNotification, object: nil,
            userInfo: [UIResponder.keyboardAnimationDurationUserInfoKey: Theme.Motion.keyboardDuration])
        #expect(!controller.container.isHidden)
        try await waitUntil(timeout: .seconds(1)) { controller.container.isHidden }
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        await afterTheCommit()
        #expect(!field.isFirstResponder)
        window.isHidden = true
    }

    @Test func upwardOrSidewaysDragsAreNotTheSheets() {
        let (controller, window) = risen()
        let pan = ScriptedPan()
        pan.scriptedVelocity = CGPoint(x: 0, y: -300)
        #expect(!controller.gestureRecognizerShouldBegin(pan))
        pan.scriptedVelocity = CGPoint(x: 300, y: 100)
        #expect(!controller.gestureRecognizerShouldBegin(pan))
        window.isHidden = true
    }

    @Test func aDragDuringTheRiseTakesTheSheetFromWhereItIsDrawn() {
        let (controller, window) = risen()
        CATransaction.flush()
        let drawn = controller.container.layer.presentation()?.frame.minY ?? controller.container.frame.minY
        controller.dragBegan()
        #expect(controller.container.layer.animationKeys() == nil)
        #expect(abs(controller.container.frame.minY - drawn) < 1)
        controller.dragChanged(20)
        #expect(abs(controller.container.frame.minY - (drawn + 20)) < 1)
        window.isHidden = true
    }

    private func released(after path: [CGFloat]) -> (AppEnvironment, UIState.Overlay) {
        let env = makeEnvironment()
        #expect(env.ui.open(.search, animated: false))
        let (controller, window) = risen(env)
        controller.dragBegan()
        for translation in path {
            controller.dragChanged(translation)
        }
        controller.dragEnded(translation: path.last!, velocity: 0)
        window.isHidden = true
        return (env, env.ui.overlay)
    }

    // These drags start inside the open, which records the grab itself before the release.
    private func drags(_ env: AppEnvironment) -> [HapticRecord] {
        env.haptics.records.filter { $0.interaction != .searchGrabDuringOpen }
    }

    @Test func easedBackStillCloses() {
        #expect(released(after: [85, 75]).1 == .none)
        let (env, overlay) = released(after: [85, 71])
        #expect(overlay == .search)
        #expect(drags(env).map(\.interaction) == [.searchDragReturn])
        #expect(drags(env).map(\.played) == [false])
        #expect(released(after: [79]).1 == .search)
    }

    @Test func upwardDragStretchesBelowLimit() {
        let (controller, window) = risen()
        controller.dragBegan()
        controller.dragChanged(-300)
        let lift = controller.container.transform.ty
        #expect(lift > -Theme.Gesture.sheetStretch && lift < -40)
        window.isHidden = true
    }

    @Test func dismissIsSilent() {
        let (env, overlay) = released(after: [40, 120, 140])
        #expect(overlay == .none)
        #expect(drags(env).map(\.interaction) == [.searchDragDismiss])
        #expect(drags(env).map(\.played) == [false])
    }

    // Return records at Return, not at adoption, and plays nothing: Enter is silent.
    @Test func submitRecordsAtReturnNotAtAdoption() {
        let env = makeEnvironment()
        #expect(env.ui.open(.search, animated: false))
        let (controller, window) = risen(env)
        controller.model.text = "example.com"
        _ = controller.textFieldShouldReturn(controller.field)
        #expect(env.haptics.records.map(\.interaction) == [.searchSubmit])
        #expect(env.haptics.records.map(\.played) == [false])
        let atReturn = env.haptics.records
        env.ui.submitHidden()
        #expect(env.haptics.records == atReturn)

        #expect(env.ui.open(.search, animated: false))
        controller.model.text = "   "
        _ = controller.textFieldShouldReturn(controller.field)
        #expect(env.haptics.records.count == 1)
        window.isHidden = true
    }

    @Test func theClearButtonFiresSearchClear() {
        let env = makeEnvironment()
        let (controller, window) = risen(env)
        controller.field.text = "abc"
        controller.field.sendActions(for: .editingChanged)
        (controller.field.rightView as! UIButton).sendActions(for: .primaryActionTriggered)
        #expect(env.haptics.records.map(\.interaction) == [.searchClear])
        window.isHidden = true
    }

    // The clear button's touch-down prepares its tap. Return (Enter) is silent, so typing prepares nothing.
    @Test func theClearButtonIsPreparedBeforeItPlaysAndReturnIsSilent() {
        let sink = RecordingHapticSink(start: .now)
        let env = makeEnvironment(hapticSink: sink)
        let (controller, window) = risen(env)
        let medium = Theme.Haptic.medium
        sink.advance(by: Theme.Haptic.preparedFor)
        let before = sink.calls.count
        controller.field.text = "abc"
        controller.field.sendActions(for: .editingChanged)
        #expect(sink.calls.count == before)
        sink.advance(by: Theme.Haptic.preparedFor)
        let clear = controller.field.rightView as! UIButton
        clear.sendActions(for: .touchDown)
        #expect(sink.calls.last == .prepare(medium))
        clear.sendActions(for: .primaryActionTriggered)
        #expect(sink.played == [medium])
        sink.advance(by: Theme.Latency.frame)
        controller.model.text = "example.com"
        _ = controller.textFieldShouldReturn(controller.field)
        let submit = env.haptics.records.filter { $0.interaction == .searchSubmit }
        #expect(submit.count == 1)
        #expect(submit.compactMap(\.event).isEmpty)
        #expect(sink.played == [medium])
        #expect(sink.playsArePrepared)
        window.isHidden = true
    }

    @Test func debugActionsRunTheSearchControls() {
        let env = makeEnvironment()
        #expect(env.ui.open(.search, animated: false))
        let (controller, window) = risen(env)
        env.debugActions[.searchTyping]!()
        #expect(controller.field.text?.isEmpty == false)
        env.debugActions[.searchClear]!()
        #expect(controller.field.text == "")
        env.debugActions[.searchSubmit]!()
        env.ui.submitHidden()
        #expect(env.ui.open(.search, animated: false))
        controller.model.text = "example"
        controller.model.textChanged(appending: true)
        env.debugActions[.suggestionTap]!()
        #expect(env.haptics.records.map(\.interaction) == [.searchClear, .searchSubmit, .suggestionTap])
        #expect(env.debugWatches[.searchSheet] != nil)
        window.isHidden = true
    }

    // The searchClear driver types, waits for the button, then clears, so the watch has a hide to see.
    @Test func clearButtonWatchShowsOverTypedTextAndHidesOnClear() async throws {
        let env = makeEnvironment()
        #expect(env.ui.open(.search, animated: false))
        let (_, window) = risen(env)
        let shown = env.debugWatches[.clearButton]!
        try await waitUntil { shown() == 0 }
        env.debugActions[.searchTyping]!()
        try await waitUntil { shown() == 1 }
        env.debugActions[.searchClear]!()
        try await waitUntil { shown() == 0 }
        #expect(env.haptics.records.map(\.interaction) == [.searchClear])
        window.isHidden = true
    }

    @Test func searchDriversCoverTheSearchInteractions() {
        #expect(Set(SearchDrivers.table.keys) == [
            .searchDragDismiss, .searchDragReturn, .searchSubmit, .suggestionTap, .searchClear, .searchDimTap,
            .searchGrabDuringOpen,
        ])
    }
}

@MainActor
private final class SheetAtUncover {
    let container: UIView
    var sheetHidden: Bool?

    init(container: UIView) {
        self.container = container
    }
}

// Stands for a row's press or the field's selection, and records being disabled, which UIKit documents as cancelling
// a recognizer that is tracking a touch.
final class TrackingPress: UIGestureRecognizer {
    private(set) var cancelled = false

    override var isEnabled: Bool {
        didSet {
            if !isEnabled {
                cancelled = true
            }
        }
    }
}
