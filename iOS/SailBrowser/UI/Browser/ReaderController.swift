import UIKit
import WebKit

// The article over the page in the tab's card, in a web view of its own that runs none of the article's script, keeps
// no data and loads nothing but https and inline images. It rises from the bottom on a Core Animation spring and is
// taken as the search sheet and the menu are (SheetDragging): a touch-down on the rising reader holds it where it is
// drawn, a drag moves it from there, and a catch let go finishes the rise. At rest its page scrolls as usual.
final class ReaderController: UIViewController, UIGestureRecognizerDelegate, UIScrollViewDelegate, SheetDragging,
    WKNavigationDelegate
{
    static let contentSecurityPolicy = "default-src 'none'; img-src https: data:; style-src 'unsafe-inline'"
    // reader.css with the Theme's reader tokens in place of its placeholders.
    static let stylesheet = try! String(
        contentsOf: Bundle.main.url(forResource: "reader", withExtension: "css")!, encoding: .utf8)
        .replacing("{{bodyFont}}", with: shorthand(Theme.Typography.readerBody))
        .replacing("{{titleFont}}", with: shorthand(Theme.Typography.readerTitle))
        .replacing("{{measure}}", with: "\(Int(Theme.Metrics.readerMeasure))px")
        .replacing("{{inset}}", with: "\(Int(Theme.Metrics.readerInset))px")

    // A link tapped in the article, for the tab to load.
    var onOpen: ((URL) -> Void)?
    // The article a drag left showing, or nil once a drag has closed it.
    var onShown: ((ReaderArticle?) -> Void)?
    // A two-finger pinch on the reader, forwarded to the tab: the tab stack button is reachable over the reader, so the
    // pinch presses it there too. The article's zoom ending, bounce included, is forwarded the same way.
    var onPinch: ((UIPinchGestureRecognizer) -> Void)?
    var onZoomEnded: (() -> Void)?
    let container = UIView()
    let sheetCatch = SheetCatch()
    // Built for each article and released once the reader has closed, so the next one takes the lists of its moment.
    private(set) var page: WKWebView?
    private(set) var article: ReaderArticle?
    private(set) var isOpen = false
    // The spring the reader is on; nil at rest, held, under the finger, or hidden.
    private(set) var motion: SheetSpring?
    private(set) var transition = 0
    // The deck's rate while the finger moves the reader.
    private(set) var presence: FrameRateVote.Presence?
    private let haptics: HapticsEngine
    private var drag = MenuDrag()
    // The shell's own load is the only navigation the reader's page makes on its own.
    private var awaitsShell = false

    init(haptics: HapticsEngine) {
        self.haptics = haptics
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = SheetHostView {}
    }

    var hostView: SheetHostView {
        view as! SheetHostView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        container.isHidden = true
        container.backgroundColor = Theme.Palette.readerBackground
        container.frame = view.bounds
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(container)
        addGestures(pan: UIPanGestureRecognizer(target: self, action: #selector(panned)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
        pinch.delegate = self
        container.addGestureRecognizer(pinch)
    }

    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        onPinch?(pinch)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        onZoomEnded?()
    }

    static func configuration(ruleLists: [WKContentRuleList]) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        ruleLists.forEach(configuration.userContentController.add)
        return configuration
    }

    static func document(for article: ReaderArticle) -> String {
        let lang = article.lang.map { #" lang="\#(escaped($0))""# } ?? ""
        let dir = article.dir.map { #" dir="\#(escaped($0))""# } ?? ""
        let byline = article.byline.map { #"<p class="byline">\#(escaped($0))</p>"# } ?? ""
        return """
            <!doctype html>
            <html\(lang)\(dir)>
            <head>
            <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(escaped(article.title))</title>
            <style>\(stylesheet)</style>
            </head>
            <body><article><h1>\(escaped(article.title))</h1>\(byline)\(article.html)</article></body>
            </html>
            """
    }

    private static func shorthand(_ font: WebFont) -> String {
        "\(font.weight) \(Int(font.size))px \(font.family)"
    }

    private static func escaped(_ text: String) -> String {
        text.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;")
            .replacing("\"", with: "&quot;")
    }

    func present(
        _ article: ReaderArticle, baseURL: URL?, zoom: Double, insets: UIEdgeInsets, ruleLists: [WKContentRuleList]
    ) {
        loadViewIfNeeded()
        self.article = article
        page?.removeFromSuperview()
        let page = makePage(ruleLists: ruleLists)
        page.pageZoom = zoom
        page.setObscuredInsets(insets)
        awaitsShell = true
        page.loadHTMLString(Self.document(for: article), baseURL: baseURL)
        open()
    }

    func dismiss() {
        isOpen = false
        nextTransition()
        close(velocity: nil)
    }

    func setZoom(_ zoom: Double) {
        page?.pageZoom = zoom
    }

    func setInsets(_ insets: UIEdgeInsets) {
        page?.setObscuredInsets(insets)
    }

    private func makePage(ruleLists: [WKContentRuleList]) -> WKWebView {
        let page = WKWebView(frame: container.bounds, configuration: Self.configuration(ruleLists: ruleLists))
        page.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Opaque in the reader's own background, so a scroll frame blends nothing; the same colour shows until the
        // article paints and past its ends.
        page.backgroundColor = Theme.Palette.readerBackground
        page.underPageBackgroundColor = Theme.Palette.readerBackground
        page.scrollView.contentInsetAdjustmentBehavior = .never
        page.scrollView.delegate = self
        page.navigationDelegate = self
        container.addSubview(page)
        self.page = page
        return page
    }

    // A link opens in the tab; one to a place in the article itself stays here. Past the shell's own load nothing
    // else navigates the reader, a meta refresh in the article included.
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url!
        switch navigationAction.navigationType {
        case .other where awaitsShell:
            awaitsShell = false
            return .allow
        case .linkActivated where url.fragment != nil && Self.withoutFragment(url) == webView.url.map(Self.withoutFragment):
            return .allow
        case .linkActivated:
            onOpen?(url)
            return .cancel
        default:
            return .cancel
        }
    }

    // The article's process going away leaves nothing to show: the reader closes as a drag would.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        dismiss()
        onShown?(nil)
    }

    private static func withoutFragment(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.fragment = nil
        return components.url!
    }

    private var height: CGFloat {
        view.bounds.height
    }

    private func nextTransition() {
        transition += 1
    }

    // From below, or, during a close, from where it is drawn with the speed it has there.
    private func open() {
        isOpen = true
        nextTransition()
        hostView.drawnTarget = { [unowned self] point, event in target(at: point, with: event) }
        var velocity: CGFloat = 0
        if container.isHidden {
            container.isHidden = false
            place(height)
        } else {
            velocity = takeDrawn(toward: 0)
        }
        move(to: 0, on: Theme.Motion.readerOpen, velocity: velocity) {}
    }

    private func close(velocity: CGFloat?) {
        let carried = takeDrawn(toward: height)
        move(to: height, on: Theme.Motion.readerClose, velocity: velocity ?? carried) { [weak self] in
            self?.finishHiding()
        }
    }

    private func finishHiding() {
        container.isHidden = true
        hostView.drawnTarget = nil
        page?.removeFromSuperview()
        page = nil
    }

    private func place(_ offset: CGFloat) {
        container.transform = CGAffineTransform(translationX: 0, y: offset)
    }

    // Ends the motion where the reader is drawn, which becomes its model, and returns the speed it had there relative
    // to the travel to `target`.
    private func takeDrawn(toward target: CGFloat) -> CGFloat {
        guard let motion else { return 0 }
        let speed = motion.speed(at: CACurrentMediaTime())
        // A reader whose tab is off screen is drawn nowhere, and its model stands for it.
        place((container.layer.presentation() ?? container.layer).affineTransform().ty)
        container.layer.removeAllAnimations()
        self.motion = nil
        return SheetDrag.releaseVelocity(speed, toward: target - container.transform.ty)
    }

    // The spring begins now, set on the animation rather than read back from the layer: a reader whose tab is off
    // screen has its animation finish and leave at once. It is recorded before the commit, whose completion may run in
    // it, and the completion holds the reader weakly, as it can outlive the tab.
    private func move(to target: CGFloat, on token: MotionToken, velocity: CGFloat, arrived: @escaping () -> Void) {
        let current = transition
        let begin = CACurrentMediaTime()
        let slide = token.layerAnimation(
            keyPath: "transform", from: NSValue(caTransform3D: container.layer.transform), initialVelocity: velocity)
        slide.beginTime = container.layer.convertTime(begin, from: nil)
        motion = SheetSpring(
            begin: begin, travel: target - container.transform.ty, spring: token, velocity: velocity)
        FrameRateVote.hold(token)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, current == transition else { return }
            motion = nil
            arrived()
        }
        container.layer.add(slide, forKey: "transform")
        place(target)
        container.layer.letSpringsArrive()
        CATransaction.commit()
    }

    // While the reader moves only where it is drawn counts; above it the page has the touch. A touch on the rising or
    // returning reader catches it there, so the article under the finger takes the touch; a closing reader's touch only
    // feeds the pan. At rest the article answers as usual.
    private func target(at point: CGPoint, with event: UIEvent?) -> UIView? {
        guard motion != nil else {
            return container.hitTest(view.convert(point, to: container), with: event)
        }
        guard point.y >= container.layer.presentation()!.frame.minY else { return nil }
        return isOpen ? caughtTarget(at: point, with: event) : container
    }

    func holdDrawn() {
        nextTransition()
        _ = takeDrawn(toward: 0)
    }

    func riseFromHold() {
        nextTransition()
        move(to: 0, on: Theme.Motion.readerOpen, velocity: 0) {}
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        route(pan)
    }

    func dragBegan() {
        presence = FrameRateVote.Presence()
        nextTransition()
        _ = takeDrawn(toward: 0)
        drag = MenuDrag(from: container.transform.ty)
    }

    func dragChanged(_ translation: CGFloat) {
        place(drag.changed(translation))
    }

    func dragEnded(translation: CGFloat, velocity: CGFloat) {
        presence = nil
        switch drag.ended(translation: translation, velocity: velocity, sheetHeight: height) {
        case .close(let velocity):
            haptics.fire(.readerDragDismiss)
            isOpen = false
            nextTransition()
            close(velocity: velocity)
            onShown?(nil)
        case .stay(let velocity):
            haptics.fire(.readerDragReturn)
            returnToRest(velocity: velocity)
        }
    }

    func dragCancelled() {
        presence = nil
        returnToRest(velocity: 0)
    }

    // A reader taken during its close is open again once it returns.
    private func returnToRest(velocity: CGFloat) {
        if !isOpen {
            isOpen = true
            onShown?(article)
        }
        nextTransition()
        move(to: 0, on: Theme.Motion.readerReturn, velocity: velocity) {}
    }

    // Only a moving or caught reader is taken, by a mostly vertical drag; at rest its page scrolls.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === catcher {
            return catchMayBegin
        }
        // The pinch always may begin; eligibility is decided at fire time in the tab.
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return (motion != nil || catchMayBegin) && abs(velocity.y) > abs(velocity.x)
    }

    // The article's scrolling begins on touch-down and would otherwise keep the pan from starting. The pan runs
    // alongside it, and when it begins it cancels it (cancelTouchSharers).
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

extension WKWebView {
    // The page sits under the bars, which cover these insets, and scrolls its content clear of them.
    func setObscuredInsets(_ insets: UIEdgeInsets) {
        obscuredContentInsets = insets
        scrollView.contentInset = insets
        scrollView.verticalScrollIndicatorInsets = insets
        scrollView.horizontalScrollIndicatorInsets = insets
    }
}
