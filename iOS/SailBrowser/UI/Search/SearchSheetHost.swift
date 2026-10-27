import SwiftUI
import UIKit
import os

struct SearchSheetHost: UIViewControllerRepresentable {
    let isActive: Bool
    let isSubmitting: Bool
    @Environment(AppEnvironment.self) var env

    final class Coordinator {
        let model: SearchModel

        init(model: SearchModel) {
            self.model = model
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            model: SearchModel(
                history: env.history, service: SuggestionService(), engine: { [env] in env.browser.settings.searchEngine }))
    }

    func makeUIViewController(context: Context) -> SearchSheetController {
        SearchSheetController(model: context.coordinator.model, env: env)
    }

    func updateUIViewController(_ controller: SearchSheetController, context: Context) {
        controller.setActive(isActive, submitting: isSubmitting)
    }
}

final class SearchSheetController: UIViewController, UITextFieldDelegate, UIGestureRecognizerDelegate, SheetDragging {
    private static let pillCenterBelowBarTop = Theme.Metrics.barTotalHeight - Theme.Metrics.barControlCenterFromBottom
    private static let fieldCenterBelowTop = Theme.Metrics.searchSheetTopPadding + Theme.Metrics.searchFieldHeight / 2
    // A phone trace splits each keystroke's work of ours (the edit handler and the ranking) from UIKit's text input.
    private static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier!, category: .pointsOfInterest)

    let model: SearchModel
    let env: AppEnvironment
    private(set) lazy var sheet = hosting(
        SearchSheet(model: model, swipe: recentSwipe, privacy: privacy) { [unowned self] in select($0) }.environment(env))
    // Whether the sheet shows incognito; the rows and the notice follow it.
    let privacy = SearchPrivacy()
    // Over the material, under everything else: the whole sheet darkens in incognito.
    let privateShade = UIView()
    let recentSwipe = RecentSwipe()
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(drag))
    private let rowSwiper = RowSwipeRecognizer()
    private var rowSwipe: RowSwipe?
    // A recent's return runs per frame, so the offset the rows draw is always the model's and a touch can hold it.
    private(set) var rowReturn: FrameClock?
    private let rowCatch = UILongPressGestureRecognizer()
    private var rowHeld = false
    private let look = SearchBarLook()
    private lazy var browsingCopies = hosting(SearchBarCopies(atDeck: false, look: look).environment(env))
    private lazy var deckCopies = hosting(SearchBarCopies(atDeck: true, look: look))
    private(set) lazy var plus = hosting(SearchPlusGlyph(look: look))
    let material = SearchSheetMaterial(Theme.Frost.sheet)
    // The bar the sheet lands on, drawn under its material at full alpha for the material to fade over, so the composite
    // is always a blur and never the sharp page: the light bar's material, or the dark bar's tinted to the deck strip or
    // the private bar as the sheet lands. Over a dark page the sheet's material already is the bar: nothing lies under it
    // and nothing fades (a blur of a blur would darken a mid-dark page by up to 24 levels).
    let underBar = SearchSheetMaterial(nil)
    // 1 where the material fades over the under-layer, 0 on the dark look.
    private var fades: CGFloat = 0
    private var underSolid: UIColor?
    private let edge = SearchSheetEdge()
    // Between the host view and the container, so a drag on the sheet lets UIKit's interactive dismissal take the real
    // keyboard with the finger once it reaches it.
    let tracker = KeyboardTrackingScrollView()
    let container = UIView()
    let capsule = SearchFieldCapsule()
    let field: SearchField
    private var keyboardBottom: NSLayoutConstraint!
    private var detachedTop: NSLayoutConstraint!
    private var containerHeight: NSLayoutConstraint!
    private var capsuleWidth: NSLayoutConstraint!
    private var capsuleHeight: NSLayoutConstraint!
    private var capsuleCenterY: NSLayoutConstraint!
    private var fieldWidth: NSLayoutConstraint!
    private var fieldLead: NSLayoutConstraint!
    private var plusLead: NSLayoutConstraint!
    private var wantsActive = false
    private var wantsSubmit = false
    private var isActive = false
    private var appendingEdit = false
    private var rankPending = false
    // Rebuilding the keyboard's input views costs 45 to 75 ms on the phone, so it happens only where the stale
    // Return key can appear: the first keyboard after launch or after the scene comes back to the foreground.
    private(set) var needsKeyboardRepaint = true
    private(set) var transition = 0
    private(set) var closeClock: CloseClock?
    // The running close's top spring, while a grab or a "+" can still take the sheet back.
    private(set) var closeTop: SheetSpring?
    // How far below its rest the sheet was when the current drag took it; a grab during a close starts there.
    private var dragBase: CGFloat = 0
    // What UIKit's interactive dismissal did to the keyboard during the current drag.
    private(set) var ride = KeyboardRide(grabbed: false)
    // The keyboard's frame on the screen when shown for the field, which a drag's frame changes are read against.
    private var keyboardRestFrame = CGRect.zero
    private var grabsClose = false
    // Until when the latest open is still moving, so a grab in it is recorded as one.
    private var opensUntil: CFTimeInterval = 0
    let sheetCatch = SheetCatch()
    // Whether a keyboard show has placed the keyboard guide; before the first one it sits at the bottom of the screen and
    // says nothing about the sheet's rest.
    private var keyboardPlaced = false
    private lazy var reopenTarget: UIControl = {
        let target = UIControl()
        target.addAction(UIAction { [unowned self] _ in openDuringClose() }, for: .touchDown)
        return target
    }()
    private(set) var blurFade: UIViewPropertyAnimator?
    // The sheet's top with the search keyboard at rest, learnt each time it shows under the attached sheet.
    private(set) var restTop: CGFloat?
    // Whether this open's field takes the keyboard: Auto-Open Keyboard at the open, or a tap on the field since.
    private var focusesField = true
    private var liftsOnShow = false
    private(set) var attachesWhenKeyboardShown = false
    private var keyboardResign = KeyboardResign()
    private(set) var keyboardShown = false
    private var detent = Detent(line: Theme.Gesture.sheetDragClose)
    // The deck's rate is held for as long as a finger is on the sheet or on a recent; every motion the sheet starts
    // holds it for its settling time, and a keystroke for Theme.SearchIdle.searchTypingHold. At rest it holds nothing,
    // so the panel idles.
    private(set) var presence: FrameRateVote.Presence?
    private(set) var rowPresence: FrameRateVote.Presence?
    #if DEBUG
    // The sheet's own main-thread work as (name, start, duration), so a profile can tell it from UIKit's and SwiftUI's:
    // the latest workKept entries, enough for one profile run.
    private static let workKept = 64
    private(set) var work: [(name: String, at: CFTimeInterval, duration: CFTimeInterval)] = []
    #endif

    init(model: SearchModel, env: AppEnvironment) {
        self.model = model
        self.env = env
        field = SearchField(
            onPress: { env.haptics.prepare(.searchClear) }, onClear: { env.haptics.fire(.searchClear) })
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = SheetHostView { [unowned self] in apply() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.overrideUserInterfaceStyle = .dark
        container.isHidden = true
        view.addSubview(tracker)
        tracker.addSubview(container)
        view.addSubview(reopenTarget)
        container.addSubview(underBar)
        container.addSubview(material)
        privateShade.backgroundColor = Theme.Palette.privateSheetShade
        privateShade.alpha = 0
        privateShade.isUserInteractionEnabled = false
        privateShade.frame = material.contentView.bounds
        privateShade.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        material.contentView.addSubview(privateShade)
        container.addSubview(edge)
        mount(sheet)
        container.addSubview(capsule)
        capsule.addSubview(field)
        for host in [browsingCopies, deckCopies, plus] {
            mount(host)
            host.view.isUserInteractionEnabled = false
        }
        field.delegate = self
        field.addAction(UIAction { [unowned self] _ in fieldEdited() }, for: .editingChanged)
        field.privateToggle.addAction(UIAction { [env] _ in env.haptics.prepare(.privateToggle) }, for: .touchDown)
        field.privateToggle.addAction(UIAction { [unowned self] _ in togglePrivate() }, for: .primaryActionTriggered)

        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDidActivate), name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardDidShow), name: UIResponder.keyboardDidShowNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChangeFrame), name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
        #if DEBUG
        runDebugDemo()
        #endif

        addGestures(pan: pan)
        rowSwiper.addTarget(self, action: #selector(swiped))
        rowSwiper.delegate = self
        sheet.view.addGestureRecognizer(rowSwiper)
        rowCatch.addTarget(self, action: #selector(rowPressed))
        rowCatch.minimumPressDuration = 0
        rowCatch.cancelsTouchesInView = false
        rowCatch.delegate = self
        sheet.view.addGestureRecognizer(rowCatch)

        let copies = [browsingCopies.view!, deckCopies.view!]
        for subview in [tracker, container, underBar, material, edge, sheet.view!, capsule, field, plus.view!] + copies {
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        let sheetView = sheet.view!
        keyboardBottom = sheetView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        detachedTop = sheetView.topAnchor.constraint(equalTo: view.topAnchor)
        containerHeight = container.heightAnchor.constraint(equalToConstant: 0)
        capsuleWidth = capsule.widthAnchor.constraint(equalToConstant: 0)
        capsuleHeight = capsule.heightAnchor.constraint(equalToConstant: 0)
        capsuleCenterY = capsule.centerYAnchor.constraint(equalTo: sheetView.topAnchor)
        fieldWidth = field.widthAnchor.constraint(equalToConstant: 0)
        fieldLead = field.leadingAnchor.constraint(equalTo: capsule.leadingAnchor)
        plusLead = plus.view.centerXAnchor.constraint(equalTo: capsule.leadingAnchor)
        NSLayoutConstraint.activate([
            keyboardBottom,
            containerHeight,
            tracker.topAnchor.constraint(equalTo: view.topAnchor),
            tracker.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tracker.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tracker.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sheetView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sheetView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sheetView.heightAnchor.constraint(equalToConstant: Theme.Metrics.searchSheetAboveKeyboard),
            container.topAnchor.constraint(equalTo: sheetView.topAnchor),
            container.leadingAnchor.constraint(equalTo: tracker.frameLayoutGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: tracker.frameLayoutGuide.trailingAnchor),
            underBar.topAnchor.constraint(equalTo: container.topAnchor),
            underBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            underBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            underBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            material.topAnchor.constraint(equalTo: container.topAnchor),
            material.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            material.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            material.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            edge.topAnchor.constraint(equalTo: container.topAnchor),
            edge.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            edge.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            edge.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            capsuleWidth,
            capsuleHeight,
            capsuleCenterY,
            capsule.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            fieldWidth,
            fieldLead,
            field.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: Theme.Metrics.searchFieldHeight),
            plusLead,
            plus.view.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
        ] + copies.flatMap { copy in
            [
                copy.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                copy.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                copy.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
                copy.heightAnchor.constraint(equalToConstant: Theme.Metrics.barHeight),
            ]
        })
    }

    #if DEBUG
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        env.debugSurfaces[.searchSheet] = { [unowned self] in route($0, $1) }
        publishDebugControls()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        env.debugSurfaces[.searchSheet] = nil
        withdrawDebugControls()
    }
    #endif

    private func hosting(_ root: some View) -> UIViewController {
        let host = UIHostingController(rootView: root)
        host.safeAreaRegions = []
        return host
    }

    private func mount(_ host: UIViewController) {
        addChild(host)
        host.view.backgroundColor = .clear
        container.addSubview(host.view)
        host.didMove(toParent: self)
    }

    func setActive(_ active: Bool, submitting: Bool) {
        wantsActive = active
        wantsSubmit = submitting
        apply()
    }

    // Focusing while the scene is still inactive (cold launch, return to foreground) leaves the
    // keyboard's Return key enabled on an empty field, so the rise waits for activation. Even then the
    // keyboard's first paint at launch can keep its default enabled Return, so it reloads once shown.
    private func apply() {
        guard let scene = view.window?.windowScene, wantsActive != isActive,
            !wantsActive || scene.activationState == .foregroundActive
        else { return }
        isActive = wantsActive
        if isActive {
            rise()
        } else if wantsSubmit {
            dismissForSubmit()
        } else {
            lower()
        }
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard notification.object as? UIWindowScene === view.window?.windowScene else { return }
        needsKeyboardRepaint = true
        apply()
    }

    // A prefilled sheet rides the keyboard's own animation, which starts here, after the open's commit.
    @objc private func keyboardWillShow(_ notification: Notification) {
        FrameRateVote.hold(for: notification.userInfo![UIResponder.keyboardAnimationDurationUserInfoKey] as! Double)
        keyboardPlaced = true
        keyboardResign.willShow()
        if liftsOnShow, field.isFirstResponder {
            liftsOnShow = false
            let end = (notification.userInfo![UIResponder.keyboardFrameEndUserInfoKey] as! NSValue).cgRectValue
            lift(toKeyboardTop: view.convert(end, from: view.window!.screen.coordinateSpace).minY)
        }
    }

    // A tap's keyboard takes an unfocused sheet off the guide. The sheet springs to the keyboard's end ahead of it, as
    // an empty open does, inside a rise so a catch holds it on the way, and goes back on the guide once the keyboard has
    // shown.
    private func lift(toKeyboardTop keyboardTop: CGFloat) {
        FrameRateVote.hold(for: max(Theme.Motion.searchOpen.settlingDuration, Theme.Motion.keyboardDuration))
        nextTransition()
        detachFromKeyboard()
        let drawnTop = layoutTop
        detachedTop.constant = keyboardTop - Theme.Metrics.searchSheetAboveKeyboard
        view.layoutIfNeeded()
        container.transform = offset(drawnTop - layoutTop)
        attachesWhenKeyboardShown = true
        rising {
            Theme.Motion.searchOpen.animate(initialVelocity: 0) {
                self.container.transform = .identity
            } completion: { _ in }
        }
    }

    // During a drag the keyboard's frame changes are UIKit's interactive dismissal moving it; the release reads them.
    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let end = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        ride.keyboardWillChangeFrame(to: end.cgRectValue, rest: keyboardRestFrame)
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        FrameRateVote.hold(for: notification.userInfo![UIResponder.keyboardAnimationDurationUserInfoKey] as! Double)
        keyboardPlaced = false
        keyboardShown = false
        keyboardResign.willHide()
        ride.keyboardWillHide()
    }

    @objc private func keyboardDidShow(_ notification: Notification) {
        keyboardShown = true
        if field.isFirstResponder, let end = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
            keyboardRestFrame = end.cgRectValue
        }
        // A resign that waited out the show, or a keyboard shown for the field once the sheet has gone (a resign that
        // did not take), is resigned on the next turn, so the keyboard never stays without its sheet. A closing sheet's
        // own hand-off is left alone. Inside this callback the show has not settled and a resign does not take.
        let waited = keyboardResign.didShow()
        if waited || (container.isHidden && field.isFirstResponder) {
            recoverKeyboardNextTurn()
            return
        }
        if attachesWhenKeyboardShown {
            attachesWhenKeyboardShown = false
            attach()
        }
        // The keyboard notifications are app-wide and the closed sheet stays on the guide, so only the search
        // field's own keyboard may teach the rest: a web form's keyboard, with its accessory bar, sits elsewhere.
        if keyboardBottom.isActive, field.isFirstResponder {
            view.layoutIfNeeded()
            restTop = layoutTop
        }
        // The reload shows the keyboard again, with its Return key repainted.
        guard needsKeyboardRepaint, field.isFirstResponder else { return }
        needsKeyboardRepaint = false
        field.reloadInputViews()
    }

    private var layoutTop: CGFloat {
        container.center.y - container.bounds.height / 2
    }

    private var barTop: CGFloat {
        view.window!.bounds.height - Theme.Metrics.barTotalHeight
    }

    private var copies: [UIView] {
        [browsingCopies.view!, deckCopies.view!]
    }

    private func shapeField(asPill pill: Bool) {
        let full = CGSize(
            width: view.bounds.width - 2 * Theme.Metrics.searchFieldInset, height: Theme.Metrics.searchFieldHeight)
        let size = pill ? Theme.Metrics.pillSize : full
        fieldWidth.constant = full.width
        capsuleWidth.constant = size.width
        capsuleHeight.constant = size.height
        capsuleCenterY.constant = pill ? Self.pillCenterBelowBarTop : Self.fieldCenterBelowTop
        capsule.layer.cornerRadius = size.height / 2
        container.layoutIfNeeded()
    }

    private func shapeSheet(barProgress progress: CGFloat) {
        material.shape(barProgress: progress)
        underBar.shape(barProgress: progress)
        edge.shape(barProgress: progress)
        material.tint(Theme.Frost.sheetTint, opacity: Theme.Frost.sheetTintOpacity * (1 - progress))
        material.alpha = 1 - progress * fades
        underBar.contentView.backgroundColor = underSolid?.withAlphaComponent(progress)
    }

    // With no page in front (the deck, or no tabs at all) the bar is the deck's. The under-layer follows: the page's bar
    // material on a light or private look, the dark bar's at the deck, none over a dark page.
    private func updateLook() {
        let page = env.ui.deckProgress == 1 ? nil : env.activeController
        let scheme: ColorScheme = view.window!.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        look.style = page.map {
            BarStyle.browsing(on: $0.barTint, in: scheme, isPrivate: env.pool.isPrivate($0.tabID))
        } ?? .deck
        let style = look.style
        let handsOff = style.light || style.atDeck || style.isPrivate
        fades = handsOff ? 1 : 0
        underSolid = style.atDeck
            ? UIColor(Theme.Palette.deckBarStrip) : style.isPrivate ? UIColor(Theme.Palette.privateBarBackground) : nil
        underBar.show(handsOff ? Theme.Frost.bar(light: style.light) : nil)
    }

    private var fieldFill: UIColor {
        env.ui.isPrivateMode ? Theme.Palette.privateFieldFill : SearchFieldCapsule.fieldFill
    }

    // The fill, the sheet's shade and the label's wipe run linearly from where they are drawn, over the share of the
    // fade still to go, so a second tap mid-motion turns them back without a jump. The glyph swaps at once.
    private func togglePrivate() {
        env.togglePrivateMode()
        let on = env.ui.isPrivateMode
        let shown = CGFloat(privateShade.layer.presentation()!.opacity) / Theme.Opacity.privateSheetShade
        let share = abs((on ? 1 : 0) - shown)
        let fill = capsule.layer.presentation()!.backgroundColor!
        let shade = privateShade.layer.presentation()!.opacity
        let wipe = field.privateLabel.layer.mask!
        let wiped = wipe.presentation()!.bounds
        field.showPrivate(on)
        field.layoutIfNeeded()
        privacy.isOn = on
        capsule.backgroundColor = fieldFill
        privateShade.alpha = on ? Theme.Opacity.privateSheetShade : 0
        FrameRateVote.hold(Theme.Motion.privateToggle)
        runPrivateFade(on: capsule.layer, "backgroundColor", from: fill, share: share)
        runPrivateFade(on: privateShade.layer, "opacity", from: shade, share: share)
        runPrivateFade(on: wipe, "bounds", from: NSValue(cgRect: wiped), share: share)
    }

    private func runPrivateFade(on layer: CALayer, _ keyPath: String, from: Any, share: CGFloat) {
        let fade = Theme.Motion.privateToggle.layerAnimation(keyPath: keyPath, from: from)
        fade.duration *= share
        layer.add(fade, forKey: keyPath)
    }

    // An open shows the mode it opens in at once.
    private func showPrivacy() {
        let on = env.ui.isPrivateMode
        field.showPrivate(on)
        field.privateLabel.layer.mask!.removeAllAnimations()
        privateShade.layer.removeAllAnimations()
        privateShade.alpha = on ? Theme.Opacity.privateSheetShade : 0
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { privacy.isOn = on }
    }

    // While the pill and the field morph into each other the "+" sits near the capsule's leading edge with
    // the text after it, drawn as "+ hi". At the pill it is centred, and at rest the text has its own inset.
    private func placePlus(beforeText: Bool) {
        plusLead.constant = beforeText ? Theme.Metrics.searchMorphPlusLead : Theme.Metrics.pillSize.width / 2
        fieldLead.constant = beforeText ? Theme.Metrics.searchMorphTextShift : 0
    }

    private func offset(_ y: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: 0, y: y)
    }

    private func rise() {
        let done = measure("searchRise")
        defer { done() }
        let close = closeTop
        nextTransition()
        let settles = max(Theme.Motion.searchOpen.settlingDuration, Theme.Motion.keyboardDuration)
        FrameRateVote.hold(for: settles)
        showSubmitFadedParts()
        opensUntil = CACurrentMediaTime() + settles
        focusesField = env.browser.settings.autoOpenKeyboard
        liftsOnShow = false
        if let close {
            reopen(from: close)
            return
        }
        let animated = [container, capsule, field, plus.view!, material, material.contentView, underBar, underBar.contentView, edge]
        for part in animated + copies {
            part.layer.removeAllAnimations()
        }
        container.alpha = 1
        field.alpha = 1
        containerHeight.constant = view.window!.bounds.height
        let prepared = measure("searchRisePrepare")
        let prefill = model.prepareForOpen(over: env.activeController?.url)
        showPrivacy()
        prepared()
        // An empty field rises on its own spring ahead of the keyboard; a prefilled one rides the keyboard. Leading
        // needs the keyboard's rest, known once it has shown.
        let leadTop = prefill.text.isEmpty ? keyboardRestTop : nil
        if let leadTop {
            keyboardBottom.isActive = false
            detachedTop.constant = leadTop
            detachedTop.isActive = true
        } else {
            attach()
        }
        attachesWhenKeyboardShown = leadTop != nil
        hostView.takesTouches = true
        container.isHidden = false
        let covered = measure("searchRiseCover")
        env.ui.searchCoversBar(true)
        covered()
        let laidOut = measure("searchRiseLayout")
        view.layoutIfNeeded()
        laidOut()
        container.transform = offset(barTop - layoutTop)
        updateLook()
        let atDeck = look.style.atDeck
        shapeField(asPill: true)
        placePlus(beforeText: true)
        // Laid out now, not inside the grow animation below, which would carry the "+" and the text from their pill
        // places and cross them ("+earch...") on the open's first frames.
        let laidOutParts = measure("searchRiseParts")
        container.layoutIfNeeded()
        laidOutParts()
        shapeSheet(barProgress: 1)
        plus.view.alpha = 1
        capsule.backgroundColor = SearchFieldCapsule.pillFill(look)
        browsingCopies.view.isHidden = atDeck
        deckCopies.view.isHidden = !atDeck
        for copy in copies {
            copy.alpha = 1
        }
        field.text = prefill.text
        UIView.animate(
            withDuration: Theme.Motion.searchCopyFade, delay: Theme.Motion.searchCopyHold,
            options: .allowUserInteraction
        ) {
            for copy in self.copies {
                copy.alpha = 0
            }
        }
        Theme.Motion.fieldGrow.animate(initialVelocity: 0) {
            self.shapeField(asPill: false)
            self.capsule.backgroundColor = self.fieldFill
        } completion: { _ in }
        UIView.animate(
            withDuration: Theme.Motion.searchCopyFade, delay: Theme.Motion.searchCopyHold,
            options: .allowUserInteraction
        ) {
            self.plus.view.alpha = 0
        }
        Theme.Motion.fieldGrow.animate(
            after: Theme.Motion.searchCopyHold + Theme.Motion.searchCopyFade, initialVelocity: 0
        ) {
            self.placePlus(beforeText: false)
            self.container.layoutIfNeeded()
        } completion: { _ in }
        let arrive = {
            self.container.transform = .identity
            self.shapeSheet(barProgress: 0)
        }
        rising {
            if leadTop != nil {
                Theme.Motion.searchOpen.animate(initialVelocity: 0, arrive) { _ in }
            } else {
                animateWithKeyboard(arrive)
            }
        }
        if focusesField {
            afterFirstFrame { [self] in
                focus()
                if prefill.selectAll {
                    field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
                }
            }
        }
    }

    // An open during a close rises from where the sheet is drawn, its top carrying the close spring's speed, and the
    // parts grow back from where they are.
    private func reopen(from close: SheetSpring) {
        let speed = close.speed(at: CACurrentMediaTime())
        let below = holdDrawnSheet()
        attachesWhenKeyboardShown = !keyboardBottom.isActive
        let prefill = model.prepareForOpen(over: env.activeController?.url)
        field.text = prefill.text
        showPrivacy()
        UIView.animate(withDuration: Theme.Motion.searchCopyFade, delay: 0, options: .allowUserInteraction) {
            for copy in self.copies {
                copy.alpha = 0
            }
            self.plus.view.alpha = 0
            self.field.alpha = 1
        }
        Theme.Motion.fieldGrow.animate(initialVelocity: 0) {
            self.capsule.backgroundColor = self.fieldFill
            self.placePlus(beforeText: false)
            self.shapeField(asPill: false)
        } completion: { _ in }
        rising {
            Theme.Motion.searchOpen.animate(initialVelocity: SheetDrag.releaseVelocity(speed, toward: -below)) {
                self.container.transform = .identity
                self.shapeSheet(barProgress: 0)
            } completion: { _ in }
        }
        guard focusesField else { return }
        afterFirstFrame { [self] in
            focus()
            if prefill.selectAll {
                field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
            }
        }
    }

    // The close runs on native springs fitted to measured motion: the sheet's top to the bar and the field collapsing into
    // the pill, while the "+", the text and the bar's side controls fade on their measured tables. It starts from where
    // the sheet is drawn, and a grab or a "+" during it takes the sheet back from where it is drawn then.
    private func lower(afterDrag: Bool = false) {
        let done = measure("searchLower")
        defer { done() }
        let current = nextTransition()
        attachesWhenKeyboardShown = false
        // A close before the keyboard has ever shown takes its own top as the rest of a sheet that takes the keyboard,
        // the place a grab or a "+" during it returns to.
        if focusesField, restTop == nil {
            restTop = layoutTop
        }
        detachFromKeyboard()
        holdDrawnParts()
        updateLook()
        let top = afterDrag ? Theme.Motion.searchReleaseClose : Theme.Motion.searchTapClose
        let velocity = afterDrag ? Theme.Motion.searchReleaseCloseVelocity : Theme.Motion.searchTapCloseVelocity
        let lag = afterDrag ? 0 : Theme.Motion.searchTapCollapseLag
        let frames = (afterDrag ? Theme.Motion.searchReleaseCloseFrames : Theme.Motion.searchTapCloseFrames) + lag
        FrameRateVote.hold(for: max(top.settlingDuration, Double(frames) * Theme.Motion.searchCloseFrame))
        let travel = barTop - layoutTop
        plusLead.constant = Self.closePlusLead(width: capsuleWidth.constant)
        container.layoutIfNeeded()
        // Added on Core Animation, so the close has its top spring and its begin even when the sheet is drawn at the bar
        // already, as on a close inside the open's first frame, where UIKit would add no animation for a zero travel.
        let fall = top.layerAnimation(
            keyPath: "transform", from: NSValue(caTransform3D: container.layer.transform), initialVelocity: velocity)
        fall.fillMode = .backwards
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.layer.add(fall, forKey: "transform")
        container.transform = offset(travel)
        CATransaction.commit()
        top.animate(initialVelocity: velocity) {
            self.shapeSheet(barProgress: 1)
        } completion: { _ in }
        Theme.Motion.searchCollapse.animate(after: Double(lag) * Theme.Motion.searchCloseFrame, initialVelocity: 0) {
            self.fieldLead.constant = 0
            self.plusLead.constant = Self.closePlusLead(width: Theme.Metrics.pillSize.width)
            self.capsule.backgroundColor = SearchFieldCapsule.pillFill(self.look)
            self.shapeField(asPill: true)
        } completion: { _ in }
        let handOffFrames = afterDrag ? Theme.Motion.searchReleaseCloseFrames : Theme.Motion.searchTapCloseFrames
        // Committed in this turn, so the close starts on the next frame; the fades and every step count from its begin.
        CATransaction.flush()
        let begin = container.layer.animation(forKey: "transform")!.beginTime
        closeTop = SheetSpring(begin: begin, travel: travel, spring: top, velocity: velocity)
        hostView.drawnTarget = { [unowned self] point, event in closingTarget(at: point, with: event) }
        fade(field, along: Theme.Motion.searchCollapseText, from: begin, after: lag)
        fade(plus.view, along: Theme.Motion.searchCollapsePlus, from: begin, after: lag)
        for copy in copies {
            fade(copy, along: afterDrag ? Theme.Motion.searchReleaseCopies : Theme.Motion.searchTapCopies, from: begin, after: lag)
        }
        // A display link holds its clock, so the clock's steps hold the sheet weakly: the sheet can go before the close ends.
        let handOff: (frame: Int, run: () -> Void) = (handOffFrames, { [weak self] in self?.finishHiding(current) })
        if afterDrag {
            // The keyboard leaves on the system's own hide from wherever the finger left it.
            startCloseClock(begin: begin, steps: [handOff])
            afterFirstFrame(stopTaking)
            return
        }
        // The keyboard holds still while the sheet slides under it, then leaves in one frame: it stays up and resigns
        // without animation on that frame. The text turns to the placeholder as the collapse starts,
        // after the resign, so clearing it does not sync a focused field with its keyboard.
        startCloseClock(
            begin: begin,
            steps: [
                (Theme.Motion.searchTapKeyboardVanishFrame, { [weak self] in self?.resign(animated: false) }),
                (Theme.Motion.searchTapCollapseLag + 1, { [weak self] in
                    guard let self else { return }
                    field.text = ""
                    hostView.takesTouches = false
                }),
                handOff,
            ])
    }

    private func startCloseClock(begin: CFTimeInterval, steps: [(frame: Int, run: () -> Void)]) {
        let clock = CloseClock(begin: begin, in: container.layer, steps: steps)
        clock.start()
        closeClock = clock
    }

    // The "+" centre sits short of the capsule's centre in proportion to its width, so it lands on the pill's centre.
    private static func closePlusLead(width: CGFloat) -> CGFloat {
        Theme.Metrics.searchClosePlusLead - Theme.Metrics.searchClosePlusLeadPerWidth * width
    }

    // A part fades on its measured table from lag frames after the close begins: frame k after that shows entry k - 1,
    // and until then the part holds what it showed.
    private func fade(_ part: UIView, along table: [CGFloat], from begin: CFTimeInterval, after lag: Int) {
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [part.alpha] + table
        fade.keyTimes = (0...table.count).map { NSNumber(value: Double($0) / Double(table.count)) }
        fade.duration = Double(table.count) * Theme.Motion.searchCloseFrame
        fade.beginTime = begin + Double(lag) * Theme.Motion.searchCloseFrame
        fade.fillMode = .backwards
        fade.preferredFrameRateRange = Theme.Latency.frameRateRange
        part.layer.add(fade, forKey: "opacity")
        part.alpha = table.last!
    }

    // Takes the sheet's parts from where they are drawn: what each shows becomes its model value and its motion ends, so
    // the next motion starts there. The sheet's own shape follows the material's drawn corner.
    private func holdDrawnParts() {
        let capsuleShown = capsule.layer.presentation()!
        capsuleWidth.constant = capsuleShown.bounds.width
        capsuleHeight.constant = capsuleShown.bounds.height
        capsuleCenterY.constant = capsuleShown.position.y
        capsule.layer.cornerRadius = capsuleShown.cornerRadius
        capsule.backgroundColor = UIColor(cgColor: capsuleShown.backgroundColor!)
        plusLead.constant = plus.view.layer.presentation()!.position.x - capsuleShown.frame.minX
        fieldLead.constant = field.layer.presentation()!.frame.minX
        let fading = [field, plus.view!] + copies
        for part in fading {
            part.alpha = CGFloat(part.layer.presentation()!.opacity)
        }
        let barProgress = 1 - material.layer.presentation()!.cornerRadius / Theme.Metrics.searchSheetCorner
        for part in fading + [capsule, material, material.contentView, underBar, underBar.contentView, edge] {
            part.layer.removeAllAnimations()
        }
        shapeSheet(barProgress: barProgress)
        container.layoutIfNeeded()
    }

    // Takes the whole sheet from where an open, a return or a close has drawn it, laid out at its rest and offset to the
    // drawn top. Returns the offset.
    @discardableResult
    private func holdDrawnSheet() -> CGFloat {
        learnRestFromKeyboard()
        let drawnTop = container.layer.presentation()!.frame.minY
        holdDrawnParts()
        container.layer.removeAllAnimations()
        // With no keyboard to rest on, or before it first shows, the sheet goes on the keyboard guide, offset to where
        // it is drawn.
        guard let restTop = keyboardRestTop else {
            attach()
            view.layoutIfNeeded()
            container.transform = offset(drawnTop - layoutTop)
            hostView.takesTouches = true
            return drawnTop - layoutTop
        }
        keyboardBottom.isActive = false
        detachedTop.constant = restTop
        detachedTop.isActive = true
        view.layoutIfNeeded()
        container.transform = offset(drawnTop - restTop)
        hostView.takesTouches = true
        return drawnTop - restTop
    }

    private var keyboardRestTop: CGFloat? {
        focusesField ? restTop : nil
    }

    private func learnRestFromKeyboard() {
        if keyboardBottom.isActive, keyboardPlaced, field.isFirstResponder {
            restTop = layoutTop
        }
    }

    // During a close the drawn pill reopens the sheet on touch-down, as "+" does, and the rest of the drawn sheet can be
    // grabbed. Once the sheet is drawn as the bar, a touch on the bar's strip hands off at once and reaches the bar's own
    // control under it.
    private func closingTarget(at point: CGPoint, with event: UIEvent?) -> UIView? {
        let sheet = container.layer.presentation()!.frame
        guard sheet.contains(point) else { return nil }
        let local = CGPoint(x: point.x - sheet.minX, y: point.y - sheet.minY)
        if capsule.layer.presentation()!.frame.contains(local) {
            return reopenTarget
        }
        guard point.y >= barTop, barTop - sheet.minY <= Theme.Gesture.closeBarHandOff else { return container }
        // Only a touch hands off; a hit test that asks where a point goes, as the pan's cancel does, changes nothing.
        if event?.type == .touches {
            finishHiding(transition)
        }
        return nil
    }

    private func openDuringClose() {
        env.haptics.fire(.plusTap)
        env.ui.open(.search)
    }

    private func dismissForSubmit() {
        let done = measure("searchSubmitStart")
        defer { done() }
        let current = nextTransition()
        attachesWhenKeyboardShown = false
        detachFromKeyboard()
        FrameRateVote.hold(Theme.Motion.searchSubmitRise)
        FrameRateVote.hold(Theme.Motion.submitFadeOut)
        // On Core Animation, like the page's fade: this runs in the same SwiftUI pass, which can have UIKit
        // animations off. The container never fades: a blur under a fading ancestor drops on the fade's first frame
        // and the rows float over the page. Its parts fade by their own alpha and the blur by its effect, so the
        // sheet stays a dark slab while it rises and fades.
        let layer = container.layer
        let rise = Theme.Motion.searchSubmitRise.layerAnimation(
            keyPath: "transform", from: NSValue(caTransform3D: layer.transform))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.add(rise, forKey: "transform")
        container.transform = offset(container.transform.ty - Theme.Metrics.searchSheetRiseOnSubmit)
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { self.finishHiding(current) }
        for part in submitFadingParts {
            let fade = Theme.Motion.submitFadeOut.layerAnimation(keyPath: "opacity", from: part.layer.opacity)
            part.layer.add(fade, forKey: "opacity")
            part.alpha = 0
        }
        CATransaction.commit()
        let blurFade = Theme.Motion.submitFadeOut.propertyAnimator {
            self.material.clear()
            self.underBar.clear()
        }
        self.blurFade = blurFade
        // A blur's effect animates only through UIKit, which this SwiftUI pass may have turned off, so its fade starts a
        // turn later, while the sheet is still a full slab.
        AfterCommit.run { [self] in
            guard current == transition else { return }
            blurFade.startAnimation()
        }
        // The first change to the focused field in a turn (its text, its touches, its focus) holds the main thread for 10
        // to 25 ms while UIKit syncs the keyboard, so all of them wait for the first frame of the sheet's and the page's
        // fade-outs. The keyboard then leaves on the system's own hide on Go, its Return key live until then.
        afterFirstFrame(stopTaking)
    }

    // A signposted interval of the sheet's own work, for a phone trace to tell it from UIKit's and SwiftUI's in a turn.
    private func measure(_ name: StaticString) -> () -> Void {
        let interval = Self.signposter.beginInterval(name)
        #if DEBUG
        let begin = CACurrentMediaTime()
        #endif
        return {
            Self.signposter.endInterval(name, interval)
            #if DEBUG
            self.work.append(("\(name)", begin, CACurrentMediaTime() - begin))
            self.work.removeFirst(max(0, self.work.count - Self.workKept))
            #endif
        }
    }

    // A first-responder change holds the main thread for 12 to 25 ms on the phone, so it runs on the turn after the
    // motion's first frame is committed. The motion is flushed here where no outer transaction holds it, and again just
    // before the change, which commits any write made later in the turn, such as a grab's first move; UIKit's own commit
    // may not have run by then. A newer transition drops the change.
    private func afterFirstFrame(_ change: @escaping () -> Void) {
        CATransaction.flush()
        let current = transition
        AfterCommit.run { [self] in
            guard current == transition else { return }
            CATransaction.flush()
            let done = measure("searchResponder")
            defer { done() }
            change()
        }
    }

    private func focus() {
        keyboardResign.refocus()
        field.becomeFirstResponder()
    }

    // Animated, the keyboard leaves on the system's hide; unanimated, it is gone on the next frame.
    private func resign(animated: Bool) {
        guard keyboardResign.resignNow() else { return }
        if animated {
            field.resignFirstResponder()
        } else {
            UIView.performWithoutAnimation { field.resignFirstResponder() }
        }
    }

    // Resigned first, so clearing the text does not sync a focused field with its keyboard.
    private func stopTaking() {
        resign(animated: true)
        field.text = ""
        hostView.takesTouches = false
    }

    @discardableResult
    private func nextTransition() -> Int {
        closeClock?.cancel()
        closeTop = nil
        hostView.drawnTarget = nil
        ride = KeyboardRide(grabbed: false)
        transition += 1
        return transition
    }

    var submitFadingParts: [UIView] {
        [sheet.view, capsule, edge]
    }

    private func showSubmitFadedParts() {
        blurFade?.stopAnimation(true)
        blurFade = nil
        material.restore()
        // The under-layer's style comes back with the next open's look.
        underBar.contentView.alpha = 1
        for part in submitFadingParts {
            part.layer.removeAnimation(forKey: "opacity")
            part.alpha = 1
        }
    }

    private func finishHiding(_ ended: Int) {
        guard ended == transition else { return }
        let done = measure("searchHide")
        defer { done() }
        closeClock?.cancel()
        closeTop = nil
        hostView.drawnTarget = nil
        showSubmitFadedParts()
        presence = nil
        rowPresence = nil
        container.isHidden = true
        env.ui.searchCoversBar(false)
        container.alpha = 1
        attach()
        // A resign that did not take during the close would otherwise leave the keyboard up with no sheet until a
        // show that may never come. A show still in flight ends in keyboardDidShow, which recovers it there.
        if field.isFirstResponder, !keyboardResign.showing {
            recoverKeyboardNextTurn()
        }
    }

    // A field still focused after the sheet hid is resigned, animated.
    private func recoverKeyboardNextTurn() {
        let current = transition
        DispatchQueue.main.async { [self] in
            guard current == transition, field.isFirstResponder else { return }
            resign(animated: true)
        }
    }

    private func detachFromKeyboard() {
        let shownTop = container.layer.presentation()!.frame.minY
        container.layer.removeAllAnimations()
        container.transform = .identity
        keyboardBottom.isActive = false
        detachedTop.constant = shownTop
        detachedTop.isActive = true
        view.layoutIfNeeded()
    }

    private func attach() {
        detachedTop.isActive = false
        keyboardBottom.isActive = true
    }

    // A return with the keyboard still at rest springs on its own and reattaches only when it ends, where the keyboard
    // guide puts the sheet at the same top; following the guide while the keyboard comes back would mix two curves. A
    // return after the finger moved the keyboard goes back on the guide at once and rides the keyboard up: UIKit's own
    // revert, or the keyboard asked for again when UIKit had completed the dismissal.
    private func reRise(velocity: CGFloat) {
        FrameRateVote.hold(Theme.Motion.searchReturn)
        let ridesKeyboard = ride.returnRidesKeyboard
        let current = nextTransition()
        let visualTop = layoutTop + container.transform.ty
        // With no keyboard to rest on, or before it first shows, the sheet goes back on the keyboard guide and rides the
        // keyboard up, as the first open does; the keyboard's spring settles later than the return's.
        guard let restTop = keyboardRestTop, !ridesKeyboard else {
            FrameRateVote.hold(.keyboard)
            attach()
            view.layoutIfNeeded()
            container.transform = offset(visualTop - layoutTop)
            rising {
                animateWithKeyboard {
                    self.container.transform = .identity
                    self.showOpenParts()
                }
            }
            // The keyboard comes back where UIKit had completed the dismissal; a keyboard still up, or reverting on its
            // own, is left to UIKit.
            if focusesField {
                afterFirstFrame { [self] in focus() }
            }
            return
        }
        detachedTop.constant = restTop
        view.layoutIfNeeded()
        container.transform = offset(visualTop - restTop)
        let travel = -container.transform.ty
        rising {
            Theme.Motion.searchReturn.animate(initialVelocity: SheetDrag.releaseVelocity(velocity, toward: travel)) {
                self.container.transform = .identity
                self.showOpenParts()
            } completion: { _ in }
        } arrived: { [self] in
            // A newer gesture has taken the sheet if the transition moved on.
            guard current == transition else { return }
            // A keyboard that stayed up through the return has shown already, so the sheet goes back on it here.
            if attachesWhenKeyboardShown, keyboardShown, field.isFirstResponder {
                attachesWhenKeyboardShown = false
                attach()
            }
        }
        attachesWhenKeyboardShown = true
        afterFirstFrame { [self] in focus() }
    }

    // A sheet grabbed during a close grows its parts back as it returns; on an open sheet they are already there.
    private func showOpenParts() {
        capsule.backgroundColor = fieldFill
        placePlus(beforeText: false)
        shapeField(asPill: false)
        plus.view.alpha = 0
        field.alpha = 1
        for copy in copies {
            copy.alpha = 0
        }
        shapeSheet(barProgress: 0)
    }

    // While the sheet rises its model is already at rest, so until the motion's springs arrive touches go by where it is
    // drawn.
    private func rising(_ motion: () -> Void, arrived: @escaping () -> Void = {}) {
        let current = transition
        CATransaction.begin()
        CATransaction.setCompletionBlock { [self] in
            if current == transition {
                hostView.drawnTarget = nil
            }
            arrived()
        }
        motion()
        letSpringsArrive()
        CATransaction.commit()
        hostView.drawnTarget = { [unowned self] point, event in risingTarget(at: point, with: event) }
    }

    // Above the drawn top there is no sheet yet, so a touch goes behind, to the dim. A touch on the drawn sheet catches
    // it there, so a row's press and the field resolve it on the held sheet.
    private func risingTarget(at point: CGPoint, with event: UIEvent?) -> UIView? {
        guard container.layer.presentation()!.frame.contains(point) else { return nil }
        return caughtTarget(at: point, with: event)
    }

    private func letSpringsArrive() {
        let parts = [container, capsule, field, plus.view!, material, material.contentView, underBar, underBar.contentView, edge]
        for part in parts {
            part.layer.letSpringsArrive()
        }
    }

    private func animateWithKeyboard(_ animations: @escaping () -> Void) {
        MotionToken.keyboard.animate(initialVelocity: 0, animations) { _ in }
    }

    @objc private func drag(_ pan: UIPanGestureRecognizer) {
        route(pan)
    }

    @objc private func swiped(_ swiper: RowSwipeRecognizer) {
        switch swiper.state {
        case .began:
            // Taken first, so the catch's cancel below finds no hold to let go.
            rowSwipeBegan(recentRow(at: swiper.start)!)
            cancelTouchSharers(from: hostView.touchedDown, keeping: swiper)
        case .changed:
            rowSwipeChanged(swiper.travel)
        case .ended:
            rowSwipeEnded(velocity: swiper.releaseVelocity)
        case .cancelled:
            rowSwipeCancelled()
        default:
            break
        }
    }

    // A touch on a recent springing back holds it where it is drawn, on the touch's own turn as SheetCatch holds a
    // moving sheet. The catch then cancels the row's press, so the tap only catches, as on the platform's swipe actions,
    // and a cancelled removal never opens the page. A swipe takes the row from there; a release, or a pan that takes the
    // sheet instead, lets it spring on.
    @objc private func rowPressed(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .began:
            rowCatchBegan(from: hostView.touchedDown)
        case .ended, .cancelled:
            rowReleased()
        default:
            break
        }
    }

    func rowCatchHolds(at point: CGPoint) -> Bool {
        rowReturn != nil && recentRow(at: point) == recentSwipe.row
    }

    func rowTouched(at point: CGPoint) {
        if rowCatchHolds(at: point) {
            rowCaught()
        }
    }

    func rowCaught() {
        rowReturn?.stop()
        rowReturn = nil
        rowHeld = true
    }

    // The swipe and the sheet's pan stay on the touch, so it can still swipe the row or drag the sheet.
    func rowCatchBegan(from start: UIView?) {
        cancelTouchSharers(from: start, keeping: rowCatch, rowSwiper, pan)
    }

    func rowSwipeMayBegin(at point: CGPoint) -> Bool {
        isActive && closeTop == nil && recentRow(at: point) != nil
    }

    func rowReleased() {
        guard rowHeld else { return }
        rowHeld = false
        springRowBack(velocity: 0)
    }

    // The recent drawn under a point in the rows' host, if the row there is one.
    func recentRow(at point: CGPoint) -> Suggestion? {
        let index = Int(((point.y - SearchSheet.fieldSlotHeight) / Theme.Metrics.suggestionRowHeight).rounded(.down))
        guard index >= 0, index < min(model.rows.count, Theme.Metrics.suggestionRowCount),
            case .site = model.rows[index]
        else { return nil }
        return model.rows[index]
    }

    func rowSwipeBegan(_ row: Suggestion) {
        env.haptics.prepare(.recentArm)
        rowPresence = FrameRateVote.Presence()
        if rowReturn != nil, recentSwipe.row != row {
            // The other recent finishes its return on its own spring.
            FrameRateVote.hold(Theme.Motion.recentReturn)
            settleRows(Theme.Motion.recentReturn) { recentSwipe.clear() }
        }
        rowReturn?.stop()
        rowReturn = nil
        rowHeld = false
        let swipe = RowSwipe(width: container.bounds.width, from: recentSwipe.offset(for: row))
        rowSwipe = swipe
        recentSwipe.follow(row, swipe)
    }

    func rowSwipeChanged(_ travel: CGFloat) {
        let armed = rowSwipe!.follow(travel) == .armed
        recentSwipe.follow(recentSwipe.row!, rowSwipe!)
        if armed {
            env.haptics.fire(.recentArm)
        }
    }

    // Past the line the row vanishes in one frame, the recent leaves the store and the rows close its
    // gap; short of it the row springs home, carrying the finger's speed (leftward positive).
    func rowSwipeEnded(velocity: CGFloat) {
        guard rowSwipe!.removes, case .site(let url, _) = recentSwipe.row! else {
            rowSwipeReturned(velocity: velocity)
            return
        }
        rowSwipe = nil
        rowPresence = nil
        FrameRateVote.hold(Theme.Motion.recentCollapse)
        settleRows(Theme.Motion.recentCollapse) {
            recentSwipe.clear()
            model.removeRecent(url)
        }
        env.haptics.fire(.recentRemove)
    }

    // A pan taking the sheet, or the app going inactive, cancels the swipe: the row springs home as a short release does.
    func rowSwipeCancelled() {
        rowSwipeReturned(velocity: 0)
    }

    private func rowSwipeReturned(velocity: CGFloat) {
        rowSwipe = nil
        rowPresence = nil
        springRowBack(velocity: velocity)
        env.haptics.fire(.recentReturn)
    }

    // The row never passes rest, so a flick back toward it stops there.
    private func springRowBack(velocity: CGFloat) {
        let token = Theme.Motion.recentReturn
        let spring = token.spring
        let from = recentSwipe.offset
        let begin = view.layer.convertTime(CACurrentMediaTime(), from: nil)
        rowReturn = FrameClock(in: view.layer) { [weak self] now, _ in
            guard let self else { return false }
            let time = now - begin
            guard time < spring.settlingDuration else {
                recentSwipe.clear()
                rowReturn = nil
                return false
            }
            recentSwipe.place(max(0, from + spring.value(target: -from, initialVelocity: velocity, time: time)))
            return true
        }
        FrameRateVote.hold(token)
    }

    private func settleRows(_ token: MotionToken, _ change: () -> Void) {
        var transaction = Transaction(animation: token.animation)
        transaction.recentSwipeMotion = true
        withTransaction(transaction, change)
    }

    // A catch holds the rising sheet where it is drawn, its parts included, so the next frame shows it still under the
    // finger. The keyboard stays.
    func holdDrawn() {
        nextTransition()
        attachesWhenKeyboardShown = false
        holdDrawnSheet()
    }

    func riseFromHold() {
        reRise(velocity: 0)
    }

    // A drag takes the sheet from where it is drawn, even mid-rise or mid-return, so it follows the finger
    // from the first frame without waiting for the open or the keyboard. The keyboard stays up and is UIKit's: its
    // interactive dismissal takes it with the finger once the finger reaches it, and the release reads what it did.
    func dragBegan() {
        presence = FrameRateVote.Presence()
        if isActive, CACurrentMediaTime() < opensUntil {
            env.haptics.fire(.searchGrabDuringOpen)
        }
        grabsClose = closeTop != nil
        nextTransition()
        attachesWhenKeyboardShown = false
        detent = Detent(line: Theme.Gesture.sheetDragClose)
        if grabsClose {
            dragBase = holdDrawnSheet()
        } else {
            learnRestFromKeyboard()
            dragBase = 0
            detachFromKeyboard()
        }
        ride = KeyboardRide(grabbed: field.isFirstResponder)
    }

    func dragCancelled() {
        presence = nil
        returnSheet(velocity: 0)
    }

    // The sheet follows the finger; its rows slide under the keyboard until the finger reaches it.
    func dragChanged(_ translation: CGFloat) {
        _ = detent.update(dragBase + translation)
        container.transform = offset(SheetDrag.offset(translation: dragBase + translation))
    }

    // A sheet grabbed during its close is open again once it returns: search reopens with the text it closed with.
    private func returnSheet(velocity: CGFloat) {
        if grabsClose {
            grabsClose = false
            wantsActive = true
            isActive = true
            field.text = model.text
            env.ui.open(.search)
        }
        reRise(velocity: velocity)
    }

    // The sheet starts lowering in this call so the release frame already moves; UIState's update then
    // finds the controller inactive and does nothing.
    func dragEnded(translation: CGFloat, velocity: CGFloat) {
        presence = nil
        let closes = SheetDrag.closes(armed: detent.isArmed, translation: dragBase + translation, velocity: velocity)
        env.haptics.fire(closes ? .searchDragDismiss : .searchDragReturn)
        guard closes else {
            returnSheet(velocity: velocity)
            return
        }
        grabsClose = false
        wantsActive = false
        isActive = false
        lower(afterDrag: true)
        env.ui.close()
    }

    // The row catch sees each touch-down as it is delivered, before the rows' own recognizers act on it.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === rowCatch {
            rowTouched(at: touch.location(in: sheet.view))
        }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === catcher {
            return catchMayBegin
        }
        if gestureRecognizer === rowCatch {
            return rowHeld
        }
        if gestureRecognizer === rowSwiper {
            return rowSwipeMayBegin(at: rowSwiper.start)
        }
        // A recent's swipe owns its touch, so the sheet leaves it alone.
        guard rowSwipe == nil else { return false }
        let velocity = (gestureRecognizer as! UIPanGestureRecognizer).velocity(in: view)
        // A closing sheet is taken back whichever way the finger goes; an open one only by a downward drag.
        return closeTop != nil ? abs(velocity.y) > abs(velocity.x) : isActive && velocity.y > abs(velocity.x)
    }

    // The rows are SwiftUI buttons whose press begins on touch-down and would otherwise keep the sheet's pan from
    // starting, so a swipe that lands on the suggestions moved nothing. The pan and the catch run alongside them; when
    // the pan begins it cancels the rows (cancelTouchSharers), as a bottom sheet over a list does.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func textField(
        _ textField: UITextField, shouldChangeCharactersInRanges ranges: [NSValue], replacementString string: String
    ) -> Bool {
        let length = ((textField.text ?? "") as NSString).length
        appendingEdit = !string.isEmpty && ranges.last.map { NSMaxRange($0.rangeValue) } == length
        return true
    }

    // UIKit's own text input costs 18 to 29 ms of a keystroke's frame on the phone. The inline completion is written in
    // the keystroke's own turn, so the field syncs with its keyboard once; the ranking and the rows' layout run on the
    // turn after its commit, once for every keystroke that lands before then.
    private func fieldEdited() {
        FrameRateVote.hold(for: Theme.SearchIdle.searchTypingHold)
        let typed = field.text ?? ""
        model.text = typed
        model.complete(appending: appendingEdit)
        if let completed = model.completedText {
            field.text = completed
            let start = field.position(from: field.beginningOfDocument, offset: (typed as NSString).length)!
            field.selectedTextRange = field.textRange(from: start, to: field.endOfDocument)
        }
        guard !rankPending else { return }
        rankPending = true
        AfterCommit.run { [self] in rank() }
    }

    private func rank() {
        rankPending = false
        let done = measure("searchEdit")
        defer { done() }
        model.rank()
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        liftsOnShow = !focusesField
        focusesField = true
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if let url = model.submit() {
            submit(url, via: .searchSubmit)
        }
        return false
    }

    private func select(_ suggestion: Suggestion) {
        submit(model.url(for: suggestion), via: .suggestionTap)
    }

    private func submit(_ url: URL, via interaction: Interaction) {
        model.record(url)
        env.submit(url, via: interaction)
    }
}
