import SwiftUI
import UIKit

// A swipe right from the left half of a page with nothing to go back to archives its tab, as a card thrown away in the
// switcher, and shows the tab shown before it, the one a flick on the tab stack goes to. The page slides right over
// that tab's picture, as UIKit's back swipe slides over the screen under it, but held as by a magnet, as Arc Search's
// is (EdgeMagnet): it gives a little under the finger with a texture that sharpens as the pull grows, comes free with
// a thock past the unstick line and closes on the finger, and sticks again with a click back under it. A release while
// it is free sends the page off and archives the tab once it has gone; one while it is held, or a flick back, springs
// it to rest. A private tab closes instead, a pinned tab takes no swipe, and a page with somewhere to go
// back to keeps WebKit's own back swipe (EdgeArchive.outcome). With no other tab the empty deck shows, as after the
// switcher's last card.
@MainActor final class EdgeArchiveSwipe {
    private struct Swipe {
        let pan: UIPanGestureRecognizer
        let controller: WebTabController
        let container: WebPageView.Container
        let tabID: Tab.ID
        var magnet: EdgeMagnet
        var offset: CGFloat = 0
        // Set by the release: whether the spring ends with the tab archived.
        var completes: Bool?
    }

    private unowned let env: AppEnvironment
    private var swipe: Swipe?
    // Bumped by every release and finish, so a spring's completion that a finish overtook does nothing.
    private var generation = 0
    // The 120 Hz vote while the finger has the page; the release's spring holds its own.
    private var presence: FrameRateVote.Presence?
    // Draws the page each frame while the finger has it, so the magnet's spring runs under a still finger, and drives
    // the texture.
    private var clock: FrameClock?

    init(env: AppEnvironment) {
        self.env = env
    }

    // From the first move to the end of the release's spring.
    var isMoving: Bool {
        swipe != nil
    }

    // The active page in the browser with nothing over it and no zoom, swipe or flick in motion, on a tab the swipe
    // may take.
    func takes(_ controller: WebTabController) -> Bool {
        let deck = env.ui.deck
        guard swipe == nil, controller === env.activeController, env.ui.overlay == .none, env.ui.deckProgress == 0,
            !deck.isZooming, !deck.isPaging, deck.flick == nil, env.pager?.isMoving != true,
            env.flick?.isMoving != true, let tab = env.browser.activeTab, tab.id == controller.tabID
        else { return false }
        return EdgeArchive.outcome(isPinned: tab.isPinned, isPrivate: tab.isPrivate, canGoBack: controller.canGoBack)
            != nil
    }

    func swiped(_ pan: UIPanGestureRecognizer, on controller: WebTabController) {
        switch pan.state {
        case .began:
            began(pan, on: controller)
        case .changed:
            guard let swipe, swipe.pan === pan, swipe.completes == nil else { return }
            move(to: pan.translation(in: swipe.container).x)
        case .ended:
            guard let swipe, swipe.pan === pan, swipe.completes == nil else { return }
            release(velocity: pan.velocity(in: swipe.container).x, cancelled: false)
        case .cancelled, .failed:
            guard let swipe, swipe.pan === pan, swipe.completes == nil else { return }
            release(velocity: 0, cancelled: true)
        default:
            break
        }
    }

    // Another tab switch, the switcher or a sheet lands the swipe at once: a spring heading off the screen archives
    // now, anything else goes back to rest.
    func finish() {
        guard let swipe else { return }
        generation += 1
        presence = nil
        stopMagnet()
        self.swipe = nil
        if swipe.completes == true {
            commit(swipe)
        } else {
            swipe.container.endEdgeSwipe()
        }
        // A finger still on the page loses it; its cancel finds no swipe.
        if swipe.completes == nil {
            swipe.pan.isEnabled = false
            swipe.pan.isEnabled = true
        }
    }

    private func began(_ pan: UIPanGestureRecognizer, on controller: WebTabController) {
        guard takes(controller), let container = controller.pageContainer else {
            pan.isEnabled = false
            pan.isEnabled = true
            return
        }
        env.cancelWarmUp()
        presence = FrameRateVote.Presence()
        let (picture, fill) = landing()
        container.beginEdgeSwipe(picture: picture, fill: fill)
        swipe = Swipe(
            pan: pan, controller: controller, container: container, tabID: controller.tabID,
            magnet: EdgeMagnet(width: container.bounds.width))
        env.haptics.prepare(.webEdgeSwipe, .webEdgeSwipeFree, .webEdgeSwipeStick)
        move(to: pan.translation(in: container).x)
        clock = FrameClock { [weak self] now in
            self?.frame(at: now) ?? false
        }
    }

    // The previous tab's picture over its tint, or its tint alone; with no other tab, the empty deck's backdrop.
    private func landing() -> (UIImage?, UIColor) {
        guard let id = env.browser.previousTabID, let tab = env.browser.tabs.first(where: { $0.id == id }) else {
            return (nil, UIColor(Theme.Palette.deckGradientStops.first!.color))
        }
        let thumbnail = env.snapshots.thumbnail(for: id)
        let fill = tab.tint.map { UIColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: 1) }
            ?? UIColor(Theme.Palette.newTabPlaceholder)
        return (thumbnail.image ?? thumbnail.small, fill)
    }

    private func move(to translation: CGFloat) {
        guard var swipe else { return }
        let now = ContinuousClock.now
        switch swipe.magnet.update(translation: translation, at: now) {
        case .freed: env.haptics.fire(.webEdgeSwipeFree)
        case .stuck: env.haptics.fire(.webEdgeSwipeStick)
        case nil: break
        }
        swipe.offset = swipe.magnet.offset(at: now)
        swipe.container.setEdgeShift(swipe.offset)
        self.swipe = swipe
    }

    // Each frame the finger has the page: the page where the magnet draws it, and the texture under the finger.
    private func frame(at now: ContinuousClock.Instant) -> Bool {
        guard var swipe, swipe.completes == nil else { return false }
        env.haptics.drive(Theme.Haptic.edgeTexture, swipe.magnet.level(at: now))
        let offset = swipe.magnet.offset(at: now)
        if offset != swipe.offset {
            swipe.offset = offset
            swipe.container.setEdgeShift(offset)
        }
        self.swipe = swipe
        return true
    }

    private func stopMagnet() {
        clock?.stop()
        clock = nil
        env.haptics.stop(Theme.Haptic.edgeTexture)
    }

    // The page coming free already played the haptic the archive promises; the release records itself silently.
    private func release(velocity: CGFloat, cancelled: Bool) {
        guard var swipe else { return }
        presence = nil
        stopMagnet()
        swipe.offset = swipe.magnet.offset(at: .now)
        swipe.container.setEdgeShift(swipe.offset)
        let width = swipe.container.bounds.width
        // A tab switch from elsewhere under the finger (a link opening a tab) leaves the page at rest.
        let isCurrent = swipe.controller === env.activeController && env.browser.activeTabID == swipe.tabID
        let completes =
            !cancelled && isCurrent && EdgeArchive.completes(isFree: swipe.magnet.isFree, velocity: velocity)
        swipe.completes = completes
        self.swipe = swipe
        if completes, env.browser.previousTabID != nil {
            env.haptics.fire(.webEdgeSwipe)
        }
        generation += 1
        let release = generation
        let token = Theme.Motion.edgeArchive
        FrameRateVote.hold(token)
        let container = swipe.container
        token.animate(
            initialVelocity: EdgeArchive.releaseVelocity(
                offset: swipe.offset, velocity: velocity, completes: completes, width: width),
            { container.setEdgeShift(completes ? width : 0) },
            completion: { [weak self] _ in
                guard let self, generation == release else { return }
                settled()
            })
    }

    private func settled() {
        guard let swipe else { return }
        self.swipe = nil
        if swipe.completes == true {
            commit(swipe)
        } else {
            swipe.container.endEdgeSwipe()
        }
    }

    // The page is off the screen with the landing tab's picture under it: the store switches, and the archived tab's
    // card leaves with its container, so the picture shows until the landing tab's own card replaces it.
    private func commit(_ swipe: Swipe) {
        env.edgeArchived(swipe.tabID)
        if env.browser.tabs.contains(where: { $0.id == swipe.tabID }) {
            swipe.container.endEdgeSwipe()
        }
    }
}
