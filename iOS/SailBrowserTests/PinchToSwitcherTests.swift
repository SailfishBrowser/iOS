import Testing
import UIKit
import WebKit
@testable import SailBrowser

// Overrides only the state; UIPinchGestureRecognizer's scale is already settable.
final class ScriptedPinch: UIPinchGestureRecognizer {
    private var scriptedState = UIGestureRecognizer.State.possible

    func scripted(_ state: UIGestureRecognizer.State) {
        scriptedState = state
    }

    override var state: UIGestureRecognizer.State {
        get { scriptedState }
        set {}
    }
}

// A pinch in from the page's minimum zoom presses the tab stack button: the controller fires once at the threshold,
// and the environment opens the deck through the button's own path, refusing it where the button is unreachable or
// something still moves.
@MainActor @Suite(.serialized)
struct PinchToSwitcherGestureTests {
    // One pinch on the controller's web view: a begin at scale 1, a change to `scale`, the end.
    private func pinch(_ controller: WebTabController, to scale: CGFloat = 0.84) {
        end(fired(on: controller, to: scale), on: controller)
    }

    // A pinch begun at scale 1 and closed to `scale`, the fingers still down.
    private func fired(on controller: WebTabController, to scale: CGFloat = 0.84) -> ScriptedPinch {
        let pinch = ScriptedPinch()
        controller.webView.addGestureRecognizer(pinch)
        pinch.scale = 1
        pinch.scripted(.began)
        controller.pinched(pinch)
        pinch.scale = scale
        pinch.scripted(.changed)
        controller.pinched(pinch)
        return pinch
    }

    private func end(_ pinch: ScriptedPinch, on controller: WebTabController) {
        pinch.scripted(.ended)
        controller.pinched(pinch)
        controller.webView.removeGestureRecognizer(pinch)
    }

    // An environment on one settled page whose own settled snapshot has been requested, so every capture request
    // after this is the deck's. The deck's clock is held.
    private func settled() async throws -> (env: AppEnvironment, controller: WebTabController, captures: Captures) {
        let env = makeEnvironment()
        env.open(page("a"))
        let captures = Captures()
        env.onCaptureRequested = { captures.ids.append($0) }
        try await waitUntil { captures.ids.count == 1 }
        captures.ids = []
        env.ui.deck.hold()
        return (env, env.activeController!, captures)
    }

    private func stepToRest(_ env: AppEnvironment) {
        var frames = 0
        while env.ui.deck.isAnimating, frames < 240 {
            env.ui.deck.step(by: Theme.Latency.frame)
            frames += 1
        }
        #expect(!env.ui.deck.isAnimating)
    }

    private func sample(_ dx: CGFloat, velocity: CGFloat = 0) -> DragSample {
        DragSample(
            startLocation: CGPoint(x: 200, y: 30), location: CGPoint(x: 200 + dx, y: 30),
            translation: CGSize(width: dx, height: 0), velocity: CGSize(width: velocity, height: 0), time: Date())
    }

    // One fire per pinch at the threshold, the button's tap prepared at the begin. A blank web view is at its minimum
    // zoom (scale 1, minimum 1), so atMinimum holds throughout.
    @Test func aScriptedPinchFiresOnceAtTheThreshold() {
        let sink = RecordingHapticSink(start: .now)
        let controller = WebTabController(
            tabID: UUID(), webView: WKWebView(), haptics: HapticsEngine(sink: sink),
            connectivity: Connectivity(monitor: nil))
        var fired = 0
        controller.onPinchToSwitcher = {
            fired += 1
            return true
        }
        let pinch = ScriptedPinch()
        controller.webView.addGestureRecognizer(pinch)

        pinch.scale = 1
        pinch.scripted(.began)
        controller.pinched(pinch)
        #expect(fired == 0)
        #expect(sink.calls.contains(.prepare(Theme.Haptic.medium)))

        pinch.scale = 0.9
        pinch.scripted(.changed)
        controller.pinched(pinch)
        #expect(fired == 0)
        pinch.scale = 0.84
        controller.pinched(pinch)
        #expect(fired == 1)
        pinch.scale = 0.5
        controller.pinched(pinch)
        #expect(fired == 1)
        pinch.scripted(.ended)
        controller.pinched(pinch)
        #expect(fired == 1)
    }

    // A pinch that begins zoomed in is the page's own zoom out: nothing fires however far the fingers close.
    @Test func aPinchWhileZoomedInFiresNothing() async throws {
        let sink = RecordingHapticSink(start: .now)
        let controller = WebTabController(
            tabID: UUID(), webView: WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844)),
            haptics: HapticsEngine(sink: sink), connectivity: Connectivity(monitor: nil))
        await loadAndFinish(
            controller,
            html: "<meta name=viewport content='width=device-width, initial-scale=1, maximum-scale=3'><p>one</p>",
            base: "https://example.test/1")
        let scrollView = controller.webView.scrollView
        try await waitUntil { scrollView.maximumZoomScale >= 2 }
        scrollView.setZoomScale(2, animated: false)
        try #require(
            !PinchToSwitcher.isAtMinimumZoom(
                zoomScale: scrollView.zoomScale, minimumZoomScale: scrollView.minimumZoomScale))
        var fired = 0
        controller.onPinchToSwitcher = {
            fired += 1
            return true
        }
        pinch(controller, to: 0.5)
        #expect(fired == 0)
        #expect(sink.calls.isEmpty)
    }

    // With the deck's clock held, the pinch and the button's tap leave the same state and run the same motion: the
    // deck at 1 on the zoom spring, frame for frame, with the switcher's tap played under the pinch's name.
    @Test func aPinchFromMinimumZoomOpensTheDeckAsTheTabStackTapDoes() {
        let pinched = makeEnvironment()
        let tapped = makeEnvironment()
        for env in [pinched, tapped] {
            env.open(page("a"))
            env.ui.deck.hold()
        }
        pinch(pinched.activeController!)
        tapped.showSwitcher(via: .tabStackTap)

        #expect(pinched.ui.deckProgress == 1 && tapped.ui.deckProgress == 1)
        #expect(pinched.ui.overlay == .none)
        #expect(pinched.ui.deck.isZooming && tapped.ui.deck.isZooming)
        let fire = pinched.haptics.records.last
        #expect(fire?.interaction == .pinchSwitcher && fire?.played == true)
        #expect(fire?.event == .switcherOpened && fire?.event == tapped.haptics.records.last?.event)
        for _ in 0..<12 {
            pinched.ui.deck.step(by: Theme.Latency.frame)
            tapped.ui.deck.step(by: Theme.Latency.frame)
            #expect(pinched.ui.deck.progress == tapped.ui.deck.progress)
            #expect(pinched.ui.deck.barProgress == tapped.ui.deck.barProgress)
        }
        #expect(pinched.ui.deck.progress > 0 && pinched.ui.deck.progress < 1)
    }

    // Where the button is unreachable or something still moves, the pinch does nothing: a bar swipe's spring, an open
    // overlay, the deck already showing, or a page that is not the active one.
    @Test func aPinchWithSomethingMovingOrAwayFromTheBrowserOpensNothing() throws {
        do {
            let env = makeEnvironment()
            env.open(page("a"))
            env.open(page("b"))
            env.ui.deck.hold()
            let pager = TabPager(
                env: env, driver: env.ui.deck, layout: CardLayout(screen: CGSize(width: 390, height: 844)))
            env.pager = pager
            pager.swiped(.began, sample(0))
            pager.swiped(.changed, sample(120))
            pager.swiped(.ended, sample(120, velocity: 1500))
            try #require(pager.isMoving)
            pinch(env.activeController!)
            #expect(env.ui.deckProgress == 0)
            #expect(!env.haptics.records.contains { $0.interaction == .pinchSwitcher })
        }
        do {
            let env = makeEnvironment()
            env.open(page("a"))
            #expect(env.ui.open(.menu))
            pinch(env.activeController!)
            #expect(env.ui.deckProgress == 0 && env.ui.overlay == .menu)
            #expect(!env.haptics.records.contains { $0.interaction == .pinchSwitcher })
        }
        do {
            let env = makeEnvironment()
            env.open(page("a"))
            env.ui.setDeck(1, animated: false)
            pinch(env.activeController!)
            #expect(!env.haptics.records.contains { $0.interaction == .pinchSwitcher })
        }
        do {
            let env = makeEnvironment()
            env.open(page("a"))
            let first = env.activeController!
            env.open(page("b"))
            pinch(first)
            #expect(env.ui.deckProgress == 0)
            #expect(!env.haptics.records.contains { $0.interaction == .pinchSwitcher })
        }
    }

    // The button's tap takes the page's picture once the deck rests, where the page is still. Under a pinch WebKit keeps
    // shrinking the page past that rest, so the pinched page's picture waits for WebKit's zoom to end: here the fingers
    // lift on a page WebKit is not zooming, and the capture comes then, once.
    @Test func thePinchedPagesPictureWaitsForItsZoomToEndNotForTheDeck() async throws {
        let pinched = try await settled()
        let tapped = try await settled()
        let pinch = fired(on: pinched.controller)
        tapped.env.showSwitcher(via: .tabStackTap)
        #expect(pinched.env.ui.deckProgress == 1 && tapped.env.ui.deckProgress == 1)
        stepToRest(pinched.env)
        stepToRest(tapped.env)
        try await waitUntil { tapped.captures.ids == [tapped.controller.tabID] }
        #expect(pinched.captures.ids.isEmpty)

        end(pinch, on: pinched.controller)
        #expect(pinched.captures.ids == [pinched.controller.tabID])
        pinched.controller.scrollViewDidEndZooming(pinched.controller.webView.scrollView, with: nil, atScale: 1)
        #expect(pinched.captures.ids == [pinched.controller.tabID])
        pinched.env.ui.deck.resume()
        tapped.env.ui.deck.resume()
    }

    // WebKit's zoom end, from the page's scroll view or the reader's, takes the pinched page's picture once; a zoom end
    // with no fire behind it, or a pinch the environment refused, takes nothing.
    @Test func webKitsZoomEndCapturesThePinchedPageOnce() async throws {
        let (env, controller, captures) = try await settled()
        let webPinch = fired(on: controller)
        controller.scrollViewDidEndZooming(controller.webView.scrollView, with: nil, atScale: 1)
        #expect(captures.ids == [controller.tabID])
        end(webPinch, on: controller)
        controller.scrollViewDidEndZooming(controller.webView.scrollView, with: nil, atScale: 1)
        #expect(captures.ids == [controller.tabID])

        env.ui.setDeck(0, animated: false)
        let readerPinch = fired(on: controller)
        controller.reader.onZoomEnded!()
        #expect(captures.ids == [controller.tabID, controller.tabID])
        end(readerPinch, on: controller)
        #expect(captures.ids.count == 2)

        #expect(env.ui.open(.menu))
        pinch(controller)
        controller.scrollViewDidEndZooming(controller.webView.scrollView, with: nil, atScale: 1)
        #expect(captures.ids.count == 2)
        env.ui.deck.resume()
    }
}

@MainActor final class Captures {
    var ids: [Tab.ID] = []
}

struct PinchToSwitcherTests {
    // The gate reads the visible scroll view: at its minimum zoom within the slack, a desktop page's fraction included.
    @Test func theGateHoldsAtMinimumZoomWithinTheSlack() {
        #expect(PinchToSwitcher.isAtMinimumZoom(zoomScale: 1, minimumZoomScale: 1))
        #expect(PinchToSwitcher.isAtMinimumZoom(zoomScale: 1.005, minimumZoomScale: 1))
        #expect(!PinchToSwitcher.isAtMinimumZoom(zoomScale: 1.02, minimumZoomScale: 1))
        #expect(!PinchToSwitcher.isAtMinimumZoom(zoomScale: 2, minimumZoomScale: 1))
        #expect(PinchToSwitcher.isAtMinimumZoom(zoomScale: 0.395, minimumZoomScale: 0.39))
        #expect(PinchToSwitcher.fires(scale: 0.85))
        #expect(PinchToSwitcher.fires(scale: 0.84))
        #expect(!PinchToSwitcher.fires(scale: 0.86))
    }

    @Test func theTrackerFiresOncePerPinchArmedAtMinimumZoom() {
        var tracker = PinchToSwitcher.Tracker()
        var fired = [tracker.changed(scale: 0.5, atMinimumZoom: true)]
        tracker.began(atMinimumZoom: true)
        fired += [
            tracker.changed(scale: 0.9, atMinimumZoom: true), tracker.changed(scale: 0.84, atMinimumZoom: true),
            tracker.changed(scale: 0.5, atMinimumZoom: true),
        ]
        tracker.ended()
        tracker.began(atMinimumZoom: true)
        fired.append(tracker.changed(scale: 0.84, atMinimumZoom: true))
        tracker.ended()
        tracker.began(atMinimumZoom: false)
        fired.append(tracker.changed(scale: 0.5, atMinimumZoom: true))
        tracker.ended()
        // The page zoomed in during the pinch, then came back.
        tracker.began(atMinimumZoom: true)
        fired += [tracker.changed(scale: 0.84, atMinimumZoom: false), tracker.changed(scale: 0.8, atMinimumZoom: true)]
        #expect(fired == [false, false, true, false, true, false, false, true])
    }
}
