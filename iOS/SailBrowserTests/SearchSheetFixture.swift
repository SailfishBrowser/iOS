import UIKit
@testable import SailBrowser

// A search sheet hosted as the root of its own key window and set active, as a tap on the pill opens it. Each test then
// waits for the state it needs: the keyboard shown, the rest learnt, or just the first layout.
@MainActor
func hostedSearchSheet(_ env: AppEnvironment = makeEnvironment()) -> (SearchSheetController, UIWindow) {
    let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
    let window = UIWindow(windowScene: scene)
    let controller = SearchSheetController(
        model: SearchModel(history: env.history, service: SuggestionService(), engine: { .google }), env: env)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    controller.setActive(true, submitting: false)
    return (controller, window)
}
