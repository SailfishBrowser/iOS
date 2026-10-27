import SwiftUI

// A flick up on the tab stack switches to the previous tab: as the pull locks the live page shrinks into the bottom-left corner, and the previous tab's card rises out of the tab
// stack over it, following the finger freely in both axes, drawn per frame on the deck's driver. A release
// past the flick distance, or on an upward flick, drops the page left into the tab stack and zooms the card to the
// screen; its haptic plays as it lands and the store switches once everything is still. An early release runs both
// back. The tab stack picks the flick up where it is drawn, and a touch anywhere holds it.
@MainActor final class TabStackFlick {
    let layout: CardLayout
    private unowned let env: AppEnvironment
    // The card's offset when the finger took it, the finger's translation then, and, for a fresh flick, the slop the
    // finger led the card by at the lock, which the card makes up over `tabStackFlickCatchUp` times its length.
    private var grip: (offset: CGSize, translation: CGSize, slop: CGSize)?
    // How much of the slop the card has still to make up, in points of rise.
    private var behind: CGFloat = 0
    private var isHeld = false
    // A caught flick holds where drawn until the finger moves, then arms again.
    private var rearms = false
    // The 120 Hz vote, held from the stack's touch-down to the lift; the frame clock carries the rate after that.
    private(set) var presence: FrameRateVote.Presence?

    init(env: AppEnvironment, layout: CardLayout) {
        self.env = env
        self.layout = layout
    }

    private var driver: DeckDriver {
        env.ui.deck
    }

    var isMoving: Bool {
        driver.isFlickMoving
    }

    // The stack's finger has the card.
    var isDragging: Bool {
        grip != nil
    }

    // How far the card has risen, in points.
    private var travel: CGFloat {
        -driver.flick!.offsetY
    }

    // A touch on the tab stack takes a springing or held flick where it is drawn. A landing goes on. True when it
    // took one.
    func touchDown() -> Bool {
        presence = FrameRateVote.Presence()
        guard driver.flick != nil, isMoving || isHeld, !driver.isFlickLanding else { return false }
        isHeld = false
        driver.holdFlick()
        grip = (driver.flick!.offset, .zero, .zero)
        behind = 0
        rearms = true
        return true
    }

    // From rest the flick takes the touch once upward travel leads by the slop, at `start` in the tab stack button's
    // own space. The card starts where it is, with no jump, and makes up the slop over the catch-up's multiple of it,
    // so the point the finger took is under it exactly from then on, on the same move.
    func moved(_ translation: CGSize, from start: CGPoint) {
        guard let grip else {
            begin(translation, from: start)
            return
        }
        // Another tab switch can land the flick under the finger.
        guard let flick = driver.flick else {
            self.grip = nil
            return
        }
        let follow = Theme.Gesture.tabStackFlickFollow
        let moved = CGSize(
            width: translation.width - grip.translation.width, height: translation.height - grip.translation.height)
        let slop = hypot(grip.slop.width, grip.slop.height)
        let since = hypot(moved.width - grip.slop.width, moved.height - grip.slop.height)
        let left = slop == 0 ? 0 : max(0, 1 - since / (slop * Theme.Gesture.tabStackFlickCatchUp))
        behind = -grip.slop.height * left * follow
        let offset = CGSize(
            width: grip.offset.width + (moved.width - grip.slop.width * left) * follow,
            height: grip.offset.height + (moved.height - grip.slop.height * left) * follow)
        // The card grows out of the stack with its rise toward the peek's height and keeps the size it has reached,
        // wherever it goes from there.
        let grow = max(flick.grow, layout.flickGrow(rise: -offset.height, grab: flick.grab, safeTop: flick.safeTop))
        guard rearms else {
            driver.moveFlick(to: offset, grow: grow)
            return
        }
        rearms = false
        driver.batch {
            driver.moveFlick(to: offset, grow: grow)
            driver.animateFlick(\.arm, to: 1, spring: DeckSnap.flick)
        }
    }

    // Velocity is the finger's, down positive. The landing line is the finger's travel, against its coast.
    func lifted(velocity: CGSize) {
        presence = nil
        guard grip != nil else { return }
        grip = nil
        rearms = false
        guard driver.flick != nil else { return }
        let finishes = TabStackButton.finishes(travel: travel + behind, velocity: velocity.height)
        behind = 0
        if finishes {
            land(velocity: velocity)
        } else {
            back(velocity: velocity)
        }
    }

    func hold() {
        guard isMoving else { return }
        isHeld = true
        driver.holdFlick()
    }

    // A hold the tab stack never took lands on the end its drawn pull reaches; a landing goes on.
    func catchEnded() {
        guard isHeld else { return }
        isHeld = false
        guard grip == nil, driver.flick != nil else { return }
        if driver.isFlickLanding || TabStackButton.finishes(travel: travel, velocity: 0) {
            land(velocity: .zero)
        } else {
            back(velocity: .zero)
        }
    }

    // Another tab switch or the switcher lands the flick at once: on the previous tab if it is landing or heading
    // there, or, under the finger or held, if its pull is past the line.
    func finish() {
        presence = nil
        finishFlick()
    }

    private func finishFlick() {
        guard let flick = driver.flick else { return }
        // Landing, or with no spring running and the pull past the line.
        let finishing = driver.isFlickLanding
            || driver.flickTarget == nil && TabStackButton.finishes(travel: travel + behind, velocity: 0)
        let played = hasLanded
        grip = nil
        behind = 0
        isHeld = false
        driver.endFlick()
        if finishing, env.browser.activeTabID != flick.to {
            if !played {
                env.haptics.fire(.tabStackFlick)
            }
            env.flickedTo(flick.to)
        }
    }

    private func begin(_ translation: CGSize, from start: CGPoint) {
        guard BarSwipe.lock(translation) == .vertical, translation.height < 0, env.ui.overlay == .none,
            env.ui.deckProgress == 0, !driver.isZooming
        else { return }
        // A swipe on the bar still springing lands first, so the flick leaves the tab it lands on. A flick still
        // landing (the stack's touch-down takes any other flick where drawn) lands first too, so this one flicks back
        // to the tab just left, a toggle; its page cuts from its drawn zoom to the arm's first frame.
        env.pager?.finish()
        finishFlick()
        guard let previous = env.browser.previousTabID, let active = env.browser.activeTabID else { return }
        let button = layout.tabStackButtonFrame.origin
        let grab = layout.flickGrab(at: CGPoint(x: button.x + start.x, y: button.y + start.y))
        driver.batch {
            driver.beginFlick(from: active, to: previous, safeTop: env.pool.page.safeTop, grab: grab)
            driver.animateFlick(\.arm, to: 1, spring: DeckSnap.flick)
        }
        grip = (.zero, .zero, translation)
        behind = -translation.height * Theme.Gesture.tabStackFlickFollow
    }

    // The landing's haptic has played once the card is within the settled distance of the screen.
    private var hasLanded: Bool {
        driver.flick!.land > 1 - Theme.Gesture.deckSettledDistance
    }

    // The page left drops into the tab stack and the card zooms to the screen from where both are drawn, while the card
    // coasts straight up to the peek's height, always before it lands, and sideways only as far as the
    // finger's speed carries it from where it was put. Both axes carry the finger's speed. The haptic plays as the card
    // visibly lands; the store switches once everything is still. A flick caught after its switch only springs on.
    private func land(velocity: CGSize) {
        let to = driver.flick!.to
        let flick = driver.flick!
        let follow = Theme.Gesture.tabStackFlickFollow
        let rise = layout.flickRiseHeight(grab: flick.grab, safeTop: flick.safeTop)
        let coast = Magnet.project(velocity: velocity.width * follow, rate: Theme.Gesture.decelerationFast)
        let switches = env.browser.activeTabID != to
        let played = hasLanded
        driver.batch {
            driver.animateFlick(
                \.offsetX, to: flick.offsetX + coast, spring: DeckSnap.flick, velocity: velocity.width * follow)
            driver.animateFlick(\.offsetY, to: -rise, spring: DeckSnap.flick, velocity: velocity.height * follow)
            driver.animateFlick(\.grow, to: 1, spring: DeckSnap.flick)
            driver.animateFlick(\.drop, to: 1, spring: DeckSnap.flickDrop)
            driver.animateFlick(\.land, to: 1, spring: DeckSnap.flick)
            driver.releaseFlick(
                landing: switches && !played ? { [weak self] in self?.env.haptics.fire(.tabStackFlick) } : nil,
                settled: switches ? { [weak self] in self?.env.flickedTo(to) } : nil)
        }
    }

    // Both cards run back from where they are drawn, carrying the finger's speed in both axes: the previous tab's card
    // into the tab stack, the live page to the screen.
    private func back(velocity: CGSize) {
        let follow = Theme.Gesture.tabStackFlickFollow
        driver.batch {
            driver.animateFlick(\.offsetX, to: 0, spring: DeckSnap.flick, velocity: velocity.width * follow)
            driver.animateFlick(\.offsetY, to: 0, spring: DeckSnap.flick, velocity: velocity.height * follow)
            driver.animateFlick(\.grow, to: 0, spring: DeckSnap.flick)
            driver.animateFlick(\.arm, to: 0, spring: DeckSnap.flick)
            driver.releaseFlick(landing: nil, settled: nil)
        }
    }
}
