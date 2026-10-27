import SwiftUI
import UIKit
import WebKit

// Asks whether a site may use the camera or microphone, in a sheet over the page that takes its turn with the page's
// dialogs. Answers nil when the sheet is dismissed or its page leaves the screen.
enum PermissionPrompt {
    static func ask(host: String, kinds: [MediaKind], over webView: WKWebView, env: AppEnvironment) async -> Bool? {
        await PageDialogs.takeTurn()
        guard webView.window != nil else {
            PageDialogs.endTurn()
            return nil
        }
        return await withCheckedContinuation { continuation in
            let prompt = PermissionPromptController(host: host, kinds: kinds, env: env) {
                continuation.resume(returning: $0)
            }
            prompt.present(over: webView)
        }
    }

    static func title(host: String, kinds: [MediaKind]) -> String {
        let uses = kinds.map { $0 == .camera ? "camera" : "microphone" }.joined(separator: " and ")
        return "Allow “\(host)” to use your \(uses)?"
    }
}

// The prompt's sheet is a SpringSheet: a touch-down on the moving sheet holds it where it is drawn, a drag moves it from
// there, and a catch let go finishes the rise. A drag past the line closes it, and the answer, nil, goes once the close
// lands, so the closing sheet can still be caught back. A button, a tap on the dim or the page leaving the screen answers
// at once and the sheet closes with no more touches.
final class PermissionPromptController: UIViewController, UIGestureRecognizerDelegate, SpringSheet {
    let container = UIView()
    let dim = UIView()
    private let background = MenuSheetBackground()
    let sheetCatch = SheetCatch()
    private(set) var isOpen = false
    var motion: SheetSpring?
    var transition = 0
    var presence: FrameRateVote.Presence?
    var drag = MenuDrag()
    let rise = Theme.Motion.permissionSheet
    private let host: String
    private let kinds: [MediaKind]
    private let env: AppEnvironment
    private var onAnswer: ((Bool?) -> Void)?
    private let watch = WindowWatch()

    init(host: String, kinds: [MediaKind], env: AppEnvironment, onAnswer: @escaping (Bool?) -> Void) {
        self.host = host
        self.kinds = kinds
        self.env = env
        self.onAnswer = onAnswer
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        overrideUserInterfaceStyle = .dark
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = SheetHostView {}
    }

    // Above the drawn sheet the dim has the touch, the prompt open or closing.
    var aboveSheet: UIView? {
        dim
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        dim.backgroundColor = UIColor(Theme.Palette.searchDim)
        dim.frame = view.bounds
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dimTapped)))
        view.addSubview(dim)
        background.apply(MenuLook(isLight: false, tint: nil))
        background.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(background)
        let content = UIHostingController(
            rootView: PermissionPromptView(host: host, kinds: kinds) { [unowned self] in answer($0) }.environment(env))
        content.view.backgroundColor = .clear
        addChild(content)
        content.view.frame = container.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(content.view)
        content.didMove(toParent: self)
        view.addSubview(container)
        // The sheet's fill runs a screen's height from its top, so a drag past the rest never shows its edge.
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: container.topAnchor),
            background.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            background.heightAnchor.constraint(equalTo: view.heightAnchor),
        ])
        addGestures(pan: UIPanGestureRecognizer(target: self, action: #selector(panned)))
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        let height = Theme.Metrics.permissionSheetHeight + view.safeAreaInsets.bottom
        container.frame = CGRect(x: 0, y: view.bounds.height - height, width: view.bounds.width, height: height)
        open()
    }

    func present(over webView: WKWebView) {
        watch.isHidden = true
        watch.onLeaveWindow = { [unowned self] in finish(nil) }
        webView.addSubview(watch)
        webView.window!.presentOnTop(self, animated: false) { [weak self] in self?.onAnswer != nil }
    }

    func answer(_ allows: Bool) {
        env.haptics.fire(.permissionAnswer)
        finish(allows)
    }

    @objc func dimTapped() {
        finish(nil)
    }

    private func open() {
        isOpen = true
        nextTransition()
        hostView.drawnTarget = { [unowned self] point, event in target(at: point, with: event) }
        place(sheetHeight)
        move(to: 0, on: rise, velocity: 0) {}
    }

    private func close(velocity: CGFloat?) {
        isOpen = false
        nextTransition()
        let carried = takeDrawn(toward: sheetHeight)
        move(to: sheetHeight, on: Theme.Motion.permissionSheet, velocity: velocity ?? carried) { [unowned self] in
            closed()
        }
    }

    // A drag-away's answer goes here, once its close lands; then the next dialog takes its turn.
    private func closed() {
        send(nil)
        guard let presenting = presentingViewController else { return PageDialogs.endTurn() }
        presenting.dismiss(animated: false, completion: PageDialogs.endTurn)
    }

    // A final answer: the sheet closes from where it is drawn, or keeps the close it is on, and takes no more touches.
    private func finish(_ answer: Bool?) {
        guard onAnswer != nil else { return }
        send(answer)
        guard isViewLoaded, view.window != nil else { return PageDialogs.endTurn() }
        presence = nil
        if isOpen {
            close(velocity: nil)
        }
    }

    private func send(_ answer: Bool?) {
        guard let onAnswer else { return }
        self.onAnswer = nil
        watch.onLeaveWindow = nil
        watch.removeFromSuperview()
        hostView.drawnTarget = nil
        onAnswer(answer)
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        route(pan)
    }

    func dragChanged(_ translation: CGFloat) {
        guard onAnswer != nil else { return }
        place(drag.changed(translation))
    }

    func dragEnded(translation: CGFloat, velocity: CGFloat) {
        presence = nil
        guard onAnswer != nil else { return }
        switch drag.ended(translation: translation, velocity: velocity, sheetHeight: sheetHeight) {
        case .close(let velocity): close(velocity: velocity)
        case .stay(let velocity): returnToRest(velocity: velocity)
        }
    }

    func dragCancelled() {
        presence = nil
        guard onAnswer != nil else { return }
        returnToRest(velocity: 0)
    }

    // A sheet taken during its drag-away close is open again once it returns, its answer still to come.
    private func returnToRest(velocity: CGFloat) {
        isOpen = true
        nextTransition()
        move(to: 0, on: rise, velocity: velocity) {}
    }

    // An answered sheet is not taken.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === catcher ? catchMayBegin : onAnswer != nil && takes(gestureRecognizer)
    }

    // The buttons' presses begin on touch-down; the pan runs alongside them and cancels them when it begins.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

private struct PermissionPromptView: View {
    let host: String
    let kinds: [MediaKind]
    let answer: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Theme.Palette.permissionGrabber)
                .frame(
                    width: Theme.Metrics.permissionGrabberSize.width, height: Theme.Metrics.permissionGrabberSize.height)
                .padding(.top, Theme.Metrics.permissionGrabberTop)
            Spacer()
            HStack(spacing: Theme.Metrics.permissionGlyphGap) {
                ForEach(kinds, id: \.self) {
                    Image(systemName: $0 == .camera ? "camera.fill" : "mic.fill")
                }
            }
            .font(Theme.Typography.permissionGlyph)
            Spacer()
            Text(PermissionPrompt.title(host: host, kinds: kinds))
                .font(Theme.Typography.permissionTitle)
                .multilineTextAlignment(.center)
            Spacer()
            HStack(spacing: Theme.Metrics.permissionButtonGap) {
                button("Don't Allow", fill: Theme.Palette.menuInk(light: false).opacity(Theme.Opacity.menuFill), allows: false)
                button("Allow", fill: Theme.Palette.searchCaret, allows: true)
            }
        }
        .padding(.horizontal, Theme.Metrics.permissionSidePadding)
        .foregroundStyle(Theme.Palette.menuInk(light: false))
    }

    private func button(_ title: String, fill: Color, allows: Bool) -> some View {
        Button {
            answer(allows)
        } label: {
            Text(title)
                .font(Theme.Typography.permissionButton)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Metrics.permissionButtonHeight)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle(scale: Theme.Metrics.pressScaleWide, preparing: .permissionAnswer))
    }
}
