import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry var screenInsets = EdgeInsets()
}

@Observable final class ScreenInsets {
    var value = EdgeInsets()
}

struct BehindHost: UIViewControllerRepresentable {
    let shrink: CGFloat
    let deckProgress: CGFloat
    let opacity: CGFloat
    @Environment(AppEnvironment.self) private var env

    func makeUIViewController(context: Context) -> BehindController {
        BehindController(env: env)
    }

    func updateUIViewController(_ controller: BehindController, context: Context) {
        guard controller.needsUpdate(shrink, deckProgress: deckProgress, opacity: opacity) else { return }
        controller.applyShrink(shrink, deckProgress: deckProgress, motion: env.ui.searchShrinkMotion)
        controller.applyFade(opacity)
    }
}

final class BehindController: UIViewController {
    private let insets = ScreenInsets()
    let env: AppEnvironment
    private var applied: (shrink: CGFloat, deckProgress: CGFloat, opacity: CGFloat) = (0, 0, 1)
    private var fadeOuts = 0
    private static let shrinkLegKey = "shrink"
    private var shrinkLegs = 0
    private var goTime: CFTimeInterval = 0
    private var riseHeld = false
    private var shrinkHeld = false
    let stage = DrawnHitView()
    let card = DrawnHitView()
    // Over the card and inside the stage, so a submit's veil covers it with the page.
    let dim = UIView()
    // A submitted page waits here from Go, in the window but under an opaque cover in the submit's own backdrop, so
    // it paints during the fade and is revealable when the hidden step adopts it. The cover shows only from Go until
    // the page's rise ends; around the shrunk page during an open the root's navy backdrop shows.
    let staging = UIView()
    private let stagingCover = UIView()
    private let stagingBand = PrivateBandView()
    // The submit's fade: a flat cover in the submit's backdrop over the stage, faded in over the page and out over
    // the one that replaces it. Fading the stage itself would composite its whole subtree offscreen on every frame.
    // A private submit's veil carries the band the page will show, so the band stays put through the fade.
    let veil = UIView()
    private let veilBand = PrivateBandView()
    private let host: UIViewController
    // A touch anywhere on the page or the bar while the pages of a bar swipe or a tab stack flick spring holds them
    // where drawn.
    let catcher = UILongPressGestureRecognizer()
    private let router: BarSwipeRouter

    init(env: AppEnvironment) {
        let host = UIHostingController(rootView: BehindContent(insets: insets).environment(env))
        host.safeAreaRegions = []
        self.host = host
        self.env = env
        router = BarSwipeRouter(pager: { [unowned env] in env.pager }, flick: { [unowned env] in env.flick })
        super.init(nibName: nil, bundle: nil)
        env.onSubmitted = { [unowned self] in stageSubmitted($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        staging.isUserInteractionEnabled = false
        staging.isHidden = true
        stagingCover.backgroundColor = Theme.Palette.submitCover
        staging.addSubview(stagingCover)
        stagingCover.addSubview(stagingBand)
        view.addSubview(staging)
        view.addSubview(stage)
        veil.alpha = 0
        veil.isUserInteractionEnabled = false
        veil.backgroundColor = Theme.Palette.submitCover
        view.addSubview(veil)
        card.clipsToBounds = true
        card.layer.cornerCurve = .continuous
        stage.addSubview(card)
        addChild(host)
        host.view.backgroundColor = .clear
        card.addSubview(host.view)
        host.didMove(toParent: self)
        dim.backgroundColor = UIColor(Theme.Palette.searchDim)
        dim.alpha = 0
        dim.isUserInteractionEnabled = false
        stage.addSubview(dim)
        stage.onGrab = { [unowned self] in holdRise() }
        card.onGrab = { [unowned self] in holdShrink() }
        view.addGestureRecognizer(TouchLiftObserver { [unowned self] in releaseHeld() })
        catcher.minimumPressDuration = 0
        catcher.cancelsTouchesInView = false
        catcher.delegate = router
        catcher.addTarget(self, action: #selector(caught(by:)))
        view.addGestureRecognizer(catcher)
    }

    override func loadView() {
        view = WindowSizedView()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let window = view.window else { return }
        stage.bounds = view.bounds
        stage.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        dim.frame = stage.bounds
        staging.frame = view.bounds
        stagingCover.frame = staging.bounds
        veil.frame = view.bounds
        host.view.frame = window.bounds
        layoutCard(nil)
        let safe = window.safeAreaInsets
        for band in [stagingBand, veilBand] {
            band.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: safe.top + Theme.Metrics.privateBandExtra)
            band.layout(safeTop: safe.top)
        }
        let value = EdgeInsets(top: safe.top, leading: safe.left, bottom: safe.bottom, trailing: safe.right)
        if insets.value != value {
            insets.value = value
        }
        env.pool.page = PageGeometry(bounds: window.bounds, safeTop: safe.top)
    }

    func needsUpdate(_ shrink: CGFloat, deckProgress: CGFloat, opacity: CGFloat) -> Bool {
        applied != (shrink, deckProgress, opacity)
    }

    // A shrink change runs its motion on Core Animation, asking for the deck's rate; SwiftUI's animation clock ticks at
    // 60 Hz on the phone. Each change adds an additive leg from the old model value to the new one, so a change
    // mid-motion keeps the running legs' place and speed, as SwiftUI's springs did; a jump ends every leg. A deck
    // change alone moves nothing the eye sees while the card is unshrunk.
    func applyShrink(_ shrink: CGFloat, deckProgress: CGFloat, motion: UIState.ShrinkMotion?) {
        guard applied.shrink != shrink || applied.deckProgress != deckProgress else { return }
        let shrinkChanged = applied.shrink != shrink
        if shrinkChanged {
            shrinkHeld = false
        }
        applied.shrink = shrink
        applied.deckProgress = deckProgress
        if shrinkChanged, motion == nil {
            endShrinkLegs()
        }
        layoutCard(shrinkChanged ? motion : nil)
    }

    // The card's lift toward the top is in its position, so its transform is a pure scale and scale legs compose in any
    // order.
    private func layoutCard(_ motion: UIState.ShrinkMotion?) {
        guard let window = view.window else { return }
        let (shrink, deckProgress) = (applied.shrink, applied.deckProgress)
        let rest = Theme.Metrics.browsingShrinkScale
            + (Theme.Metrics.switcherShrinkScale - Theme.Metrics.browsingShrinkScale) * deckProgress
        let scale = 1 + (rest - 1) * shrink
        let frame = view.convert(window.bounds, from: window)
        let clipTop = window.safeAreaInsets.top * shrink * (1 - deckProgress)
        let height = frame.height - clipTop
        let bounds = CGRect(x: 0, y: clipTop, width: frame.width, height: height)
        let position = CGPoint(x: frame.midX, y: frame.minY + clipTop + height / 2 - (1 - scale) * height / 2)
        let corner = Theme.Metrics.browsingShrinkCorner * shrink / scale
        let dimOpacity = Float(Theme.Opacity.searchDim * shrink)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let motion {
            FrameRateVote.hold(motion.token)
            shrinkLegs += 1
            let was = (card.layer.bounds, card.layer.position, card.layer.transform.m11, card.layer.cornerRadius)
            let legs: [(CALayer, String, Any, Any)] = [
                (card.layer, "bounds",
                 NSValue(cgRect: CGRect(
                    x: was.0.minX - bounds.minX, y: was.0.minY - bounds.minY, width: was.0.width - bounds.width,
                    height: was.0.height - bounds.height)),
                 NSValue(cgRect: .zero)),
                (card.layer, "position",
                 NSValue(cgPoint: CGPoint(x: was.1.x - position.x, y: was.1.y - position.y)), NSValue(cgPoint: .zero)),
                (card.layer, "transform",
                 NSValue(caTransform3D: CATransform3DMakeScale(was.2 / scale, was.2 / scale, 1)),
                 NSValue(caTransform3D: CATransform3DIdentity)),
                (card.layer, "cornerRadius", was.3 - corner, 0),
                (dim.layer, "opacity", dim.layer.opacity - dimOpacity, 0),
            ]
            for (layer, keyPath, from, to) in legs {
                let leg = motion.token.layerAnimation(keyPath: keyPath, from: from, initialVelocity: motion.velocity)
                leg.toValue = to
                leg.isAdditive = true
                layer.add(leg, forKey: Self.shrinkLegKey + "\(shrinkLegs).\(keyPath)")
            }
        }
        card.bounds = bounds
        card.center = position
        card.transform = CGAffineTransform(scaleX: scale, y: scale)
        card.layer.cornerRadius = corner
        dim.layer.opacity = dimOpacity
        CATransaction.commit()
    }

    private func endShrinkLegs() {
        for layer in [card.layer, dim.layer] {
            for key in layer.animationKeys() ?? [] where key.hasPrefix(Self.shrinkLegKey) {
                layer.removeAnimation(forKey: key)
            }
        }
    }

    func applyFade(_ opacity: CGFloat) {
        guard applied.opacity != opacity else { return }
        applied.opacity = opacity
        fadeOuts += 1
        guard opacity < 1 else {
            unstage()
            fadeVeil(Theme.Motion.submitFadeIn, to: 0) {}
            return
        }
        let fadeOut = fadeOuts
        goTime = CACurrentMediaTime()
        fadeVeil(Theme.Motion.submitFadeOut, to: 1 - opacity) {
            self.revealSubmitted(after: fadeOut)
        }
    }

    // On Core Animation: SwiftUI can apply the opacity in a pass with UIKit animations off, which would jump the
    // veil and end the fade (and the submit's hidden step) at once. The model value is set with actions off so no
    // surrounding UIView animation can replace the fade.
    private func fadeVeil(_ token: MotionToken, to opacity: CGFloat, completion: @escaping () -> Void) {
        let fade = token.layerAnimation(keyPath: "opacity", from: (veil.layer.presentation() ?? veil.layer).opacity)
        FrameRateVote.hold(token)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        veil.layer.add(fade, forKey: "opacity")
        veil.alpha = opacity
        CATransaction.commit()
    }

    private func stageSubmitted(_ controller: WebTabController) {
        unstage()
        staging.isHidden = false
        // A private submit's cover is the darker one, under the band the page will show. The veil takes the band
        // only then, so outside a private submit it is a leaf and its fade needs no offscreen group.
        let isPrivate = env.pool.isPrivate(controller.tabID)
        let cover = isPrivate ? Theme.Palette.privateSubmitCover : Theme.Palette.submitCover
        stagingBand.isHidden = !isPrivate
        stagingCover.backgroundColor = cover
        veil.backgroundColor = cover
        if isPrivate {
            veil.addSubview(veilBand)
        } else {
            veilBand.removeFromSuperview()
        }
        let webView = controller.webView
        webView.frame = staging.bounds
        staging.insertSubview(webView, belowSubview: stagingCover)
        controller.revealWhenPainted()
    }

    // The deck takes an adopted page straight from here, never through a moment out of the window; a cancelled
    // submit's page leaves the window with the fade back in.
    private func unstage() {
        for view in staging.subviews where view !== stagingCover {
            view.removeFromSuperview()
        }
        staging.isHidden = true
    }

    // Right after the hidden step switches the tab, the page fades in rising into place. The
    // rise runs on a clock from Go, painted or not: it began submitPageRiseDelay after Go while the page was hidden,
    // so about its last 60 pt show. Until its first paint the deck's cover rises in its place, so no white frame
    // shows.
    private func revealSubmitted(after fadeOut: Int) {
        guard fadeOut == fadeOuts, env.ui.isSubmitting else { return }
        applied.opacity = 1
        env.ui.submitHidden()
        rise(
            from: CATransform3DMakeTranslation(0, Theme.Metrics.submitPageRise, 0),
            beginTime: stage.layer.convertTime(goTime + Theme.Motion.submitPageRiseDelay, from: nil))
        fadeVeil(Theme.Motion.submitPageFadeIn, to: 0) {}
    }

    // The cover stays under the rising page until the rise ends, held or not, so the strip it uncovers at the top is
    // the submit's grey to the last frame. A newer submit has its own page staged there, so only this one hides it.
    private func rise(from: CATransform3D, beginTime: CFTimeInterval = 0) {
        let fadeOut = fadeOuts
        riseHeld = false
        let rise = Theme.Motion.submitPageRise.layerAnimation(keyPath: "transform", from: NSValue(caTransform3D: from))
        rise.beginTime = beginTime
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock {
            guard fadeOut == self.fadeOuts, !self.riseHeld else { return }
            self.staging.isHidden = true
        }
        FrameRateVote.hold(Theme.Motion.submitPageRise)
        stage.layer.add(rise, forKey: "transform")
        stage.transform = .identity
        CATransaction.commit()
    }

    // A touch on the page during the submit's rise or the close's unshrink holds it where it is drawn, so the touch,
    // a tap or a scroll, lands on what the finger sees. The last finger's lift springs the rest of the way.
    private func holdRise() {
        guard stage.layer.animation(forKey: "transform") != nil else { return }
        let drawn = stage.layer.presentation()!.transform
        riseHeld = true
        stage.layer.removeAnimation(forKey: "transform")
        stage.layer.transform = drawn
    }

    func caught(_ down: Bool) {
        let (pager, flick) = (env.pager!, env.flick!)
        if down {
            if pager.isMoving {
                pager.hold()
            } else {
                flick.hold()
            }
        } else {
            pager.catchEnded()
            flick.catchEnded()
        }
    }

    @objc private func caught(by press: UILongPressGestureRecognizer) {
        switch press.state {
        case .began: caught(true)
        case .ended, .cancelled, .failed: caught(false)
        default: break
        }
    }

    private func holdShrink() {
        guard card.layer.animationKeys()?.contains(where: { $0.hasPrefix(Self.shrinkLegKey) }) == true else { return }
        let drawnCard = card.layer.presentation()!
        let drawnDim = dim.layer.presentation()!
        endShrinkLegs()
        shrinkHeld = true
        card.layer.bounds = drawnCard.bounds
        card.layer.position = drawnCard.position
        card.layer.transform = drawnCard.transform
        card.layer.cornerRadius = drawnCard.cornerRadius
        dim.layer.opacity = drawnDim.opacity
    }

    private func releaseHeld() {
        if riseHeld {
            rise(from: stage.layer.transform)
        }
        if shrinkHeld {
            shrinkHeld = false
            layoutCard(UIState.ShrinkMotion(token: Theme.Motion.submitPageRise, velocity: 0))
        }
    }
}

private final class WindowSizedView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        subviews.contains { $0.point(inside: convert(point, to: $0), with: event) }
    }
}

// The submit's rise moves the stage and the close's unshrink moves the card while their models are already at rest,
// so while either runs a touch maps through the drawn geometry before the page under it is tested, and a touch that
// lands asks the owner to hold the motion where it is drawn.
final class DrawnHitView: UIView {
    var onGrab: () -> Void = {}

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(layer.drawnLocal(layer.convert(point, to: layer.superlayer)), with: event)
        if hit != nil, event?.type == .touches, layer.animationKeys() != nil {
            onGrab()
        }
        return hit
    }
}

// Follows every touch on the page to its end without delaying, cancelling or competing for it, and reports the last
// finger's lift.
final class TouchLiftObserver: UIGestureRecognizer {
    private let onLift: () -> Void
    private var touching = 0

    init(onLift: @escaping () -> Void) {
        self.onLift = onLift
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        touching += touches.count
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches)
    }

    private func lift(_ touches: Set<UITouch>) {
        touching -= touches.count
        guard touching == 0 else { return }
        onLift()
        state = .failed
    }

    override func reset() {
        touching = 0
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
}

private struct BehindContent: View {
    @Environment(AppEnvironment.self) private var env
    let insets: ScreenInsets

    var body: some View {
        let ui = env.ui
        let safe = insets.value
        ZStack {
            DeckView()
            if let controller = env.activeController {
                LoadingRing(controller: controller)
                    .padding(.top, safe.top)
                    .opacity(1 - ui.deckProgress)
                BarSlide(controller: controller)
                    .frame(height: Theme.Metrics.barTotalHeight)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .modifier(DrawnBar(deck: ui.deck, atDeck: false))
            }
            SwitcherBar()
                .frame(maxHeight: .infinity, alignment: .bottom)
                .modifier(DrawnBar(deck: ui.deck, atDeck: true))
        }
        .environment(\.screenInsets, safe)
    }
}

// One bar of the zoom's cross-fade. It reads the fade per frame, so only this modifier redraws while the fade runs.
private struct DrawnBar: ViewModifier {
    let deck: DeckDriver
    let atDeck: Bool

    func body(content: Content) -> some View {
        content
            .opacity(atDeck ? deck.barProgress : 1 - deck.barProgress)
            .allowsHitTesting(deck.barsShowDeck == atDeck)
    }
}
