import UIKit

// What the search sheet and the page menu share: a sheet that springs on Core Animation, can be taken from where it is
// drawn at any moment, and answers touches by where it is drawn.

// A sheet's spring from its begin, so whatever takes the sheet during it knows how fast it is going.
struct SheetSpring {
    let begin: CFTimeInterval
    let travel: CGFloat
    let spring: MotionToken
    // Relative to the travel, as UIKit's is.
    let velocity: CGFloat

    func speed(at time: CFTimeInterval) -> CGFloat {
        spring.spring.velocity(target: travel, initialVelocity: velocity * travel, time: time - begin)
    }
}

// A touch-down on a moving sheet holds it where it is drawn, in the touch's own hit test, so the control under the finger
// is the one the touch lands on. This press sees the touch through to its end, where a catch let go without a drag
// finishes the sheet's rise.
final class SheetCatch: NSObject {
    let press = UILongPressGestureRecognizer()
    // The transition the catch holds the sheet in, and the pan's translation when it began from that catch: UIKit's
    // slop, which the sheet already held still through.
    fileprivate var heldIn: Int?
    fileprivate var slop: CGFloat = 0
    private var released: () -> Void = {}

    fileprivate func attach(to container: UIView, delegate: UIGestureRecognizerDelegate, released: @escaping () -> Void) {
        press.addTarget(self, action: #selector(pressed))
        press.minimumPressDuration = 0
        press.cancelsTouchesInView = false
        press.delegate = delegate
        container.addGestureRecognizer(press)
        self.released = released
    }

    @objc private func pressed(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .ended, .cancelled:
            released()
        default:
            break
        }
    }
}

// A sheet's drag, fed by its pan or by the DEBUG surface, and its catch. The host view routes the touches; the
// container is the sheet that moves. Each sheet supplies how it holds where it is drawn and how it rises from a hold.
protocol SheetDragging: UIViewController, UIGestureRecognizerDelegate {
    var container: UIView { get }
    var hostView: SheetHostView { get }
    var sheetCatch: SheetCatch { get }
    // Moves on with each motion, so whatever a motion left behind can tell it has been superseded.
    var transition: Int { get }
    // Holds the sheet where it is drawn, its parts included, and moves the transition on.
    func holdDrawn()
    // Let go without a drag, the sheet finishes its rise from where it is held.
    func riseFromHold()
    func dragBegan()
    func dragChanged(_ translation: CGFloat)
    func dragEnded(translation: CGFloat, velocity: CGFloat)
    func dragCancelled()
}

extension SheetDragging {
    var hostView: SheetHostView {
        view as! SheetHostView
    }

    var catcher: UILongPressGestureRecognizer {
        sheetCatch.press
    }

    // The pan and the catch on the container; the controller is their delegate.
    func addGestures(pan: UIPanGestureRecognizer) {
        pan.delegate = self
        container.addGestureRecognizer(pan)
        sheetCatch.attach(to: container, delegate: self) { [unowned self] in catchEnded() }
    }

    func catchBegan() {
        holdDrawn()
        sheetCatch.heldIn = transition
    }

    // A pan or a control's action since the catch has moved the transition on and takes the sheet instead.
    func catchEnded() {
        guard sheetCatch.heldIn == transition else { return }
        riseFromHold()
    }

    // The catch sees only a touch whose hit test caught the sheet.
    var catchMayBegin: Bool {
        sheetCatch.heldIn == transition
    }

    // A point on the drawn moving sheet. A touch holds the sheet there before any view or recognizer reads it, then goes
    // to what the held sheet has under it; a hit test that only asks where a point goes reaches what the model has at
    // the same place in the sheet.
    func caughtTarget(at point: CGPoint, with event: UIEvent?) -> UIView? {
        if event?.type == .touches {
            catchBegan()
            return hostView.modelHit(point, with: event)
        }
        let drawn = container.layer.presentation()!.frame
        return hostView.modelHit(CGPoint(x: point.x, y: point.y + container.frame.minY - drawn.minY), with: event)
    }

    func route(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: view).y
        switch pan.state {
        case .began:
            sheetCatch.slop = sheetCatch.heldIn == transition ? translation : 0
            cancelTouchSharers(from: hostView.touchedDown, keeping: pan)
            dragBegan()
            dragChanged(translation - sheetCatch.slop)
        case .changed:
            dragChanged(translation - sheetCatch.slop)
        case .ended:
            dragEnded(translation: translation - sheetCatch.slop, velocity: pan.velocity(in: view).y)
        case .cancelled, .failed:
            dragCancelled()
        default:
            break
        }
    }

    // Whatever else is tracking the touch under a beginning pan (a row's press, a field's selection) is cancelled, so
    // a drag that starts on a row never ends in its tap. Disabling a recognizer cancels it; it is enabled again for the
    // next touch. They are found from the view the touch landed on, not from where the pan is detected about 10 pt on,
    // which can have left the control. The catch is left to see its touch end: cancelled now, it would re-rise the
    // sheet the pan is taking.
    func cancelTouchSharers(from start: UIView?, keeping kept: UIGestureRecognizer...) {
        var touched = start
        while let current = touched {
            for other in current.gestureRecognizers ?? []
            where !kept.contains(where: { $0 === other }) && other !== catcher && other.isEnabled {
                other.isEnabled = false
                other.isEnabled = true
            }
            touched = current === container ? nil : current.superview
        }
    }

    #if DEBUG
    func route(_ phase: DragPhase, _ sample: DragSample) {
        switch phase {
        case .began:
            dragBegan()
            dragChanged(sample.translation.height)
        case .changed:
            dragChanged(sample.translation.height)
        case .ended:
            dragEnded(translation: sample.translation.height, velocity: sample.velocity.height)
        case .cancelled:
            dragCancelled()
        }
    }
    #endif
}

// A sheet that rises from the screen's bottom over a dim: the page menu and the permission prompt. Only the container's
// layer and the dim's layer move, on Core Animation springs that start where the sheet is drawn, stretched to arrive;
// the dim rides the sheet's spring with the same velocity, so its opacity stays a function of the drawn offset. The host
// names the spring a held sheet rises on and what a touch above the drawn sheet reaches, and keeps its own ends of a
// drag.
protocol SpringSheet: SheetDragging {
    var dim: UIView { get }
    var isOpen: Bool { get }
    // The spring the sheet is on; nil at rest, under the finger, or hidden.
    var motion: SheetSpring? { get set }
    var transition: Int { get set }
    var drag: MenuDrag { get set }
    // The deck's rate while the finger moves the sheet; each spring holds it for its settling time.
    var presence: FrameRateVote.Presence? { get set }
    var rise: MotionToken { get }
    var aboveSheet: UIView? { get }
}

extension SpringSheet {
    // From the sheet's top to the screen's bottom.
    var sheetHeight: CGFloat {
        container.bounds.height
    }

    // In the sheet's layer time, where its springs begin: media time in the app, held with a test's window.
    var now: CFTimeInterval {
        container.layer.convertTime(CACurrentMediaTime(), from: nil)
    }

    func nextTransition() {
        transition += 1
    }

    func place(_ offset: CGFloat) {
        container.transform = CGAffineTransform(translationX: 0, y: offset)
        dim.alpha = Theme.Opacity.menuDim * min(max(1 - offset / sheetHeight, 0), 1)
    }

    // Ends the sheet's motion where it is drawn, which becomes its model, and returns the speed it had there relative to
    // the travel to `target`. A sheet whose window has gone is drawn nowhere, and its model stands for it.
    func takeDrawn(toward target: CGFloat) -> CGFloat {
        guard let motion else { return 0 }
        let speed = motion.speed(at: now)
        place((container.layer.presentation() ?? container.layer).affineTransform().ty)
        container.layer.removeAllAnimations()
        dim.layer.removeAllAnimations()
        self.motion = nil
        return SheetDrag.releaseVelocity(speed, toward: target - container.transform.ty)
    }

    // The spring begins now, set on the animations and recorded before the commit, whose completion may run in it: a
    // sheet whose window has gone has its animation finish at once. Until that begin, on the next frame, each animation
    // shows where it starts, so the drawn sheet never jumps to the model. Core Animation runs the completion even once
    // the sheet is gone, so it holds the sheet weakly. Committed in this turn, so the motion starts on the next frame.
    func move(to target: CGFloat, on token: MotionToken, velocity: CGFloat, arrived: @escaping () -> Void) {
        let current = transition
        let begin = now
        let slide = token.layerAnimation(
            keyPath: "transform", from: NSValue(caTransform3D: container.layer.transform), initialVelocity: velocity)
        let fade = token.layerAnimation(keyPath: "opacity", from: dim.layer.opacity, initialVelocity: velocity)
        for animation in [slide, fade] {
            animation.beginTime = begin
            animation.fillMode = .backwards
        }
        motion = SheetSpring(begin: begin, travel: target - container.transform.ty, spring: token, velocity: velocity)
        FrameRateVote.hold(token)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, current == transition else { return }
            motion = nil
            arrived()
        }
        container.layer.add(slide, forKey: "transform")
        dim.layer.add(fade, forKey: "opacity")
        place(target)
        container.layer.letSpringsArrive()
        dim.layer.letSpringsArrive()
        CATransaction.commit()
        CATransaction.flush()
    }

    // While the sheet moves only where it is drawn counts. A touch on a rising or returning sheet catches it there, so
    // the control under the finger takes the touch; a closing sheet's touch only feeds the pan. At rest its controls
    // answer as usual.
    func target(at point: CGPoint, with event: UIEvent?) -> UIView? {
        let top = (motion == nil ? container.layer : container.layer.presentation()!).frame.minY
        guard point.y >= top else { return aboveSheet }
        guard motion != nil else { return container.hitTest(view.convert(point, to: container), with: event) ?? container }
        return isOpen ? caughtTarget(at: point, with: event) : container
    }

    // A catch holds the sheet where it is drawn, the dim with it.
    func holdDrawn() {
        nextTransition()
        _ = takeDrawn(toward: 0)
    }

    // The rise moves the transition on, so the catch it ends is spent.
    func riseFromHold() {
        nextTransition()
        move(to: 0, on: rise, velocity: 0) {}
    }

    // Taken from where it is drawn: the finger moves it from the next frame on.
    func beginDrag() {
        presence = FrameRateVote.Presence()
        nextTransition()
        _ = takeDrawn(toward: 0)
        drag = MenuDrag(from: container.transform.ty)
    }

    func dragBegan() {
        beginDrag()
    }

    func dragChanged(_ translation: CGFloat) {
        place(drag.changed(translation))
    }

    // A moving sheet is taken by a mostly vertical drag either way, and a caught sheet is held mid-motion, so it is still
    // a moving one; a sheet at rest only by a downward drag.
    func takes(_ pan: UIGestureRecognizer) -> Bool {
        let velocity = (pan as! UIPanGestureRecognizer).velocity(in: view)
        let moving = motion != nil || catchMayBegin
        return moving ? abs(velocity.y) > abs(velocity.x) : velocity.y > abs(velocity.x)
    }
}

extension CALayer {
    // What is on screen: the presentation once one is committed.
    var drawn: CALayer {
        presentation() ?? self
    }

    // A point in the superlayer's space, in this layer's own space as the layer is drawn there.
    func drawnLocal(_ point: CGPoint) -> CGPoint {
        drawn.convert(point, from: drawn.superlayer)
    }

    // UIKit ends a spring once it is within about a thousandth of its travel and jumps the rest, a visible step on the
    // last frame of a long travel. The same springs run longer here so they arrive first.
    func letSpringsArrive() {
        for key in animationKeys() ?? [] {
            guard let spring = animation(forKey: key) as? CASpringAnimation else { continue }
            let arriving = spring.copy() as! CASpringAnimation
            arriving.duration = spring.duration * Theme.Motion.springArrivalStretch
            add(arriving, forKey: key)
        }
    }
}

// Touches are refused by hit-testing, never by isUserInteractionEnabled: turning that off resigns a focused field
// inside the setter, a 20 to 25 ms frame on the phone in the middle of the close.
final class SheetHostView: UIView {
    private let onWindow: () -> Void
    var takesTouches = false
    // While the sheet rises or closes its model is already where the motion ends, so touches go by where it is drawn.
    var drawnTarget: ((CGPoint, UIEvent?) -> UIView?)?
    // The view the latest touch landed on, which a pan beginning from that touch cancels from.
    private(set) weak var touchedDown: UIView?

    init(onWindow: @escaping () -> Void) {
        self.onWindow = onWindow
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindow()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = drawnTarget.map { $0(point, event) } ?? (takesTouches ? modelHit(point, with: event) : nil)
        if event?.type == .touches {
            touchedDown = hit
        }
        return hit
    }

    func modelHit(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

// A hairline round a sheet's top corners: a border kept to a band as tall as the corner, so it fades into the sides.
class SheetEdge: UIView {
    private let band = CALayer()
    private let corner: CGFloat

    init(corner: CGFloat) {
        self.corner = corner
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.borderWidth = Theme.Metrics.hairlineWidth
        layer.cornerRadius = corner
        layer.cornerCurve = .continuous
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        band.backgroundColor = UIColor.black.cgColor
        layer.mask = band
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        band.frame = CGRect(x: 0, y: 0, width: bounds.width, height: corner)
    }
}
