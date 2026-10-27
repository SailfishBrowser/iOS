import SwiftUI
import UIKit

struct PageMenuHost: UIViewControllerRepresentable {
    let isOpen: Bool
    @Environment(AppEnvironment.self) var env

    func makeUIViewController(context: Context) -> PageMenuController {
        PageMenuController(env: env)
    }

    func updateUIViewController(_ controller: PageMenuController, context: Context) {
        controller.setOpen(isOpen)
    }
}

// The page menu, a SpringSheet whose content is SwiftUI: it can be taken by the finger at any moment of its rise, its
// return or its close, and touches go by where it is drawn.
final class PageMenuController: UIViewController, UIGestureRecognizerDelegate, SpringSheet {
    let env: AppEnvironment
    let dim = UIView()
    let container = UIView()
    private let background = MenuSheetBackground()
    private(set) lazy var sheet: UIViewController = {
        let host = UIHostingController(
            rootView: PageMenuContent(
                onLook: { [unowned self] in background.apply($0) }, onFold: { [unowned self] in fold($0) }
            ).environment(env))
        host.safeAreaRegions = []
        host.sizingOptions = .intrinsicContentSize
        return host
    }()
    private var wantsOpen = false
    private(set) var isOpen = false
    var motion: SheetSpring?
    // Folds asked for during a close, applied once the sheet is hidden or opens again.
    private var heldFolds: [() -> Void] = []
    var transition = 0
    let sheetCatch = SheetCatch()
    private var opensUntil: CFTimeInterval = 0
    var drag = MenuDrag()
    var presence: FrameRateVote.Presence?
    let rise = Theme.Motion.menuOpen

    init(env: AppEnvironment) {
        self.env = env
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = SheetHostView { [unowned self] in apply() }
    }

    // Above the drawn sheet is the dim while the menu is open (a tap closes it) and the page once it is closing.
    var aboveSheet: UIView? {
        isOpen ? dim : nil
    }

    private var layoutTop: CGFloat {
        container.center.y - container.bounds.height / 2
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        dim.backgroundColor = .black
        dim.alpha = 0
        dim.isHidden = true
        dim.frame = view.bounds
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dimTapped)))
        view.addSubview(dim)
        container.isHidden = true
        view.addSubview(container)
        container.addSubview(background)
        addChild(sheet)
        sheet.view.backgroundColor = .clear
        container.addSubview(sheet.view)
        sheet.didMove(toParent: self)

        addGestures(pan: UIPanGestureRecognizer(target: self, action: #selector(panned)))

        let content = sheet.view!
        for subview in [container, background, content] {
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        // The content rests on the keyboard's guide, which follows the address editor's keyboard on its own curve and
        // sits on the home indicator's inset without one. The sheet's fill runs a screen's height from its top, so neither
        // the upward stretch nor a fold that springs from a taller sheet shows its edge.
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            container.topAnchor.constraint(equalTo: content.topAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            background.topAnchor.constraint(equalTo: container.topAnchor),
            background.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            background.heightAnchor.constraint(equalTo: view.heightAnchor),
        ])
    }

    #if DEBUG
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        env.debugSurfaces[.menuSheet] = { [unowned self] in route($0, $1) }
        env.debugWatches[.menuSheet] = { [unowned self] in container.layer.presentation()!.frame.minY }
        env.debugActions[.menuDimTap] = { [unowned self] in dimTap() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        env.debugSurfaces[.menuSheet] = nil
        env.debugWatches[.menuSheet] = nil
        env.debugActions[.menuDimTap] = nil
    }
    #endif

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        background.endGradient(below: sheetHeight)
    }

    // A fold changes the content's height in place. The change is laid out in this call, so nothing is left pending: the
    // sheet stays where it is drawn and springs to its new top, the dim holding still. Hidden, the change just applies;
    // closing, it waits until the sheet is hidden, so the closing sheet never steps.
    func fold(_ change: @escaping () -> Void) {
        guard isOpen else {
            if container.isHidden {
                change()
            } else {
                heldFolds.append(change)
            }
            return
        }
        let top = layoutTop
        change()
        sheet.view.setNeedsLayout()
        view.layoutIfNeeded()
        guard layoutTop != top else { return }
        nextTransition()
        _ = takeDrawn(toward: 0)
        container.transform = CGAffineTransform(translationX: 0, y: container.transform.ty + top - layoutTop)
        move(to: 0, on: Theme.Motion.menuFold, velocity: 0) {}
    }

    func setOpen(_ open: Bool) {
        wantsOpen = open
        apply()
    }

    private func apply() {
        guard view.window != nil, wantsOpen != isOpen else { return }
        isOpen = wantsOpen
        if isOpen {
            present()
        } else {
            dismiss(velocity: nil)
        }
    }

    // From below the screen, or, during a close, from where the sheet is drawn with the speed it has there.
    private func present() {
        if !heldFolds.isEmpty {
            fold(takeHeldFolds())
        }
        nextTransition()
        opensUntil = now + Theme.Motion.menuOpen.settlingDuration
        hostView.drawnTarget = { [unowned self] point, event in target(at: point, with: event) }
        var velocity: CGFloat = 0
        if container.isHidden {
            container.isHidden = false
            dim.isHidden = false
            view.layoutIfNeeded()
            place(sheetHeight)
        } else {
            velocity = takeDrawn(toward: 0)
        }
        move(to: 0, on: Theme.Motion.menuOpen, velocity: velocity) {}
    }

    // A tapped close carries the speed the sheet is drawn with; a dismissing release carries the finger's.
    private func dismiss(velocity: CGFloat?) {
        nextTransition()
        view.endEditing(true)
        let carried = takeDrawn(toward: sheetHeight)
        move(to: sheetHeight, on: Theme.Motion.menuClose, velocity: velocity ?? carried) { [unowned self] in
            finishHiding()
        }
    }

    private func finishHiding() {
        container.isHidden = true
        takeHeldFolds()()
        dim.isHidden = true
        hostView.drawnTarget = nil
    }

    private func takeHeldFolds() -> () -> Void {
        let changes = heldFolds
        heldFolds = []
        return { changes.forEach { $0() } }
    }

    @objc private func dimTapped() {
        dimTap()
    }

    private func dimTap() {
        env.haptics.fire(.menuDimTap)
        env.ui.close()
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        route(pan)
    }

    func dragBegan() {
        if isOpen, now < opensUntil {
            env.haptics.fire(.menuGrabDuringOpen)
        }
        beginDrag()
    }

    // The sheet starts closing in this call so the release frame already moves; UIState's update then finds the
    // controller closed and does nothing.
    func dragEnded(translation: CGFloat, velocity: CGFloat) {
        presence = nil
        switch drag.ended(translation: translation, velocity: velocity, sheetHeight: sheetHeight) {
        case .close(let velocity):
            env.haptics.fire(.menuDragDismiss)
            wantsOpen = false
            isOpen = false
            dismiss(velocity: velocity)
            env.ui.close(animated: false)
        case .stay(let velocity):
            env.haptics.fire(.menuDragReturn)
            returnSheet(velocity: velocity)
        }
    }

    func dragCancelled() {
        presence = nil
        returnSheet(velocity: 0)
    }

    // A sheet taken during its close is open again once it returns.
    private func returnSheet(velocity: CGFloat) {
        if !isOpen {
            wantsOpen = true
            isOpen = true
            env.ui.open(.menu)
        }
        nextTransition()
        move(to: 0, on: Theme.Motion.menuReturn, velocity: velocity) {}
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === catcher ? catchMayBegin : takes(gestureRecognizer)
    }

    // The tiles and rows are SwiftUI buttons whose press begins on touch-down and would otherwise keep the pan from
    // starting. The pan runs alongside them, and when it begins it cancels them (cancelTouchSharers).
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

private struct PageMenuContent: View {
    @Environment(AppEnvironment.self) private var env
    let onLook: (MenuLook) -> Void
    let onFold: (@escaping () -> Void) -> Void

    var body: some View {
        if let controller = env.activeController, let tab = env.browser.activeTab {
            MenuSheet(controller: controller, tab: tab, onLook: onLook, onFold: onFold)
        }
    }
}

// What the sheet's fill follows from the page: light or dark, and the site's colour.
struct MenuLook: Equatable {
    let isLight: Bool
    let tint: UIColor?

    // From the sheet's top to the screen's bottom.
    var sheetColors: (top: UIColor, bottom: UIColor) {
        let top = isLight ? Theme.Palette.menuSheetTop : Theme.Palette.menuSheetDark
        guard let tint else { return (top, top) }
        return (top, top.mixed(with: tint, by: Theme.Opacity.menuSheetTint))
    }
}

// The gradient as a view's backing layer: UIView's layer rules suppress the implicit 0.25 s ease a bare sublayer would
// run on every colours, end point or bounds set, and endGradient(below:) runs on every layout.
final class GradientView: UIView {
    override class var layerClass: AnyClass {
        CAGradientLayer.self
    }

    var gradient: CAGradientLayer {
        layer as! CAGradientLayer
    }
}

// The page menu's and the permission prompt's sheet: a thick material under the measured gradient,
// the hairline on top. The sheet's springs and drags move the container it rides in; the material never fades.
final class MenuSheetBackground: ChromeMaterial {
    private let gradient = GradientView()
    private let edge = SheetEdge(corner: Theme.Metrics.menuSheetCorner)

    init() {
        super.init(nil)
        isUserInteractionEnabled = false
        layer.cornerRadius = Theme.Metrics.menuSheetCorner
        layer.cornerCurve = .continuous
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        clipsToBounds = true
        contentView.addSubview(gradient)
        contentView.addSubview(edge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        edge.frame = bounds
    }

    // The gradient ends at the screen's bottom, `height` below the sheet's top; under it the fill holds the bottom colour.
    func endGradient(below height: CGFloat) {
        gradient.gradient.endPoint = CGPoint(x: 0.5, y: height / bounds.height)
    }

    func apply(_ look: MenuLook) {
        show(Theme.Frost.menu(light: look.isLight))
        let colors = look.sheetColors
        let opacity = Theme.Frost.menuGradient(light: look.isLight)
        gradient.gradient.colors = [
            colors.top.withAlphaComponent(opacity).cgColor, colors.bottom.withAlphaComponent(opacity).cgColor,
        ]
        edge.layer.borderColor = UIColor(Theme.Palette.menuInk(light: look.isLight))
            .withAlphaComponent(Theme.Opacity.menuSheetEdge).cgColor
    }
}

private extension UIColor {
    func mixed(with other: UIColor, by amount: CGFloat) -> UIColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        var otherRed: CGFloat = 0, otherGreen: CGFloat = 0, otherBlue: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: nil)
        other.getRed(&otherRed, green: &otherGreen, blue: &otherBlue, alpha: nil)
        return UIColor(
            red: red + (otherRed - red) * amount, green: green + (otherGreen - green) * amount,
            blue: blue + (otherBlue - blue) * amount, alpha: 1)
    }
}
