import SwiftUI
import Testing
import UIKit
import WebKit
@testable import SailBrowser

@Suite(.serialized)
struct BarTests {
    @Test func controlsUseDarkFillWithWhiteGlyphsOnDarkTint() {
        let style = BarStyle.browsing(on: UIColor(red: 0.1, green: 0.12, blue: 0.2, alpha: 1), in: .dark, isPrivate: false)
        #expect(style.controlFill == .white.opacity(Theme.Opacity.darkBarControlFill))
        #expect(style.glyph == .white)
    }

    @Test func controlsUseFaintBlackFillWithBlackGlyphsOnLightTint() {
        let style = BarStyle.browsing(on: .white, in: .light, isPrivate: false)
        #expect(style.controlFill == .black.opacity(Theme.Opacity.browsingControlFill))
        #expect(style.glyph == .black)
    }

    @Test func theDeckBarUsesWhiteGlyphsOnItsFaintWhiteFill() {
        #expect(BarStyle.deck.controlFill == .white.opacity(Theme.Opacity.switcherControlFill))
        #expect(BarStyle.deck.glyph == .white)
    }

    @Test func ringSpinIsRemovedOnceTheFadeOutCompletes() async throws {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let ring = RingView()
        ring.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        window.addSubview(ring)
        window.makeKeyAndVisible()
        let gradient = try #require(ring.layer.sublayers?.first?.sublayers?.first)

        ring.update(progress: 1, isSpinning: false, isArmed: false)
        ring.update(progress: 0, isSpinning: true, isArmed: false)
        #expect(gradient.animationKeys() != nil)

        ring.update(progress: 0, isSpinning: false, isArmed: false)
        try await waitUntil(timeout: .seconds(1)) { gradient.animationKeys() == nil }
        #expect(ring.alpha == 0)
    }

    @Test func ringGrowsFromItsStartScaleWithTheArc() {
        let ring = RingView()
        ring.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        let start = Theme.Refresh.ringStartScale

        ring.update(progress: 0.5, isSpinning: false, isArmed: false)
        #expect(ring.presentedScale == start + (1 - start) * 0.5)
        ring.update(progress: 0, isSpinning: false, isArmed: false)
        #expect(ring.presentedScale == start + (1 - start) * 0.5)
        ring.update(progress: 0.96, isSpinning: false, isArmed: false)
        ring.update(progress: 0, isSpinning: true, isArmed: false)
        #expect(ring.presentedScale == 1)
    }

    @Test func ringPulsesOnceOnEachRisingArmEdge() throws {
        let ring = RingView()
        ring.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        let layer = try #require(ring.layer.sublayers?.first)

        ring.update(progress: 1, isSpinning: false, isArmed: true)
        let pulse = try #require(layer.animation(forKey: RingView.pulseKey) as? CAKeyframeAnimation)
        #expect(pulse.keyPath == "transform.scale")
        #expect((pulse.values as? [NSNumber])?.map(\.doubleValue) == [1, Double(Theme.Refresh.armPulseScale), 1])
        #expect(pulse.duration == Theme.Refresh.armPulseDuration)
        #expect(pulse.keyTimes?.map(\.doubleValue) == [0, 0.5, 1])
        let curves = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        #expect(pulse.timingFunctions.map { $0.map(controlPoints) } == curves.map(controlPoints))

        layer.removeAnimation(forKey: RingView.pulseKey)
        ring.update(progress: 1, isSpinning: false, isArmed: true)
        #expect(layer.animation(forKey: RingView.pulseKey) == nil)

        ring.update(progress: 0.93, isSpinning: false, isArmed: false)
        ring.update(progress: 1, isSpinning: false, isArmed: true)
        #expect(layer.animation(forKey: RingView.pulseKey) != nil)
    }

    @Test func tabStackHitAreaCoversTheTiltedThumbnails() {
        let frame = Theme.Metrics.tabStackButtonSize
        let outset = TabStackButton.hitOutset
        let hit = CGRect(origin: .zero, size: frame).insetBy(dx: -outset, dy: -outset)
        let size = Theme.Metrics.tabStackThumbnailSize
        let tilts = [Theme.Metrics.tabStackTilt, -Theme.Metrics.tabStackTilt]
        let drawn = zip(Theme.Metrics.tabStackThumbnailOffsets, tilts).map { offset, tilt in
            CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
                .applying(CGAffineTransform(rotationAngle: Angle.degrees(tilt).radians))
                .offsetBy(dx: frame.width / 2 + offset.width, dy: frame.height / 2 + offset.height)
        }.reduce(CGRect.null) { $0.union($1) }
        #expect(hit.contains(drawn))
        #expect(abs(drawn.maxY - hit.maxY) < 0.01)
    }

    private func sample(_ dx: CGFloat, _ dy: CGFloat, velocity vy: CGFloat = 0) -> DragSample {
        DragSample(
            startLocation: .zero, location: CGPoint(x: dx, y: dy), translation: CGSize(width: dx, height: dy),
            velocity: CGSize(width: 0, height: vy), time: Date())
    }

    private func release(_ dy: CGFloat, velocity vy: CGFloat, duration: TimeInterval) -> TabStackButton.Release {
        TabStackButton.release(sample(0, dy, velocity: vy), duration: duration, locked: false)
    }

    @Test func tapWinsOverFlick() {
        #expect(release(-3, velocity: -100, duration: 0.1) == .tap)
    }

    // The flick's floor is the lock's eight points.
    @Test func flickNeedsTravelAndFastProjection() {
        #expect(release(-12, velocity: -900, duration: 0.2) == .flick)
        #expect(release(-12, velocity: -100, duration: 0.2) == .none)
        #expect(release(-7, velocity: -3000, duration: 0.35) == .none)
        #expect(release(-8, velocity: -3000, duration: 0.35) == .flick)
        #expect(release(-31, velocity: 0, duration: 0.5) == .flick)
    }

    // A pull that locked on the tab stack is never a tap, however short, so an 8 to 10 pt wobble returns the flick
    // instead of opening the switcher over an armed page; a thumb's shallow arc is the swipe's, and a steep one past
    // the line is the flick's.
    @Test func aLockedWobbleOnTheTabStackIsNotATapAndAThumbArcIsTheSwipes() {
        #expect(TabStackButton.release(sample(0, -9), duration: 0.2, locked: true) == .none)
        #expect(TabStackButton.release(sample(0, -9), duration: 0.2, locked: false) == .tap)
        #expect(TabStackButton.release(sample(10.4, -6), duration: 0.2, locked: false) == .none)
        #expect(BarSwipe.lock(CGSize(width: 10.4, height: -6)) == .horizontal)
        #expect(TabStackButton.release(sample(6, -10.4, velocity: -900), duration: 0.2, locked: true) == .flick)
    }

    // A caught flick is judged on the travel it draws, the finger's own travel added to the held one.
    @Test func aCaughtFlickFinishesOnItsDrawnTravel() {
        #expect(TabStackButton.finishes(travel: 31, velocity: 0))
        #expect(!TabStackButton.finishes(travel: 20, velocity: 0))
        #expect(TabStackButton.finishes(travel: 20, velocity: -900))
        #expect(!TabStackButton.finishes(travel: 40, velocity: 3000))
    }

    @Test func chevronHoldNeverAlsoOpensTheMenu() {
        let hold = Theme.Gesture.chevronLongPress
        // pressing(false) after perform: the release comes past the hold time.
        #expect(!ChevronButton.opensMenu(isInside: true, held: hold + 0.2))
        // pressing(false) before perform at recognition: the hold time is already reached.
        #expect(!ChevronButton.opensMenu(isInside: true, held: hold))
        #expect(ChevronButton.opensMenu(isInside: true, held: hold - 0.01))
        #expect(!ChevronButton.opensMenu(isInside: false, held: 0.05))
    }
}

private func controlPoints(_ function: CAMediaTimingFunction) -> [Float] {
    (1...2).flatMap { index in
        var point: [Float] = [0, 0]
        function.getControlPoint(at: index, values: &point)
        return point
    }
}

@MainActor
struct StackThumbnailFillTests {
    @Test func aTabWithNoSnapshotShowsItsTintOrTheSubmitBackdropNeverBlack() {
        #expect(StackThumbnail.fill(tint: nil) == Theme.Palette.submitBackdrop)
        #expect(StackThumbnail.fill(tint: nil) != Theme.Palette.newTabPlaceholder)
        let tint = CodableColor(red: 0.1, green: 0.5, blue: 0.3)
        #expect(StackThumbnail.fill(tint: tint) == Color(red: 0.1, green: 0.5, blue: 0.3))
    }
}

// A slide moves the drawn bar ahead of its model placement, so these hit at the drawn place mid-slide. The window's
// layer runs at a quarter speed so the poll lands between 20% and 80% of the travel.
@MainActor @Suite(.serialized)
struct BarSlideHitTests {
    private let tabStack = CGPoint(
        x: Theme.Metrics.barSideInset + Theme.Metrics.tabStackButtonSize.width / 2,
        y: Theme.Metrics.barTotalHeight - Theme.Metrics.barControlCenterFromBottom)
    private let travel = Theme.Metrics.barHideOffset

    private func placed(hidden: Bool) -> (BarSlideView, UIWindow) {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        let bar = BarSlideView(BarContent(env: makeEnvironment(), controller: controller), hidden: hidden)
        bar.frame = CGRect(x: 0, y: 300, width: window.bounds.width, height: Theme.Metrics.barTotalHeight)
        window.addSubview(bar)
        window.layer.speed = 0.25
        window.makeKeyAndVisible()
        bar.layoutIfNeeded()
        CATransaction.flush()
        return (bar, window)
    }

    private func drawnOffset(_ bar: BarSlideView) -> CGFloat {
        bar.host.view.layer.presentation()!.transform.m42
    }

    // The presentation shows the model until the frame after the slide's commit, so the band skips that stale read.
    private func waitUntilMidSlide(_ bar: BarSlideView) async throws {
        try await waitUntil { (0.2 * travel...0.8 * travel).contains(drawnOffset(bar)) }
    }

    private func isBar(_ hit: UIView?, _ bar: BarSlideView) -> Bool {
        hit?.isDescendant(of: bar.host.view) == true
    }

    @Test func aTapOnTheDrawnTabStackDuringAHideReachesTheBar() async throws {
        let (bar, window) = placed(hidden: false)
        defer { window.isHidden = true }
        bar.slide(hidden: true)
        try await waitUntilMidSlide(bar)
        let hit = bar.hitTest(CGPoint(x: tabStack.x, y: tabStack.y + drawnOffset(bar)), with: nil)
        #expect(isBar(hit, bar))
    }

    @Test func aTapAboveTheDrawnBarDuringAShowIsNotTheBar() async throws {
        let (bar, window) = placed(hidden: true)
        defer { window.isHidden = true }
        bar.slide(hidden: false)
        try await waitUntilMidSlide(bar)
        #expect(bar.hitTest(CGPoint(x: tabStack.x, y: drawnOffset(bar) - 10), with: nil) == nil)
    }

    @Test func withNoSlideTheBarIsHitAtItsPlacement() {
        let (shown, shownWindow) = placed(hidden: false)
        defer { shownWindow.isHidden = true }
        #expect(isBar(shown.hitTest(tabStack, with: nil), shown))
    }

    @Test func aHiddenBarPassesItsStripToThePage() {
        let (hidden, window) = placed(hidden: true)
        defer { window.isHidden = true }
        #expect(hidden.hitTest(tabStack, with: nil) == nil)
    }
}
