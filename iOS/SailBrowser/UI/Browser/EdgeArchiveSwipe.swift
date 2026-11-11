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
//
// Its mirror, a swipe left from the right half, goes forward: on the tab an edge swipe landed on, it brings the tab it
// archived back from the Archive (EdgeForwardHistory). That tab's picture comes in from the right over the page, on
// the same magnet, as UIKit's forward push.
//
// A page with history moves through it the same way, in place of WebKit's own edge swipes (EdgeArchive.backMove,
// forwardMove): back slides the page off over its picture of the page before, forward slides its picture of the page
// after in over it, both on the magnet, and the picture stays over the page until the page it went to shows.
@MainActor final class EdgeArchiveSwipe {
    enum Direction {
        // Right from the left half: back through the page's history, or, on its first page, the tab to the Archive.
        case historyBack, archive
        // Left from the right half: forward through the history, or the last tab archived from here comes back.
        case historyForward
        case restore(EdgeForwardHistory.Entry)

        var isForward: Bool {
            switch self {
            case .historyForward, .restore: true
            case .historyBack, .archive: false
            }
        }
    }

    private struct Swipe {
        let pan: UIPanGestureRecognizer
        let controller: WebTabController
        let container: WebPageView.Container
        let tabID: Tab.ID
        let direction: Direction
        var magnet: EdgeMagnet
        var offset: CGFloat = 0
        // Set by the release: whether the spring ends with the swipe done.
        var completes: Bool?

        // The finger's travel in the swipe's direction.
        func travel(_ x: CGFloat) -> CGFloat {
            direction.isForward ? -x : x
        }

        // Animatable: the page and its picture where the swipe has them.
        func show(_ offset: CGFloat) {
            if direction.isForward {
                container.setForwardShift(offset)
            } else {
                container.setEdgeShift(offset)
            }
        }
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
        backDirection(controller) != nil
    }

    // The same page, with somewhere to go forward or a tab the edge swipe archived from here.
    func takesForward(_ controller: WebTabController) -> Bool {
        forwardDirection(controller) != nil
    }

    private func backDirection(_ controller: WebTabController) -> Direction? {
        guard let tab = shownTab(controller) else { return nil }
        switch EdgeArchive.backMove(canGoBack: controller.canGoBack, isPinned: tab.isPinned, isPrivate: tab.isPrivate) {
        case .historyBack: return .historyBack
        case .archive: return .archive
        case .historyForward, .restore, nil: return nil
        }
    }

    private func forwardDirection(_ controller: WebTabController) -> Direction? {
        guard shownTab(controller) != nil else { return nil }
        let entry = controller.canGoForward ? nil : env.forwardEntry()
        switch EdgeArchive.forwardMove(canGoForward: controller.canGoForward, hasArchivedTab: entry != nil) {
        case .historyForward: return .historyForward
        case .restore: return entry.map(Direction.restore)
        case .historyBack, .archive, nil: return nil
        }
    }

    func swiped(_ pan: UIPanGestureRecognizer, on controller: WebTabController) {
        handle(pan, on: controller, forward: false)
    }

    func swipedForward(_ pan: UIPanGestureRecognizer, on controller: WebTabController) {
        handle(pan, on: controller, forward: true)
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

    private func shownTab(_ controller: WebTabController) -> Tab? {
        let deck = env.ui.deck
        guard swipe == nil, controller === env.activeController, env.ui.overlay == .none, env.ui.deckProgress == 0,
            !deck.isZooming, !deck.isPaging, deck.flick == nil, env.pager?.isMoving != true,
            env.flick?.isMoving != true, let tab = env.browser.activeTab, tab.id == controller.tabID
        else { return nil }
        return tab
    }

    private func handle(_ pan: UIPanGestureRecognizer, on controller: WebTabController, forward: Bool) {
        switch pan.state {
        case .began:
            began(pan, on: controller, forward: forward)
        case .changed:
            guard let swipe, swipe.pan === pan, swipe.completes == nil else { return }
            move(to: swipe.travel(pan.translation(in: swipe.container).x))
        case .ended:
            guard let swipe, swipe.pan === pan, swipe.completes == nil else { return }
            release(velocity: swipe.travel(pan.velocity(in: swipe.container).x), cancelled: false)
        case .cancelled, .failed:
            guard let swipe, swipe.pan === pan, swipe.completes == nil else { return }
            release(velocity: 0, cancelled: true)
        default:
            break
        }
    }

    private func began(_ pan: UIPanGestureRecognizer, on controller: WebTabController, forward: Bool) {
        let direction = forward ? forwardDirection(controller) : backDirection(controller)
        guard let direction, let container = controller.pageContainer else {
            pan.isEnabled = false
            pan.isEnabled = true
            return
        }
        env.cancelWarmUp()
        presence = FrameRateVote.Presence()
        let pageFill = Self.fill(env.browser.activeTab?.tint)
        switch direction {
        case .archive:
            let (picture, fill) = landing()
            container.beginEdgeSwipe(picture: picture, fill: fill)
        case .historyBack:
            // The page left gets its picture now, while it is surely still the one shown, for a swipe forward to it.
            controller.captureHistoryPicture()
            container.beginEdgeSwipe(picture: controller.backPicture, fill: pageFill)
        case .historyForward:
            controller.captureHistoryPicture()
            container.beginForwardSwipe(picture: controller.forwardPicture, fill: pageFill)
        case .restore(let entry):
            let (picture, tint) = env.forwardPicture(for: entry.archived)
            container.beginForwardSwipe(picture: picture, fill: Self.fill(tint))
        }
        let swipe = Swipe(
            pan: pan, controller: controller, container: container, tabID: controller.tabID, direction: direction,
            magnet: EdgeMagnet(width: container.bounds.width))
        self.swipe = swipe
        env.haptics.prepare(.webEdgeSwipe, .webForwardSwipe, .webEdgeSwipeFree, .webEdgeSwipeStick)
        move(to: swipe.travel(pan.translation(in: container).x))
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
        return (thumbnail.image ?? thumbnail.small, Self.fill(tab.tint))
    }

    private static func fill(_ tint: CodableColor?) -> UIColor {
        tint.map { UIColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: 1) }
            ?? UIColor(Theme.Palette.newTabPlaceholder)
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
        swipe.show(swipe.offset)
        self.swipe = swipe
    }

    // Each frame the finger has the page: the page where the magnet draws it, and the texture under the finger.
    private func frame(at now: ContinuousClock.Instant) -> Bool {
        guard var swipe, swipe.completes == nil else { return false }
        env.haptics.drive(Theme.Haptic.edgeTexture, swipe.magnet.level(at: now))
        let offset = swipe.magnet.offset(at: now)
        if offset != swipe.offset {
            swipe.offset = offset
            swipe.show(offset)
        }
        self.swipe = swipe
        return true
    }

    private func stopMagnet() {
        clock?.stop()
        clock = nil
        env.haptics.stop(Theme.Haptic.edgeTexture)
    }

    // The page coming free already played the haptic the swipe promises; the release records itself silently.
    private func release(velocity: CGFloat, cancelled: Bool) {
        guard var swipe else { return }
        presence = nil
        stopMagnet()
        swipe.offset = swipe.magnet.offset(at: .now)
        swipe.show(swipe.offset)
        let width = swipe.container.bounds.width
        // A tab switch from elsewhere under the finger (a link opening a tab) leaves the page at rest.
        let isCurrent = swipe.controller === env.activeController && env.browser.activeTabID == swipe.tabID
        let completes =
            !cancelled && isCurrent && EdgeArchive.completes(isFree: swipe.magnet.isFree, velocity: velocity)
        swipe.completes = completes
        self.swipe = swipe
        if completes {
            switch swipe.direction {
            case .archive where env.browser.previousTabID == nil: break
            case .archive, .historyBack: env.haptics.fire(.webEdgeSwipe)
            case .historyForward, .restore: env.haptics.fire(.webForwardSwipe)
            }
        }
        generation += 1
        let release = generation
        let token = Theme.Motion.edgeArchive
        FrameRateVote.hold(token)
        let landed = swipe
        token.animate(
            initialVelocity: EdgeArchive.releaseVelocity(
                offset: swipe.offset, velocity: velocity, completes: completes, width: width),
            { landed.show(completes ? width : 0) },
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

    // Archive: the page is off the screen with the landing tab's picture under it; the store switches, and the
    // archived tab's card leaves with its container, so the picture shows until the landing tab's own card replaces it.
    // Restore: the returning tab's picture covers the page; the tab comes back with it as its snapshot, and the page
    // left keeps its own card, so its picture comes off.
    // History: the picture of the page gone to covers the page, which moves there under it; the picture fades once
    // that page shows.
    private func commit(_ swipe: Swipe) {
        switch swipe.direction {
        case .archive:
            env.edgeArchived(swipe.tabID)
            if env.browser.tabs.contains(where: { $0.id == swipe.tabID }) {
                swipe.container.endEdgeSwipe()
            }
        case .restore(let entry):
            env.edgeForwarded(entry)
            swipe.container.endEdgeSwipe()
        case .historyBack, .historyForward:
            let container = swipe.container
            let back = !swipe.direction.isForward
            let held = container.holdSwipePicture()
            Task { [weak controller = swipe.controller] in
                await controller?.moveThroughHistory(back: back)
                if let held {
                    container.releaseHeldPicture(held)
                }
            }
        }
    }
}
