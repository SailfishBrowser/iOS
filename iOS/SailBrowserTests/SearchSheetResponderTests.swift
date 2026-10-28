import Testing
import UIKit
@testable import SailBrowser

// The phone traced 12 to 25 ms of first-responder change inside the first frame of the open and Go. Each entry point is
// triggered as a touch is, and its motion's first frame must be committed when the field's responder changes.
@MainActor @Suite(.serialized)
struct SearchSheetResponderTests {
    private func risen() async throws -> (SearchSheetController, UIWindow) {
        let (controller, window) = hostedSearchSheet()
        try await waitUntil { controller.keyboardShown }
        return (controller, window)
    }

    private func closed() async throws -> (SearchSheetController, UIWindow) {
        let (controller, window) = try await risen()
        controller.setActive(false, submitting: false)
        try await waitUntil { controller.container.isHidden && !controller.keyboardShown }
        return (controller, window)
    }

    // When the field's responder changes, the motion's first frame must be committed: Core Animation stamps an
    // animation's begin time at its commit, and the presented sheet shows a grab's first write once it is committed.
    private func expectCommittedAtResponderChange(
        _ controller: SearchSheetController, committed: @escaping () -> Bool, _ action: @escaping () -> Void
    ) async throws {
        let watch = ResponderWatch(controller.field, committed: committed)
        await likeATouch(action)
        try await waitUntil(timeout: .seconds(1)) { watch.committed != nil }
        watch.stop()
        #expect(watch.committed == true)
    }

    private func transformCommitted(_ controller: SearchSheetController) -> () -> Bool {
        { (controller.container.layer.animation(forKey: "transform")?.beginTime ?? 0) > 0 }
    }

    @Test(.timeLimit(.minutes(1)))
    func theOpenFocusesOnceItsFirstFrameIsCommitted() async throws {
        let (controller, window) = try await closed()
        try await expectCommittedAtResponderChange(controller, committed: transformCommitted(controller)) {
            controller.setActive(true, submitting: false)
        }
        #expect(controller.field.isFirstResponder)
        window.isHidden = true
    }

    @Test(.timeLimit(.minutes(1)))
    func goResignsOnceItsFirstFrameIsCommitted() async throws {
        let (controller, window) = try await risen()
        try await expectCommittedAtResponderChange(controller, committed: transformCommitted(controller)) {
            controller.setActive(false, submitting: true)
        }
        window.isHidden = true
    }

    // A close inside the open's first frame finds the sheet drawn at the bar, with nothing left to travel; it still runs
    // its top spring, from which every step of the close counts.
    @Test(.timeLimit(.minutes(1)), .timingSensitive)
    func aCloseInsideTheOpensFirstFrameStillRunsItsTopSpring() async throws {
        let (controller, window) = try await closed()
        controller.setActive(true, submitting: false)
        controller.setActive(false, submitting: false)
        let top = try #require(controller.container.layer.animation(forKey: "transform") as? CASpringAnimation)
        let from = try #require(top.fromValue as? NSValue).caTransform3DValue
        #expect(abs(from.m42 - controller.container.layer.transform.m42) < 0.5)
        #expect(abs(top.stiffness - Theme.Motion.searchTapClose.spring.stiffness) < 1e-6)
        #expect(top.initialVelocity == Theme.Motion.searchTapCloseVelocity)
        try await waitUntil(timeout: .seconds(1)) { controller.container.isHidden }
        window.isHidden = true
    }

    // A keystroke's own turn takes the text and the inline completion, so the field syncs with its keyboard once; the
    // ranking and the rows follow its commit.
    @Test(.timeLimit(.minutes(1)))
    func aKeystrokesRankingRunsOnTheTurnAfterItsCommit() async throws {
        let env = makeEnvironment()
        env.history.recordVisit(url: URL(string: "https://github.com/")!, title: "GitHub")
        let (controller, window) = hostedSearchSheet(env)
        try await waitUntil { controller.keyboardShown }
        let before = controller.model.rows
        _ = controller.textField(
            controller.field, shouldChangeCharactersInRanges: [NSValue(range: NSRange(location: 0, length: 0))],
            replacementString: "g")
        controller.field.insertText("g")
        #expect(controller.model.text == "g")
        #expect(controller.field.text == "github.com")
        #expect(controller.model.rows == before)
        await afterTheCommit()
        #expect(controller.model.rows.contains(.query("g")))
        window.isHidden = true
    }

    // The keyboard notifications are app-wide: a web form's keyboard, with its accessory bar, never teaches the rest.
    @Test(.timeLimit(.minutes(1)))
    func aKeyboardShownForAnotherResponderLeavesTheRest() async throws {
        let (controller, window) = try await closed()
        let rest = try #require(controller.restTop)
        let form = UITextField()
        form.inputAccessoryView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        controller.view.addSubview(form)
        form.becomeFirstResponder()
        try await waitUntil { controller.keyboardShown }
        controller.dragBegan()
        #expect(controller.restTop == rest)
        form.resignFirstResponder()
        window.isHidden = true
    }
}

// Returns on the turn after the run loop's next commit, once any work the code under test queued there has run.
@MainActor func afterTheCommit() async {
    await withCheckedContinuation { done in AfterCommit.run { done.resume() } }
}

// Runs `action` as UIKit delivers a touch: from a run-loop source, after which a block sent to the main queue still runs
// before the run loop's next commit.
@MainActor func likeATouch(_ action: @escaping () -> Void) async {
    await withCheckedContinuation { done in
        TouchSource {
            action()
            done.resume()
        }.signal()
    }
}

@MainActor private final class TouchSource {
    private let action: () -> Void
    private var source: CFRunLoopSource?

    init(_ action: @escaping () -> Void) {
        self.action = action
        var context = CFRunLoopSourceContext()
        context.info = Unmanaged.passRetained(self).toOpaque()
        context.perform = { info in
            let touch = Unmanaged<TouchSource>.fromOpaque(info!).takeRetainedValue()
            MainActor.assumeIsolated { touch.fire() }
        }
        source = CFRunLoopSourceCreate(nil, 0, &context)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func signal() {
        CFRunLoopSourceSignal(source)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func fire() {
        CFRunLoopSourceInvalidate(source)
        action()
    }
}

// Records, the moment a field's first responder changes, whether `committed` holds then.
@MainActor final class ResponderWatch: NSObject {
    private(set) var committed: Bool?
    private let check: () -> Bool

    init(_ field: UITextField, committed check: @escaping () -> Bool) {
        self.check = check
        super.init()
        for name in [UITextField.textDidBeginEditingNotification, UITextField.textDidEndEditingNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: name, object: field)
        }
    }

    @objc private func changed() {
        guard committed == nil else { return }
        committed = check()
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
    }
}
