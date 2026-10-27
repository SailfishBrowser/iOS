import Observation
import UIKit
import WebKit

// Which pages are in element fullscreen, and so whether the app may rotate. The app delegate answers with `mask`;
// the plist stays portrait-only. A page is tracked for its life, so every fullscreen episode is heard, however the
// card that shows it comes and goes.
@Observable final class OrientationPolicy {
    private struct Tracked {
        weak var webView: WKWebView?
        let observation: NSKeyValueObservation
    }

    static let shared = OrientationPolicy()

    private var fullscreenWebViews: Set<ObjectIdentifier> = []
    // WebKit's fullscreen hierarchy holds a page mid-episode; a dead entry goes, id and all, before it can pin the mask
    // or alias a new page at the same address.
    @ObservationIgnored private var tracked: [ObjectIdentifier: Tracked] = [:]
    // Asks the scene for portrait and has UIKit re-read the delegate. Tests replace it with a recorder.
    @ObservationIgnored var restorePortrait: (UIWindow) -> Void = { window in
        window.windowScene!.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    var isElementFullscreen: Bool {
        !fullscreenWebViews.isEmpty
    }

    var mask: UIInterfaceOrientationMask {
        isElementFullscreen ? .allButUpsideDown : .portrait
    }

    func track(_ webView: WKWebView) {
        for (id, entry) in tracked where entry.webView == nil {
            tracked[id] = nil
            fullscreenWebViews.remove(id)
        }
        let id = ObjectIdentifier(webView)
        guard tracked[id] == nil else { return }
        // WebKit sets the state on the main thread inside its own fullscreen calls.
        let observation = webView.observe(\.fullscreenState) { [weak self] webView, _ in
            MainActor.assumeIsolated { self?.changed(webView) }
        }
        tracked[id] = Tracked(webView: webView, observation: observation)
    }

    // The mask widens as a page enters and narrows only once the page is back: while WebKit's controller is still
    // presented, its own mask (the page's orientation lock) has to intersect ours. Returns true when the mask changed.
    @discardableResult func record(_ state: WKWebView.FullscreenState, of id: ObjectIdentifier) -> Bool {
        let before = mask
        switch state {
        case .enteringFullscreen, .inFullscreen:
            fullscreenWebViews.insert(id)
        case .notInFullscreen:
            fullscreenWebViews.remove(id)
        case .exitingFullscreen:
            break
        @unknown default:
            break
        }
        return mask != before
    }

    // As the exit starts the web view is still in WebKit's window and the request is a geometry one, which UIKit
    // refuses while the page holds a landscape lock; the one at .notInFullscreen comes from our own window and lands.
    private func changed(_ webView: WKWebView) {
        let state = webView.fullscreenState
        record(state, of: ObjectIdentifier(webView))
        guard let window = webView.window,
            state == .notInFullscreen || state == .exitingFullscreen && Theme.Fullscreen.returnsToPortraitOnExitStart
        else { return }
        restorePortrait(window)
    }
}
