import SwiftUI
import Testing
import UIKit
@testable import SailBrowser

// During a zoom a touch lands on what is drawn under it: the page at its drawn place during a zoom-in, and the bar
// that is drawn more strongly at that moment.
@Suite(.serialized)
struct DeckZoomTouchTests {
    private func hosted(
        _ directories: AppDirectories = .temporary(), pages: [String] = ["a"]
    ) async throws -> (AppEnvironment, UIWindow) {
        let env = makeEnvironment(directories)
        for name in pages {
            env.open(page(name))
        }
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        window.rootViewController = BehindController(env: env)
        window.makeKeyAndVisible()
        try await waitUntil { bar(in: window) != nil && env.activeController?.webView.window != nil }
        return (env, window)
    }

    private func bar(in view: UIView) -> BarSlideView? {
        if let bar = view as? BarSlideView {
            return bar
        }
        return view.subviews.lazy.compactMap { bar(in: $0) }.first
    }

    // The active card's drawn zoom progress, read from the page's own transform: 0 browsing, 1 at the deck.
    private func drawnProgress(_ env: AppEnvironment, in window: UIWindow) -> CGFloat {
        let stage = env.activeController!.webView.superview!
        let rest = CardLayout(screen: window.bounds.size).restScale
        return (1 - stage.transform.a) / (1 - rest)
    }

    private func atDeck(
        _ directories: AppDirectories = .temporary(), pages: [String] = ["a"]
    ) async throws -> (AppEnvironment, UIWindow) {
        let (env, window) = try await hosted(directories, pages: pages)
        env.showSwitcher(via: .tabStackTap)
        try await waitUntil { abs(drawnProgress(env, in: window) - 1) < 0.001 }
        try await Task.sleep(for: .seconds(Theme.Motion.zoom.settlingDuration))
        return (env, window)
    }

    private func tabStackHit(in window: UIWindow) -> (hit: UIView?, bar: BarSlideView) {
        let bar = bar(in: window)!
        let center = bar.convert(
            CGPoint(
                x: Theme.Metrics.tabStackButtonCenterX, y: bar.bounds.height - Theme.Metrics.barControlCenterFromBottom),
            to: window)
        return (window.hitTest(center, with: nil), bar)
    }

    // A tap plays when the switcher opens, never when a card zooms in to its page.
    @Test func aZoomOutRecordsOneHapticAndAZoomInFromTheDeckNone() async throws {
        let (env, window) = try await hosted()
        let sink = env.haptics
        let beforeOut = sink.records.count
        env.showSwitcher(via: .tabStackTap)
        try await waitUntil { abs(drawnProgress(env, in: window) - 1) < 0.001 }
        try await Task.sleep(for: .seconds(Theme.Motion.zoom.settlingDuration))
        let zoomOut = sink.records[beforeOut...].compactMap(\.event)
        #expect(zoomOut == [.switcherOpened])

        let beforeIn = sink.records.count
        env.showTab(env.browser.activeTabID!, via: .deckCardTap)
        try await waitUntil { drawnProgress(env, in: window) < 0.001 }
        try await Task.sleep(for: .seconds(Theme.Motion.zoom.settlingDuration))
        let zoomIn = sink.records[beforeIn...].compactMap(\.event)
        #expect(zoomIn.isEmpty)
        window.isHidden = true
    }

    // The deck takes no touch during a zoom-in; the page does, where it is drawn, from the zoom's start.
    @Test func aTouchDuringTheZoomInReachesThePageWhereItIsDrawn() async throws {
        let (env, window) = try await atDeck()
        let webView = env.activeController!.webView
        env.showTab(env.browser.activeTabID!, via: .deckCardTap)
        env.ui.deck.hold()
        try await stepFade(env, to: 0.5)
        #expect((0.2...0.8).contains(drawnProgress(env, in: window)))
        #expect(!env.ui.deckTakesTouches)
        let drawn = webView.convert(CGPoint(x: webView.bounds.midX, y: webView.bounds.height * 0.3), to: window)
        let hit = try #require(window.hitTest(drawn, with: nil))
        #expect(hit.isDescendant(of: webView.scrollView))
        #expect(webView.scrollView.panGestureRecognizer.isEnabled)
        env.ui.deck.resume()
        window.isHidden = true
    }

    // Early in a zoom-out the browsing bar is still the one drawn, so the tab stack takes the second tap of a double
    // tap instead of Archive under it.
    @Test func earlyInAZoomOutTheTabStackIsHitWhereTheBrowsingBarIsDrawn() async throws {
        let (env, window) = try await hosted()
        env.showSwitcher(via: .tabStackTap)
        env.ui.deck.hold()
        try await stepFade(env, to: 0.2)
        #expect((0.2...0.25).contains(fadeTravel(env)))
        let (hit, bar) = tabStackHit(in: window)
        #expect(hit?.isDescendant(of: bar) == true)
        try await stepFade(env, to: 0.7)
        #expect((0.7...0.75).contains(fadeTravel(env)))
        #expect(tabStackHit(in: window).hit?.isDescendant(of: bar) != true)
        env.ui.deck.resume()
        window.isHidden = true
    }

    // Steps the held deck a quarter frame at a time until the bars' cross-fade toward the deck's target has gone `travel`
    // of its way, then lets the bars draw that frame, so a touch lands on a known point of the fade however late the
    // test's turns run.
    private func stepFade(_ env: AppEnvironment, to travel: CGFloat) async throws {
        let deck = env.ui.deck
        var steps = 0
        while fadeTravel(env) < travel {
            try #require(steps < 240, "the fade did not reach \(travel) within a second")
            deck.step(by: .seconds(1.0 / 240))
            steps += 1
        }
        await nextDisplayFrame()
        await nextDisplayFrame()
    }

    private func fadeTravel(_ env: AppEnvironment) -> CGFloat {
        1 - abs(env.ui.deckProgress - env.ui.deck.barProgress)
    }

    // Early in a zoom-in the switcher bar is the one drawn, with the browsing bar clearly drawn under it. A touch on
    // its Archive button lands in the behind host's own content, not the browsing bar or the page, and Archive opens.
    @Test func earlyInAZoomInTheSwitcherBarTakesTheTouch() async throws {
        let (env, window) = try await atDeck()
        env.showTab(env.browser.activeTabID!, via: .deckCardTap)
        env.ui.deck.hold()
        try await stepFade(env, to: 0.3)
        #expect((0.3...0.35).contains(fadeTravel(env)))
        let bar = bar(in: window)!
        let archive = bar.convert(
            CGPoint(
                x: Theme.Metrics.barSideInset + Theme.Metrics.controlSize / 2,
                y: bar.bounds.height - Theme.Metrics.barControlCenterFromBottom),
            to: window)
        let hit = try #require(window.hitTest(archive, with: nil))
        #expect(!hit.isDescendant(of: bar))
        #expect(!hit.isDescendant(of: env.activeController!.webView))
        #expect(hit.isDescendant(of: window.rootViewController!.view))
        #expect(env.ui.canOpen(.archive))
        env.ui.deck.resume()
        try await Task.sleep(for: .seconds(Theme.Motion.zoom.settlingDuration))
        #expect(tabStackHit(in: window).hit?.isDescendant(of: bar) == true)
        window.isHidden = true
    }

    // A tap on the drawn Archive button early in a zoom-in opens Archive and turns the zoom back to the switcher.
    @Test func archiveTappedEarlyInAZoomInOpensAndReturnsToTheSwitcher() async throws {
        let (env, window) = try await atDeck()
        env.showTab(env.browser.activeTabID!, via: .deckCardTap)
        env.ui.deck.hold()
        try await stepFade(env, to: 0.2)
        #expect((0.2...0.25).contains(fadeTravel(env)))
        let drawn = env.ui.deck.progress
        env.debugActions[.archiveOpen]!()
        #expect(env.ui.overlay == .archive)
        #expect(env.ui.deckProgress == 1)
        #expect(env.ui.deck.isAnimating)
        #expect(env.ui.deck.progress < 1)
        #expect(abs(env.ui.deck.progress - drawn) < 0.2)
        env.ui.deck.resume()
        window.isHidden = true
    }

    // A grab mid-snap catches the deck where its last frame drew it, not where the spring is by the touch's turn.
    @Test func aGrabMidSnapCatchesTheDeckWhereItIsDrawn() async throws {
        let (env, window) = try await atDeck(pages: ["a", "b", "c"])
        let deck = env.ui.deck
        let surface = try #require(env.debugSurfaces[.deck])
        let layout = CardLayout(screen: window.bounds.size)
        let start = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        func sample(_ dx: CGFloat) -> DragSample {
            DragSample(
                startLocation: start, location: CGPoint(x: start.x + dx, y: start.y),
                translation: CGSize(width: dx, height: 0), velocity: .zero, time: .now)
        }
        let lock = Theme.Gesture.deckAxisLock + 2
        surface(.began, sample(0))
        surface(.changed, sample(lock))
        surface(.changed, sample(lock + layout.stride * 0.3))
        surface(.ended, sample(lock + layout.stride * 0.3))
        deck.hold()
        let released = deck.position
        for _ in 0..<4 {
            deck.step(by: Theme.Latency.frame)
        }
        let drawn = deck.position
        try #require(deck.motion != nil && abs(drawn - released) * layout.stride > 2)
        surface(.began, sample(0))
        #expect(abs(deck.position - drawn) * layout.stride < 0.5)
        surface(.cancelled, sample(0))
        deck.resume()
        window.isHidden = true
    }

    // The deck's driver lives on the environment's own state, so its motion callback must not hold the environment.
    @Test func theDecksMotionCallbackDoesNotHoldTheEnvironment() async throws {
        weak var released: AppEnvironment?
        do {
            let env = makeEnvironment()
            released = env
            env.ui.setDeck(1)
            #expect(env.ui.deck.isAnimating)
        }
        try await waitUntil(timeout: .seconds(3)) { released == nil }
    }

    // A thrown tab is archived when the gap close settles. Going to the background commits it first, so the saved state
    // never brings the thrown tab back at the next launch.
    @Test func goingToTheBackgroundRightAfterAThrowSavesTheArchive() async throws {
        let directories = AppDirectories.temporary()
        let (env, window) = try await atDeck(directories, pages: ["a", "b"])
        env.debugDeckThrow!()
        #expect(env.browser.tabs.count == 2)
        env.sceneDidEnterBackground()
        #expect(env.browser.tabs.count == 1)
        #expect(env.browser.archived.count == 1)
        await env.browser.flush()
        let reloaded = BrowserStore(directories: directories)
        #expect(reloaded.tabs.count == 1)
        #expect(reloaded.archived.count == 1)
        window.isHidden = true
    }

    // The app goes inactive for Control Center, a banner or a call while it stays on screen: the pending archive
    // commits, and the deck keeps moving from where it is drawn.
    @Test func goingInactiveCommitsAThrowAndKeepsTheDeckMoving() async throws {
        let (env, window) = try await atDeck(pages: ["a", "b"])
        env.debugDeckThrow!()
        #expect(env.browser.tabs.count == 2)
        env.ui.setDeck(0)
        env.ui.deck.hold()
        try await stepFade(env, to: 0.2)
        #expect((0.2...0.25).contains(fadeTravel(env)))
        let drawn = env.ui.deck.progress
        env.sceneWillResignActive()
        #expect(env.browser.tabs.count == 1)
        #expect(env.browser.archived.count == 1)
        #expect(env.ui.deck.isAnimating)
        #expect(env.ui.deck.progress == drawn)
        env.ui.deck.resume()
        window.isHidden = true
    }
}
