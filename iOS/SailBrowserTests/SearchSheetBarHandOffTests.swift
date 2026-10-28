import Testing
import UIKit
@testable import SailBrowser

// A closing sheet over the browsing bar: the bar lies under it, hidden but touchable, and takes its own touches once the
// sheet is drawn as the bar.
@MainActor @Suite(.serialized)
struct SearchSheetBarHandOffTests {
    private struct Stage {
        let env: AppEnvironment
        let sheet: SearchSheetController
        let bar: BarSlideView
        let window: UIWindow
    }

    private func barSlide(in view: UIView) -> BarSlideView? {
        view as? BarSlideView ?? view.subviews.lazy.compactMap(barSlide(in:)).first
    }

    // The page with its bar, and the search sheet over it, as the app stacks them.
    private func staged() async throws -> Stage {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let env = makeEnvironment()
        let root = UIViewController()
        let behind = BehindController(env: env)
        let sheet = SearchSheetController(
            model: SearchModel(history: env.history, service: SuggestionService(), engine: { .google }), env: env)
        window.rootViewController = root
        for child in [behind, sheet] as [UIViewController] {
            root.addChild(child)
            child.view.frame = root.view.bounds
            child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            root.view.addSubview(child.view)
            child.didMove(toParent: root)
        }
        window.makeKeyAndVisible()
        env.open(page("handoff"))
        try await waitUntil { barSlide(in: behind.view) != nil }
        let bar = try #require(barSlide(in: behind.view))
        return Stage(env: env, sheet: sheet, bar: bar, window: window)
    }

    // A tapped close from an open whose keyboard has shown; returns the close's begin.
    private func tappedClose(_ stage: Stage) async throws -> CFTimeInterval {
        #expect(stage.env.ui.open(.search, animated: false))
        stage.sheet.setActive(true, submitting: false)
        try await waitUntil { stage.sheet.keyboardShown }
        stage.sheet.setActive(false, submitting: false)
        stage.env.ui.close(animated: false)
        return try #require(stage.sheet.container.layer.animation(forKey: "transform")).beginTime
    }

    private func tabStackCentre(_ window: UIWindow) -> CGPoint {
        CGPoint(
            x: Theme.Metrics.barSideInset + Theme.Metrics.tabStackButtonSize.width / 2,
            y: window.bounds.height - Theme.Metrics.barControlCenterFromBottom)
    }

    private func drawnAboveBar(_ stage: Stage) -> CGFloat {
        stage.window.bounds.height - Theme.Metrics.barTotalHeight - stage.sheet.container.layer.presentation()!.frame.minY
    }

    // Today the strip is swallowed by the sheet's host until the close's own hand-off.
    @Test(.timeLimit(.minutes(1)), .timingSensitive)
    func lateInATapCloseTheTabStackTakesItsOwnTouch() async throws {
        let stage = try await staged()
        _ = try await tappedClose(stage)
        let deadline = ContinuousClock.now + .seconds(1)
        while drawnAboveBar(stage) > Theme.Gesture.closeBarHandOff {
            #expect(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(!stage.sheet.container.isHidden)
        // A hit test that only asks where the point goes, as a beginning pan's cancel does, hands nothing off.
        _ = stage.window.hitTest(tabStackCentre(stage.window), with: nil)
        #expect(!stage.sheet.container.isHidden)
        let hit = try #require(stage.window.hitTest(tabStackCentre(stage.window), with: TouchEvent()))
        #expect(hit.isDescendant(of: stage.bar))
        #expect(stage.sheet.container.isHidden)
        #expect(!stage.env.ui.isSearchCoveringBar)
        #expect(stage.bar.host.view.layer.mask == nil)
        stage.window.isHidden = true
    }

    @Test(.timeLimit(.minutes(1)))
    func earlyInATapCloseTheStripGrabsTheSheetWhereItIsDrawn() async throws {
        let stage = try await staged()
        let begin = try await tappedClose(stage)
        // The window's animation clock, which the close's steps count in, is held and stepped to the close's 8th frame;
        // two display frames then run the steps due by it.
        let clock = HeldClock(stage.window.layer)
        while clock.now < begin + 8 * Theme.Motion.searchCloseFrame {
            clock.step(by: Theme.Motion.searchCloseFrame / 4)
        }
        await nextDisplayFrame()
        await nextDisplayFrame()
        #expect(clock.now - begin < 8.25 * Theme.Motion.searchCloseFrame)
        #expect(drawnAboveBar(stage) > 4 * Theme.Gesture.closeBarHandOff)
        let sheet = stage.sheet
        #expect(stage.window.hitTest(tabStackCentre(stage.window), with: nil) === sheet.container)
        let drawnTop = sheet.container.layer.presentation()!.frame.minY
        sheet.dragBegan()
        sheet.dragChanged(0)
        #expect(abs(sheet.container.frame.minY - drawnTop) < 2)
        #expect(!sheet.container.isHidden)
        stage.window.isHidden = true
    }

    @Test(.timeLimit(.minutes(1)))
    func aCoveredBarDrawsNothingAndKeepsItsTouches() async throws {
        let stage = try await staged()
        let host = stage.bar.host.view!
        #expect(host.layer.mask == nil)
        #expect(stage.env.ui.open(.search, animated: false))
        stage.sheet.setActive(true, submitting: false)
        #expect(stage.env.ui.isSearchCoveringBar)
        let mask = try #require(host.layer.mask)
        #expect(mask.bounds.isEmpty)
        #expect(host.alpha == 1)
        #expect(!host.isHidden)
        stage.window.isHidden = true
    }
}
