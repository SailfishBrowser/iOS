import UIKit
import WebKit

// A page's alerts, confirms, prompts and sign-in requests, shown one at a time across all pages as system alerts. The
// camera and microphone prompt takes the same turn.
final class PageDialogs {
    static let muteTitle = "Don't allow more dialogs from this page"

    private static var isTurnTaken = false
    private static var waiting: [CheckedContinuation<Void, Never>] = []

    private(set) var current: PageDialog?
    private var shown = 0
    private var isMuted = false

    func pageCommitted() {
        shown = 0
        isMuted = false
    }

    func alert(_ message: String, host: String, in webView: WKWebView) async {
        await show(title: host, message: message, cancel: (), isPage: true, in: webView) { dialog, answer in
            dialog.add("OK", style: .default) { answer(()) }
        }
    }

    func confirm(_ message: String, host: String, in webView: WKWebView) async -> Bool {
        await show(title: host, message: message, cancel: false, isPage: true, in: webView) { dialog, answer in
            dialog.add("Cancel", style: .cancel) { answer(false) }
            dialog.add("OK", style: .default) { answer(true) }
        }
    }

    // A page that jumps to another app's link on its own asks first, as Safari does, and counts as one of its dialogs.
    func openApp(_ app: String, in webView: WKWebView) async -> Bool {
        await show(title: "Open in “\(app)”?", message: nil, cancel: false, isPage: true, in: webView) { dialog, answer in
            dialog.add("Cancel", style: .cancel) { answer(false) }
            dialog.add("Open", style: .default) { answer(true) }
        }
    }

    func prompt(_ message: String, defaultText: String?, host: String, in webView: WKWebView) async -> String? {
        await show(title: host, message: message, cancel: nil, isPage: true, in: webView) { dialog, answer in
            dialog.alert.addTextField { $0.text = defaultText }
            let field = dialog.alert.textFields![0]
            dialog.add("Cancel", style: .cancel) { answer(nil) }
            dialog.add("OK", style: .default) { answer(field.text ?? "") }
        }
    }

    func signIn(host: String, in webView: WKWebView) async -> URLCredential? {
        await show(title: host, message: nil, cancel: nil, isPage: false, in: webView) { dialog, answer in
            dialog.alert.addTextField {
                $0.placeholder = "User Name"
                $0.textContentType = .username
            }
            dialog.alert.addTextField {
                $0.placeholder = "Password"
                $0.textContentType = .password
                $0.isSecureTextEntry = true
            }
            let fields = dialog.alert.textFields!
            dialog.add("Cancel", style: .cancel) { answer(nil) }
            dialog.add("Log In", style: .default) {
                answer(URLCredential(user: fields[0].text ?? "", password: fields[1].text ?? "", persistence: .forSession))
            }
        }
    }

    // A page off screen gets the cancel answer at once, and a shown dialog whose page leaves the screen is dismissed
    // with it. A dialog raised while another is up waits its turn. A page's own dialogs (not sign-in) count toward
    // offering a way to silence the rest until its next commit.
    private func show<Answer: Sendable>(
        title: String, message: String?, cancel: Answer, isPage: Bool, in webView: WKWebView,
        build: (PageDialog, @escaping (Answer) -> Void) -> Void
    ) async -> Answer {
        guard !(isPage && isMuted), webView.window != nil else { return cancel }
        await Self.takeTurn()
        guard !(isPage && isMuted), webView.window != nil else {
            Self.endTurn()
            return cancel
        }
        return await withCheckedContinuation { continuation in
            let dialog = PageDialog(title: title.isEmpty ? nil : title, message: message)
            let answer: (Answer) -> Void = { [unowned self] value in
                dialog.close(then: Self.endTurn)
                current = nil
                continuation.resume(returning: value)
            }
            build(dialog, answer)
            if isPage {
                shown += 1
                if shown > Theme.Gesture.dialogMuteAfter {
                    dialog.add(Self.muteTitle, style: .default) { [unowned self] in
                        isMuted = true
                        answer(cancel)
                    }
                }
            }
            dialog.onCancel = { answer(cancel) }
            current = dialog
            dialog.present(over: webView)
        }
    }

    static func takeTurn() async {
        guard isTurnTaken else {
            isTurnTaken = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    static func endTurn() {
        if waiting.isEmpty {
            isTurnTaken = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

final class PageDialog {
    let alert: UIAlertController
    fileprivate var onCancel: () -> Void = {}
    private var answers: [UIAlertAction: () -> Void] = [:]
    private let watch = WindowWatch()

    fileprivate init(title: String?, message: String?) {
        alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    }

    fileprivate func add(_ title: String, style: UIAlertAction.Style, answer: @escaping () -> Void) {
        let action = UIAlertAction(title: title, style: style) { [unowned self] in choose($0) }
        answers[action] = answer
        alert.addAction(action)
    }

    // What a tap on the action does; the action's own handler calls this after UIKit starts the dismissal.
    func choose(_ action: UIAlertAction) {
        answers[action]!()
    }

    fileprivate func present(over webView: WKWebView) {
        watch.isHidden = true
        watch.onLeaveWindow = { [unowned self] in onCancel() }
        webView.addSubview(watch)
        webView.window!.presentOnTop(alert, animated: true) { [weak self] in self?.answers.isEmpty == false }
    }

    // The next dialog waits until this one is off screen, since UIKit cannot present over a dismissing alert. A dismiss
    // during the alert's own presentation is dropped by UIKit, so any running transition ends first.
    fileprivate func close(then done: @escaping () -> Void) {
        watch.onLeaveWindow = nil
        watch.removeFromSuperview()
        answers = [:]
        onCancel = {}
        let alert = alert
        let finish = { alert.presentingViewController == nil ? done() : alert.dismiss(animated: true, completion: done) }
        guard let coordinator = alert.transitionCoordinator else { return finish() }
        coordinator.animate(alongsideTransition: nil) { _ in finish() }
    }
}

extension UIWindow {
    // UIKit drops a present on a controller mid-transition, so this waits for a sheet animating in or out and then
    // looks again. A controller no longer wanted meanwhile is not shown.
    func presentOnTop(_ controller: UIViewController, animated: Bool, while wanted: @escaping () -> Bool) {
        var top = rootViewController!
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        guard let coordinator = top.presentedViewController?.transitionCoordinator ?? top.transitionCoordinator else {
            return top.present(controller, animated: animated)
        }
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self, wanted() else { return }
            presentOnTop(controller, animated: animated, while: wanted)
        }
    }
}

// Rides inside the page's web view so a dialog learns when its page leaves the screen: a tab switch, close or eviction.
final class WindowWatch: UIView {
    var onLeaveWindow: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            onLeaveWindow?()
        }
    }
}
