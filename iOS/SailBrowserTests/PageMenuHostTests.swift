import SwiftUI
import Testing
import UIKit
@testable import SailBrowser

@MainActor @Suite(.serialized)
struct PageMenuHostTests {
    private func opened(_ env: AppEnvironment = makeEnvironment()) -> (PageMenuController, UIWindow) {
        env.open(page("a"))
        return hosted(env)
    }

    // The menu hosted as the root of its own key window over the environment's active page, and opened.
    private func hosted(_ env: AppEnvironment) -> (PageMenuController, UIWindow) {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let controller = PageMenuController(env: env)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        #expect(env.ui.open(.menu))
        controller.setOpen(true)
        return (controller, window)
    }

    private func settled(_ env: AppEnvironment = makeEnvironment()) async throws -> (PageMenuController, UIWindow) {
        let (controller, window) = opened(env)
        try await waitUntil { controller.container.layer.animationKeys() == nil && controller.motion == nil }
        return (controller, window)
    }

    private func drawnOffset(_ controller: PageMenuController) -> CGFloat {
        controller.container.layer.presentation()!.affineTransform().ty
    }

    private func dimAlpha(_ controller: PageMenuController, at offset: CGFloat) -> CGFloat {
        Theme.Opacity.menuDim * (1 - offset / controller.sheetHeight)
    }

    private func closeByTap(_ controller: PageMenuController) {
        controller.env.ui.close()
        controller.setOpen(false)
    }

    // Core Animation still runs a spring's completion once the menu that started it is gone; it leaves the menu alone.
    // The menu's time is held from the close and stepped a frame at a time through its settling time once the menu is
    // gone, then the end already passed is delivered.
    @Test(.timeLimit(.minutes(1)))
    func aMenuFreedMidCloseRunsNoCompletionOnIt() async throws {
        weak var freed: PageMenuController?
        let clock: HeldClock
        let sheet: CALayer
        do {
            let (controller, window) = try await settled()
            freed = controller
            clock = HeldClock(controller.view.layer)
            sheet = controller.container.layer
            closeByTap(controller)
            window.rootViewController = nil
            window.isHidden = true
        }
        try await waitUntil { freed == nil }
        clock.step(by: Theme.Motion.menuClose.settlingDuration)
        clock.creep()
        try await waitUntil { sheet.animationKeys() == nil }
        await afterTheCommit()
    }

    // Partway up, a touch on the drawn sheet reaches it and a touch above it, where the model already is, is dim.
    // Partway down, a touch on the drawn sheet, above where the model already is, still reaches the sheet.
    @Test(.timeLimit(.minutes(1)))
    func touchesGoByWhereTheSheetIsDrawnWhileItRisesAndCloses() async throws {
        let (controller, window) = opened()
        let height = controller.sheetHeight
        try await waitUntil(timeout: .seconds(1)) {
            (0.25 * height...0.75 * height).contains(drawnOffset(controller))
        }
        var drawn = controller.container.layer.presentation()!.frame
        let model = controller.container.frame
        let onSheet = try #require(controller.view.hitTest(CGPoint(x: drawn.midX, y: drawn.minY + 4), with: nil))
        #expect(onSheet.isDescendant(of: controller.container))
        let between = CGPoint(x: drawn.midX, y: (model.minY + drawn.minY) / 2)
        #expect(controller.view.hitTest(between, with: nil) === controller.dim)

        try await waitUntil { controller.container.layer.animationKeys() == nil }
        closeByTap(controller)
        try await waitUntil(timeout: .seconds(1)) { drawnOffset(controller) > 0.3 * height }
        drawn = controller.container.layer.presentation()!.frame
        #expect(drawn.minY + 4 < controller.container.frame.minY)
        #expect(controller.view.hitTest(CGPoint(x: drawn.midX, y: drawn.minY + 4), with: nil) === controller.container)
        #expect(controller.view.hitTest(CGPoint(x: drawn.midX, y: drawn.minY - 20), with: nil) == nil)
        window.isHidden = true
    }

    // A grab at 30, 60 or 90 percent of the open's settling time takes the sheet where it is drawn: its motion and the
    // dim's end, the finger's first move lands on the drawn offset, and the next frame shows exactly that. The window's
    // clock is held from the open and stepped a quarter frame at a time to the grab's point of the open.
    @Test(.timeLimit(.minutes(1)), arguments: [0.3, 0.6, 0.9])
    func aGrabDuringTheOpenFollowsTheFingerFromWhereTheSheetIsDrawn(_ fraction: Double) async throws {
        let (controller, window) = opened()
        let clock = HeldClock(window.layer)
        let begin = try #require(controller.container.layer.animation(forKey: "transform")).beginTime
        while clock.now < begin + fraction * Theme.Motion.menuOpen.settlingDuration {
            clock.step(by: 1.0 / 240)
        }
        let drawn = drawnOffset(controller)
        controller.dragBegan()
        controller.dragChanged(20)
        #expect(controller.container.layer.animationKeys() == nil)
        #expect(controller.dim.layer.animationKeys() == nil)
        #expect(abs(controller.container.transform.ty - (drawn + 20)) < 0.5)
        #expect(abs(controller.dim.alpha - dimAlpha(controller, at: controller.container.transform.ty)) < 0.001)
        #expect(controller.env.haptics.records.last?.interaction == .menuGrabDuringOpen)
        await nextDisplayFrame()
        #expect(abs(drawnOffset(controller) - controller.container.transform.ty) < 0.5)
        window.isHidden = true
    }

    // The open counts in the sheet's own time: held past its settling time, with its end not yet delivered, a grab is
    // no longer one during the open.
    @Test(.timeLimit(.minutes(1)))
    func aGrabPastTheOpensSettlingTimeIsNotDuringTheOpen() async throws {
        let (controller, window) = opened()
        let clock = HeldClock(window.layer)
        clock.step(by: Theme.Motion.menuOpen.settlingDuration + 1.0 / 60)
        #expect(controller.motion != nil)
        controller.dragBegan()
        #expect(controller.env.haptics.records.last?.interaction != .menuGrabDuringOpen)
        window.isHidden = true
    }

    // A reopen during the close carries the speed the close has at the drawn time, in the sheet's own time.
    @Test(.timeLimit(.minutes(1)))
    func aReopenMidCloseCarriesTheSpeedAtTheDrawnTime() async throws {
        let (controller, window) = try await settled()
        let clock = HeldClock(window.layer)
        closeByTap(controller)
        let close = try #require(controller.motion)
        clock.step(by: 0.4 * Theme.Motion.menuClose.settlingDuration)
        let drawn = drawnOffset(controller)
        #expect(controller.env.ui.open(.menu))
        controller.setOpen(true)
        let rise = try #require(controller.container.layer.animation(forKey: "transform") as? CASpringAnimation)
        let carried = SheetDrag.releaseVelocity(close.speed(at: clock.now), toward: -drawn)
        #expect(carried != 0)
        #expect(abs(rise.initialVelocity - carried) < 0.001)
        window.isHidden = true
    }

    // A grab at half the close's travel released at once reopens the menu and returns from where it was taken.
    @Test(.timeLimit(.minutes(1)))
    func aGrabDuringTheCloseReleasedAtOnceReopensFromWhereItIsDrawn() async throws {
        let (controller, window) = try await settled()
        let height = controller.sheetHeight
        closeByTap(controller)
        #expect(controller.env.ui.overlay == .none)
        try await waitUntil(timeout: .seconds(1)) { drawnOffset(controller) >= height / 2 }
        controller.dragBegan()
        #expect(controller.presence != nil)
        let held = controller.container.transform.ty
        controller.dragChanged(0)
        let releasing = CACurrentMediaTime()
        controller.dragEnded(translation: 0, velocity: 0)
        #expect(controller.presence == nil)
        #expect(FrameRateVote.heldUntil >= releasing + Theme.Motion.menuReturn.settlingDuration)
        #expect(controller.env.ui.overlay == .menu)
        #expect(controller.env.haptics.records.last?.interaction == .menuDragReturn)
        let rise = try #require(controller.container.layer.animation(forKey: "transform") as? CASpringAnimation)
        let from = (rise.fromValue as! NSValue).caTransform3DValue
        #expect(abs(from.m42 - held) < 0.5)
        #expect(controller.container.transform == .identity)
        try await waitUntil { controller.container.layer.animationKeys() == nil }
        #expect(!controller.container.isHidden)
        window.isHidden = true
    }

    // The dim is the sheet's position: menuDim at rest, none with the sheet's top at the screen's bottom.
    @Test(.timeLimit(.minutes(1)), arguments: [40.0, 120.0, 200.0])
    func theDimFollowsTheDraggedSheet(_ translation: CGFloat) async throws {
        let (controller, window) = try await settled()
        #expect(abs(controller.dim.alpha - Theme.Opacity.menuDim) < 0.001)
        controller.dragBegan()
        controller.dragChanged(translation)
        #expect(controller.container.transform.ty == translation)
        #expect(abs(controller.dim.alpha - dimAlpha(controller, at: translation)) < 0.001)
        window.isHidden = true
    }

    // The dim rides the sheet's own spring, so it is a function of the drawn sheet all the way.
    @Test func theDimRidesTheSheetsSpring() {
        let (controller, window) = opened()
        let slide = controller.container.layer.animation(forKey: "transform") as! CASpringAnimation
        let fade = controller.dim.layer.animation(forKey: "opacity") as! CASpringAnimation
        #expect(fade.mass == slide.mass)
        #expect(fade.stiffness == slide.stiffness)
        #expect(fade.damping == slide.damping)
        #expect(fade.initialVelocity == slide.initialVelocity)
        #expect(fade.duration == slide.duration)
        #expect(fade.beginTime == slide.beginTime)
        #expect(slide.duration == Theme.Motion.menuOpen.settlingDuration * Theme.Motion.springArrivalStretch)
        #expect(abs(controller.dim.alpha - Theme.Opacity.menuDim) < 0.001)
        window.isHidden = true
    }

    // The open and the close each hold the deck's rate for their settling time, and the menu holds no Presence of its
    // own, so it idles while it is read. The motion is the container's and the dim's own layers.
    @Test(.timeLimit(.minutes(1)))
    func theOpenAndTheCloseHoldTheRateForTheirSettlingTimesAndTheMenuIdlesAtRest() async throws {
        let opening = CACurrentMediaTime()
        let (controller, window) = opened()
        #expect(FrameRateVote.heldUntil >= opening + Theme.Motion.menuOpen.settlingDuration)
        #expect(controller.presence == nil)
        #expect(controller.container.layer.animationKeys() == ["transform"])
        #expect(controller.dim.layer.animationKeys() == ["opacity"])
        #expect(controller.sheet.view.layer.animationKeys() == nil)
        try await waitUntil { controller.container.layer.animationKeys() == nil }
        #expect(controller.presence == nil)
        let closing = CACurrentMediaTime()
        closeByTap(controller)
        #expect(FrameRateVote.heldUntil >= closing + Theme.Motion.menuClose.settlingDuration)
        try await waitUntil { controller.container.isHidden }
        #expect(controller.presence == nil)
        #expect(controller.view.hitTest(CGPoint(x: 100, y: window.bounds.height - 20), with: nil) == nil)
        window.isHidden = true
    }

    // A drag holds a Presence from its begin to its release or cancel, and the spring it lets go on holds for its
    // settling time; a dismissing release drops the Presence the same way.
    @Test(.timeLimit(.minutes(1)))
    func aDragHoldsAPresenceOnlyWhileTheFingerIsDown() async throws {
        let (controller, window) = try await settled()
        #expect(controller.presence == nil)
        controller.dragBegan()
        #expect(controller.presence != nil)
        controller.dragChanged(40)
        let releasing = CACurrentMediaTime()
        controller.dragEnded(translation: 40, velocity: 0)
        #expect(controller.presence == nil)
        #expect(FrameRateVote.heldUntil >= releasing + Theme.Motion.menuReturn.settlingDuration)
        controller.dragBegan()
        #expect(controller.presence != nil)
        controller.dragCancelled()
        #expect(controller.presence == nil)
        controller.dragBegan()
        controller.dragChanged(100)
        let closing = CACurrentMediaTime()
        controller.dragEnded(translation: 100, velocity: 1000)
        #expect(controller.presence == nil)
        #expect(FrameRateVote.heldUntil >= closing + Theme.Motion.menuClose.settlingDuration)
        try await waitUntil { controller.container.isHidden }
        window.isHidden = true
    }

    // UIState only flips the overlay: no SwiftUI animation and no timed vote for the menu.
    @Test func theMenuOverlayFlipsWithNoTimedVote() {
        let env = makeEnvironment()
        let held = FrameRateVote.heldUntil
        #expect(env.ui.open(.menu))
        #expect(env.ui.overlay == .menu)
        env.ui.close()
        #expect(env.ui.overlay == .none)
        #expect(FrameRateVote.heldUntil == held)
    }

    // The pan asks to run alongside every other recognizer, so a press that begins on touch-down cannot keep it from
    // starting.
    @Test func thePanAsksToRunAlongsideOtherRecognizers() {
        let (controller, window) = opened()
        let pan = controller.container.gestureRecognizers!.first { $0 is UIPanGestureRecognizer }!
        let press = UILongPressGestureRecognizer()
        press.minimumPressDuration = 0
        #expect(controller.gestureRecognizer(pan, shouldRecognizeSimultaneouslyWith: press))
        #expect(pan.cancelsTouchesInView)
        window.isHidden = true
    }

    // The fold changes the content's height in place: the sheet keeps its drawn top, then springs to its new one.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aFoldKeepsTheDrawnTopAndSpringsToTheNewOne(_ expands: Bool) async throws {
        let env = makeEnvironment()
        env.browser.settings.displayOptionsExpanded = !expands
        let (controller, window) = try await settled(env)
        let top = controller.container.frame.minY
        controller.fold { env.browser.settings.displayOptionsExpanded = expands }
        #expect(controller.container.layer.animation(forKey: "transform") != nil)
        let fold = try #require(controller.container.layer.animation(forKey: "transform") as? CASpringAnimation)
        let restTop = controller.container.frame.minY
        #expect(expands ? restTop < top : restTop > top)
        #expect(abs((fold.fromValue as! NSValue).caTransform3DValue.m42 - (top - restTop)) < 0.5)
        #expect(abs(fold.stiffness - Theme.Motion.menuFold.spring.stiffness) < 0.01)
        #expect(abs(CGFloat(controller.dim.layer.presentation()!.opacity) - Theme.Opacity.menuDim) < 0.001)
        try await waitUntil { controller.container.layer.animationKeys() == nil }
        window.isHidden = true
    }

    // A tracker counted while the menu is open brings in the footer the way a fold does: from the drawn top, springing.
    @Test(.timeLimit(.minutes(1)))
    func theFooterArrivingWhileOpenSpringsTheSheetToItsNewTop() async throws {
        let env = makeEnvironment()
        let url = URL(string: "https://footer.test/")!
        env.open(url)
        let page = try #require(env.activeController)
        page.webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: "<p>page</p>")
        try await waitUntil { page.url == url }
        let (controller, window) = hosted(env)
        try await waitUntil { controller.container.layer.animationKeys() == nil }
        let top = controller.container.frame.minY

        page.countBlocked(URL(string: "https://tracker.test/t.js")!)
        try await waitUntil { controller.container.layer.animation(forKey: "transform") != nil }
        let arrival = try #require(controller.container.layer.animation(forKey: "transform") as? CASpringAnimation)
        let restTop = controller.container.frame.minY
        #expect(restTop < top)
        #expect(abs((arrival.fromValue as! NSValue).caTransform3DValue.m42 - (top - restTop)) < 0.5)
        #expect(abs(arrival.stiffness - Theme.Motion.menuFold.spring.stiffness) < 0.01)
        try await waitUntil { controller.container.layer.animationKeys() == nil }
        window.isHidden = true
    }

    // The Translate row comes and goes as a fold does: once the page's language is known, and again on the next page.
    @Test(.timeLimit(.minutes(1)))
    func theTranslateRowComingAndGoingWhileOpenSpringsTheSheetToItsNewTop() async throws {
        let env = makeEnvironment()
        let url = URL(string: "https://translate.test/")!
        env.open(url)
        let page = try #require(env.activeController)
        page.webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: "<p>a</p>")
        try await waitUntil { page.url == url && !page.isLoading }
        let (controller, window) = hosted(env)
        try await waitUntil { controller.container.layer.animationKeys() == nil }

        for change in [true, false] {
            let top = controller.container.frame.minY
            let translator = page.translator
            if change {
                try await translator.apply(translator.collect())
                try await translator.mark(Locale.Language(identifier: "fr"))
                await translator.detect()
            } else {
                translator.reset()
            }
            try await waitUntil { controller.container.layer.animation(forKey: "transform") != nil }
            let fold = try #require(controller.container.layer.animation(forKey: "transform") as? CASpringAnimation)
            let restTop = controller.container.frame.minY
            #expect(change ? restTop < top : restTop > top)
            #expect(abs((fold.fromValue as! NSValue).caTransform3DValue.m42 - (top - restTop)) < 0.5)
            #expect(abs(fold.stiffness - Theme.Motion.menuFold.spring.stiffness) < 0.01)
            try await waitUntil { controller.container.layer.animationKeys() == nil }
        }
        window.isHidden = true
    }

    // "Tap to block them again" removes the footer and closes the menu: the closing sheet keeps its height to the end,
    // and the footer goes once the sheet is hidden.
    @Test(.timeLimit(.minutes(1)))
    func theFooterLeavingDuringTheCloseWaitsForTheSheetToHide() async throws {
        let env = makeEnvironment()
        let url = URL(string: "https://allowed.test/")!
        env.setSiteSettings(SiteSettings(blocksTrackers: false), forHost: "allowed.test")
        env.open(url)
        let page = try #require(env.activeController)
        page.webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: "<p>page</p>")
        try await waitUntil { page.url == url }
        let (controller, window) = hosted(env)
        try await waitUntil { controller.container.layer.animationKeys() == nil }
        let height = controller.sheetHeight

        env.setTrackerBlocking(true, forHost: "allowed.test")
        controller.setOpen(false)
        while !controller.container.isHidden {
            #expect(controller.sheetHeight == height)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await waitUntil {
            controller.view.layoutIfNeeded()
            return controller.sheetHeight < height
        }
        window.isHidden = true
    }

    private func onFindTile(_ controller: PageMenuController) -> CGPoint {
        let inSheet = CGPoint(
            x: Theme.Metrics.menuPadding + 20,
            y: Theme.Metrics.menuPadding + Theme.Metrics.navPillHeight + Theme.Metrics.menuPillToTiles + 10)
        let drawn = controller.container.layer.presentation()!.frame
        return CGPoint(x: drawn.minX + inSheet.x, y: drawn.minY + inSheet.y)
    }

    // A pan that begins on a tile cancels the tile's press, so a drag that starts on it never ends in its tap.
    @Test(.timeLimit(.minutes(1)))
    func aPanBeginningOnATileCancelsItsPress() async throws {
        let (controller, window) = try await settled()
        let point = onFindTile(controller)
        let hit = try #require(controller.view.hitTest(point, with: nil))
        #expect(hit.isDescendant(of: controller.sheet.view))
        let press = TrackingPress()
        hit.addGestureRecognizer(press)
        let pan = try #require(controller.container.gestureRecognizers?.first { $0 is UIPanGestureRecognizer })
        controller.cancelTouchSharers(from: hit, keeping: pan)
        #expect(press.cancelled)
        #expect(pan.isEnabled)
        window.isHidden = true
    }

    // A touch-down on the rising menu holds it where it is drawn, in the touch's own hit test, so the tile under the
    // finger is the one the touch lands on. Let go without a drag, the menu finishes its rise on the open's spring. The
    // window's animation clock is held from the open and stepped a quarter frame at a time to the touch's point of the
    // open; it runs on in real time from the catch.
    @Test(.timeLimit(.minutes(1)), arguments: [0.3, 0.6])
    func aTouchDownMidOpenHoldsTheMenuAndLandsOnTheDrawnTile(_ fraction: CGFloat) async throws {
        let (controller, window) = opened()
        let height = controller.sheetHeight
        let clock = HeldClock(window.layer)
        while drawnOffset(controller) > (1 - fraction) * height {
            try #require(clock.now - controller.container.layer.animation(forKey: "transform")!.beginTime < 1)
            clock.step(by: 1.0 / 240)
        }
        #expect(drawnOffset(controller) > (0.9 - fraction) * height)
        #expect(drawnOffset(controller) > 0.1 * height)
        let point = onFindTile(controller)
        let drawn = drawnOffset(controller)
        let hit = try #require(controller.view.hitTest(point, with: TouchEvent()))
        #expect(hit.isDescendant(of: controller.sheet.view))
        #expect(controller.container.layer.animationKeys() == nil)
        #expect(abs(controller.container.transform.ty - drawn) < 1)
        let inSheet = controller.sheet.view.convert(point, from: controller.view)
        #expect(abs(inSheet.y - (Theme.Metrics.menuPadding + Theme.Metrics.navPillHeight + Theme.Metrics.menuPillToTiles
            + 10)) < 1)
        clock.resume()
        try await Task.sleep(for: .milliseconds(20))
        #expect(abs(drawnOffset(controller) - controller.container.transform.ty) < 0.5)
        controller.catchEnded()
        let rise = try #require(controller.container.layer.animation(forKey: "transform") as? CASpringAnimation)
        #expect(abs(rise.stiffness - Theme.Motion.menuOpen.spring.stiffness) < 0.01)
        try await waitUntil { controller.container.layer.animationKeys() == nil }
        #expect(abs(drawnOffset(controller)) < 0.5)
        #expect(controller.env.ui.overlay == .menu)
        window.isHidden = true
    }

    // The catch runs alongside the pan and the tiles, sees only a touch whose hit test caught the sheet, and is left
    // alone by a beginning pan, which would otherwise re-rise the sheet it takes.
    @Test(.timeLimit(.minutes(1)))
    func theMenusCatchRunsAlongsideThePanAndIsKeptByIt() async throws {
        let (controller, window) = opened()
        try await waitUntil(timeout: .seconds(1)) { drawnOffset(controller) < 0.7 * controller.sheetHeight }
        let press = controller.catcher
        #expect(press.view === controller.container)
        #expect(!press.cancelsTouchesInView)
        #expect(!controller.gestureRecognizerShouldBegin(press))
        let touched = controller.view.hitTest(onFindTile(controller), with: TouchEvent())
        #expect(controller.gestureRecognizerShouldBegin(press))
        let pan = try #require(controller.container.gestureRecognizers?.first { $0 is UIPanGestureRecognizer })
        let toggled = Count()
        let observation = press.observe(\.isEnabled) { _, _ in MainActor.assumeIsolated { toggled.value += 1 } }
        controller.cancelTouchSharers(from: touched, keeping: pan)
        observation.invalidate()
        #expect(toggled.value == 0)
        window.isHidden = true
    }

    // A caught menu is still a moving one: an upward pan from the catch begins and takes the sheet up from where it is
    // held, and the catch is left to see its touch end. The window's animation clock is held from the open and stepped a
    // quarter frame at a time, so the catch lands just past half the open, never near the rest, where the 40 pt pan
    // would cross it and stretch.
    @Test(.timeLimit(.minutes(1)))
    func anUpwardDragFromACatchOnTheRisingMenuBegins() async throws {
        let (controller, window) = opened()
        let clock = HeldClock(window.layer)
        while drawnOffset(controller) > 0.5 * controller.sheetHeight {
            try #require(clock.now - controller.container.layer.animation(forKey: "transform")!.beginTime < 1)
            clock.step(by: 1.0 / 240)
        }
        #expect(drawnOffset(controller) > 0.4 * controller.sheetHeight)
        let touched = controller.view.hitTest(onFindTile(controller), with: TouchEvent())
        let held = controller.container.transform.ty
        #expect(controller.container.layer.animationKeys() == nil)
        let pan = MenuScriptedPan()
        pan.scriptedVelocity = CGPoint(x: 10, y: -400)
        #expect(controller.gestureRecognizerShouldBegin(pan))
        let toggled = Count()
        let observation = controller.catcher.observe(\.isEnabled) { _, _ in
            MainActor.assumeIsolated { toggled.value += 1 }
        }
        controller.cancelTouchSharers(from: touched, keeping: pan)
        observation.invalidate()
        #expect(toggled.value == 0)
        controller.dragBegan()
        controller.dragChanged(-40)
        #expect(abs(controller.container.transform.ty - (held - 40)) < 0.5)
        window.isHidden = true
    }

    // A catch let go without a drag is spent once the sheet rises from it: at rest an upward drag does not begin, and a
    // tap's release starts no open spring.
    @Test(.timeLimit(.minutes(1)))
    func aReleasedCatchLeavesTheSettledMenuAtRest() async throws {
        let (controller, window) = opened()
        try await waitUntil(timeout: .seconds(1)) { drawnOffset(controller) <= 0.5 * controller.sheetHeight }
        _ = controller.view.hitTest(onFindTile(controller), with: TouchEvent())
        controller.catchEnded()
        try await waitUntil { controller.container.layer.animationKeys() == nil && controller.motion == nil }
        #expect(!controller.gestureRecognizerShouldBegin(controller.catcher))
        let pan = MenuScriptedPan()
        pan.scriptedVelocity = CGPoint(x: 10, y: -400)
        #expect(!controller.gestureRecognizerShouldBegin(pan))
        _ = controller.view.hitTest(onFindTile(controller), with: TouchEvent())
        controller.catchEnded()
        #expect(controller.container.layer.animationKeys() == nil)
        window.isHidden = true
    }

    // At rest only a downward drag is the sheet's.
    @Test(.timeLimit(.minutes(1)))
    func anUpwardDragOnTheMenuAtRestDoesNotBegin() async throws {
        let (controller, window) = try await settled()
        let pan = MenuScriptedPan()
        pan.scriptedVelocity = CGPoint(x: 10, y: -400)
        #expect(!controller.gestureRecognizerShouldBegin(pan))
        pan.scriptedVelocity = CGPoint(x: 10, y: 400)
        #expect(controller.gestureRecognizerShouldBegin(pan))
        window.isHidden = true
    }

    // Once the open has visibly arrived, a tap reaches the tile even though the stretched spring is still running.
    @Test(.timeLimit(.minutes(1)))
    func aTapInTheOpensSettledTailReachesTheTile() async throws {
        let (controller, window) = opened()
        try await waitUntil { abs(drawnOffset(controller)) < 1 }
        #expect(controller.container.layer.animation(forKey: "transform") != nil)
        let hit = try #require(controller.view.hitTest(onFindTile(controller), with: nil))
        #expect(hit.isDescendant(of: controller.sheet.view))
        window.isHidden = true
    }

    // In the close's settled tail the sheet is at its rest below the screen and the menu is closed: a tap anywhere reaches
    // the page, not the dim, and plays nothing.
    @Test(.timeLimit(.minutes(1)))
    func aTapInTheClosesSettledTailReachesThePage() async throws {
        let (controller, window) = try await settled()
        let height = controller.sheetHeight
        closeByTap(controller)
        let records = controller.env.haptics.records.count
        try await waitUntil { abs(drawnOffset(controller) - height) < 1 }
        #expect(controller.container.layer.animation(forKey: "transform") != nil)
        #expect(controller.view.hitTest(CGPoint(x: 100, y: window.bounds.height / 2), with: nil) == nil)
        #expect(controller.view.hitTest(CGPoint(x: 100, y: window.bounds.height - 4), with: nil) == nil)
        #expect(controller.env.haptics.records.count == records)
        window.isHidden = true
    }

    // The chevron turns on Core Animation, on the fold's spring, from where it is drawn.
    @Test(.timeLimit(.minutes(1)))
    func theFoldsChevronTurnsOnCoreAnimation() async throws {
        let (controller, window) = try await settled()
        let chevron = try #require(firstChevron(in: controller.sheet.view))
        controller.fold { controller.env.browser.settings.displayOptionsExpanded = false }
        try await waitUntil { chevron.layer.animation(forKey: "turn") != nil }
        let turn = try #require(chevron.layer.animation(forKey: "turn") as? CASpringAnimation)
        #expect(turn.keyPath == "transform.rotation.z")
        #expect(abs(turn.stiffness - Theme.Motion.menuFold.spring.stiffness) < 0.01)
        #expect(abs((chevron.layer.value(forKeyPath: "transform.rotation.z") as! CGFloat) + .pi / 2) < 0.001)
        window.isHidden = true
    }

    // A fold is laid out in its own call, so nothing is left pending: a height change that comes later, outside a fold,
    // starts nothing, and the next open rises to the new height on the open's spring alone.
    @Test(.timeLimit(.minutes(1)))
    func aFoldWhileHiddenStartsNothing() async throws {
        let (controller, window) = try await settled()
        closeByTap(controller)
        try await waitUntil { controller.container.isHidden }
        let top = controller.container.frame.minY
        controller.env.browser.settings.displayOptionsExpanded = false
        try await waitUntil { controller.container.frame.minY != top }
        controller.view.layoutIfNeeded()
        #expect(controller.container.layer.animationKeys() == nil)
        #expect(controller.env.ui.open(.menu))
        controller.setOpen(true)
        #expect(controller.container.layer.animationKeys() == ["transform"])
        let rise = try #require(controller.container.layer.animation(forKey: "transform") as? CASpringAnimation)
        #expect(abs(rise.stiffness - Theme.Motion.menuOpen.spring.stiffness) < 0.01)
        window.isHidden = true
    }

    private func firstChevron(in view: UIView) -> UIImageView? {
        if let image = view as? UIImageView { return image }
        return view.subviews.lazy.compactMap { firstChevron(in: $0) }.first
    }

    @Test(.timeLimit(.minutes(1)))
    func aDismissingReleaseClosesOnTheCloseSpringWithTheFingersSpeed() async throws {
        let (controller, window) = try await settled()
        controller.dragBegan()
        controller.dragChanged(100)
        controller.dragEnded(translation: 100, velocity: 1000)
        #expect(controller.env.ui.overlay == .none)
        let fall = try #require(controller.container.layer.animation(forKey: "transform") as? CASpringAnimation)
        let close = Theme.Motion.menuClose
        #expect(abs(fall.stiffness - close.spring.stiffness) < 0.01)
        #expect(abs(fall.initialVelocity - 1000 / (controller.sheetHeight - 100)) < 0.001)
        #expect(controller.container.transform.ty == controller.sheetHeight)
        try await waitUntil { controller.container.isHidden }
        window.isHidden = true
    }
}

@MainActor func nextDisplayFrame() async {
    await withCheckedContinuation { done in
        _ = FrameClock { _ in
            done.resume()
            return false
        }
    }
}

private final class MenuScriptedPan: UIPanGestureRecognizer {
    var scriptedVelocity = CGPoint.zero

    override func velocity(in view: UIView?) -> CGPoint { scriptedVelocity }
}
