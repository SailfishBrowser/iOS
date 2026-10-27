import UIKit

// The system's leave to keep running after the app has left the foreground, for the flush that saves its state.
struct BackgroundAssertion {
    // Begins a named assertion; returns its end. The expiration handler calls `expired` on the main actor.
    var begin: @MainActor (_ name: String, _ expired: @escaping @MainActor @Sendable () -> Void) -> (@MainActor () -> Void)

    // Every begin is balanced by one end, and an assertion the system refused is never ended.
    static let live = BackgroundAssertion(begin: { name, expired in
        let task = UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expired)
        return {
            guard task != .invalid else { return }
            UIApplication.shared.endBackgroundTask(task)
        }
    })
}
