import UIKit

// Replaces the plist key at runtime; the plist stays portrait-only for check-release.sh. Scene delegate at iOS 27.
final class AppDelegate: NSObject, UIApplicationDelegate {
    // Set by the app's init: the delegate adaptor is not reachable there, and a push that launches the app in the
    // background may never build the scene.
    static var remoteNotification: (@MainActor () async -> Void)?

    // One app-wide mask, never per window: UIKit evaluates ours while WebKit's fullscreen window is key.
    func application(
        _ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationPolicy.shared.mask
    }

    // The silent push of the Mac tabs subscription.
    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        await Self.remoteNotification?()
        return .newData
    }
}
