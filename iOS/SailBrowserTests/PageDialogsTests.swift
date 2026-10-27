import Testing
import UIKit
import UIKit.UIGestureRecognizerSubclass
import WebKit
@testable import SailBrowser

@Suite(.serialized)
struct PageDialogsTests {
    private static let confirmPage = "<script>document.title = String(confirm('x'))</script>"

    @Test func confirmAnswersWithTheTappedAction() async throws {
        let server = try await LocalPageServer { _ in Self.confirmPage }
        let (controller, window) = hostedPage()
        defer { window.isHidden = true }

        controller.load(server.url("/page"))
        let dialog = try await shownDialog(controller)
        #expect(dialog.alert.title == "127.0.0.1")
        #expect(dialog.alert.message == "x")
        #expect(dialog.alert.preferredStyle == .alert)
        dialog.tap("OK")
        try await waitUntil { controller.webView.title == "true" }

        controller.reload()
        try await shownDialog(controller).tap("Cancel")
        try await waitUntil { controller.webView.title == "false" }
    }

    @Test func offScreenConfirmAnswersFalseWithoutPresenting() async throws {
        let server = try await LocalPageServer { _ in Self.confirmPage }
        let controller = WebTabController(tabID: UUID(), webView: PageWebView(), haptics: recordingHaptics())

        controller.load(server.url("/page"))
        try await waitUntil { controller.webView.title == "false" }
        #expect(controller.dialogs.current == nil)
    }

    @Test func promptReturnsTheTypedTextAndAlertWaitsForOK() async throws {
        let page = """
            <script>alert('hi'); document.title = prompt('name?', 'sail') + ',' + prompt('again?')</script>
            """
        let server = try await LocalPageServer { _ in page }
        let (controller, window) = hostedPage()
        defer { window.isHidden = true }

        controller.load(server.url("/page"))
        try await shownDialog(controller).tap("OK")
        let prompt = try await shownDialog(controller)
        #expect(prompt.alert.textFields?.first?.text == "sail")
        prompt.alert.textFields![0].text = "search"
        prompt.tap("OK")
        try await shownDialog(controller).tap("Cancel")
        try await waitUntil { controller.webView.title == "search,null" }
    }

    @Test func basicSignInLoadsTheProtectedPage() async throws {
        let server = try await LocalPageServer(signIn: "ada:secret") { _ in "<title>protected</title>" }
        let (controller, window) = hostedPage()
        defer { window.isHidden = true }

        controller.load(server.url("/page"))
        let dialog = try await shownDialog(controller)
        #expect(dialog.alert.title == "127.0.0.1")
        let fields = dialog.alert.textFields!
        #expect(fields.count == 2)
        #expect(fields[1].isSecureTextEntry)
        fields[0].text = "ada"
        fields[1].text = "secret"
        dialog.tap("Log In")
        try await waitUntil { controller.webView.title == "protected" }
    }

    @Test func cancelledSignInLeavesThePageUnloaded() async throws {
        let server = try await LocalPageServer(signIn: "ada:secret") { _ in "<title>protected</title>" }
        let (controller, window) = hostedPage()
        defer { window.isHidden = true }

        controller.load(server.url("/page"))
        try await shownDialog(controller).tap("Cancel")
        try await waitUntil { controller.hasSettled }
        #expect(controller.webView.title != "protected")
        #expect(server.requestedPaths == ["/page"])
    }

    @Test func fourthDialogOffersMutingUntilTheNextCommit() async throws {
        let page = "<script>document.title = [0, 1, 2, 3, 4].map(i => confirm(i)).join()</script>"
        let server = try await LocalPageServer { _ in page }
        let (controller, window) = hostedPage()
        defer { window.isHidden = true }

        controller.load(server.url("/page"))
        for _ in 0..<Theme.Gesture.dialogMuteAfter {
            let dialog = try await shownDialog(controller)
            #expect(dialog.titles == ["Cancel", "OK"])
            dialog.tap("OK")
        }
        let fourth = try await shownDialog(controller)
        #expect(fourth.titles == ["Cancel", "OK", PageDialogs.muteTitle])
        fourth.tap(PageDialogs.muteTitle)
        try await waitUntil { controller.webView.title == "true,true,true,false,false" }

        controller.reload()
        let afterCommit = try await shownDialog(controller)
        #expect(afterCommit.titles == ["Cancel", "OK"])
        afterCommit.tap("Cancel")
        for _ in 1..<Theme.Gesture.dialogMuteAfter {
            try await shownDialog(controller).tap("Cancel")
        }
        try await shownDialog(controller).tap(PageDialogs.muteTitle)
        try await waitUntil { controller.webView.title == "false,false,false,false,false" }
    }

    @Test func pageLeavingTheScreenDismissesItsDialogWithCancel() async throws {
        let server = try await LocalPageServer { _ in Self.confirmPage }
        let (controller, window) = hostedPage()
        defer { window.isHidden = true }

        controller.load(server.url("/page"))
        let alert = try await shownDialog(controller).alert
        controller.webView.removeFromSuperview()
        try await waitUntil { controller.webView.title == "false" }
        #expect(controller.dialogs.current == nil)
        try await waitUntil { alert.presentingViewController == nil }
    }

    @Test func pageLeavingTheScreenWhileItsAlertRisesStillAnswersAndDismisses() async throws {
        let server = try await LocalPageServer { _ in Self.confirmPage }
        let (controller, window) = hostedPage()
        defer { window.isHidden = true }

        controller.load(server.url("/page"))
        try await waitUntil(every: .milliseconds(2)) { controller.dialogs.current != nil }
        let alert = controller.dialogs.current!.alert
        #expect(alert.isBeingPresented)
        controller.webView.removeFromSuperview()
        try await waitUntil { controller.webView.title == "false" }
        try await waitUntil { alert.presentingViewController == nil }
    }

    @Test func dialogWaitsForASheetAnimatingInOrOut() async throws {
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        let (controller, window) = hostedPage()
        defer { window.isHidden = true }
        controller.load(server.url("/page"))
        try await waitUntil { controller.hasSettled }
        let root = window.rootViewController!
        let confirm = "document.title = String(confirm('x'))"

        let sheet = UIViewController()
        root.present(sheet, animated: true)
        #expect(sheet.isBeingPresented)
        controller.webView.evaluateJavaScript(confirm, completionHandler: nil)
        let over = try await shownDialog(controller)
        #expect(over.alert.presentingViewController === sheet)
        over.tap("OK")
        try await waitUntil { controller.webView.title == "true" }

        try await waitUntil { sheet.presentedViewController == nil }
        sheet.dismiss(animated: true)
        #expect(sheet.isBeingDismissed)
        controller.webView.evaluateJavaScript(confirm, completionHandler: nil)
        let under = try await shownDialog(controller)
        #expect(under.alert.presentingViewController === root)
        under.tap("Cancel")
        try await waitUntil { controller.webView.title == "false" }
    }

    @Test func secondPagesDialogWaitsForTheFirst() async throws {
        let server = try await LocalPageServer { _ in Self.confirmPage }
        let (first, window) = hostedPage()
        let second = WebTabController(tabID: UUID(), webView: PageWebView(), haptics: recordingHaptics())
        defer { window.isHidden = true }
        second.webView.frame = window.bounds
        window.rootViewController!.view.addSubview(second.webView)

        first.load(server.url("/page"))
        let firstDialog = try await shownDialog(first)
        second.load(server.url("/page"))
        try await waitUntil { server.requestedPaths.count == 2 }
        try await Task.sleep(for: .milliseconds(500))
        #expect(second.dialogs.current == nil)
        #expect(firstDialog.alert.presentedViewController == nil)

        firstDialog.tap("OK")
        try await shownDialog(second).tap("Cancel")
        try await waitUntil { first.webView.title == "true" && second.webView.title == "false" }
    }

    @Test func thePromptWaitsForAnOpenPageDialog() async throws {
        let server = try await LocalPageServer { _ in "<script>alert('x')</script>" }
        let (controller, window) = hostedPage()
        defer { window.isHidden = true }

        controller.load(server.url("/page"))
        let alert = try await shownDialog(controller)
        let answer = asking(controller)
        for _ in 0..<10 {
            await nextDisplayFrame()
        }
        #expect(presentedPrompt(in: window) == nil)

        alert.tap("OK")
        let prompt = try await shownPrompt(in: window)
        prompt.answer(true)
        #expect(await answer.value == true)
        try await waitUntil { prompt.presentingViewController == nil }
    }

    // A touch-down on the rising prompt holds it where it is drawn, in the touch's own hit test, so the touch lands on
    // what is drawn under the finger. Let go without a drag, the sheet finishes its rise on its spring.
    @Test(.timeLimit(.minutes(1)))
    func aTouchDownMidRiseHoldsThePromptWhereItIsDrawn() async throws {
        let (controller, window) = hostedPage()
        defer { window.isHidden = true }
        let (prompt, answer, clock, drawn) = try await promptMidRise(over: controller, in: window)
        #expect(drawn.minY > prompt.container.frame.minY + 1)

        let point = CGPoint(x: drawn.midX, y: drawn.minY + 40)
        let hit = try #require(prompt.view.hitTest(point, with: TouchEvent()))
        #expect(hit.isDescendant(of: prompt.container))
        #expect(prompt.container.layer.animationKeys() == nil)
        #expect(abs(prompt.container.frame.minY - drawn.minY) < 0.5)
        #expect(abs(prompt.container.convert(point, from: prompt.view).y - 40) < 0.5)

        prompt.catchEnded()
        let rise = try #require(prompt.container.layer.animation(forKey: "transform") as? CASpringAnimation)
        #expect(abs(rise.stiffness - Theme.Motion.permissionSheet.spring.stiffness) < 0.01)
        #expect(FrameRateVote.heldUntil > CACurrentMediaTime())
        clock.resume()
        try await waitUntil { prompt.container.layer.animationKeys() == nil }
        #expect(abs(prompt.container.transform.ty) < 0.5)
        try await dismissed(prompt, answer)
    }

    // A pan from the catch takes the sheet from where it is held, without the slop the finger moved before the pan
    // began, and votes for the finger's rate until the release.
    @Test(.timeLimit(.minutes(1)))
    func aDragFromTheCatchTakesNoSlopAndVotesForTheFinger() async throws {
        let (controller, window) = hostedPage()
        defer { window.isHidden = true }
        let (prompt, answer, clock, drawn) = try await promptMidRise(over: controller, in: window)
        _ = prompt.view.hitTest(CGPoint(x: drawn.midX, y: drawn.minY + 40), with: TouchEvent())
        let held = prompt.container.frame.minY

        let pan = PromptScriptedPan()
        pan.scripted(.began, translation: 12, velocity: 400)
        #expect(prompt.gestureRecognizerShouldBegin(pan))
        prompt.route(pan)
        #expect(abs(prompt.container.frame.minY - held) < 0.5)
        #expect(prompt.presence != nil)
        pan.scripted(.changed, translation: 32, velocity: 400)
        prompt.route(pan)
        #expect(abs(prompt.container.frame.minY - (held + 20)) < 0.5)
        pan.scripted(.ended, translation: 32, velocity: 0)
        prompt.route(pan)
        #expect(prompt.presence == nil)
        #expect(prompt.isOpen)
        clock.resume()
        try await dismissed(prompt, answer)
    }

    // A pan that begins on a button cancels the button's press, so a drag that starts on it never ends in its tap.
    @Test(.timeLimit(.minutes(1)))
    func aDragBeginningOnAButtonCancelsItsPress() async throws {
        let (controller, window) = hostedPage()
        defer { window.isHidden = true }
        let answer = asking(controller)
        let prompt = try await restingPrompt(in: window)
        let frame = prompt.container.frame
        let point = CGPoint(
            x: frame.minX + frame.width * 0.75,
            y: frame.maxY - prompt.view.safeAreaInsets.bottom - Theme.Metrics.permissionButtonHeight / 2)
        let hit = try #require(prompt.view.hitTest(point, with: TouchEvent()))
        #expect(hit.isDescendant(of: prompt.container))
        let press = TrackingPress()
        hit.addGestureRecognizer(press)

        let pan = PromptScriptedPan()
        pan.scripted(.began, translation: 10, velocity: 400)
        prompt.route(pan)
        #expect(press.cancelled)
        pan.scripted(.ended, translation: 10, velocity: 0)
        prompt.route(pan)
        try await dismissed(prompt, answer)
    }

    // A cancelled pan returns the sheet to rest however far it went, and answers nothing.
    @Test(.timeLimit(.minutes(1)))
    func aCancelledDragReturnsWithoutAnswering() async throws {
        let (controller, window) = hostedPage()
        defer { window.isHidden = true }
        let answer = asking(controller)
        let prompt = try await restingPrompt(in: window)
        let rest = prompt.container.frame.minY

        let pan = PromptScriptedPan()
        pan.scripted(.began, translation: 0, velocity: 400)
        prompt.route(pan)
        pan.scripted(.changed, translation: 300, velocity: 400)
        prompt.route(pan)
        pan.scripted(.cancelled, translation: 300, velocity: 4000)
        prompt.route(pan)
        #expect(prompt.isOpen)
        #expect(prompt.container.frame.minY == rest)
        prompt.answer(false)
        #expect(await answer.value == false)
        try await waitUntil { prompt.presentingViewController == nil }
    }

    // A sheet dragged away answers only once its close lands, so a grab during the close brings it back unanswered.
    @Test(.timeLimit(.minutes(1)))
    func aDragAwayCanBeCaughtBackBeforeItAnswers() async throws {
        let (controller, window) = hostedPage()
        defer { window.isHidden = true }
        let answered = Recorded<Bool?>()
        let answer = asking(controller)
        Task { answered.values.append(await answer.value) }
        let prompt = try await restingPrompt(in: window)
        let clock = HeldClock(window.layer)

        let pan = PromptScriptedPan()
        for (state, translation) in [(UIGestureRecognizer.State.began, 0.0), (.changed, 200), (.ended, 200)] {
            pan.scripted(state, translation: translation, velocity: 0)
            prompt.route(pan)
        }
        #expect(!prompt.isOpen)
        clock.step(by: Theme.Motion.permissionSheet.spring.duration / 2)
        await nextDisplayFrame()
        #expect(answered.values.isEmpty)

        for (state, translation) in [(UIGestureRecognizer.State.began, 0.0), (.changed, -100), (.ended, -100)] {
            pan.scripted(state, translation: translation, velocity: 0)
            prompt.route(pan)
        }
        #expect(prompt.isOpen)
        clock.resume()
        try await waitUntil { prompt.motion == nil }
        #expect(answered.values.isEmpty)
        prompt.answer(true)
        #expect(await answer.value == true)
        try await waitUntil { prompt.presentingViewController == nil }
    }

    @Test(.timeLimit(.minutes(1)))
    func aDragAwayAnswersNilOnceItsCloseLands() async throws {
        let (controller, window) = hostedPage()
        defer { window.isHidden = true }
        let answer = asking(controller)
        let prompt = try await restingPrompt(in: window)

        let pan = PromptScriptedPan()
        for (state, translation) in [(UIGestureRecognizer.State.began, 0.0), (.changed, 200), (.ended, 200)] {
            pan.scripted(state, translation: translation, velocity: 0)
            prompt.route(pan)
        }
        #expect(await answer.value == nil)
        try await waitUntil { prompt.presentingViewController == nil }
    }

    // A tap on the dim over the page dismisses the prompt with no answer.
    @Test(.timeLimit(.minutes(1)))
    func aTapOnTheDimAnswersNil() async throws {
        let (controller, window) = hostedPage()
        defer { window.isHidden = true }
        let answer = asking(controller)
        let prompt = try await restingPrompt(in: window)
        #expect(prompt.view.hitTest(CGPoint(x: 10, y: 100), with: TouchEvent()) === prompt.dim)
        #expect(abs(prompt.dim.alpha - Theme.Opacity.menuDim) < 0.001)

        prompt.dimTapped()
        #expect(await answer.value == nil)
        try await waitUntil { prompt.presentingViewController == nil }
    }

    // The page leaving the screen answers nil, dismisses the prompt and frees the turn for the next.
    @Test(.timeLimit(.minutes(1)))
    func thePageLeavingTheScreenDismissesThePromptAndFreesTheTurn() async throws {
        let (controller, window) = hostedPage()
        defer { window.isHidden = true }
        let answer = asking(controller)
        let prompt = try await shownPrompt(in: window)

        controller.webView.removeFromSuperview()
        #expect(await answer.value == nil)
        try await waitUntil { prompt.presentingViewController == nil }

        window.rootViewController!.view.addSubview(controller.webView)
        let next = asking(controller)
        let second = try await shownPrompt(in: window)
        #expect(second !== prompt)
        try await dismissed(second, next)
    }

    // A prompt asked while another sheet animates in waits for it and presents on top, never under it.
    @Test(.timeLimit(.minutes(1)))
    func aPromptAskedWhileASheetRisesPresentsOnTopOfIt() async throws {
        let (controller, window) = hostedPage()
        defer { window.isHidden = true }
        let sheet = UIViewController()
        window.rootViewController!.present(sheet, animated: true)
        #expect(sheet.isBeingPresented)

        let answer = asking(controller)
        let prompt = try await shownPrompt(in: window)
        #expect(prompt.presentingViewController === sheet)
        try await dismissed(prompt, answer)
        sheet.dismiss(animated: false)
    }
}

private func asking(_ controller: WebTabController) -> Task<Bool?, Never> {
    let env = makeEnvironment()
    return Task {
        await PermissionPrompt.ask(
            host: "127.0.0.1", kinds: [.camera, .microphone], over: controller.webView, env: env)
    }
}

private func presentedPrompt(in window: UIWindow) -> PermissionPromptController? {
    var top = window.rootViewController!
    while let presented = top.presentedViewController {
        if let prompt = presented as? PermissionPromptController {
            return prompt
        }
        top = presented
    }
    return nil
}

private func shownPrompt(in window: UIWindow) async throws -> PermissionPromptController {
    try await waitUntil { presentedPrompt(in: window)?.viewIfLoaded?.window != nil }
    return presentedPrompt(in: window)!
}

private func restingPrompt(in window: UIWindow) async throws -> PermissionPromptController {
    let prompt = try await shownPrompt(in: window)
    try await waitUntil { prompt.motion == nil && prompt.container.layer.animationKeys() == nil }
    return prompt
}

// Answers the prompt and waits for it to leave, which frees the dialog turn for the next test.
private func dismissed(_ prompt: PermissionPromptController, _ answer: Task<Bool?, Never>) async throws {
    prompt.answer(false)
    #expect(await answer.value == false)
    try await waitUntil { prompt.presentingViewController == nil }
}

private final class PromptScriptedPan: UIPanGestureRecognizer {
    private var scriptedState = UIGestureRecognizer.State.possible
    private var scriptedTranslation: CGFloat = 0
    private var scriptedVelocity: CGFloat = 0

    func scripted(_ state: UIGestureRecognizer.State, translation: CGFloat, velocity: CGFloat) {
        scriptedState = state
        scriptedTranslation = translation
        scriptedVelocity = velocity
    }

    override var state: UIGestureRecognizer.State {
        get { scriptedState }
        set {}
    }

    override func translation(in view: UIView?) -> CGPoint { CGPoint(x: 0, y: scriptedTranslation) }
    override func velocity(in view: UIView?) -> CGPoint { CGPoint(x: 0, y: scriptedVelocity) }
}

// A page filling the root view of its own visible window, so its dialogs have somewhere to present.
private func hostedPage() -> (WebTabController, UIWindow) {
    let controller = WebTabController(tabID: UUID(), webView: PageWebView(), haptics: recordingHaptics())
    let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIViewController()
    controller.webView.frame = window.bounds
    window.rootViewController!.view.addSubview(controller.webView)
    window.isHidden = false
    return (controller, window)
}

// The prompt asked over the page and caught half way up its rise on the window's held clock, with its drawn frame there.
private func promptMidRise(
    over controller: WebTabController, in window: UIWindow
) async throws -> (PermissionPromptController, Task<Bool?, Never>, HeldClock, CGRect) {
    let clock = HeldClock(window.layer)
    let answer = asking(controller)
    let prompt = try await shownPrompt(in: window)
    clock.step(by: Theme.Motion.permissionSheet.spring.duration / 2)
    return (prompt, answer, clock, prompt.container.layer.presentation()!.frame)
}

// The dialog once it is on screen and done animating in, so a tap can dismiss it.
@discardableResult
private func shownDialog(_ controller: WebTabController) async throws -> PageDialog {
    try await waitUntil(timeout: .seconds(10)) {
        guard let alert = controller.dialogs.current?.alert else { return false }
        return alert.viewIfLoaded?.window != nil && !alert.isBeingPresented
    }
    return controller.dialogs.current!
}

extension PageDialog {
    var titles: [String] {
        alert.actions.map { $0.title! }
    }

    func tap(_ title: String) {
        choose(alert.actions.first { $0.title == title }!)
    }
}
