import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct BottomBar: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var colorScheme
    let controller: WebTabController

    var body: some View {
        let style = BarStyle.browsing(
            on: controller.barTint, in: colorScheme, isPrivate: env.pool.isPrivate(controller.tabID))
        HStack {
            TabStackButton(foreground: style.glyph)
            Spacer()
            HStack(spacing: Theme.Translate.barGap) {
                // The slot stays reserved so the fade is the only change: a child inserted into a growing stack
                // would ride its growth out from under the chevron.
                ZStack {
                    if offersTranslation {
                        TranslateButton(controller: controller, fill: style.controlFill).transition(.opacity)
                    }
                }
                .frame(width: Theme.Metrics.controlSize)
                ChevronButton(controller: controller, fill: style.controlFill)
            }
            .animation(Theme.Motion.fade.animation, value: offersTranslation)
        }
        .buttonStyle(.plain)
        .foregroundStyle(style.glyph)
        .padding(.horizontal, Theme.Metrics.barSideInset)
        .frame(height: Theme.Metrics.barHeight)
        .overlay {
            SearchPill(fill: style.controlFill, atDeck: false)
                .foregroundStyle(style.glyph)
        }
        .padding(.bottom, Theme.Metrics.barControlCenterFromBottom - Theme.Metrics.barHeight / 2)
        .frame(height: Theme.Metrics.barTotalHeight, alignment: .bottom)
        .background {
            BarBackground(style: style)
                .overlay(alignment: .top) { BarHairline() }
        }
        .overlay(alignment: .bottom) {
            TabStackCopies(foreground: style.glyph)
        }
        .overlay(alignment: .top) {
            LoadingLine(controller: controller)
        }
        .onChange(of: ScrollMark(tabID: controller.tabID, count: controller.userScrollCount)) { old, new in
            if old.tabID == new.tabID {
                env.ui.endBarIntro()
            }
        }
    }

    // The offer comes from detection and goes at a commit or under the reader, none of them a touch on the bar, so
    // the button fades rather than pops.
    private var offersTranslation: Bool {
        controller.translator.source != nil && controller.readerArticle == nil
    }
}

// The bar slides on Core Animation from the turn its hidden state flips. A SwiftUI spring first commits its start
// value and moves only from the following frame; a scroll edge, the intro and the search cover reach the bar at once
// through the controller's and the UI state's hooks, and the rest (find navigator, a new controller) through updates.
struct BarSlide: UIViewRepresentable {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.screenInsets) private var screenInsets
    let controller: WebTabController

    final class Coordinator {
        var controller: WebTabController?
        var ui: UIState?
        #if DEBUG
        let owner = UUID()
        #endif
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // The demos' finger on the bar goes through the view's own swipe path.
    func makeUIView(context: Context) -> BarSlideView {
        let view = BarSlideView(BarContent(env: env, controller: controller), hidden: Self.isHidden(controller, env.ui))
        #if DEBUG
        env.publishDebugSurface(.bar, owner: context.coordinator.owner) { [unowned view] in view.swiped($0, $1) }
        #endif
        return view
    }

    func updateUIView(_ view: BarSlideView, context: Context) {
        view.floorHeight = screenInsets.bottom
        if context.coordinator.controller !== controller {
            view.show(BarContent(env: env, controller: controller))
            context.coordinator.controller?.onBarHiddenChanged = nil
            context.coordinator.controller = controller
            let ui = env.ui
            let update = { [unowned view, unowned controller, unowned ui] in
                Self.update(view, controller, ui)
            }
            controller.onBarHiddenChanged = update
            ui.onBarChanged = update
            context.coordinator.ui = ui
        }
        Self.update(view, controller, env.ui)
    }

    static func dismantleUIView(_ view: BarSlideView, coordinator: Coordinator) {
        coordinator.controller?.onBarHiddenChanged = nil
        coordinator.ui?.onBarChanged = nil
        #if DEBUG
        view.host.rootView.env.withdrawDebugSurface(.bar, owner: coordinator.owner)
        #endif
    }

    // The floor is for a page scrolled under the bar's place: a scroll hide or the find bar. During a submit's bar
    // intro the page runs to the screen bottom. A showing bar covers the floor as it rises, so the
    // floor is only switched while the bar is out.
    static func update(_ view: BarSlideView, _ controller: WebTabController, _ ui: UIState) {
        let hidden = isHidden(controller, ui)
        if hidden {
            view.floor.view.isHidden = !(controller.isBarHidden || controller.isFindNavigatorVisible)
        }
        view.slide(hidden: hidden)
        view.cover(ui.isSearchCoveringBar)
    }

    static func isHidden(_ controller: WebTabController, _ ui: UIState) -> Bool {
        controller.isBarHidden || controller.isFindNavigatorVisible || ui.isBarIntroPending
    }
}

struct BarContent: View {
    let env: AppEnvironment
    let controller: WebTabController

    var body: some View {
        BottomBar(controller: controller).environment(env)
    }
}

final class BarSlideView: UIView {
    let host: UIHostingController<BarContent>
    // The bottom's safe space while the bar is out: its material over the home indicator, so no page content sits
    // there. It sits under the bar, masked to the strip above the bar's drawn top, so the two materials never overlap
    // and no gap opens between them.
    let floor: UIHostingController<BarFloor>
    private let floorMask = CALayer()
    var floorHeight: CGFloat = 0 {
        didSet {
            if floorHeight != oldValue {
                setNeedsLayout()
            }
        }
    }
    // A horizontal swipe anywhere on the bar pages the tabs.
    let swipe = BarSwipeRecognizer()
    let router: BarSwipeRouter
    private(set) var isSlidOut: Bool
    private var legs = 0
    // The view the latest touch landed on, which a beginning swipe cancels from.
    private weak var touchedDown: UIView?

    init(_ content: BarContent, hidden: Bool) {
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        self.host = host
        floor = UIHostingController(rootView: BarFloor(content))
        floor.safeAreaRegions = []
        floor.view.backgroundColor = .clear
        floor.view.isUserInteractionEnabled = false
        floor.view.isHidden = true
        floorMask.backgroundColor = UIColor.black.cgColor
        floorMask.transform = CATransform3DMakeAffineTransform(Self.placement(hidden: hidden))
        floor.view.layer.mask = floorMask
        isSlidOut = hidden
        router = BarSwipeRouter(pager: { [unowned host] in host.rootView.env.pager }, flick: { [unowned host] in host.rootView.env.flick })
        super.init(frame: .zero)
        host.view.transform = Self.placement(hidden: hidden)
        addSubview(floor.view)
        addSubview(host.view)
        swipe.maximumNumberOfTouches = 1
        swipe.delegate = router
        swipe.addTarget(self, action: #selector(swiped(by:)))
        // The page a swipe or a flick would leave is captured here, before any pixel moves.
        swipe.onFirstMove = { [unowned self] in router.pager()?.prepare() }
        addGestureRecognizer(swipe)
    }

    func show(_ content: BarContent) {
        host.rootView = content
        floor.rootView = BarFloor(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        host.view.bounds = bounds
        host.view.center = CGPoint(x: bounds.midX, y: bounds.midY)
        floor.view.frame = CGRect(x: 0, y: bounds.height - floorHeight, width: bounds.width, height: floorHeight)
        // At rest above the floor by the bar's height; the bar's own translation brings it down with the bar's top.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        floorMask.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: floorHeight)
        floorMask.position = CGPoint(x: bounds.midX, y: floorHeight / 2 - bounds.height)
        CATransaction.commit()
    }

    // Additive, so a flip mid-slide keeps the running spring's position and velocity and adds the new leg to it.
    func slide(hidden: Bool) {
        guard hidden != isSlidOut else { return }
        isSlidOut = hidden
        legs += 1
        let placement = Self.placement(hidden: hidden)
        let leg = Theme.Motion.bar.layerAnimation(
            keyPath: "transform.translation.y", from: host.view.transform.ty - placement.ty)
        leg.toValue = 0
        leg.isAdditive = true
        FrameRateVote.hold(Theme.Motion.bar)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.view.transform = placement
        host.view.layer.add(leg, forKey: "slide\(legs)")
        floorMask.transform = CATransform3DMakeAffineTransform(placement)
        floorMask.add(leg, forKey: "slide\(legs)")
        CATransaction.commit()
    }

    // Under the search sheet the bar draws nothing but still takes its touches: a mask hides it from the screen and not
    // from hit testing, where SwiftUI's opacity 0 would take it out of both.
    func cover(_ covered: Bool) {
        guard covered != (host.view.layer.mask != nil) else { return }
        host.view.layer.mask = covered ? CALayer() : nil
        floor.view.alpha = covered ? 0 : 1
    }

    // UIKit hit-tests the model placement, which a slide moves at once, so a touch is shifted from where the bar is
    // drawn to where it is placed. Outside the drawn bar the touch reaches what is drawn behind it.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let layer = host.view.layer
        let hit = super.hitTest(layer.convert(layer.drawnLocal(point), to: self.layer), with: event)
        let landed = hit === self ? nil : hit
        if event?.type == .touches {
            touchedDown = landed
        }
        return landed
    }

    func swiped(_ phase: DragPhase, _ sample: DragSample) {
        router.pager()!.swiped(phase, sample)
    }

    // Whatever else tracks the touch under a beginning swipe (a control's press, the tab stack's drag) is cancelled,
    // so a swipe that starts on a control never ends in its tap. Disabling a recognizer cancels it; it is enabled again
    // for the next touch. They are found from the view the touch landed on.
    func cancelTouchSharers() {
        var touched = touchedDown
        while let current = touched, current !== self {
            for other in current.gestureRecognizers ?? [] where other.isEnabled {
                other.isEnabled = false
                other.isEnabled = true
            }
            touched = current.superview
        }
    }

    @objc private func swiped(by recognizer: BarSwipeRecognizer) {
        let phase: DragPhase
        switch recognizer.state {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended: phase = .ended
        case .cancelled, .failed: phase = .cancelled
        default: return
        }
        let translation = recognizer.translation(in: self)
        let velocity = recognizer.velocity(in: self)
        let location = recognizer.location(in: self)
        swiped(
            phase,
            DragSample(
                startLocation: CGPoint(x: location.x - translation.x, y: location.y - translation.y), location: location,
                translation: CGSize(width: translation.x, height: translation.y),
                velocity: CGSize(width: velocity.x, height: velocity.y), time: .now))
        // After the pager takes the swipe, so a control cancelled now already sees it swiping.
        if phase == .began {
            cancelTouchSharers()
        }
    }

    // A hide places the bar below these bounds, so the shifted touch is tested against the placed bar.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        host.view.frame.contains(point)
    }

    private static func placement(hidden: Bool) -> CGAffineTransform {
        CGAffineTransform(translationX: 0, y: hidden ? Theme.Metrics.barHideOffset : 0)
    }
}

// A pan that takes the touch once its path locks to the swipe: axisLockDistance of radial travel within axisLockAngle
// of horizontal. A steeper path is not yet the swipe's, so the bar keeps watching (a thumb's arc may flatten; an
// upward one is the tab stack's flick, which takesSwipe then refuses). Until the lock the pan sees no move.
final class BarSwipeRecognizer: UIPanGestureRecognizer {
    // Called once per touch, on the move that takes it half the lock distance from where it began: clear of a tap's
    // wobble and before the lock, where nothing moves yet. A fast swipe pays it on its lock frame.
    var onFirstMove: () -> Void = {}
    private var origin: CGPoint?
    private var moved = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if origin == nil {
            origin = touches.first!.location(in: view)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let origin {
            let point = touches.first!.location(in: view)
            let translation = CGSize(width: point.x - origin.x, height: point.y - origin.y)
            if !moved, hypot(translation.width, translation.height) >= Theme.Gesture.axisLockDistance / 2 {
                moved = true
                onFirstMove()
            }
            if state == .possible, BarSwipe.lock(translation) != .horizontal {
                return
            }
        }
        super.touchesMoved(touches, with: event)
    }

    override func reset() {
        super.reset()
        origin = nil
        moved = false
    }
}

// The swipe begins only on a page at rest in the browser, and the catch only while the pages of a swipe or a flick
// spring. Both run alongside the controls and the page, whose presses begin on touch-down; a beginning swipe cancels
// them.
final class BarSwipeRouter: NSObject, UIGestureRecognizerDelegate {
    let pager: () -> TabPager?
    let flick: () -> TabStackFlick?

    init(pager: @escaping () -> TabPager?, flick: @escaping () -> TabStackFlick?) {
        self.pager = pager
        self.flick = flick
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pager = pager(), let flick = flick() else { return false }
        return gestureRecognizer is BarSwipeRecognizer ? pager.takesSwipe : pager.isMoving || flick.isMoving
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

// Tap opens the menu on touch-up and a hold shares; neither has a pressed state.
struct ChevronButton: View {
    @Environment(AppEnvironment.self) private var env
    @State private var pressedAt = Date.distantPast
    @State private var isOutside = false
    let controller: WebTabController
    let fill: Color

    var body: some View {
        Image(systemName: "chevron.up")
            .font(Theme.Typography.barChevronGlyph)
            .frame(width: Theme.Metrics.controlSize, height: Theme.Metrics.controlSize)
            .background(fill, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(Theme.Opacity.barEdge), lineWidth: Theme.Metrics.hairlineWidth))
            .contentShape(Circle())
            .onLongPressGesture(
                minimumDuration: Theme.Gesture.chevronLongPress, maximumDistance: .infinity,
                perform: longPressed, onPressingChanged: pressingChanged)
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { moved(DragSample($0)) })
            #if DEBUG
            .debugSurface(.chevron) { phase, sample in
                switch phase {
                case .began: pressingChanged(true)
                case .changed: moved(sample)
                case .ended: pressingChanged(false)
                case .cancelled: break
                }
            }
            #endif
            .accessibilityLabel("Page Menu")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { openMenu() }
    }

    // A swipe on the bar that started on the chevron cancels its press, which SwiftUI reports as a release.
    private func pressingChanged(_ pressing: Bool) {
        if pressing {
            pressedAt = .now
            isOutside = false
            env.haptics.prepare(.chevronTap, .chevronLongPress)
        } else if Self.opensMenu(
            isInside: !isOutside && env.pager?.isSwiping != true, held: Date.now.timeIntervalSince(pressedAt))
        {
            openMenu()
        }
    }

    // Decided by hold time, not by whether perform has run, so either callback order gives one action.
    static func opensMenu(isInside: Bool, held: TimeInterval) -> Bool {
        isInside && held < Theme.Gesture.chevronLongPress
    }

    // The touch stays inside while it is within tap travel of where it began.
    private func moved(_ sample: DragSample) {
        let travel = hypot(sample.translation.width, sample.translation.height)
        isOutside = isOutside || travel >= Theme.Gesture.tapMaxTravel
    }

    private func longPressed() {
        guard !isOutside, controller.url != nil else { return }
        env.haptics.fire(.chevronLongPress)
        SharePresenter.share(controller)
    }

    private func openMenu() {
        guard env.ui.canOpen(.menu) else { return }
        env.haptics.fire(.chevronTap)
        env.ui.open(.menu)
    }
}

struct BarFloor: View {
    @Environment(\.colorScheme) private var colorScheme
    let controller: WebTabController
    let isPrivate: Bool

    init(_ content: BarContent) {
        controller = content.controller
        isPrivate = content.env.pool.isPrivate(content.controller.tabID)
    }

    var body: some View {
        BarBackground(style: .browsing(on: controller.barTint, in: colorScheme, isPrivate: isPrivate))
    }
}

struct BarHairline: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(Theme.Opacity.barEdge))
            .frame(height: Theme.Metrics.hairlineWidth)
    }
}

private struct ScrollMark: Equatable {
    let tabID: Tab.ID
    let count: Int
}
