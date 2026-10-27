import Testing
import UIKit
import WebKit
@testable import SailBrowser

// Drives the real KVO on fullscreenState without simulator fullscreen.
final class FullscreenWebView: WKWebView {
    var state = WKWebView.FullscreenState.notInFullscreen {
        willSet { willChangeValue(forKey: "fullscreenState") }
        didSet { didChangeValue(forKey: "fullscreenState") }
    }

    override var fullscreenState: WKWebView.FullscreenState {
        state
    }
}

struct OrientationPolicyTests {
    @Test func theMaskWidensOnEntryAndNarrowsOnlyOnceThePageIsBack() {
        let policy = OrientationPolicy()
        let id = ObjectIdentifier(policy)
        #expect(policy.mask == .portrait)
        #expect(policy.record(.enteringFullscreen, of: id))
        #expect(policy.mask == .allButUpsideDown)
        #expect(!policy.record(.inFullscreen, of: id))
        #expect(!policy.record(.exitingFullscreen, of: id))
        #expect(policy.mask == .allButUpsideDown)
        #expect(policy.isElementFullscreen)
        #expect(policy.record(.notInFullscreen, of: id))
        #expect(policy.mask == .portrait)
        #expect(!policy.isElementFullscreen)
    }

    @Test func twoPagesKeepTheMaskWideUntilBothAreBack() {
        let policy = OrientationPolicy()
        let first = ObjectIdentifier(policy)
        let second = ObjectIdentifier(Theme.self)
        #expect(policy.record(.enteringFullscreen, of: first))
        #expect(!policy.record(.enteringFullscreen, of: second))
        #expect(!policy.record(.notInFullscreen, of: second))
        #expect(policy.mask == .allButUpsideDown)
        #expect(policy.record(.notInFullscreen, of: first))
        #expect(policy.mask == .portrait)
    }

    @Test func anUnknownPageLeavesTheMaskPortrait() {
        let policy = OrientationPolicy()
        #expect(!policy.record(.notInFullscreen, of: ObjectIdentifier(policy)))
        #expect(!policy.record(.exitingFullscreen, of: ObjectIdentifier(policy)))
        #expect(policy.mask == .portrait)
    }

    @Test func aTrackedPageDrivesTheMaskAndTheTurnBack() {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let webView = FullscreenWebView()
        window.addSubview(webView)
        let policy = OrientationPolicy()
        var restored: [UIWindow] = []
        policy.restorePortrait = { restored.append($0) }
        policy.track(webView)
        policy.track(webView)
        #expect(Theme.Fullscreen.returnsToPortraitOnExitStart)

        webView.state = .enteringFullscreen
        #expect(policy.isElementFullscreen)
        #expect(restored.isEmpty)
        webView.state = .inFullscreen
        #expect(restored.isEmpty)
        webView.state = .exitingFullscreen
        #expect(policy.mask == .allButUpsideDown)
        #expect(restored.count == 1)
        webView.state = .notInFullscreen
        #expect(policy.mask == .portrait)
        #expect(restored.count == 2)
        #expect(restored.allSatisfy { $0 === window })
    }

    // Its process dies mid-film and the reload is asked for; the tab is then evicted before WebKit reports the exit.
    @Test func aPageThatDiesMidFullscreenCannotPinTheMask() async throws {
        let policy = OrientationPolicy()
        weak var freed: WKWebView?
        do {
            let webView = FullscreenWebView()
            freed = webView
            policy.track(webView)
            webView.state = .inFullscreen
            let controller = WebTabController(tabID: UUID(), webView: webView, haptics: recordingHaptics())
            controller.webViewWebContentProcessDidTerminate(webView)
            #expect(controller.needsReload)
            #expect(policy.mask == .allButUpsideDown)
        }
        try await waitUntil { freed == nil }
        policy.track(FullscreenWebView())
        #expect(!policy.isElementFullscreen)
        #expect(policy.mask == .portrait)
    }

    // On screen the termination reloads the page while WebKit still holds it; the mask narrows on the exit WebKit
    // then reports, with the one turn back.
    @Test func aTerminationMidFullscreenNarrowsTheMaskOnceWebKitExits() {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let webView = FullscreenWebView()
        let controller = WebTabController(tabID: UUID(), webView: webView, haptics: recordingHaptics())
        window.addSubview(webView)
        let policy = OrientationPolicy()
        var restores = 0
        policy.restorePortrait = { _ in restores += 1 }
        policy.track(webView)
        webView.state = .inFullscreen
        #expect(policy.mask == .allButUpsideDown)

        controller.webViewWebContentProcessDidTerminate(webView)
        #expect(!controller.needsReload)
        #expect(policy.mask == .allButUpsideDown)
        #expect(restores == 0)

        webView.state = .notInFullscreen
        #expect(policy.mask == .portrait)
        #expect(restores == 1)
    }

    @Test func aPageOutOfAnyWindowChangesTheMaskWithoutATurn() {
        let webView = FullscreenWebView()
        let policy = OrientationPolicy()
        var restores = 0
        policy.restorePortrait = { _ in restores += 1 }
        policy.track(webView)
        webView.state = .inFullscreen
        #expect(policy.isElementFullscreen)
        webView.state = .notInFullscreen
        #expect(!policy.isElementFullscreen)
        #expect(restores == 0)
    }
}
