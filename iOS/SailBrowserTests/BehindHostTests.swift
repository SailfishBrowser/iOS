import SwiftUI
import Testing
import UIKit
import WebKit
@testable import SailBrowser

struct BehindHostTests {
    private func hosted() -> (BehindController, UIWindow) {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let controller = BehindController(env: makeEnvironment())
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return (controller, window)
    }

    @Test func shrunkCardStartsAtTheSafeAreaTopWithItsOwnCorner() {
        let (controller, window) = hosted()
        controller.applyShrink(1, deckProgress: 0, motion: nil)
        let safeTop = window.safeAreaInsets.top
        let scale = Theme.Metrics.browsingShrinkScale
        let card = controller.card.frame
        #expect(safeTop > 0)
        #expect(abs(card.minY - safeTop) < 0.01)
        #expect(abs(card.width - window.bounds.width * scale) < 0.01)
        #expect(abs(card.maxY - (safeTop + (window.bounds.height - safeTop) * scale)) < 0.01)
        #expect(abs(controller.card.layer.cornerRadius * scale - Theme.Metrics.browsingShrinkCorner) < 0.01)
        #expect(controller.card.clipsToBounds)
        window.isHidden = true
    }

    @Test func cardIsFullScreenAtRestAndOverTheDeck() {
        let (controller, window) = hosted()
        controller.applyShrink(0, deckProgress: 0, motion: nil)
        #expect(controller.card.frame == window.bounds)
        controller.applyShrink(1, deckProgress: 1, motion: nil)
        #expect(controller.card.frame == window.bounds)
        window.isHidden = true
    }

    private func legs(_ layer: CALayer, _ keyPath: String) -> [CASpringAnimation] {
        (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) as? CASpringAnimation }
            .filter { $0.keyPath == keyPath }
    }

    private func shrinkLegs(_ controller: BehindController) -> [[CASpringAnimation]] {
        ["bounds", "position", "transform", "cornerRadius"].map { legs(controller.card.layer, $0) }
            + [legs(controller.dim.layer, "opacity")]
    }

    // SwiftUI's animations tick at 60 Hz on the phone, so the shrink and its dim run on the render server, on the
    // shrink's own spring, asking for the deck's rate.
    @Test func theShrinkAndItsDimRunOnTheRenderServerOnTheirSpring() {
        let (controller, window) = hosted()
        controller.applyShrink(1, deckProgress: 0, motion: UIState.ShrinkMotion(token: .keyboard, velocity: 0))
        let spring = MotionToken.keyboard.spring
        for property in shrinkLegs(controller) {
            #expect(property.count == 1)
            let leg = property.first
            #expect(leg.map { abs($0.stiffness - spring.stiffness) < 1e-6 } == true)
            #expect(leg?.isAdditive == true)
            #expect(leg?.asksForFullRate == true)
        }
        #expect(controller.card.transform.ty == 0)
        #expect(abs(controller.dim.alpha - Theme.Opacity.searchDim) < 1e-6)
        window.isHidden = true
    }

    // A close during the open adds its leg to the running one, as SwiftUI's springs kept their velocity, instead of
    // restarting the page from where it is drawn.
    @Test func aCloseMidOpenAddsItsLegToTheRunningOne() async throws {
        let (controller, window) = hosted()
        controller.applyShrink(1, deckProgress: 0, motion: UIState.ShrinkMotion(token: .keyboard, velocity: 0))
        try await Task.sleep(for: .milliseconds(80))
        let close = UIState.ShrinkMotion(
            token: Theme.Motion.searchBehindClose, velocity: Theme.Motion.searchBehindCloseVelocity)
        controller.applyShrink(0, deckProgress: 0, motion: close)
        for property in shrinkLegs(controller) {
            let additive = property.filter { $0.isAdditive }.count
            let closing = property.filter { $0.initialVelocity == Theme.Motion.searchBehindCloseVelocity }.count
            #expect(property.count == 2)
            #expect(additive == 2)
            #expect(closing == 1)
        }
        #expect(controller.dim.alpha == 0)
        #expect(controller.card.frame == window.bounds)
        window.isHidden = true
    }

    // "+" during a close: the open's leg adds to the running close leg, which keeps its place and its speed.
    @Test func anOpenMidCloseAddsItsLegToTheRunningOne() async throws {
        let (controller, window) = hosted()
        controller.applyShrink(1, deckProgress: 0, motion: nil)
        let close = UIState.ShrinkMotion(
            token: Theme.Motion.searchBehindClose, velocity: Theme.Motion.searchBehindCloseVelocity)
        controller.applyShrink(0, deckProgress: 0, motion: close)
        try await Task.sleep(for: .milliseconds(80))
        controller.applyShrink(1, deckProgress: 0, motion: UIState.ShrinkMotion(token: .keyboard, velocity: 0))
        for property in shrinkLegs(controller) {
            let additive = property.filter { $0.isAdditive }.count
            let closing = property.filter { $0.initialVelocity == Theme.Motion.searchBehindCloseVelocity }.count
            #expect(property.count == 2)
            #expect(additive == 2)
            #expect(closing == 1)
        }
        #expect(abs(controller.dim.alpha - Theme.Opacity.searchDim) < 1e-6)
        window.isHidden = true
    }

    @Test func aJumpEndsEveryRunningLegAndSetsTheCardAndDimAtOnce() {
        let (controller, window) = hosted()
        controller.applyShrink(1, deckProgress: 0, motion: UIState.ShrinkMotion(token: .keyboard, velocity: 0))
        controller.applyShrink(0, deckProgress: 0, motion: nil)
        #expect(controller.card.layer.animationKeys() == nil)
        #expect(controller.dim.layer.animationKeys() == nil)
        #expect(controller.dim.alpha == 0)
        #expect(controller.card.frame == window.bounds)
        controller.applyShrink(1, deckProgress: 0, motion: nil)
        #expect(controller.card.layer.animationKeys() == nil)
        #expect(abs(controller.dim.alpha - Theme.Opacity.searchDim) < 1e-6)
        window.isHidden = true
    }

    // On a submit the veil covers the dim with the page, so the dim's own opacity is the shrink's alone.
    @Test func theDimCoversTheWholeStageOverTheCardAndTakesNoTouches() {
        let (controller, window) = hosted()
        #expect(controller.dim.superview === controller.stage)
        #expect(controller.stage.subviews.last === controller.dim)
        #expect(controller.dim.frame == controller.stage.bounds)
        #expect(!controller.dim.isUserInteractionEnabled)
        #expect(controller.dim.alpha == 0)
        window.isHidden = true
    }

    private func barSlide(in view: UIView) -> BarSlideView? {
        view as? BarSlideView ?? view.subviews.lazy.compactMap(barSlide(in:)).first
    }

    // The edge's own call adds the spring, so it commits with that turn and moves on the next frame.
    @Test func barSlideStartsInTheTurnTheScrollEdgeIsReported() async throws {
        let (controller, window) = hosted()
        controller.env.open(page("bar"))
        try await waitUntil { barSlide(in: controller.view) != nil }
        let bar = try #require(barSlide(in: controller.view))
        let web = try #require(controller.env.activeController)
        let layer = bar.host.view.layer
        #expect(!bar.isSlidOut)

        for offset in [0, 100] as [CGFloat] {
            web.scrolled(offsetY: offset, maxOffsetY: 1000, tracking: true, decelerating: false)
        }
        let hide = layer.animationKeys()?.compactMap { layer.animation(forKey: $0) as? CASpringAnimation }
        #expect(bar.isSlidOut)
        #expect(bar.host.view.transform.ty == Theme.Metrics.barHideOffset)
        #expect(hide?.count == 1)
        #expect(hide?.first?.keyPath == "transform.translation.y")
        #expect(hide?.first?.isAdditive == true)
        #expect(hide?.first?.fromValue as? CGFloat == -Theme.Metrics.barHideOffset)
        #expect(hide?.first?.duration == Theme.Motion.bar.spring.settlingDuration)

        web.scrolled(offsetY: 80, maxOffsetY: 1000, tracking: true, decelerating: false)
        let legs = layer.animationKeys()?.compactMap { layer.animation(forKey: $0) as? CASpringAnimation }
        #expect(!bar.isSlidOut)
        #expect(bar.host.view.transform.ty == 0)
        #expect(legs?.count == 2)
        #expect(legs?.contains { $0.fromValue as? CGFloat == Theme.Metrics.barHideOffset } == true)
        window.isHidden = true
    }

    // The intro hides the bar at the submit and brings it in from the call that ends it, never through an update.
    @Test func barIntroSlidesInTheTurnItsStateFlips() async throws {
        let (controller, window) = hosted()
        controller.env.open(page("intro"))
        try await waitUntil { barSlide(in: controller.view) != nil }
        let bar = try #require(barSlide(in: controller.view))
        let layer = bar.host.view.layer
        let ui = controller.env.ui

        ui.open(.search, animated: false)
        ui.submitSearch(onHidden: {}, onCancel: {})
        #expect(bar.isSlidOut)
        #expect(bar.host.view.transform.ty == Theme.Metrics.barHideOffset)

        ui.endBarIntro()
        let legs = layer.animationKeys()?.compactMap { layer.animation(forKey: $0) as? CASpringAnimation }
        #expect(!bar.isSlidOut)
        #expect(bar.host.view.transform.ty == 0)
        #expect(legs?.count == 2)
        #expect(legs?.allSatisfy { $0.preferredFrameRateRange == Theme.Latency.frameRateRange } == true)
        window.isHidden = true
    }

    private func submitted(_ controller: BehindController, onHidden: @escaping () -> Void) {
        controller.env.ui.open(.search, animated: false)
        controller.applyShrink(1, deckProgress: 0, motion: nil)
        controller.env.ui.submitSearch(onHidden: onHidden, onCancel: {})
        controller.applyFade(controller.env.ui.behindOpacity)
    }

    @Test func submitFadesOutOnTheRenderServerFromTheSameTurn() {
        let (controller, window) = hosted()
        submitted(controller) {}
        let fade = controller.veil.layer.animation(forKey: "opacity") as? CABasicAnimation
        #expect(fade != nil)
        #expect(fade?.duration == Theme.Motion.submitFadeOutDuration)
        #expect(fade?.timingFunction == CAMediaTimingFunction(name: .easeOut))
        window.isHidden = true
    }

    // SwiftUI can apply the opacity change in a pass with UIKit animations off; the fade must still run.
    @Test func theSubmitFadeRunsEvenWhenAppliedWithUIKitAnimationsOff() async throws {
        let (controller, window) = hosted()
        var hidden = false
        controller.env.ui.open(.search, animated: false)
        controller.env.ui.submitSearch(onHidden: { hidden = true }, onCancel: {})
        UIView.performWithoutAnimation { controller.applyFade(controller.env.ui.behindOpacity) }
        let fade = controller.veil.layer.animation(forKey: "opacity") as? CABasicAnimation
        #expect(fade?.duration == Theme.Motion.submitFadeOutDuration)
        #expect(fade?.timingFunction == CAMediaTimingFunction(name: .easeOut))
        try await Task.sleep(for: .seconds(Theme.Motion.submitFadeOutDuration / 2))
        #expect(!hidden)
        #expect(controller.env.ui.open(.search))
        UIView.performWithoutAnimation { controller.applyFade(controller.env.ui.behindOpacity) }
        let fadeIn = controller.veil.layer.animation(forKey: "opacity") as? CABasicAnimation
        #expect(fadeIn?.duration == 0.12)
        #expect(fadeIn?.timingFunction == CAMediaTimingFunction(name: .easeOut))
        #expect(controller.veil.alpha == 0)
        window.isHidden = true
    }

    @Test func submittedPageCutsInRightAfterTheHiddenStep() async throws {
        let (controller, window) = hosted()
        var atSwitch: (rise: CGFloat, veil: CGFloat)?
        submitted(controller) {
            atSwitch = (controller.stage.transform.ty, controller.veil.alpha)
        }
        try await Task.sleep(for: .seconds(Theme.Motion.submitFadeOutDuration / 2))
        #expect(atSwitch == nil)
        while atSwitch == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(atSwitch?.rise == 0)
        #expect(atSwitch?.veil == 1)
        #expect(!controller.env.ui.isSubmitting)
        #expect(controller.veil.alpha == 0)
        #expect(controller.stage.transform == .identity)
        // The submitted page fades in on its own fitted fade; 0.12 s is only the fade back when search reopens.
        let fadeIn = controller.veil.layer.animation(forKey: "opacity") as? CABasicAnimation
        #expect(fadeIn?.duration == 0.225)
        #expect(fadeIn?.timingFunction == CAMediaTimingFunction(name: .easeOut))
        #expect(fadeIn?.fromValue as? Float == 1)
        window.isHidden = true
    }

    // The submitted page rises into place on a 0.40 s spring as it fades in, on a clock from Go,
    // whether or not it has painted: the spring began before the swap, so only its last part shows.
    @Test func theSubmittedPageRisesIntoPlaceOnAClockFromGo() async throws {
        let (controller, window) = hosted()
        var swapped = false
        let go = CACurrentMediaTime()
        submitted(controller) { swapped = true }
        while !swapped {
            try await Task.sleep(for: .milliseconds(5))
        }
        let rise = try #require(controller.stage.layer.animation(forKey: "transform") as? CASpringAnimation)
        let spring = Theme.Motion.submitPageRise.spring
        #expect(abs(rise.stiffness - spring.stiffness) < 1e-6)
        #expect(abs(rise.damping - spring.damping) < 1e-6)
        let from = try #require(rise.fromValue as? NSValue).caTransform3DValue
        #expect(from.m42 == Theme.Metrics.submitPageRise)
        #expect(rise.asksForFullRate)
        #expect(controller.veil.layer.animation(forKey: "opacity")?.asksForFullRate == true)
        let start = controller.stage.layer.convertTime(go + Theme.Motion.submitPageRiseDelay, from: nil)
        #expect(abs(rise.beginTime - start) < 0.05)
        #expect(rise.beginTime < controller.stage.layer.convertTime(CACurrentMediaTime(), from: nil))
        #expect(Theme.Metrics.submitPageRise == 115)
        #expect(Theme.Motion.submitPageRiseDelay == 0.095)
        #expect(Theme.Motion.submitPageRise == .spring(duration: 0.40, bounce: 0))
        window.isHidden = true
    }

    // A small view on the page at a card point, on top of everything the page holds.
    private func probe(at point: CGPoint, in controller: BehindController) -> UIView {
        let probe = UIView(frame: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4))
        controller.card.addSubview(probe)
        return probe
    }

    @Test func aTapDuringTheSubmitRiseLandsWhereThePageIsDrawn() async throws {
        let (controller, window) = hosted()
        defer { window.isHidden = true }
        var swapped = false
        submitted(controller) { swapped = true }
        try await waitUntil { swapped }
        let pagePoint = CGPoint(x: controller.card.bounds.midX, y: controller.card.bounds.minY + 40)
        let target = probe(at: pagePoint, in: controller)
        let rise = Theme.Metrics.submitPageRise
        try await waitUntil(every: .milliseconds(4)) {
            let drawn = controller.stage.layer.presentation()!.transform.m42
            return drawn > 0.1 * rise && drawn < 0.7 * rise
        }

        let drawnY = controller.stage.layer.presentation()!.transform.m42
        let atRest = window.convert(pagePoint, from: controller.card)
        let hit = window.hitTest(CGPoint(x: atRest.x, y: atRest.y + drawnY), with: nil)
        #expect(hit === target, "rise \(drawnY)")
    }

    @Test func aTapDuringTheCloseUnshrinkLandsWhereTheCardIsDrawn() async throws {
        let (controller, window) = hosted()
        defer { window.isHidden = true }
        controller.applyShrink(1, deckProgress: 0, motion: nil)
        let close = UIState.ShrinkMotion(
            token: Theme.Motion.searchBehindClose, velocity: Theme.Motion.searchBehindCloseVelocity)
        controller.applyShrink(0, deckProgress: 0, motion: close)
        let card = controller.card
        let center = CGPoint(x: card.bounds.midX, y: card.bounds.midY)
        let target = probe(at: center, in: controller)
        let rest = Theme.Metrics.browsingShrinkScale
        try await waitUntil(every: .milliseconds(4)) {
            guard let drawn = card.layer.presentation() else { return false }
            let fraction = (drawn.transform.m11 - rest) / (1 - rest)
            return fraction > 0.3 && fraction < 0.7
        }

        let drawn = card.layer.presentation()!
        let drawnCenter = CGPoint(x: drawn.bounds.midX, y: drawn.bounds.midY)
        let scale = drawn.transform.m11
        let drawnPoint = CGPoint(
            x: drawn.position.x + scale * (center.x - drawnCenter.x),
            y: drawn.position.y + scale * (center.y - drawnCenter.y))
        let hit = window.hitTest(window.convert(drawnPoint, from: controller.stage), with: nil)
        #expect(hit === target, "drawn \(drawnPoint), model \(card.center)")
    }

    private func liftObserver(_ controller: BehindController) -> TouchLiftObserver {
        controller.view.gestureRecognizers!.compactMap { $0 as? TouchLiftObserver }.first!
    }

    private func waitUntilRising(_ controller: BehindController, above low: CGFloat) async throws {
        try await waitUntil(every: .milliseconds(4)) {
            let drawn = controller.stage.layer.presentation()!.transform.m42
            return drawn > low && drawn < 0.7 * Theme.Metrics.submitPageRise
        }
    }

    // UIKit reads a touch's place in the page from the page's model geometry, so the rise is held where it is drawn
    // the moment the touch lands, and WebKit sees the link the finger is on.
    @Test func aLinkTappedDuringTheSubmitRiseIsTheLinkDrawnUnderTheFinger() async throws {
        let (controller, window) = hosted()
        defer { window.isHidden = true }
        let page = WKWebView()
        page.scrollView.contentInsetAdjustmentBehavior = .never
        controller.card.addSubview(page)
        page.loadHTMLString(
            "<meta name=viewport content='width=device-width'><body style='margin:0'>"
                + "<a id=link href='https://example.test/' style='position:absolute;top:40px;left:0;right:0;height:20px'>a</a>",
            baseURL: nil)
        try await waitUntil { !page.isLoading }
        var swapped = false
        submitted(controller) { swapped = true }
        page.frame = controller.card.bounds
        try await waitUntil { swapped }
        try await waitUntilRising(controller, above: 25)

        let link = CGPoint(x: page.bounds.midX, y: 50)
        let drawnY = controller.stage.layer.presentation()!.transform.m42
        let atRest = window.convert(link, from: page)
        let finger = CGPoint(x: atRest.x, y: atRest.y + drawnY)
        let hit = try #require(window.hitTest(finger, with: TouchEvent()))
        let touched = page.convert(finger, from: nil)

        #expect(hit.isDescendant(of: page))
        #expect(abs(touched.y - link.y) < 0.5, "rise \(drawnY), touched \(touched)")
        let id = try await page.evaluateJavaScript("document.elementFromPoint(\(touched.x), \(touched.y)).id") as? String
        #expect(id == "link")
    }

    @Test func aHeldRiseStaysWhereItIsDrawnAndSpringsHomeOnTheLastLift() async throws {
        let (controller, window) = hosted()
        defer { window.isHidden = true }
        var swapped = false
        submitted(controller) { swapped = true }
        try await waitUntil { swapped }
        controller.staging.isHidden = false
        try await waitUntilRising(controller, above: 0.1 * Theme.Metrics.submitPageRise)

        _ = window.hitTest(CGPoint(x: window.bounds.midX, y: window.bounds.midY), with: TouchEvent())
        let stage = controller.stage.layer
        let held = stage.transform.m42
        #expect(held > 0)
        #expect(stage.animation(forKey: "transform") == nil)
        let lift = liftObserver(controller)
        let fingers = [UITouch(), UITouch()]
        lift.touchesBegan(Set(fingers), with: UIEvent())
        lift.touchesEnded([fingers[0]], with: UIEvent())
        try await Task.sleep(for: .milliseconds(300))
        #expect(stage.presentation()!.transform.m42 == held)
        #expect(!controller.staging.isHidden)

        lift.touchesCancelled([fingers[1]], with: UIEvent())
        let rest = try #require(stage.animation(forKey: "transform") as? CASpringAnimation)
        let spring = Theme.Motion.submitPageRise.spring
        #expect(abs(rest.stiffness - spring.stiffness) < 1e-6)
        #expect(abs(rest.damping - spring.damping) < 1e-6)
        #expect(rest.initialVelocity == 0)
        #expect(try #require(rest.fromValue as? NSValue).caTransform3DValue.m42 == held)
        // The cover hides in the rise's completion, which Core Animation delivers in its own run loop pass after the
        // finished animation leaves the layer, so both are waited for as events before the rest is checked.
        try await waitUntil { controller.staging.isHidden && stage.animation(forKey: "transform") == nil }
        #expect(controller.stage.transform == .identity)
        #expect(stage.presentation()!.transform.m42 == 0)
    }

    @Test func aHeldUnshrinkStaysWhereItIsDrawnAndSpringsHomeOnLift() async throws {
        let (controller, window) = hosted()
        defer { window.isHidden = true }
        controller.applyShrink(1, deckProgress: 0, motion: nil)
        let close = UIState.ShrinkMotion(
            token: Theme.Motion.searchBehindClose, velocity: Theme.Motion.searchBehindCloseVelocity)
        controller.applyShrink(0, deckProgress: 0, motion: close)
        let card = controller.card.layer
        let rest = Theme.Metrics.browsingShrinkScale
        try await waitUntil(every: .milliseconds(4)) {
            guard let drawn = card.presentation() else { return false }
            let fraction = (drawn.transform.m11 - rest) / (1 - rest)
            return fraction > 0.3 && fraction < 0.7
        }

        _ = window.hitTest(CGPoint(x: window.bounds.midX, y: window.bounds.midY), with: TouchEvent())
        let held = card.transform.m11
        #expect(held < 1)
        #expect(card.animationKeys() == nil)
        let lift = liftObserver(controller)
        let finger = UITouch()
        lift.touchesBegan([finger], with: UIEvent())
        try await Task.sleep(for: .milliseconds(200))
        #expect(card.presentation()!.transform.m11 == held)

        lift.touchesEnded([finger], with: UIEvent())
        #expect(card.animationKeys() != nil)
        try await waitUntil {
            let drawn = card.presentation()!
            return drawn.transform.m11 == 1 && drawn.position == card.position && drawn.bounds == card.bounds
                && controller.dim.layer.presentation()!.opacity == 0
        }
        #expect(controller.card.frame == window.bounds)
        #expect(controller.dim.alpha == 0)
    }

    @Test func reopeningSearchMidSubmitRestoresThePage() async throws {
        let (controller, window) = hosted()
        var calls = 0
        submitted(controller) { calls += 1 }
        try await Task.sleep(for: .seconds(Theme.Motion.submitFadeOutDuration / 2))
        #expect(controller.env.ui.open(.search))
        controller.applyFade(controller.env.ui.behindOpacity)
        try await Task.sleep(for: .seconds(Theme.Motion.submitFadeOutDuration * 2))
        #expect(calls == 0)
        #expect(controller.veil.alpha == 0)
        #expect(controller.stage.transform == .identity)
        window.isHidden = true
    }

    // The fade is a flat veil in the submit's backdrop over the stage, never the stage's own opacity: that composites
    // the page, the card and the dim offscreen on every frame of the fade.
    @Test func theSubmitFadesAVeilOverTheStageNotTheStage() throws {
        let (controller, window) = hosted()
        defer { window.isHidden = true }
        _ = try submittedPage(controller)
        controller.applyFade(controller.env.ui.behindOpacity)
        let order = controller.view.subviews
        #expect(order.firstIndex(of: controller.stage)! < order.firstIndex(of: controller.veil)!)
        #expect(controller.veil.frame == controller.stage.frame)
        #expect(!controller.veil.isUserInteractionEnabled)
        #expect(controller.veil.backgroundColor == Theme.Palette.submitCover)
        #expect(controller.veil.subviews.isEmpty)
        #expect(controller.veil.alpha == 1)
        let fade = try #require(controller.veil.layer.animation(forKey: "opacity") as? CABasicAnimation)
        #expect(fade.fromValue as? Float == 0)
        #expect(controller.stage.alpha == 1)
        #expect(controller.stage.layer.animation(forKey: "opacity") == nil)
    }

    // A private submit's veil is the darker cover with the band the page will show, laid out as the staging band is;
    // a normal submit after it takes the band off the grey veil.
    @Test func aPrivateSubmitsVeilCarriesTheBand() throws {
        let (controller, window) = hosted()
        defer { window.isHidden = true }
        let env = controller.env
        env.open(URL(string: "about:blank")!, isPrivate: true)
        #expect(env.ui.open(.search, animated: false))
        env.submit(Self.staged, via: .searchSubmit)
        #expect(controller.veil.backgroundColor == Theme.Palette.privateSubmitCover)
        let band = try #require(controller.veil.subviews.first as? PrivateBandView)
        #expect(!band.isHidden)
        #expect(band.frame == CGRect(
            x: 0, y: 0, width: window.bounds.width, height: window.safeAreaInsets.top + Theme.Metrics.privateBandExtra))
        #expect(band.label.text == "Incognito")

        #expect(env.ui.open(.search))
        env.ui.setPrivateMode(false)
        env.submit(page("b"), via: .searchSubmit)
        #expect(controller.veil.subviews.isEmpty)
        #expect(controller.veil.backgroundColor == Theme.Palette.submitCover)
    }

    @Test func aStaleFadeOutNeverRevealsALaterSubmit() async throws {
        let (controller, window) = hosted()
        let ui = controller.env.ui
        var calls = 0
        submitted(controller) { calls += 1 }
        try await Task.sleep(for: .seconds(Theme.Motion.submitFadeOutDuration / 2))
        #expect(ui.open(.search))
        controller.applyFade(ui.behindOpacity)
        ui.submitSearch(onHidden: { calls += 1 }, onCancel: {})
        controller.applyFade(ui.behindOpacity)
        try await Task.sleep(for: .seconds(Theme.Motion.submitFadeOutDuration * 0.75))
        #expect(calls == 0)
        #expect(ui.isSubmitting)
        try await Task.sleep(for: .seconds(Theme.Motion.submitFadeOutDuration))
        #expect(calls == 1)
        window.isHidden = true
    }

    private static let staged = URL(string: "https://staged.test/page")!

    private func submittedPage(_ controller: BehindController) throws -> WebTabController {
        let env = controller.env
        env.open(page("a"))
        #expect(env.ui.open(.search, animated: false))
        env.submit(Self.staged, via: .searchSubmit)
        return try #require(env.pool.controllers(onHost: "staged.test").first)
    }

    @Test func aSubmittedPageWaitsInTheWindowUnderACoverBelowTheStageFromGo() throws {
        let (controller, window) = hosted()
        let submitted = try submittedPage(controller)
        let webView = submitted.webView
        #expect(webView.window === window)
        #expect(webView.isDescendant(of: controller.staging))
        let order = controller.view.subviews
        #expect(order.firstIndex(of: controller.staging)! < order.firstIndex(of: controller.stage)!)
        let cover = try #require(controller.staging.subviews.last)
        #expect(cover !== webView)
        #expect(cover.frame.contains(webView.frame))
        #expect(cover.backgroundColor?.cgColor.alpha == 1)
        #expect(!controller.staging.isUserInteractionEnabled)
        window.isHidden = true
    }

    @Test func aStagedPagePaintsAndBecomesRevealableBeforeTheDeckTakesIt() async throws {
        let (controller, window) = hosted()
        let submitted = try submittedPage(controller)
        submitted.webView.loadSimulatedRequest(URLRequest(url: Self.staged), responseHTML: "<p>s</p>")
        try await waitUntil { submitted.isRevealable }
        #expect(submitted.webView.isDescendant(of: controller.staging))
        #expect(controller.env.ui.isSubmitting)
        window.isHidden = true
    }

    @Test func reopeningSearchMidSubmitTakesTheStagedPageOutOfTheWindow() throws {
        let (controller, window) = hosted()
        let submitted = try submittedPage(controller)
        controller.applyFade(controller.env.ui.behindOpacity)
        #expect(controller.env.ui.open(.search))
        controller.applyFade(controller.env.ui.behindOpacity)
        #expect(submitted.webView.window == nil)
        #expect(controller.staging.subviews.count == 1)
        window.isHidden = true
    }
    // The staging cover is the submit's own grey; outside a submit the open's navy root backdrop shows around the
    // shrunk page, so the cover is only there from Go until the page has faded back in.
    @Test func theStagingCoverShowsOnlyFromGoUntilThePageIsBack() async throws {
        let (controller, window) = hosted()
        #expect(controller.staging.isHidden)
        _ = try submittedPage(controller)
        #expect(!controller.staging.isHidden)
        controller.applyFade(controller.env.ui.behindOpacity)
        try await waitUntil { !controller.env.ui.isSubmitting }
        try await waitUntil { controller.staging.isHidden }
        window.isHidden = true
    }

    // The page keeps rising after its 0.12 s fade-in; the strip it uncovers at the top must stay the submit's grey
    // until the rise ends, not turn to the open's navy.
    @Test func theStagingCoverStaysUntilTheRiseEnds() async throws {
        let (controller, window) = hosted()
        _ = try submittedPage(controller)
        controller.applyFade(controller.env.ui.behindOpacity)
        try await waitUntil { !controller.env.ui.isSubmitting }
        let rise = try #require(controller.stage.layer.animation(forKey: "transform"))
        let end = rise.beginTime + rise.duration
        try await Task.sleep(for: .milliseconds(150))
        #expect(CACurrentMediaTime() < end)
        #expect(!controller.staging.isHidden)
        try await waitUntil { controller.staging.isHidden }
        #expect(CACurrentMediaTime() >= end - 0.02)
        window.isHidden = true
    }

    // A newer submit started during an older one's rise has its own page staged; the older rise ending must not
    // hide that cover. The window's animation clock is held and moved on in 60 Hz frames: the newer submit starts 0.1 s
    // before the older rise ends, and the older rise's end is delivered with the clock creeping 0.02 s after it, while
    // the newer fade still has 0.053 to 0.07 s, tens of seconds of real time, to run.
    @Test func anOlderRiseEndingNeverHidesANewerSubmitsCover() async throws {
        let (controller, window) = hosted()
        let env = controller.env
        let clock = HeldClock(window.layer)
        let stage = controller.stage.layer
        func run(until time: CFTimeInterval) {
            while clock.now < time {
                clock.step()
            }
        }
        _ = try submittedPage(controller)
        controller.applyFade(env.ui.behindOpacity)
        CATransaction.flush()
        let fadeOut = try #require(controller.veil.layer.animation(forKey: "opacity"))
        run(until: fadeOut.beginTime + fadeOut.duration)
        clock.creep()
        try await waitUntil { !env.ui.isSubmitting }
        clock.hold()
        let rise = try #require(stage.animation(forKey: "transform"))
        let end = rise.beginTime + rise.duration
        #expect(clock.now < end - 0.1)
        run(until: end - 0.1)
        #expect(env.ui.open(.search, animated: false))
        env.submit(URL(string: "https://second.test/page")!, via: .searchSubmit)
        controller.applyFade(env.ui.behindOpacity)
        CATransaction.flush()
        run(until: end + 0.02)
        clock.creep()
        try await waitUntil { stage.animation(forKey: "transform") == nil }
        #expect(env.ui.isSubmitting)
        #expect(!controller.staging.isHidden)
        window.isHidden = true
    }

    @Test func aCancelledSubmitHidesTheStagingCover() throws {
        let (controller, window) = hosted()
        _ = try submittedPage(controller)
        controller.applyFade(controller.env.ui.behindOpacity)
        #expect(controller.env.ui.open(.search))
        controller.applyFade(controller.env.ui.behindOpacity)
        #expect(controller.staging.isHidden)
        window.isHidden = true
    }
}

// A bare UIEvent has no type; UIKit hit-tests a touch with a touches event.
final class TouchEvent: UIEvent {
    override var type: UIEvent.EventType { .touches }
}
